import AppKit

import PWCore

// MARK: - ExportPanelController

/// The Export panel (plan T20 step 5; spec §6 `Export รายงาน…`, acceptance 12):
/// three range presets, one export each, and a reveal button.
///
/// **It is a renderer.** `Exporter` (PWCore) reads the evidence log and writes
/// the three artifacts; this type owns the window, the preset buttons and the
/// result line, and draws whatever the last run produced. Nothing here knows
/// how a report is built.
///
/// **The run is off the main thread.** A 30-day export reads up to thirty day
/// files and writes three of them; doing that on the main actor would freeze
/// the window it is about to report in. `startExport` therefore draws the
/// running state immediately, exports in a detached task, and comes back to the
/// main actor to draw the result — with a single run in flight, so a double
/// click cannot stack exports (which would also fight over file names: one
/// minute is one export name).
///
/// **No TCC.** The files land in the exporter's own output directory
/// (`~/Library/Logs/NoPeek/exports`, ruling F4), and `เปิดใน Finder` reveals
/// them there; nothing here touches `~/Downloads` or any other protected
/// folder.
///
/// All copy comes from `Strings` (spec §10) through the injected language
/// closure, read on every refresh, so a live language switch re-renders. The
/// `onExported` hook is the app's way in for the spec §8 `export-created`
/// lifecycle line — set after construction, because the app wires it to the
/// lazy reader, and fired only for an export that really wrote its files.
@MainActor
final class ExportPanelController: NSObject, NSWindowDelegate {

    /// Content width and the padding the stack keeps inside it; the height is
    /// measured from the content, so a longer line in one language never clips.
    private static let contentWidth: CGFloat = 560
    private static let padding: CGFloat = 20

    /// The width text has to wrap in (see `CheckupWindowController`).
    private static var textWidth: CGFloat { contentWidth - 2 * padding }

    /// The three presets, in menu order (plan T20 step 5: 7 วัน / 30 วัน /
    /// ทั้งหมด).
    private enum Preset {
        case last7Days
        case last30Days
        case all
    }

    private struct PresetCopy {
        let titleKey: String
        let preset: Preset
    }

    private static let presets: [PresetCopy] = [
        PresetCopy(titleKey: "export.preset.7d", preset: .last7Days),
        PresetCopy(titleKey: "export.preset.30d", preset: .last30Days),
        PresetCopy(titleKey: "export.preset.all", preset: .all),
    ]

    /// One run's landing, made `Sendable` by carrying the failure as text: the
    /// panel draws the message, it never rethrows.
    private enum Outcome: Sendable {
        case success(ExportResult)
        case failure(String)
    }

    private let exporter: Exporter
    private let language: () -> Language

    /// Fired once per export that wrote its files — the app hangs the spec §8
    /// `export-created` lifecycle line here (`AppController` wires it after
    /// construction).
    var onExported: () -> Void = {}

    private var window: NSWindow?
    private var contentStack: NSStackView?
    private var introLabel: NSTextField?
    private var locationLabel: NSTextField?
    private var presetButtons: [NSButton] = []
    private var statusLabel: NSTextField?
    private var savedToLabel: NSTextField?
    private var revealButton: NSButton?
    private var closeButton: NSButton?

    /// The last successful export; `nil` until one lands (and after a failure).
    private var result: ExportResult?
    private var failureMessage: String?
    private var isRunning = false

    init(
        exporter: Exporter,
        language: @escaping () -> Language
    ) {
        self.exporter = exporter
        self.language = language
        super.init()
    }

    // MARK: - Life cycle

    /// Shows the panel, building it on first use. Unlike the checkup, opening
    /// it runs nothing: an export is a deliberate act, and the user picks the
    /// range.
    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        refresh()
    }

    // MARK: - Running

    /// The preset's window, in local days.
    ///
    /// `7 วัน` is today and the six days before it, `30 วัน` today and the
    /// twenty-nine before that — the same whole-day counting the log's own
    /// retention uses — and `ทั้งหมด` reaches back before any NoPeek log can
    /// exist. The window always ends at "the moment the button was pressed",
    /// which is what keeps lines the running pipeline appends *during* the
    /// export outside the report (see `Exporter`).
    private static func range(for preset: Preset, now: Date) -> (from: Date, to: Date) {
        let calendar = Calendar.current
        switch preset {
        case .last7Days:
            let start = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now))
            return (start ?? now, now)
        case .last30Days:
            let start = calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now))
            return (start ?? now, now)
        case .all:
            // Before the first macOS this app ever ran on, and still an
            // ordinary date (unlike `.distantPast`, which day arithmetic
            // should not be asked to reason about).
            return (Date(timeIntervalSince1970: 0), now)
        }
    }

    /// Runs the export for `preset` off the main thread; a no-op while one is
    /// already in flight.
    private func startExport(_ preset: Preset) {
        guard !isRunning else { return }
        isRunning = true
        failureMessage = nil
        refresh()

        let (from, to) = Self.range(for: preset, now: Date())
        let exporter = self.exporter
        Task { [weak self] in
            // Synchronous file I/O on a detached task: the panel's own thread
            // stays free to draw the running state.
            let outcome = await Task.detached(priority: .userInitiated) { () -> Outcome in
                do {
                    return .success(try exporter.export(from: from, to: to))
                } catch {
                    return .failure(error.localizedDescription)
                }
            }.value

            guard let self else { return }
            self.isRunning = false
            switch outcome {
            case .success(let result):
                self.result = result
                self.failureMessage = nil
                self.onExported()
            case .failure(let message):
                self.result = nil
                self.failureMessage = message
            }
            self.refresh()
        }
    }

    // MARK: - Refresh

    /// Redraws every line from the last result (or the running/failed state).
    private func refresh() {
        let language = self.language()
        window?.title = Strings.t("export.title", language)
        introLabel?.stringValue = Strings.t("export.intro", language)
        locationLabel?.stringValue = String(
            format: Strings.t("export.location", language),
            exporter.outputDirectory.path
        )

        for (button, copy) in zip(presetButtons, Self.presets) {
            button.title = Strings.t(copy.titleKey, language)
            button.isEnabled = !isRunning
        }
        revealButton?.title = Strings.t("export.reveal", language)
        revealButton?.isEnabled = !isRunning && result != nil
        closeButton?.title = Strings.t("export.button.close", language)

        if isRunning {
            statusLabel?.stringValue = Strings.t("export.running", language)
            statusLabel?.textColor = .secondaryLabelColor
            savedToLabel?.stringValue = ""
        } else if let failureMessage {
            statusLabel?.stringValue = String(
                format: Strings.t("export.failed", language),
                failureMessage
            )
            statusLabel?.textColor = .systemRed
            savedToLabel?.stringValue = ""
        } else if let result {
            statusLabel?.stringValue = result.eventCount == 0
                ? Strings.t("export.empty", language)
                : String(format: Strings.t("export.done", language), String(result.eventCount))
            statusLabel?.textColor = result.eventCount == 0 ? .secondaryLabelColor : .labelColor
            savedToLabel?.stringValue = String(
                format: Strings.t("export.savedTo", language),
                result.markdownURL.deletingLastPathComponent().path
            )
        } else {
            statusLabel?.stringValue = ""
            savedToLabel?.stringValue = ""
        }
        sizeToFitContent()
    }

    /// Gives the window exactly the height its content needs at the pinned
    /// width, keeping the top edge put (same rule as the checkup window).
    private func sizeToFitContent() {
        guard let window, let contentStack else { return }
        contentStack.layoutSubtreeIfNeeded()
        let height = max(contentStack.frame.height + 2 * Self.padding, 200)
        guard let content = window.contentView,
              abs(content.frame.height - height) > 1
        else { return }
        let top = window.frame.maxY
        window.setContentSize(NSSize(width: Self.contentWidth, height: height))
        window.setFrameTopLeftPoint(NSPoint(x: window.frame.minX, y: top))
    }

    // MARK: - Actions

    /// The preset buttons' one action; the tag is the index into `presets`,
    /// assigned where the buttons are built.
    @objc private func exportPreset(_ sender: NSButton) {
        guard Self.presets.indices.contains(sender.tag) else { return }
        startExport(Self.presets[sender.tag].preset)
    }

    /// `เปิดใน Finder`: reveals this export's three files in the folder they
    /// were written to, so the user can move or attach them — the whole reason
    /// the export does not write to `~/Downloads` itself (ruling F4).
    @objc private func reveal(_ sender: Any?) {
        guard let result else { return }
        NSWorkspace.shared.activateFileViewerSelecting([
            result.markdownURL,
            result.csvURL,
            result.ndjsonURL,
        ])
    }

    @objc private func closeWindow(_ sender: Any?) {
        window?.performClose(nil)
    }

    // MARK: - Layout

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.contentWidth, height: 260),
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

        let location = Self.label(secondary: true)
        locationLabel = location
        stack.addArrangedSubview(location)

        // The three presets sit together: one click is one export.
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.alignment = .centerY
        for index in Self.presets.indices {
            let button = NSButton(title: "", target: self, action: #selector(exportPreset(_:)))
            button.bezelStyle = .rounded
            // The tag is the preset's position, assigned here and read back in
            // `exportPreset` — the two lists are built from the same array.
            button.tag = index
            presetButtons.append(button)
            buttons.addArrangedSubview(button)
        }
        stack.addArrangedSubview(buttons)

        let status = Self.label(weight: .medium)
        statusLabel = status
        stack.addArrangedSubview(status)

        let savedTo = Self.label(secondary: true)
        savedToLabel = savedTo
        stack.addArrangedSubview(savedTo)

        // A stretchable spacer takes the slack to the trailing edge.
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let reveal = NSButton(title: "", target: self, action: #selector(reveal(_:)))
        reveal.bezelStyle = .rounded
        revealButton = reveal

        let close = NSButton(title: "", target: self, action: #selector(closeWindow(_:)))
        close.bezelStyle = .rounded
        closeButton = close

        let footer = NSStackView(views: [spacer, reveal, close])
        footer.orientation = .horizontal
        footer.spacing = 10
        footer.alignment = .centerY
        stack.addArrangedSubview(footer)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.padding),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Self.padding),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.padding),
            intro.widthAnchor.constraint(equalTo: stack.widthAnchor),
            location.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor),
            savedTo.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        window.center()
        return window
    }

    /// One label in the panel's voice: no bezel, no editing, wrapping text so a
    /// long path grows instead of truncating (same shape as the checkup's).
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
