import AppKit

import PWCore

// MARK: - BannerPresenter

/// The red banner (spec §6, plan T16): one non-activating `NSPanel` per screen,
/// a 3 px red frame around it and a centred black message box with the tier
/// sentence and the time.
///
/// **It must not steal focus.** NoPeek is a menu-bar accessory, and the banner
/// is exactly the moment the user is doing something else — a capture is
/// happening *right now*. So the panels are `.nonactivatingPanel` borderless
/// `NonActivatingPanel`s that refuse key/main status and are ordered in with
/// `orderFrontRegardless()`: no `NSApp.activate`, no key-window change, no
/// effect on whatever the user is typing into. Clicking one is the dismiss
/// gesture — one click, no focus shift.
///
/// **All screens** (spec §6): one panel per `NSScreen.screens`, each covering
/// that screen's full frame, with `.canJoinAllSpaces` + `.fullScreenAuxiliary`
/// so Spaces, full-screen apps and Mission Control all show it.
///
/// **Level** comes from the config's `bannerLevel` (spec §7) and is read live on
/// every `show` through the injected `windowLevel` closure — a config reload
/// changes the next banner without rebuilding the presenter. `floating` maps to
/// `.floating`; anything else (including the default `screenSaver`) maps to
/// `.screenSaver`, which sits above Mission Control — the case this banner
/// exists for.
///
/// **Life cycle.** Auto-hide after `autoHideSeconds` (spec §6: 6 s). A second
/// `show` replaces the current banner rather than stacking; a click dismisses
/// and opens the log folder (spec §6).
///
/// The copy comes from `Strings` (`banner.org` / `banner.remote`, TH + EN per
/// spec §10) — nothing in this file hardcodes UI text. The presenter assumes
/// the `BannerPolicy` gate has already run: it is offered ORG/REMOTE events
/// only, and other tiers are a no-op.
@MainActor
final class BannerPresenter {

    // MARK: - Configuration

    /// How long a banner stays on screen (spec §6: 6 s).
    static let autoHideSeconds: TimeInterval = 6

    /// The window level to show the next banner at, read live per show.
    private let windowLevel: () -> NSWindow.Level

    /// Opened in Finder when a banner is clicked (spec §6: "เปิด events log").
    private let logDirectoryURL: URL

    /// Overridable so a test could shorten it; the app uses the spec value.
    private let autoHideSeconds: TimeInterval

    // MARK: - State

    /// The panels currently on screen — one per screen, newest show only.
    private var panels: [NSPanel] = []
    /// The pending auto-hide; cancelled and replaced by every show/dismiss.
    private var hideWork: DispatchWorkItem?

    // MARK: - Init

    /// - Parameters:
    ///   - windowLevel: source of the panel level, read live on every `show`
    ///     (point it at `configStore.config.bannerLevel`).
    ///   - logDirectoryURL: the folder a click opens in Finder.
    ///   - autoHideSeconds: how long a banner stays up (spec §6: 6 s).
    init(
        windowLevel: @escaping () -> NSWindow.Level,
        logDirectoryURL: URL,
        autoHideSeconds: TimeInterval = BannerPresenter.autoHideSeconds
    ) {
        self.windowLevel = windowLevel
        self.logDirectoryURL = logDirectoryURL
        self.autoHideSeconds = autoHideSeconds
    }

    // MARK: - Level mapping

    /// The config's `bannerLevel` → `NSWindow.Level` (spec §6/§7). `floating` is
    /// the explicit alternative; every other value — the `screenSaver` default
    /// included, and any unknown string — gets `.screenSaver`. Unknown values
    /// land on the default rather than a half-visible banner: a config typo must
    /// not be the reason an ORG banner is missed.
    static func windowLevel(forBannerLevel name: String) -> NSWindow.Level {
        name == "floating" ? .floating : .screenSaver
    }

    // MARK: - Showing

    /// Puts the tier's sentence on every screen. Called on the main actor (the
    /// app hops from the pipeline sink; the `BannerPolicy` decision has already
    /// been made on the sink's serial queue).
    ///
    /// `tier` selects the copy — `org` → `banner.org`, `remote` →
    /// `banner.remote`; any other tier is a no-op (see the class note).
    func show(tier: Tier, actor: String, kind: String, lang: Language) {
        guard let key = Self.copyKey(for: tier) else { return }

        // One banner at a time: a newer event replaces the one on screen
        // rather than stacking panels the user would have to chase.
        dismiss()

        let message = String(format: Strings.t(key, lang), actor, kind)
        let time = Self.timeFormatter.string(from: Date())
        let level = windowLevel()

        for screen in NSScreen.screens {
            let panel = makePanel(screen: screen, level: level, message: message, time: time)
            panels.append(panel)
            // Shown without activating NoPeek and without taking key status
            // (see the class note): `.nonactivatingPanel` + `canBecomeKey ==
            // false` in `NonActivatingPanel`, and this call never activates.
            panel.orderFrontRegardless()
        }

        let work = DispatchWorkItem { [weak self] in
            self?.dismiss()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + autoHideSeconds, execute: work)
    }

    /// Takes every banner down and cancels the pending auto-hide. Safe when
    /// nothing is showing.
    func dismiss() {
        hideWork?.cancel()
        hideWork = nil
        for panel in panels {
            panel.orderOut(nil)
            panel.close()
        }
        panels.removeAll()
    }

    // MARK: - Panel construction

    /// `org` / `remote` copy keys, `nil` for the tiers that never banner
    /// (spec §5).
    private static func copyKey(for tier: Tier) -> String? {
        switch tier {
        case .org: "banner.org"
        case .remote: "banner.remote"
        case .normal, .systemNoise, .allowlist: nil
        }
    }

    private func makePanel(screen: NSScreen, level: NSWindow.Level, message: String, time: String) -> NSPanel {
        let panel = NonActivatingPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // `isFloatingPanel` is set *before* the explicit level: flipping the
        // flag raises an NSPanel to `.floating`, and the config's level must
        // win (setting the level first leaves the panel at CGWindow layer 3
        // instead of the configured 1000).
        panel.isFloatingPanel = true
        panel.level = level
        panel.hidesOnDeactivate = false
        // Not `.moveToActiveSpace`: the banner must appear on the Space the
        // user is on, under Mission Control, and over a full-screen app.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Swift `close()` on a released-on-close panel would over-release it.
        panel.isReleasedWhenClosed = false
        panel.setFrame(screen.frame, display: false)

        let content = BannerView(frame: NSRect(origin: .zero, size: screen.frame.size))
        content.onClick = { [weak self] in
            guard let self else { return }
            self.dismiss()
            self.openLogFolder()
        }
        panel.contentView = content
        content.configure(message: message, time: time)

        return panel
    }

    /// The click gesture (spec §6): dismiss, then reveal today's evidence in
    /// Finder. The directory is created first so the click always lands
    /// somewhere, even on a fresh install with no events yet.
    private func openLogFolder() {
        try? FileManager.default.createDirectory(
            at: logDirectoryURL,
            withIntermediateDirectories: true
        )
        NSWorkspace.shared.open(logDirectoryURL)
    }

    /// `HH:mm:ss` in the machine's locale-independent 24 h form; the banner
    /// shows when the event was seen, like the spec's "+ เวลา".
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

// MARK: - NonActivatingPanel

/// A panel that can never become key or main, so showing it cannot move focus
/// away from what the user is doing (spec §6). Structural rather than
/// best-effort: even a stray `makeKey()` would be a no-op.
private final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - BannerView

/// One screen's banner surface: the 3 px red frame, the centred message box,
/// and the whole-surface click target.
private final class BannerView: NSView {

    /// The frame around each screen (spec §6: 3 px).
    private static let borderWidth: CGFloat = 3

    /// Invoked on the next mouse-down anywhere in the banner.
    var onClick: (() -> Void)?

    /// The centred box, filled by `configure(message:time:)`.
    private let box = NSView()
    private let messageLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BannerView is created in code only")
    }

    /// The whole surface is one click target: no subview (box, labels) may
    /// swallow the dismiss gesture.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    /// Accept the *first* mouse-down while NoPeek is inactive — the banner's
    /// normal context, since it pops up over whatever app the user is in. The
    /// AppKit first-mouse rule withholds that click from a view that returns
    /// `false` (the default), and this view has no `NSButton`-style control to
    /// accept it on its behalf; without this the pinned "one click = dismiss +
    /// open the log folder" would silently need two clicks.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    /// Fills the copy. Separate from `init` so the panel's content view exists
    /// and has its screen-sized frame before the labels are laid out.
    func configure(message: String, time: String) {
        messageLabel.stringValue = message
        messageLabel.preferredMaxLayoutWidth = bounds.width * 0.7
        timeLabel.stringValue = time
        setAccessibilityLabel(message)
    }

    // MARK: - Layout

    private func setUp() {
        wantsLayer = true
        layer?.borderWidth = Self.borderWidth
        layer?.borderColor = NSColor.systemRed.cgColor
        layer?.backgroundColor = NSColor.clear.cgColor

        box.translatesAutoresizingMaskIntoConstraints = false
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        box.layer?.cornerRadius = 14
        box.layer?.borderWidth = 2
        box.layer?.borderColor = NSColor.systemRed.cgColor
        addSubview(box)

        messageLabel.font = .systemFont(ofSize: 28, weight: .bold)
        messageLabel.textColor = .white
        messageLabel.alignment = .center
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 0

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .regular)
        timeLabel.textColor = NSColor.white.withAlphaComponent(0.75)
        timeLabel.alignment = .center

        let stack = NSStackView(views: [messageLabel, timeLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)

        NSLayoutConstraint.activate([
            box.centerXAnchor.constraint(equalTo: centerXAnchor),
            box.centerYAnchor.constraint(equalTo: centerYAnchor),
            box.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.9),
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: 30),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -22),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 40),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -40),
        ])
    }
}
