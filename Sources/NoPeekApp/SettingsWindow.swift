import AppKit

import PWCore

// MARK: - SettingsWindowController

/// The Settings window (plan T23, spec §6c): every editable config key as a
/// control, and no way to write a value the config should not carry.
///
/// **It is a form over the file.** The fields are loaded from
/// `configStore.config` when the window opens; `บันทึก` validates, and only
/// then writes the whole draft through `ConfigStore.update` (ruling F2 — full
/// persist plus reload through the store's own path). A value that breaks its
/// rule (spec §6c: retention 1–365 · cooldown 0–3600 · gap 1–1440 ·
/// maxPerHour 1–100 · `bannerLevel ∈ {floating, screenSaver}` ·
/// `language ∈ {th, en}`) is refused **before any write**, with the message
/// inline under the field it belongs to; a field that is not a number at all
/// gets `settings.error.number`. Nothing is ever written partially: one
/// validation pass decides the whole save.
///
/// **Live apply happens behind the store, not here.** The save is a
/// `ConfigStore.update`, and the app rebuilds the classifier / auto-kill
/// engine / banner cooldown from the store's change notification — so the
/// window does not (and must not) reach into the running pipeline itself. That
/// also means an external edit to `config.json` and this window's save travel
/// the exact same path.
///
/// **`Purge now` uses the value that is saved.** It never purges with what is
/// currently typed in the retention field — the point of the button is "the
/// retention you asked for", and a half-edited form is not that. The app owns
/// the log, so the actual purge is the `onPurge` hook (wired to the reader's
/// serial queue, the `EvidenceLog`'s single owner) rather than a call from
/// this window; the confirmation comes back on the main actor with the true
/// number of files the purge removed.
///
/// **`เปิดไฟล์ config` stays** (spec §6c: for power users) and opens the same
/// file the menu row opens.
///
/// Main actor: it is AppKit. Dependencies are the store it reads and writes,
/// the language closure the other windows also take (re-read on every render,
/// so a live language switch re-titles the form), and the config file's URL.
/// Re-opening a window that is already on screen only brings it forward —
/// the fields are loaded on a real (re)open, so a click on `Settings…` while
/// the form is being edited never discards the edits.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {

    // MARK: - Layout

    /// The window is the other windows' shape: one fixed width, a footer that
    /// is always visible, and a scrolling form above it. The form is taller
    /// than a small Mac's screen needs to be, and the buttons are the two
    /// things that must never move.
    private static let contentWidth: CGFloat = 640
    private static let contentHeight: CGFloat = 700
    private static let padding: CGFloat = 20
    /// The label column: every control starts at the same x, so the form reads
    /// as a table even though it is a stack.
    private static let labelWidth: CGFloat = 250
    private static let fieldWidth: CGFloat = 90
    private static let textAreaHeight: CGFloat = 68

    // MARK: - The five list areas

    /// The list keys, in form order. Each one is a text area (spec §6c:
    /// บรรทัดละรายการ) parsed by `SettingsDraft.parseList`.
    private enum ListKind: String, CaseIterable {
        case orgPatterns
        case remoteControlExtra
        case systemNoiseExtra
        case allowlist
        case autoKillNames

        var labelKey: String { "settings.list.\(rawValue)" }
    }

    // MARK: - Dependencies

    /// The store the form reads and writes (spec §7/ruling F2).
    private let configStore: ConfigStore

    /// Read per render, so a live language switch re-titles the form.
    private let language: () -> Language

    /// `~/.config/nopeek/config.json` — what `เปิดไฟล์ config` opens.
    private let configURL: URL

    // MARK: - Hooks (wired by the app after construction)

    /// `Purge now`: run the purge with this many days and report, on the main
    /// actor, how many files it actually removed. The app routes the call
    /// through the reader's serial queue, the log's single owner (T8), so the
    /// call returns before the deletion does — the report is the main hop
    /// after it.
    var onPurge: (_ days: Int, _ report: @escaping @MainActor (Int) -> Void) -> Void = { _, _ in }

    // MARK: - Views

    private var window: NSWindow?
    private var statusLabel: NSTextField?
    private var introLabel: NSTextField?

    /// Section headers, kept with their `Strings` keys so a language switch
    /// can re-title them.
    private var sectionLabels: [(label: NSTextField, key: String)] = []
    /// Field labels, paired with the key they render.
    private var fieldLabels: [(label: NSTextField, key: String)] = []

    private var languagePopup: NSPopUpButton?
    private var soundCheckbox: NSButton?
    private var remoteBannerCheckbox: NSButton?
    private var bannerLevelPopup: NSPopUpButton?
    private var autoKillCheckbox: NSButton?

    /// The numeric fields, by the rule they must satisfy.
    private var numericFields: [SettingsField: NSTextField] = [:]
    /// The inline error under each numeric field (created with it, empty and
    /// hidden until a value breaks its rule).
    private var errorLabels: [SettingsField: NSTextField] = [:]
    /// The five text areas, by list key.
    private var listViews: [ListKind: NSTextView] = [:]

    private var purgeButton: NSButton?
    private var saveButton: NSButton?
    private var closeButton: NSButton?
    private var openConfigButton: NSButton?

    // MARK: - Init

    init(
        configStore: ConfigStore,
        language: @escaping () -> Language,
        configURL: URL
    ) {
        self.configStore = configStore
        self.language = language
        self.configURL = configURL
        super.init()
    }

    // MARK: - Life cycle

    /// Shows the window, building it on first use. A real (re)open reloads the
    /// fields from the saved config; a click on an already-open window only
    /// brings it forward (see the class note).
    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        if !window.isVisible {
            loadFields(configStore.config)
        }
        // Chrome always: the window may have been built before `self.window`
        // existed (its first render), and a language saved since then must be
        // reflected the moment it is opened.
        render()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    // MARK: - Loading

    /// Fills every control from `config` — the whole form, always: a field the
    /// window does not write is a field the user did not edit.
    private func loadFields(_ config: NoPeekConfig) {
        let draft = SettingsDraft(config: config)

        select(draft.language, in: languagePopup, values: SettingsDraft.languages)
        soundCheckbox?.state = draft.sound ? .on : .off
        remoteBannerCheckbox?.state = draft.bannerOnForRemote ? .on : .off
        select(draft.bannerLevel, in: bannerLevelPopup, values: SettingsDraft.bannerLevels)
        autoKillCheckbox?.state = draft.autoKillEnabled ? .on : .off

        numericFields[.orgBannerCooldownSeconds]?.stringValue = String(draft.orgBannerCooldownSeconds)
        numericFields[.gapAlertThresholdMinutes]?.stringValue = String(draft.gapAlertThresholdMinutes)
        numericFields[.logRetentionDays]?.stringValue = String(draft.logRetentionDays)
        numericFields[.autoKillMaxPerHour]?.stringValue = String(draft.autoKillMaxPerHour)

        listViews[.orgPatterns]?.string = SettingsDraft.renderList(draft.orgPatterns)
        listViews[.remoteControlExtra]?.string = SettingsDraft.renderList(draft.remoteControlExtra)
        listViews[.systemNoiseExtra]?.string = SettingsDraft.renderList(draft.systemNoiseExtra)
        listViews[.allowlist]?.string = SettingsDraft.renderList(draft.allowlist)
        listViews[.autoKillNames]?.string = SettingsDraft.renderList(draft.autoKillNames)

        clearErrors()
        statusLabel?.stringValue = ""
    }

    // MARK: - Saving

    /// `บันทึก`: parse → validate → write. A failure writes nothing (spec §6c)
    /// and says why, under the field it is about.
    @objc private func save(_ sender: Any?) {
        let language = self.language()
        clearErrors()
        statusLabel?.stringValue = ""

        var draft = SettingsDraft(config: configStore.config)
        var parsed: [SettingsField: Int] = [:]
        var hasParseFailure = false

        for field in SettingsField.allCases where numericFields[field] != nil {
            let text = numericFields[field]?.stringValue
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let value = Int(text) {
                parsed[field] = value
            } else {
                // Not a number at all: the range messages cannot describe it.
                showError(field, Strings.t("settings.error.number", language))
                hasParseFailure = true
            }
        }

        // Scalars and lists come from the controls that cannot be invalid.
        draft.language = selectedValue(in: languagePopup, values: SettingsDraft.languages)
        draft.bannerLevel = selectedValue(in: bannerLevelPopup, values: SettingsDraft.bannerLevels)
        draft.sound = soundCheckbox?.state == .on
        draft.bannerOnForRemote = remoteBannerCheckbox?.state == .on
        draft.autoKillEnabled = autoKillCheckbox?.state == .on
        draft.orgBannerCooldownSeconds = parsed[.orgBannerCooldownSeconds] ?? draft.orgBannerCooldownSeconds
        draft.gapAlertThresholdMinutes = parsed[.gapAlertThresholdMinutes] ?? draft.gapAlertThresholdMinutes
        draft.logRetentionDays = parsed[.logRetentionDays] ?? draft.logRetentionDays
        draft.autoKillMaxPerHour = parsed[.autoKillMaxPerHour] ?? draft.autoKillMaxPerHour
        draft.orgPatterns = Self.listText(of: listViews[.orgPatterns], parsed: SettingsDraft.parseList)
        draft.remoteControlExtra = SettingsDraft.parseList(listViews[.remoteControlExtra]?.string ?? "")
        draft.systemNoiseExtra = SettingsDraft.parseList(listViews[.systemNoiseExtra]?.string ?? "")
        draft.allowlist = SettingsDraft.parseList(listViews[.allowlist]?.string ?? "")
        draft.autoKillNames = SettingsDraft.parseList(listViews[.autoKillNames]?.string ?? "")

        // The rule check, on the parsed values only — a field that failed to
        // parse already has its own message and no rule to check.
        let ruleErrors = draft.errors().filter { parsed[$0] != nil }
        for field in ruleErrors {
            showError(field, Strings.t(field.messageKey, language))
        }

        guard !hasParseFailure, ruleErrors.isEmpty else { return }

        do {
            try configStore.update { config in
                draft.apply(to: &config)
            }
        } catch {
            presentConfigError()
            return
        }

        // Show what was actually saved: the store reloaded the file, and the
        // form re-reads it — so a list the parse deduped or trimmed displays as
        // the file holds it, not as it was typed. `render` also re-titles the
        // form when the save changed the language, so the window and the file
        // never disagree about which language is in use.
        loadFields(configStore.config)
        render()
        statusLabel?.stringValue = Strings.t("settings.saved", language)
    }

    /// `Purge now` (spec §6c): the **saved** retention, reported with the days
    /// it used. The purge itself belongs to the app — see `onPurge` — and
    /// deletion is best-effort by T8's design (a file that refuses to go is
    /// skipped), so the confirmation waits for the app's report and names the
    /// true number of files that were removed, not a request.
    @objc private func purgeNow(_ sender: Any?) {
        let days = configStore.config.logRetentionDays
        onPurge(days) { [weak self] removed in
            guard let self else { return }
            statusLabel?.stringValue = String(
                format: Strings.t("settings.purge.done", language()),
                String(removed), String(days)
            )
        }
    }

    /// `เปิดไฟล์ config` (spec §6c, power users): the menu row's behavior.
    @objc private func openConfigFile(_ sender: Any?) {
        if FileManager.default.fileExists(atPath: configURL.path) {
            NSWorkspace.shared.open(configURL)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([configURL])
        }
    }

    @objc private func closeWindow(_ sender: Any?) {
        window?.performClose(nil)
    }

    // MARK: - Inline errors

    /// Shows `message` under `field`. The messages are cleared as a block at
    /// the start of a save (`clearErrors()`), so what the user reads belongs to
    /// the last save attempt only.
    private func showError(_ field: SettingsField, _ message: String) {
        errorLabels[field]?.stringValue = message
        errorLabels[field]?.isHidden = message.isEmpty
    }

    private func clearErrors() {
        for label in errorLabels.values {
            label.stringValue = ""
            label.isHidden = true
        }
    }

    /// A config write that failed — the alert the menu shows (T17), so a save
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

    // MARK: - Rendering

    /// Chrome in the current language, then the field values are left alone.
    /// Every string the form shows comes from here (spec §10: no hardcoded UI
    /// copy), so a language switch re-titles the whole window on the next
    /// render — including this form's own labels.
    private func render() {
        let language = self.language()
        window?.title = Strings.t("settings.title", language)
        introLabel?.stringValue = Strings.t("settings.intro", language)

        for (label, key) in fieldLabels {
            label.stringValue = Strings.t(key, language)
        }
        for (label, key) in sectionLabels {
            label.stringValue = Strings.t(key, language)
        }

        // Popup item titles change with the language; the selection stays
        // (index-based, `item(at:)` keeps whatever was selected).
        if let popup = languagePopup {
            for (index, value) in SettingsDraft.languages.enumerated() where index < popup.numberOfItems {
                popup.item(at: index)?.title = Self.languageTitle(value, language)
            }
        }
        if let popup = bannerLevelPopup {
            for (index, value) in SettingsDraft.bannerLevels.enumerated() where index < popup.numberOfItems {
                popup.item(at: index)?.title = Self.levelTitle(value, language)
            }
        }

        purgeButton?.title = Strings.t("settings.purge", language)
        saveButton?.title = Strings.t("settings.save", language)
        closeButton?.title = Strings.t("settings.close", language)
        openConfigButton?.title = Strings.t("settings.openConfig", language)
    }

    /// The popup title for a language value (`settings.language.th`/`.en`).
    private static func languageTitle(_ value: String, _ language: Language) -> String {
        Strings.t(value == "en" ? "settings.language.en" : "settings.language.th", language)
    }

    /// The popup title for a banner level (`settings.level.floating`/`.screenSaver`).
    private static func levelTitle(_ value: String, _ language: Language) -> String {
        Strings.t(value == "floating" ? "settings.level.floating" : "settings.level.screenSaver", language)
    }

    // MARK: - Control helpers

    /// The value a popup is showing, or the first value when the selection is
    /// somehow empty — never a crash, and never a silent default other than
    /// the spec's first choice.
    private func selectedValue(in popup: NSPopUpButton?, values: [String]) -> String {
        guard let popup, values.indices.contains(popup.indexOfSelectedItem) else {
            return values.first ?? ""
        }
        return values[popup.indexOfSelectedItem]
    }

    /// Selects `value` when the popup offers it; leaves the selection alone
    /// otherwise (a draft value outside the popup's list is a validation error
    /// the user is about to see, not a selection to lose).
    private func select(_ value: String, in popup: NSPopUpButton?, values: [String]) {
        guard let popup, let index = values.firstIndex(of: value) else { return }
        popup.selectItem(at: index)
    }

    /// The text of a list area, parsed — split out so `save` reads as one
    /// statement per field.
    private static func listText(of view: NSTextView?, parsed: (String) -> [String]) -> [String] {
        parsed(view?.string ?? "")
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

        // The form scrolls; the buttons do not. A form this long must not push
        // its own Save button off a short screen.
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.padding),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.padding),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Self.padding),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])

        stack.addArrangedSubview(intro)
        stack.setCustomSpacing(14, after: intro)

        // — General (spec §6c) —
        stack.addArrangedSubview(section("settings.section.general"))
        stack.setCustomSpacing(6, after: stack.arrangedSubviews.last!)

        let languagePopup = Self.popup(SettingsDraft.languages.map { Self.languageTitle($0, .th) })
        self.languagePopup = languagePopup
        stack.addArrangedSubview(row("settings.language", languagePopup))

        let sound = Self.checkbox(#selector(noAction(_:)), self)
        soundCheckbox = sound
        stack.addArrangedSubview(row("settings.sound", sound))

        let remoteBanner = Self.checkbox(#selector(noAction(_:)), self)
        remoteBannerCheckbox = remoteBanner
        stack.addArrangedSubview(row("settings.bannerOnForRemote", remoteBanner))

        let levelPopup = Self.popup(SettingsDraft.bannerLevels.map { Self.levelTitle($0, .th) })
        bannerLevelPopup = levelPopup
        stack.addArrangedSubview(row("settings.bannerLevel", levelPopup))

        stack.addArrangedSubview(numericRow(.orgBannerCooldownSeconds, key: "settings.cooldown"))
        stack.addArrangedSubview(numericRow(.gapAlertThresholdMinutes, key: "settings.gap"))

        // Retention shares its row with the purge button: the button acts on
        // the saved version of the value right next to it.
        let retentionRow = numericRow(.logRetentionDays, key: "settings.retention")
        let purge = NSButton(title: "", target: self, action: #selector(purgeNow(_:)))
        purge.bezelStyle = .rounded
        purgeButton = purge
        if let control = retentionRow.arrangedSubviews.last {
            retentionRow.addArrangedSubview(purge)
            retentionRow.setCustomSpacing(12, after: control)
        }
        stack.addArrangedSubview(retentionRow)

        // — Lists (spec §6c: one entry per line) —
        let listHeader = section("settings.section.lists")
        stack.setCustomSpacing(16, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(listHeader)

        let hint = Self.label(secondary: true)
        hint.stringValue = Strings.t("settings.list.hint", .th)
        fieldLabels.append((hint, "settings.list.hint"))
        stack.addArrangedSubview(hint)

        for kind in [ListKind.orgPatterns, .remoteControlExtra, .systemNoiseExtra, .allowlist] {
            let block = listBlock(kind)
            stack.addArrangedSubview(block)
            // The list blocks take the form's full width (their labels would
            // hug, but a text area has to fill); every other row hugs its own
            // label + control.
            block.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        // — Auto-kill (spec §6d) —
        stack.setCustomSpacing(16, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(section("settings.section.autokill"))

        let autoKill = Self.checkbox(#selector(noAction(_:)), self)
        autoKillCheckbox = autoKill
        stack.addArrangedSubview(row("settings.autokill.enabled", autoKill))

        stack.addArrangedSubview(numericRow(.autoKillMaxPerHour, key: "settings.autokill.maxPerHour"))
        stack.setCustomSpacing(6, after: stack.arrangedSubviews.last!)
        let namesBlock = listBlock(.autoKillNames)
        stack.addArrangedSubview(namesBlock)
        namesBlock.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // — Footer: always visible, outside the scroll —
        let status = Self.label(secondary: true)
        statusLabel = status
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let openConfig = NSButton(title: "", target: self, action: #selector(openConfigFile(_:)))
        openConfig.bezelStyle = .rounded
        openConfigButton = openConfig

        let save = NSButton(title: "", target: self, action: #selector(save(_:)))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r" // Return saves, the form's primary action
        saveButton = save

        let close = NSButton(title: "", target: self, action: #selector(closeWindow(_:)))
        close.bezelStyle = .rounded
        closeButton = close

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let footer = NSStackView(views: [openConfig, spacer, status, close, save])
        footer.orientation = .horizontal
        footer.spacing = 10
        footer.alignment = .centerY
        footer.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(footer)

        NSLayoutConstraint.activate([
            footer.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 12),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.padding),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Self.padding),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Self.padding),
        ])

        render()
        // The title is set here as well: `render` above may have run before
        // `self.window` was assigned (the window is built by `show()`), and a
        // window that never shows its name would be a poor first impression.
        window.title = Strings.t("settings.title", self.language())
        window.center()
        return window
    }

    /// A section header; its `Strings` key is kept next to it so `render` can
    /// re-title it after a language switch.
    private func section(_ key: String) -> NSTextField {
        let label = NSTextField(labelWithString: Strings.t(key, Strings.defaultLanguage))
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        sectionLabels.append((label, key))
        return label
    }

    /// One labelled row: the control at the label column's right edge.
    private func row(_ key: String, _ control: NSView) -> NSStackView {
        let label = Self.label()
        label.stringValue = Strings.t(key, Strings.defaultLanguage)
        label.widthAnchor.constraint(equalToConstant: Self.labelWidth).isActive = true
        fieldLabels.append((label, key))

        let stack = NSStackView(views: [label, control])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .centerY
        return stack
    }

    /// A labelled row plus (under it) the field's inline error, kept hidden
    /// while the value is fine.
    private func numericRow(_ field: SettingsField, key: String) -> NSStackView {
        let textField = NSTextField()
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.widthAnchor.constraint(equalToConstant: Self.fieldWidth).isActive = true
        textField.alignment = .right
        numericFields[field] = textField

        let controlRow = row(key, textField)

        let error = Self.label(secondary: true)
        error.textColor = .systemRed
        error.isHidden = true
        errorLabels[field] = error

        let stack = NSStackView(views: [controlRow, error])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        return stack
    }

    /// A list area: its label, then a monospaced text area with a bezel, one
    /// entry per line. The caller pins the block to the form's width, which is
    /// what makes the area fill it.
    private func listBlock(_ kind: ListKind) -> NSStackView {
        let (scroll, view) = Self.makeTextArea()
        listViews[kind] = view

        let label = Self.label()
        label.stringValue = Strings.t(kind.labelKey, Strings.defaultLanguage)
        fieldLabels.append((label, kind.labelKey))

        let stack = NSStackView(views: [label, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    /// A monospaced editing area in a bezel scroller: config entries are paths
    /// and process names, and a fixed-width font is how they line up.
    private static func makeTextArea() -> (NSScrollView, NSTextView) {
        let view = NSTextView()
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.isRichText = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        let scroll = NSScrollView()
        scroll.documentView = view
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: textAreaHeight).isActive = true
        return (scroll, view)
    }

    // MARK: - Small view factories

    private static func label(secondary: Bool = false) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        label.textColor = secondary ? .secondaryLabelColor : .labelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private static func checkbox(_ action: Selector, _ target: AnyObject?) -> NSButton {
        let button = NSButton(checkboxWithTitle: "", target: target, action: action)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    private static func popup(_ titles: [String]) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: titles)
        popup.translatesAutoresizingMaskIntoConstraints = false
        return popup
    }

    /// The checkboxes only carry state; nothing happens on a click.
    @objc private func noAction(_ sender: Any?) {}
}

// MARK: - FlippedView

/// A document view for the form's scroller. AppKit's default is bottom-origin,
/// which would open a long form scrolled to its end; flipping it makes the
/// first row the first thing on screen.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
