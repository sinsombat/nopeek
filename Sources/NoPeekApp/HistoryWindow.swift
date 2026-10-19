import AppKit

import PWCore

// MARK: - HistoryWindowController

/// The History window (plan T22, spec §6b, acceptance 18): the evidence log read
/// back as a browsable table.
///
/// **It is a renderer.** `HistoryQuery` (PWCore) decides what the filters leave
/// on screen and in what order; `EvidenceLog.read(from:to:)` decides what is in
/// the range at all; the T21 confirm-and-kill flow and the T20 export panel are
/// the app's own and are reached through the three hooks below. Nothing about
/// *what* to show, or what an action does, is re-implemented here.
///
/// **Layout** mirrors spec §6b top to bottom: the tier segments and the
/// `ซ่อน noise` switch, the range presets and the search field, the table (เวลา /
/// tier / actor / kind / count — `×N` only when a throttled burst was folded
/// in), the selected row's detail (reason, rawSummary, pid, actorPath), and a
/// footer with `Export…` and `ปิด`. The row's own actions (`Trust`, `Kill…`,
/// `เปิดตำแหน่ง`) sit under the detail, where the row they act on is named.
///
/// **Reading happens off the main thread.** A month's range is up to thirty day
/// files and every line in them; reading that on the main actor would freeze the
/// window it is about to fill, which is why `readLog` detaches the read (the
/// same rule the checkup and export windows already follow). With one read in
/// flight at a time, a slow day cannot stack reads behind it.
///
/// **Only what is on disk.** Retention (`logRetentionDays`) is the log's own
/// business — the log directory holds the days that survived it — and
/// `EvidenceLog.read` opens only the day files the selected range can touch. So
/// the table is bounded by retention without this window knowing the number.
///
/// **Freshness**: a read on open, and every 5 s while the window is open (spec
/// §6b), with the timer invalidated when it closes. A filter change does not
/// read — it re-applies `HistoryQuery` to the events already in memory — so
/// only the day range goes back to disk. After a reload the row that was
/// selected is re-selected by *identity* (moment + actor + kind), never by row
/// number: the log grows between ticks, so row 7 of the last pass is not row 7
/// of this one.
///
/// **Dependencies are the three things it reads or relays**: the log directory
/// it reads (a read-only `EvidenceLog` is built per read inside the detached
/// task, because `EvidenceLog` is deliberately not `Sendable` — T8's one-owner
/// contract — and that is the same read path the T20 `Exporter` travels), the
/// config's language (re-read per render), and the `onTrust` / `onKill` /
/// `onExport` hooks the app wires to its own flows. All copy comes from
/// `Strings` (spec §10).
@MainActor
final class HistoryWindowController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {

    // MARK: - Pinned geometry and cadence

    /// Content size and the padding kept inside it. Unlike the other windows
    /// this one does not size itself to its content: a table is a fixed frame
    /// with a flexible middle, and the window is not resizable (the pattern of
    /// the app's other windows).
    private static let contentWidth: CGFloat = 840
    private static let contentHeight: CGFloat = 580
    private static let padding: CGFloat = 20

    /// The width text wraps in: the content width minus the padding.
    private static var textWidth: CGFloat { contentWidth - 2 * padding }

    /// Spec §6b: refresh on open and every 5 s while the window is open.
    private static let refreshInterval: TimeInterval = 5

    /// How short the table may get. Everything above it is one line of controls
    /// and everything below is the detail area, so this is the slack a longer
    /// detail line or a taller language may take before the layout is wrong.
    private static let minimumTableHeight: CGFloat = 200

    // MARK: - Table row

    /// One column of the table: its identifier, the `Strings` key of its header
    /// and its starting width. The row is the spec §6b one — เวลา / tier /
    /// actor / kind / count.
    private static let columnSpecs: [(id: NSUserInterfaceItemIdentifier, titleKey: String, width: CGFloat)] = [
        (NSUserInterfaceItemIdentifier("time"), "history.col.time", 150),
        (NSUserInterfaceItemIdentifier("tier"), "history.col.tier", 120),
        (NSUserInterfaceItemIdentifier("actor"), "history.col.actor", 210),
        (NSUserInterfaceItemIdentifier("kind"), "history.col.kind", 190),
        (NSUserInterfaceItemIdentifier("count"), "history.col.count", 70),
    ]

    private static let timeColumnID = NSUserInterfaceItemIdentifier("time")
    private static let tierColumnID = NSUserInterfaceItemIdentifier("tier")
    private static let actorColumnID = NSUserInterfaceItemIdentifier("actor")
    private static let kindColumnID = NSUserInterfaceItemIdentifier("kind")
    private static let countColumnID = NSUserInterfaceItemIdentifier("count")

    // MARK: - Filters

    /// The tier filter's four segments, in segmented order (spec §6b):
    /// ทั้งหมด / ORG / REMOTE / NORMAL. `nil` is "ทั้งหมด" — every tier, which is
    /// what `HistoryQuery` takes.
    private static let tierSegments: [Set<Tier>?] = [nil, [.org], [.remote], [.normal]]

    /// The segment's label: the pinned tier literal for a single-tier segment
    /// (the spelling the evidence log and the menu rows already use) and the one
    /// `Strings` key for "ทั้งหมด".
    private static func tierLabel(_ segment: Set<Tier>?, language: Language) -> String {
        guard let tier = segment?.first else { return Strings.t("history.tier.all", language) }
        return tier.rawValue
    }

    /// The four day-range presets (spec §6b), in segmented order.
    private enum RangePreset: Int, CaseIterable {
        case today
        case last7Days
        case last30Days
        case all

        var titleKey: String {
            switch self {
            case .today: "history.range.today"
            case .last7Days: "history.range.7d"
            case .last30Days: "history.range.30d"
            case .all: "history.range.all"
            }
        }

        /// The window to read, in local days.
        ///
        /// `วันนี้` is today from `startOfDay`; `7 วัน` / `30 วัน` are today plus
        /// the six / twenty-nine days before it — the same whole-day counting
        /// the log's own retention uses — and `ทั้งหมด` reaches back before any
        /// NoPeek log can exist, which leaves the read bounded by what is on
        /// disk rather than by the preset. The window always ends *now*: the
        /// next tick re-reads it.
        func range(now: Date, calendar: Calendar = .current) -> (from: Date, to: Date) {
            switch self {
            case .today:
                return (calendar.startOfDay(for: now), now)
            case .last7Days:
                let start = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now))
                return (start ?? now, now)
            case .last30Days:
                let start = calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now))
                return (start ?? now, now)
            case .all:
                return (.distantPast, now)
            }
        }
    }

    // MARK: - Dependencies

    /// The evidence log directory the table reads: `~/Library/Logs/NoPeek` in
    /// the app. See the class note on why reads build their own `EvidenceLog`.
    private let logDirectory: URL

    /// Read per render, so a live language switch (T23) re-renders the window.
    private let language: () -> Language

    // MARK: - Hooks (wired by the app after construction)

    /// Fired for the detail area's `Trust` with the selected row's actor:
    /// `AppController.trust`, which is the menu's `Trust แอปนี้…` write
    /// (`ConfigStore.update` over the allowlist). Throws when the config could
    /// not be written, and the window reports that exactly as the menu does.
    var onTrust: (String) throws -> Void = { _ in }

    /// Fired for `Kill…` with the selected row's target: the whole T21 manual
    /// flow (confirm dialog → signals → EPERM admin prompt → `process-kill`
    /// line). Returns the status line to show, or `nil` when the user cancelled.
    var onKill: @MainActor (KillTarget) async -> String? = { _ in nil }

    /// Fired for the footer's `Export…`: opens the T20 export panel.
    var onExport: () -> Void = {}

    // MARK: - State

    private var window: NSWindow?
    private var refreshTimer: Timer?

    // Views updated by the render pass.
    private var introLabel: NSTextField?
    private var summaryLabel: NSTextField?
    private var tierControl: NSSegmentedControl?
    private var hideNoiseButton: NSButton?
    private var rangeControl: NSSegmentedControl?
    private var searchField: NSSearchField?
    private var table: NSTableView?
    private var detailLabel: NSTextField?
    private var statusLabel: NSTextField?
    private var trustButton: NSButton?
    private var killButton: NSButton?
    private var revealButton: NSButton?
    private var exportButton: NSButton?
    private var closeButton: NSButton?

    /// Everything the last read returned for the selected range.
    private var allEvents: [ClassifiedEvent] = []

    /// What the filters leave of it, newest first — the table's rows, one for
    /// one.
    private var visibleEvents: [ClassifiedEvent] = []

    /// The range the last read ran over (both bounds inclusive).
    private var range: (from: Date, to: Date) = (.distantPast, .distantFuture)

    /// A read is in flight: the next tick waits for it instead of stacking.
    private var isReading = false

    init(logDirectory: URL, language: @escaping () -> Language) {
        self.logDirectory = logDirectory
        self.language = language
        super.init()
    }

    // MARK: - Life cycle

    /// Shows the window, building it on first use, takes a fresh read and starts
    /// the 5 s refresh. Calling it again on an open window just brings it
    /// forward and re-reads.
    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        // The read first (it sets the range and marks itself in flight), then
        // the chrome: the window is never on screen untitled and headerless
        // while the first read runs, and the count line stays blank rather than
        // claiming "no events" about a log nobody has looked at yet.
        readLog()
        render()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        startRefreshing()
    }

    /// The user closed the window: stop reading until it is opened again
    /// (spec §6b — the refresh runs *while* the window is visible).
    ///
    /// The loaded rows go with it: while the window is closed nothing needs
    /// them, they are re-read on the next `show()` anyway, and a month of
    /// "ทั้งหมด" can be a lot of events to hold for a window nobody is looking
    /// at.
    func windowWillClose(_ notification: Notification) {
        stopRefreshing()
        allEvents = []
        visibleEvents = []
        // Keep the table honest about it: nobody is looking at a closed window,
        // but a row count must not outlive the data that produced it.
        table?.reloadData()
    }

    // MARK: - Reading

    /// Reads the selected range off the main thread and renders the result, then
    /// leaves the reads to the timer.
    ///
    /// A no-op while a read is in flight: the next tick brings the same data and
    /// a stacked read would only make the window late. The timer keeps the table
    /// live while the pipeline appends to the same files, and a torn line is the
    /// one thing `EvidenceLog` already handles (spec §4).
    private func readLog() {
        guard !isReading else { return }
        isReading = true

        let range = selectedPreset.range(now: Date())
        self.range = range
        let directory = logDirectory

        Task { [weak self] in
            // Synchronous file I/O on a detached task, so the window's own
            // thread stays free to draw. The read-only instance is built inside
            // the task: only `URL`s and `Date`s cross the boundary.
            let events = await Task.detached(priority: .userInitiated) {
                EvidenceLog(directory: directory).read(from: range.from, to: range.to)
            }.value

            guard let self else { return }
            self.isReading = false
            self.allEvents = events
            self.render()
        }
    }

    // MARK: - Rendering

    /// The one render pass: chrome in the current language, then the filters
    /// through `HistoryQuery`, the table, the count line and the detail area.
    /// Called after every read and on every filter change, so the controls and
    /// what they show always belong to the same pass.
    private func render() {
        let language = self.language()

        window?.title = Strings.t("history.title", language)
        introLabel?.stringValue = Strings.t("history.intro", language)

        for index in Self.tierSegments.indices {
            tierControl?.setLabel(Self.tierLabel(Self.tierSegments[index], language: language), forSegment: index)
        }
        hideNoiseButton?.title = Strings.t("history.hideNoise", language)
        for preset in RangePreset.allCases {
            rangeControl?.setLabel(Strings.t(preset.titleKey, language), forSegment: preset.rawValue)
        }
        searchField?.placeholderString = Strings.t("history.search.placeholder", language)
        for spec in Self.columnSpecs {
            table?.tableColumn(withIdentifier: spec.id)?.headerCell.stringValue = Strings.t(spec.titleKey, language)
        }

        trustButton?.title = Strings.t("history.button.trust", language)
        killButton?.title = Strings.t("history.button.kill", language)
        revealButton?.title = Strings.t("menu.event.reveal", language)
        exportButton?.title = Strings.t("history.button.export", language)
        closeButton?.title = Strings.t("history.button.close", language)

        // The row the user was reading, captured before the reload clears the
        // selection (the restore below puts it back if it is still visible).
        let previouslySelected = selectedEvent

        visibleEvents = HistoryQuery.filter(
            allEvents,
            tiers: selectedTiers,
            hideNoise: hideNoiseButton?.state == .on,
            from: range.from,
            to: range.to,
            search: searchField?.stringValue ?? ""
        )
        table?.reloadData()

        summaryLabel?.stringValue = summaryText(language: language)

        restoreSelection(of: previouslySelected)
        refreshDetail()
    }

    /// The line above the table: what the current filters leave of what was
    /// read. While a read is in flight it is blank — the count is about to
    /// change, and "no event matches" would be a guess about a log nobody has
    /// looked at yet.
    private func summaryText(language: Language) -> String {
        if isReading { return "" }
        guard !visibleEvents.isEmpty else { return Strings.t("history.empty", language) }
        return String(
            format: Strings.t("history.summary", language),
            String(visibleEvents.count),
            String(allEvents.count)
        )
    }

    /// The detail area for the selected row, and the row actions that exist for
    /// it (spec §6b):
    /// - `Trust` — any actor can be trusted, which is exactly what the menu's
    ///   trust list offers, so the button always exists when a row is selected;
    /// - `Kill…` — a REMOTE/ORG row with a usable pid, the same availability
    ///   rule the menu rows use (`ClassifiedEvent.offersKillAction`);
    /// - `เปิดตำแหน่ง` — present when a location really resolves for the row
    ///   (`ProcessLocation`), which for a pid-only row means the process is
    ///   still alive to ask. A row whose reveal would fail offers nothing.
    private func refreshDetail() {
        let language = self.language()
        let none = Strings.t("history.detail.none", language)

        guard let event = selectedEvent else {
            detailLabel?.stringValue = Strings.t("history.none.selected", language)
            trustButton?.isHidden = true
            killButton?.isHidden = true
            revealButton?.isHidden = true
            return
        }

        detailLabel?.stringValue = [
            String(format: Strings.t("history.detail.reason", language), event.reason),
            String(format: Strings.t("history.detail.raw", language), event.event.rawSummary ?? none),
            String(format: Strings.t("history.detail.pid", language), event.event.pid.map(String.init) ?? none),
            String(format: Strings.t("history.detail.path", language), event.event.actorPath ?? none),
        ].joined(separator: "\n")

        trustButton?.isHidden = false
        killButton?.isHidden = !event.offersKillAction
        revealButton?.isHidden = ProcessLocation.revealURL(
            for: event.event.actorPath,
            pid: event.event.pid
        ) == nil
    }

    // MARK: - Selection

    /// The selected row's event, or `nil` when nothing (visible) is selected.
    private var selectedEvent: ClassifiedEvent? {
        guard let table, visibleEvents.indices.contains(table.selectedRow) else { return nil }
        return visibleEvents[table.selectedRow]
    }

    /// Re-selects `event` after a reload, by identity rather than by row number:
    /// the log grows between refreshes, so an index is not stable while a
    /// (moment, actor, kind) triple is. A row the filters no longer show simply
    /// stays unselected.
    private func restoreSelection(of event: ClassifiedEvent?) {
        guard let table, let event,
              let index = visibleEvents.firstIndex(where: { Self.sameRow($0, event) })
        else { return }
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    }

    /// Whether two rows are the same log line: the same moment, actor and kind.
    /// `count` is deliberately *not* compared — the Throttler folds repeats into
    /// a row that is already on screen (spec §5), and a selection must survive
    /// that.
    private static func sameRow(_ lhs: ClassifiedEvent, _ rhs: ClassifiedEvent) -> Bool {
        lhs.event.ts == rhs.event.ts
            && lhs.event.actor == rhs.event.actor
            && lhs.event.kind == rhs.event.kind
    }

    // MARK: - Table data

    func numberOfRows(in tableView: NSTableView) -> Int {
        visibleEvents.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn?.identifier, visibleEvents.indices.contains(row) else {
            return nil
        }
        let event = visibleEvents[row]

        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? Self.makeCell(identifier: identifier)
        cell.textField?.stringValue = Self.cellText(for: identifier, event: event, language: language())
        // Only the tier cell is coloured: it is the one column worth reading at
        // a glance, and the word in it survives a monochrome screenshot.
        cell.textField?.textColor = identifier == Self.tierColumnID
            ? Self.color(for: event.tier)
            : .labelColor
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        refreshDetail()
    }

    /// One cell's text for one event.
    private static func cellText(
        for column: NSUserInterfaceItemIdentifier,
        event: ClassifiedEvent,
        language: Language
    ) -> String {
        switch column {
        case timeColumnID:
            timestamp(event.event.ts)
        case tierColumnID:
            event.tier.rawValue
        case actorColumnID:
            event.event.actor
        case kindColumnID:
            event.event.kind.rawValue
        case countColumnID:
            // `×N` only when a throttled burst was folded in — the menu rows'
            // own suffix, so the two views spell a count the same way.
            event.count > 1
                ? String(format: Strings.t("menu.event.count", language), String(event.count))
                : ""
        default:
            ""
        }
    }

    /// The tier colours: the two alerting tiers are the warm ones the banner
    /// uses, NORMAL is plain text, and the two tiers that never notify are quiet
    /// (secondary / the trusted green).
    private static func color(for tier: Tier) -> NSColor {
        switch tier {
        case .org: .systemRed
        case .remote: .systemOrange
        case .normal: .labelColor
        case .systemNoise: .secondaryLabelColor
        case .allowlist: .systemGreen
        }
    }

    /// `yyyy-MM-dd HH:mm:ss` in local time, `en_US_POSIX` so the digits and the
    /// calendar never follow the user's locale. The table is scanned vertically
    /// across several days (unlike the menu's `HH:mm:ss` today-only rows), so the
    /// date is part of it and the stamp is fixed-width — the same convention the
    /// exporter's CSV and the log's own `yyyy-MM-dd` day files use.
    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    // MARK: - Actions

    /// A filter changed: re-apply. The filters are pure and the range's events
    /// are already in memory, so nothing is read from disk here.
    @objc private func filterChanged(_ sender: Any?) {
        render()
    }

    /// The day range changed: it decides what to *read*, not what to show of
    /// what is already loaded, so this goes back to disk.
    @objc private func rangeChanged(_ sender: Any?) {
        readLog()
    }

    /// `Trust`: the same allowlist write the menu's `Trust แอปนี้…` makes, run
    /// through the app's own `trust` (the `onTrust` hook) so the two can never
    /// drift. A write failure is reported exactly as the menu reports it.
    @objc private func trustSelected(_ sender: Any?) {
        guard let event = selectedEvent else { return }
        let actor = event.event.actor
        do {
            try onTrust(actor)
            setStatus(String(format: Strings.t("menu.trust.done", language()), actor))
        } catch {
            presentConfigError()
        }
    }

    /// `Kill…`: the T21 manual flow, untouched — confirm dialog, `SIGTERM` →
    /// wait → `SIGKILL`, EPERM → the macOS admin prompt, and one `process-kill`
    /// line for the outcome. The window only relays the returned status line and
    /// re-reads, so the new evidence row appears without waiting for the tick.
    @objc private func killSelected(_ sender: Any?) {
        guard let event = selectedEvent, event.offersKillAction else { return }
        let target = KillTarget(event)

        Task { [weak self] in
            guard let self else { return }
            self.setStatus(await self.onKill(target))
            self.readLog()
        }
    }

    /// `เปิดตำแหน่ง`: the same reveal the menu row and the notification action
    /// use. A reveal that resolves at selection time can still miss here — the
    /// process may have died in between — and that is an honest no-op
    /// (`openInFinder(for:)` returns `false`).
    @objc private func revealSelected(_ sender: Any?) {
        guard let event = selectedEvent else { return }
        ProcessLocation.openInFinder(for: KillTarget(event))
    }

    /// The footer's `Export…`: the T20 flow, wherever the app routes it.
    @objc private func exportReport(_ sender: Any?) {
        onExport()
    }

    @objc private func closeWindow(_ sender: Any?) {
        window?.performClose(nil)
    }

    /// The line under the detail area: what the last action did. The 5 s refresh
    /// does not clear it (the user may still be reading it) — another action
    /// replaces it, and a cancelled dialog returns `nil`, which clears it.
    private func setStatus(_ message: String?) {
        statusLabel?.stringValue = message ?? ""
    }

    /// A config write that failed — the alert the menu shows (T17), so a `Trust`
    /// from this window cannot fail silently.
    private func presentConfigError() {
        let language = self.language()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = Strings.t("menu.config.failed", language)
        alert.addButton(withTitle: Strings.t("about.ok", language))
        NSApp.activate()
        alert.runModal()
    }

    // MARK: - Filter accessors

    /// The tier filter's current answer: `nil` for "ทั้งหมด".
    private var selectedTiers: Set<Tier>? {
        let index = tierControl?.selectedSegment ?? 0
        guard Self.tierSegments.indices.contains(index) else { return nil }
        return Self.tierSegments[index]
    }

    /// The range preset's current answer; `วันนี้` when nothing is selected.
    private var selectedPreset: RangePreset {
        RangePreset(rawValue: rangeControl?.selectedSegment ?? 0) ?? .today
    }

    // MARK: - Timer

    private func startRefreshing() {
        guard refreshTimer == nil else { return }
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.readLog() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func stopRefreshing() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Layout

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.contentWidth, height: Self.contentHeight),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.delegate = self

        let content = NSView()
        window.contentView = content

        let intro = Self.label(secondary: true)
        introLabel = intro

        let summary = Self.label(weight: .medium)
        summaryLabel = summary

        // Filter row 1 (spec §6b): the tier segments and the `ซ่อน noise` switch.
        let tier = NSSegmentedControl(
            labels: Self.tierSegments.map { Self.tierLabel($0, language: Strings.defaultLanguage) },
            trackingMode: .selectOne,
            target: self,
            action: #selector(filterChanged(_:))
        )
        tier.selectedSegment = 0
        tierControl = tier

        let hideNoise = NSButton(
            checkboxWithTitle: "",
            target: self,
            action: #selector(filterChanged(_:))
        )
        hideNoise.state = .off
        hideNoiseButton = hideNoise

        // Filter row 2 (spec §6b): the range presets and the search field.
        let range = NSSegmentedControl(
            labels: RangePreset.allCases.map {
                Strings.t($0.titleKey, Strings.defaultLanguage)
            },
            trackingMode: .selectOne,
            target: self,
            action: #selector(rangeChanged(_:))
        )
        range.selectedSegment = RangePreset.today.rawValue
        rangeControl = range

        let search = NSSearchField()
        search.target = self
        search.action = #selector(filterChanged(_:))
        // Live filtering: the action fires as the user types rather than only on
        // Return (an in-memory filter has nothing to wait for).
        search.sendsWholeSearchString = false
        search.sendsSearchStringImmediately = true
        search.translatesAutoresizingMaskIntoConstraints = false
        searchField = search

        let tierRow = Self.row([tier, hideNoise])
        let rangeRow = Self.row([range], trailing: search)
        search.widthAnchor.constraint(equalToConstant: 240).isActive = true

        // The table: one row per visible event, newest first.
        let table = NSTableView()
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.headerView = NSTableHeaderView()
        // A little more air than the 17 pt default: every cell is one line of
        // the system font, and a row of a table meant to be read down a column
        // should not be cropped.
        table.rowHeight = 20
        table.dataSource = self
        table.delegate = self
        for spec in Self.columnSpecs {
            let column = NSTableColumn(identifier: spec.id)
            column.width = spec.width
            column.minWidth = 60
            column.isEditable = false
            table.addTableColumn(column)
        }
        self.table = table

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.documentView = table
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let detail = Self.label(secondary: true)
        // Four lines, and never more: a very long path truncates instead of
        // pushing the footer out of the window.
        detail.maximumNumberOfLines = 4
        detail.lineBreakMode = .byTruncatingTail
        detailLabel = detail

        let status = Self.label(secondary: true)
        statusLabel = status

        // The row actions and the footer.
        let trust = NSButton(title: "", target: self, action: #selector(trustSelected(_:)))
        trust.bezelStyle = .rounded
        trustButton = trust

        let kill = NSButton(title: "", target: self, action: #selector(killSelected(_:)))
        kill.bezelStyle = .rounded
        killButton = kill

        let reveal = NSButton(title: "", target: self, action: #selector(revealSelected(_:)))
        reveal.bezelStyle = .rounded
        revealButton = reveal

        let export = NSButton(title: "", target: self, action: #selector(exportReport(_:)))
        export.bezelStyle = .rounded
        exportButton = export

        let close = NSButton(title: "", target: self, action: #selector(closeWindow(_:)))
        close.bezelStyle = .rounded
        closeButton = close

        let footer = NSStackView(views: [NSView(), trust, kill, reveal, export, close])
        footer.orientation = .horizontal
        footer.spacing = 8
        footer.alignment = .centerY
        footer.setHuggingPriority(.defaultLow, for: .horizontal)

        for view in [intro, summary, tierRow, rangeRow, scroll, detail, status, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }

        NSLayoutConstraint.activate([
            intro.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.padding),
            intro.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Self.padding),
            intro.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.padding),

            summary.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.padding),
            summary.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Self.padding),
            summary.topAnchor.constraint(equalTo: intro.bottomAnchor, constant: 4),

            tierRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.padding),
            tierRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Self.padding),
            tierRow.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 10),

            rangeRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.padding),
            rangeRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Self.padding),
            rangeRow.topAnchor.constraint(equalTo: tierRow.bottomAnchor, constant: 8),

            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.padding),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Self.padding),
            scroll.topAnchor.constraint(equalTo: rangeRow.bottomAnchor, constant: 12),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumTableHeight),

            detail.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.padding),
            detail.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Self.padding),
            detail.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),

            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.padding),
            status.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Self.padding),
            status.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 6),

            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.padding),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Self.padding),
            footer.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 12),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Self.padding),
        ])

        window.center()
        return window
    }

    /// One filter row: `views` on the leading edge, a stretchable spacer taking
    /// the slack, and `trailing` (the search field) at the far end.
    private static func row(_ views: [NSView], trailing: NSView? = nil) -> NSStackView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: views + [spacer] + (trailing.map { [$0] } ?? []))
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        return row
    }

    /// One reuse-queue cell: a text field filling its column, so a long actor or
    /// path truncates at the column edge instead of running into its neighbour.
    private static func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier

        let text = NSTextField(labelWithString: "")
        text.font = .systemFont(ofSize: NSFont.systemFontSize)
        text.lineBreakMode = .byTruncatingTail
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        cell.textField = text

        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    /// One label in the window's voice: no bezel, no editing, wrapping text so a
    /// long line grows instead of truncating (the same shape the other windows
    /// use).
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
