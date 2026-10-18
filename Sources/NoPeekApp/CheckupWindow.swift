import AppKit

import PWCore

// MARK: - CheckupWindowController

/// The System Checkup window (plan T19 step 5, spec §6 `System Checkup…`): a
/// snapshot of the channels this Mac has open, one row per check, each with its
/// severity in colour and — where a pane exists — a `เปิด System Settings`
/// button that deep-links to it.
///
/// **It is a renderer.** The probes live in `CheckupService` (PWCore); this type
/// owns a window, one row per item and the deep links, and draws whatever report
/// the last run produced. The report carries its own timestamp
/// (`checkup.generated`), so a window left open cannot be mistaken for live
/// truth: the only things that refresh it are `ตรวจใหม่` and re-opening it from
/// the menu.
///
/// **The probes run off the main thread.** `run()` spawns three short-lived
/// commands and lists the process table; doing that on the main actor would
/// freeze the window it is about to draw. `startRun` therefore opens the window
/// immediately in its `กำลังตรวจสอบ…` state, runs the checkup in a detached task,
/// and comes back to the main actor to draw — with a single run in flight, so a
/// double click cannot stack reports.
///
/// **Dependencies are the two things it reads**: the service it draws, and the
/// config's language (read per refresh, so a live language switch re-renders).
/// All copy comes from `Strings` (spec §10). The `onRun` hook is the app's way
/// in for the spec §8 `checkup-run` lifecycle line — set after construction,
/// because the app builds this window before its own lazy components exist.
@MainActor
final class CheckupWindowController: NSObject, NSWindowDelegate {

    /// Content width and the padding the stack keeps inside it; the height is
    /// measured from the content, so a longer detail line in one language never
    /// clips.
    private static let contentWidth: CGFloat = 560
    private static let padding: CGFloat = 20

    /// The width text has to wrap in: the content width minus the stack's
    /// padding. Labels are given it as their `preferredMaxLayoutWidth`, which is
    /// what makes a multi-line label report the height it will really need.
    private static var textWidth: CGFloat { contentWidth - 2 * padding }

    private let checkup: CheckupService
    private let language: () -> Language

    /// Fired once per **started** run — before the probes go out. The app hangs
    /// the spec §8 `checkup-run` lifecycle line here (`AppController` wires it
    /// after construction), so a re-run from the window is recorded exactly like
    /// the menu's first one, and a run suppressed because one was already in
    /// flight is not recorded twice.
    var onRun: () -> Void = {}

    private var window: NSWindow?
    private var contentStack: NSStackView?
    private var introLabel: NSTextField?
    private var generatedLabel: NSTextField?
    private var summaryLabel: NSTextField?
    private var rowsStack: NSStackView?
    private var rerunButton: NSButton?
    private var closeButton: NSButton?

    /// The last finished report; `nil` while the first run is in flight.
    private var report: CheckupReport?
    private var isRunning = false

    init(
        checkup: CheckupService,
        language: @escaping () -> Language
    ) {
        self.checkup = checkup
        self.language = language
        super.init()
    }

    // MARK: - Life cycle

    /// Shows the window, building it on first use, and takes a fresh snapshot.
    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        startRun()
    }

    // MARK: - Running

    /// Runs the checkup on a background queue, then draws it on the main actor.
    /// A no-op while a run is in flight (`ตรวจใหม่` double click, a re-open
    /// while the first report is still coming).
    private func startRun() {
        guard !isRunning else { return }
        isRunning = true
        report = nil
        refresh()
        onRun()

        // The probes are synchronous I/O, so the run is a detached task — off
        // the main actor, where the three commands and the process listing
        // cannot freeze the window they are about to fill — while the drawing
        // lands back on the actor this type lives on.
        let checkup = self.checkup
        Task { [weak self] in
            let report = await Task.detached(priority: .userInitiated) { checkup.run() }.value
            guard let self else { return }
            self.isRunning = false
            self.report = report
            self.refresh()
        }
    }

    // MARK: - Refresh

    /// Redraws every line from the last report (or the loading state).
    private func refresh() {
        let language = self.language()
        window?.title = Strings.t("checkup.title", language)
        introLabel?.stringValue = Strings.t("checkup.intro", language)
        rerunButton?.title = Strings.t("checkup.button.rerun", language)
        closeButton?.title = Strings.t("checkup.button.close", language)

        if let report {
            generatedLabel?.stringValue = String(
                format: Strings.t("checkup.generated", language),
                Self.timestamp(report.generatedAt, language: language)
            )
            summaryLabel?.stringValue = report.findingCount == 0
                ? Strings.t("checkup.summary.allOk", language)
                : String(
                    format: Strings.t("checkup.summary.findings", language),
                    String(report.findingCount)
                )
            summaryLabel?.textColor = Self.color(Self.worst(of: report))
        } else {
            generatedLabel?.stringValue = Strings.t("checkup.checking", language)
            summaryLabel?.stringValue = ""
        }

        let rows = report.map { rows(for: $0, language: language) } ?? []
        rowsStack?.setViews(rows, in: .top)
        if let rowsStack {
            for row in rows {
                row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
            }
        }
        sizeToFitContent()
    }

    /// Gives the window exactly the height its content needs at the pinned
    /// width — the row set changes between the loading state and a four-item
    /// report, and the detail lines are language-dependent. A change of a point
    /// or less is skipped so an unchanged window never twitches, and the top
    /// edge stays put.
    private func sizeToFitContent() {
        guard let window, let contentStack else { return }
        contentStack.layoutSubtreeIfNeeded()
        let height = max(contentStack.frame.height + 2 * Self.padding, 220)
        guard let content = window.contentView,
              abs(content.frame.height - height) > 1
        else { return }
        let top = window.frame.maxY
        window.setContentSize(NSSize(width: Self.contentWidth, height: height))
        window.setFrameTopLeftPoint(NSPoint(x: window.frame.minX, y: top))
    }

    // MARK: - Rows

    /// One row per item: the title and the severity word on one line, the
    /// evidence line under it, and the deep-link button when the item has a
    /// pane. The two-way division is deliberate — the fast read (colour) and
    /// the honest read (the sentence), so the row still says which state it is
    /// in when colour is unavailable.
    private func rows(for report: CheckupReport, language: Language) -> [NSView] {
        report.items.enumerated().map { index, item in
            let title = Self.label(weight: .semibold)
            title.stringValue = item.title
            title.setContentHuggingPriority(.defaultLow, for: .horizontal)
            title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let severity = Self.label(weight: .medium)
            severity.stringValue = Strings.t(Self.severityKey(item.severity), language)
            severity.textColor = Self.color(item.severity)
            severity.alignment = .right
            severity.setContentHuggingPriority(.required, for: .horizontal)
            severity.setContentCompressionResistancePriority(.required, for: .horizontal)

            let headline = NSStackView(views: [title, severity])
            headline.orientation = .horizontal
            headline.spacing = 12
            headline.alignment = .firstBaseline

            let detail = Self.label(secondary: true)
            detail.stringValue = item.detail

            let row = NSStackView(views: [headline, detail])
            row.orientation = .vertical
            row.alignment = .leading
            row.spacing = 4

            // Both lines take the full row width: the severity label right-aligns
            // against it, and the detail wraps inside it instead of running off
            // the window.
            headline.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
            detail.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true

            if item.settingsURL != nil {
                let button = NSButton(
                    title: Strings.t("checkup.open", language),
                    target: self,
                    action: #selector(openSettings(_:))
                )
                button.bezelStyle = .rounded
                button.controlSize = .small
                // The row's position in the report is the destination: the
                // rows and their tags are rebuilt together on every refresh, so
                // a tag can never point past the report it was made for.
                button.tag = index
                row.addArrangedSubview(button)
            }
            return row
        }
    }

    // MARK: - Actions

    /// The per-item deep link. `NSWorkspace` hands the URL to System Settings,
    /// which is the whole point of the button — NoPeek never opens a pane that
    /// would need a permission of its own (spec §13).
    @objc private func openSettings(_ sender: NSButton) {
        guard let report,
              report.items.indices.contains(sender.tag),
              let url = report.items[sender.tag].settingsURL
        else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func restart(_ sender: Any?) {
        startRun()
    }

    @objc private func closeWindow(_ sender: Any?) {
        window?.performClose(nil)
    }

    // MARK: - Presentation helpers

    private static func severityKey(_ severity: Severity) -> String {
        switch severity {
        case .ok: "checkup.severity.ok"
        case .warn: "checkup.severity.warn"
        case .attention: "checkup.severity.attention"
        }
    }

    /// Traffic-light order: green = closed, orange = open but idle, red =
    /// something is happening now (or an org agent is running).
    private static func color(_ severity: Severity) -> NSColor {
        switch severity {
        case .ok: .systemGreen
        case .warn: .systemOrange
        case .attention: .systemRed
        }
    }

    /// The strongest severity in the report — the summary line's colour.
    private static func worst(of report: CheckupReport) -> Severity {
        if report.items.contains(where: { $0.severity == .attention }) { return .attention }
        if report.items.contains(where: { $0.severity == .warn }) { return .warn }
        return .ok
    }

    /// The run's timestamp in the configured language's locale: the window is
    /// read in one language at a time, and Thai's Buddhist-era short date is
    /// part of reading it the way the user's Mac would.
    private static func timestamp(_ date: Date, language: Language) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language.rawValue)
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
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
        contentStack = stack

        let intro = Self.label(secondary: true)
        introLabel = intro
        stack.addArrangedSubview(intro)

        let generated = Self.label(weight: .medium)
        generatedLabel = generated
        stack.addArrangedSubview(generated)

        let summary = Self.label(weight: .medium)
        summaryLabel = summary
        stack.addArrangedSubview(summary)

        // The item rows live in their own stack so a run can replace all of
        // them without touching the labels above.
        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 14
        rows.translatesAutoresizingMaskIntoConstraints = false
        rowsStack = rows
        stack.addArrangedSubview(rows)

        // Buttons on the trailing edge: a stretchable spacer takes the slack.
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let rerun = NSButton(title: "", target: self, action: #selector(restart(_:)))
        rerun.bezelStyle = .rounded
        rerunButton = rerun

        let close = NSButton(title: "", target: self, action: #selector(closeWindow(_:)))
        close.bezelStyle = .rounded
        closeButton = close

        let buttons = NSStackView(views: [spacer, rerun, close])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.alignment = .centerY
        stack.addArrangedSubview(buttons)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.padding),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Self.padding),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.padding),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            rows.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        window.center()
        return window
    }

    /// One label in the checkup's voice: no bezel, no editing, wrapping text so
    /// a long evidence line grows instead of truncating.
    private static func label(
        weight: NSFont.Weight = .regular,
        secondary: Bool = false
    ) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: weight)
        label.textColor = secondary ? .secondaryLabelColor : .labelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = textWidth
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }
}
