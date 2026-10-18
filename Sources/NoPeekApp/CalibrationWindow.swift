import AppKit

import PWCore

// MARK: - CalibrationWindowController

/// The Calibration Wizard's window (plan T18 step 5, spec §6 `Calibration
/// Wizard…`): it walks the user through the three detectors — ⌘⇧5, Photo
/// Booth, Voice Memos — and shows each step's live verdict until all three
/// have one.
///
/// **It is a renderer.** The state machine is `CalibrationService` (PWCore);
/// this type owns a window, a 1 s refresh timer and a row per step, and draws
/// `calibration.status()` as it is. The timer is not a detector poller —
/// nothing here watches the system; it re-reads the service, which is what
/// makes the countdown tick and a timed-out step appear while the user does
/// nothing (the service owns no timer of its own — see its note on
/// interaction).
///
/// **Closing the window cancels the run** (`windowWillClose` →
/// `calibration.cancel()`): a wizard nobody is looking at should not keep a run
/// open, and a cancelled run is never persisted — so the first-launch
/// auto-start simply comes back on the next launch. `ทำใหม่` (Restart) starts a
/// fresh run in the same window.
///
/// **Dependencies are the three things it reads, not the whole app**: the
/// service it draws, the config's language (re-read per refresh, so T23's live
/// switch re-renders), and the `calibration.json` path whose existence the
/// `saved` line reports. All copy comes from `Strings` (spec §10).
@MainActor
final class CalibrationWindowController: NSObject, NSWindowDelegate {

    /// How often the window redraws the run: the countdown ticks at 1 Hz, and
    /// a step that runs out of time shows its verdict within a second.
    private static let refreshInterval: TimeInterval = 1

    /// Content width and the padding the stack keeps inside it; the height is
    /// measured from the content, so a longer line in one language never clips.
    private static let contentWidth: CGFloat = 480
    private static let padding: CGFloat = 20

    private let calibration: CalibrationService
    private let language: () -> Language
    private let recordURL: URL

    private var window: NSWindow?
    private var refreshTimer: Timer?

    // Views updated by `refresh()`.
    private var stack: NSStackView?
    private var introLabel: NSTextField?
    private var instructions: [CalibrationStep: NSTextField] = [:]
    private var statuses: [CalibrationStep: NSTextField] = [:]
    private var summaryLabel: NSTextField?
    private var savedLabel: NSTextField?
    private var retryButton: NSButton?
    private var closeButton: NSButton?

    /// - Parameters:
    ///   - calibration: the run to draw (the caller has already started it).
    ///   - language: read per refresh, so a config change lands without
    ///     rebuilding the window.
    ///   - recordURL: the persisted summary whose existence the `saved` line
    ///     reports (`~/Library/Application Support/NoPeek/calibration.json`).
    init(
        calibration: CalibrationService,
        language: @escaping () -> Language,
        recordURL: URL
    ) {
        self.calibration = calibration
        self.language = language
        self.recordURL = recordURL
        super.init()
    }

    // MARK: - Life cycle

    /// Shows the window, building it on first use, and starts refreshing.
    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        refresh()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        startRefreshing()
    }

    /// The user closed the window: stop drawing and abandon the run.
    func windowWillClose(_ notification: Notification) {
        stopRefreshing()
        calibration.cancel()
    }

    // MARK: - Refresh

    /// Redraws every row from the service's live status. Called once per second
    /// while the window is open and once on show.
    private func refresh() {
        let status = calibration.status()
        let language = self.language()

        window?.title = Strings.t("calib.title", language)
        introLabel?.stringValue = Strings.t("calib.intro", language)
        retryButton?.title = Strings.t("calib.button.retry", language)
        closeButton?.title = Strings.t("calib.button.close", language)

        for step in CalibrationStep.allCases {
            instructions[step]?.stringValue = Strings.t(Self.instructionKey(for: step), language)
            statuses[step]?.stringValue = statusText(for: step, status: status, language: language)
        }

        // The result line appears once every step has a verdict; the saved
        // line once the record really is on disk (the app persists on the
        // reader's queue the moment the run completes, so it lands here a tick
        // later at most).
        let complete = CalibrationStep.allCases.allSatisfy { status.results[$0] != nil }
        summaryLabel?.stringValue = complete ? summaryText(for: status, language: language) : ""
        let saved = complete
            && !status.isRunning
            && FileManager.default.fileExists(atPath: recordURL.path)
        savedLabel?.stringValue = saved ? Strings.t("calib.saved", language) : ""

        sizeToFitContent()
    }

    /// Gives the window exactly the height its content needs at the pinned
    /// width. Called after every refresh because a line appearing — the result
    /// and saved lines are empty until the run ends — needs room; a change of a
    /// point or less is skipped so an unchanged window never twitches. The top
    /// edge stays put, so a grown window never jumps on screen.
    private func sizeToFitContent() {
        guard let window, let stack else { return }
        stack.layoutSubtreeIfNeeded()
        let height = max(stack.frame.height + 2 * Self.padding, 260)
        guard let content = window.contentView,
              abs(content.frame.height - height) > 1
        else { return }
        let top = window.frame.maxY
        window.setContentSize(NSSize(width: Self.contentWidth, height: height))
        window.setFrameTopLeftPoint(NSPoint(x: window.frame.minX, y: top))
    }

    private static func instructionKey(for step: CalibrationStep) -> String {
        switch step {
        case .screen: "calib.step.screen"
        case .camera: "calib.step.camera"
        case .mic: "calib.step.mic"
        }
    }

    /// One step's status cell: the countdown while it waits, the verdict after.
    private func statusText(
        for step: CalibrationStep,
        status: CalibrationStatus,
        language: Language
    ) -> String {
        if let result = status.results[step] {
            switch result {
            case .passed(let actor):
                return String(format: Strings.t("calib.status.passed", language), actor)
            case .failed(let reason):
                return String(format: Strings.t("calib.status.failed", language), reason)
            case .timedOut:
                return Strings.t("calib.status.timeout", language)
            }
        }

        guard status.currentStep == step else {
            return Strings.t("calib.status.waiting", language)
        }

        // Rounded up: "เหลือ 1 วินาที" must not read 0 while the window is still
        // waiting. A missing remaining (a snapshot taken between steps) falls
        // back to the full window.
        let seconds = Int((status.remaining ?? calibration.timeout).rounded(.up))
        return String(format: Strings.t("calib.status.current", language), String(seconds))
    }

    /// The result line: all ✅ or "N of 3".
    private func summaryText(for status: CalibrationStatus, language: Language) -> String {
        if status.allPassed {
            return Strings.t("calib.summary.passed", language)
        }
        return String(
            format: Strings.t("calib.summary.incomplete", language),
            String(status.passedCount)
        )
    }

    // MARK: - Timer

    private func startRefreshing() {
        guard refreshTimer == nil else { return }
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func stopRefreshing() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Actions

    /// `ทำใหม่` — a fresh run, same window (spec §6's re-run, without a trip
    /// back to the menu).
    @objc private func restart(_ sender: Any?) {
        calibration.start()
        refresh()
    }

    @objc private func closeWindow(_ sender: Any?) {
        window?.performClose(nil)
    }

    // MARK: - Layout

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.contentWidth, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.delegate = self

        let content = NSView()
        window.contentView = content

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        self.stack = stack

        let intro = Self.label(secondary: true)
        introLabel = intro
        stack.addArrangedSubview(intro)

        for step in CalibrationStep.allCases {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 12
            row.alignment = .firstBaseline

            let instruction = Self.label(weight: .medium)
            let status = Self.label(secondary: true)
            status.alignment = .right
            instruction.setContentHuggingPriority(.defaultLow, for: .horizontal)
            instruction.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            status.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            status.setContentCompressionResistancePriority(.required, for: .horizontal)
            row.addArrangedSubview(instruction)
            row.addArrangedSubview(status)

            instructions[step] = instruction
            statuses[step] = status
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        let summary = Self.label(weight: .medium)
        summaryLabel = summary
        stack.addArrangedSubview(summary)

        let saved = Self.label(secondary: true)
        savedLabel = saved
        stack.addArrangedSubview(saved)

        // Buttons on the trailing edge: a stretchable spacer takes the slack.
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let retry = NSButton(title: "", target: self, action: #selector(restart(_:)))
        retry.bezelStyle = .rounded
        retryButton = retry

        let close = NSButton(title: "", target: self, action: #selector(closeWindow(_:)))
        close.bezelStyle = .rounded
        closeButton = close

        let buttons = NSStackView(views: [spacer, retry, close])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.alignment = .centerY
        stack.addArrangedSubview(buttons)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.padding),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Self.padding),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.padding),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        window.center()
        return window
    }

    /// One label in the wizard's voice: no bezel, no editing, wrapping text so
    /// a long instruction grows instead of truncating.
    private static func label(
        weight: NSFont.Weight = .regular,
        secondary: Bool = false
    ) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: weight)
        label.textColor = secondary ? .secondaryLabelColor : .labelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }
}
