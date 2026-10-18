import Darwin
import Foundation

// MARK: - NoPeekConfig

/// The user-visible configuration (spec §7), persisted as JSON by `ConfigStore`.
///
/// The twelve keys are exactly spec §7's, and every one of them has a default,
/// so a partial (or hand-trimmed) file still produces a usable config. The
/// four list keys hold **only the user's entries**; the built-in lists live in
/// `defaultOrgPatterns`, `defaultRemoteControl` and `defaultSystemNoise` and
/// are merged in at read time by `effectiveOrgPatterns`,
/// `effectiveRemoteControl` and `effectiveSystemNoise` — those `effective*`
/// accessors are what consumers hand to `Classifier` and `ProcessWatch`.
/// `allowlist` is a passthrough: it has no built-in entries to merge.
///
/// Decoding is tolerant on purpose. Missing keys (and explicit `null`s) fall
/// back per key; unknown keys are ignored, and are not carried over when the
/// store rewrites the file (accepted v1 choice). A key with the *wrong type*
/// still fails the whole read, and `ConfigStore` answers that with the
/// all-defaults fallback (Review Focus #3).
public struct NoPeekConfig: Codable, Equatable, Sendable {

    // MARK: - Keys (spec §7)

    /// UI language; `"th"` (Thai) is the only shipped language in v1.
    public var language: String
    /// Play a sound with notifications.
    public var sound: Bool
    /// Show the banner for REMOTE-tier events (ORG banners are never optional).
    public var bannerOnForRemote: Bool
    /// Banner window level: `"floating"` or `"screenSaver"` (spec §6).
    public var bannerLevel: String
    /// Minimum seconds between two org banners.
    public var orgBannerCooldownSeconds: Int
    /// How many days of `events-*.ndjson` to keep (spec §8).
    public var logRetentionDays: Int
    /// Silence longer than this many minutes is a monitor gap (spec §4).
    public var gapAlertThresholdMinutes: Int
    /// `true` makes the three list keys below *replace* the built-in lists
    /// instead of extending them (spec §7 escape hatch).
    public var replaceDefaultLists: Bool
    /// User's extra org / RMM patterns, merged with `defaultOrgPatterns`.
    public var orgPatterns: [String]
    /// User's extra remote-control process names, merged with `defaultRemoteControl`.
    public var remoteControlExtra: [String]
    /// User's extra system-noise patterns, merged with `defaultSystemNoise`.
    public var systemNoiseExtra: [String]
    /// Actors (path prefix or process name) the user trusts. Passthrough — no
    /// built-in entries, and never merged with anything.
    public var allowlist: [String]

    // MARK: - Init

    public init(
        language: String = "th",
        sound: Bool = true,
        bannerOnForRemote: Bool = true,
        bannerLevel: String = "screenSaver",
        orgBannerCooldownSeconds: Int = 60,
        logRetentionDays: Int = 30,
        gapAlertThresholdMinutes: Int = 15,
        replaceDefaultLists: Bool = false,
        orgPatterns: [String] = [],
        remoteControlExtra: [String] = [],
        systemNoiseExtra: [String] = [],
        allowlist: [String] = []
    ) {
        self.language = language
        self.sound = sound
        self.bannerOnForRemote = bannerOnForRemote
        self.bannerLevel = bannerLevel
        self.orgBannerCooldownSeconds = orgBannerCooldownSeconds
        self.logRetentionDays = logRetentionDays
        self.gapAlertThresholdMinutes = gapAlertThresholdMinutes
        self.replaceDefaultLists = replaceDefaultLists
        self.orgPatterns = orgPatterns
        self.remoteControlExtra = remoteControlExtra
        self.systemNoiseExtra = systemNoiseExtra
        self.allowlist = allowlist
    }

    /// Every scalar at its spec §7 default and every user list empty.
    /// `ConfigStore` writes exactly this shape when the file is missing, so a
    /// future version's new defaults reach existing installs without touching
    /// the user's file.
    public static let `default` = NoPeekConfig()

    // MARK: - Built-in lists (spec §7, verbatim — order matters)

    /// RMM / remote / capture-capable agents that fail the "org agent" check.
    /// Matched as case-insensitive substrings of the process name or path.
    public static let defaultOrgPatterns: [String] = [
        "/Library/ManageEngine/", "dcondemand", "PanGPS", "GlobalProtect",
        "CloudflareWARP", "TeamViewer", "AnyDesk", "ScreenConnect",
        "ConnectWise", "Splashtop", "SRService", "RustDesk", "LogMeIn",
        "LMIGuardianSvc", "GoToAssist", "AteraAgent", "winagent", "dwagent",
        "KaseyaAgent", "AgentMon", "ZohoAssist", "TaniumClient", "Tanium",
    ]

    /// Remote-control process names (spec §7 watchlist for `ProcessWatch`).
    public static let defaultRemoteControl: [String] = [
        "screensharingd", "ARDAgent", "RemoteManagement", "remoting_host",
        "AnyDesk", "TeamViewer", "ScreenConnect", "SRService", "Splashtop",
        "rustdesk", "dwagent", "winagent",
    ]

    /// macOS's own window-management chatter: logged, never notified.
    public static let defaultSystemNoise: [String] = [
        "WindowManager", "Dock", "ControlCenter",
    ]

    // MARK: - Effective lists (ruling F1)

    /// Patterns for `Classifier(org:)`: the built-in list plus the user's,
    /// unless `replaceDefaultLists` swaps the built-ins out entirely.
    public var effectiveOrgPatterns: [String] {
        replaceDefaultLists
            ? orgPatterns
            : Self.dedupePreservingOrder(Self.defaultOrgPatterns + orgPatterns)
    }

    /// Watchlist for `ProcessWatch`: the built-in list plus `remoteControlExtra`.
    public var effectiveRemoteControl: [String] {
        replaceDefaultLists
            ? remoteControlExtra
            : Self.dedupePreservingOrder(Self.defaultRemoteControl + remoteControlExtra)
    }

    /// Patterns for `Classifier(noise:)`: the built-in list plus `systemNoiseExtra`.
    public var effectiveSystemNoise: [String] {
        replaceDefaultLists
            ? systemNoiseExtra
            : Self.dedupePreservingOrder(Self.defaultSystemNoise + systemNoiseExtra)
    }

    /// Exact-string dedupe that keeps the first occurrence — so a built-in
    /// entry always wins over a user's duplicate, and the merged order stays
    /// stable (defaults first, user's additions after).
    static func dedupePreservingOrder(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case language, sound, bannerOnForRemote, bannerLevel
        case orgBannerCooldownSeconds, logRetentionDays, gapAlertThresholdMinutes
        case replaceDefaultLists
        case orgPatterns, remoteControlExtra, systemNoiseExtra, allowlist
    }

    /// Tolerant decoding: every key is optional and falls back to its spec §7
    /// default. Unknown keys are ignored. A wrong-typed key throws — the store
    /// turns that into the all-defaults fallback plus `lastError`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = NoPeekConfig.default

        self.language = try container.decodeIfPresent(String.self, forKey: .language)
            ?? fallback.language
        self.sound = try container.decodeIfPresent(Bool.self, forKey: .sound)
            ?? fallback.sound
        self.bannerOnForRemote = try container.decodeIfPresent(Bool.self, forKey: .bannerOnForRemote)
            ?? fallback.bannerOnForRemote
        self.bannerLevel = try container.decodeIfPresent(String.self, forKey: .bannerLevel)
            ?? fallback.bannerLevel
        self.orgBannerCooldownSeconds = try container.decodeIfPresent(Int.self, forKey: .orgBannerCooldownSeconds)
            ?? fallback.orgBannerCooldownSeconds
        self.logRetentionDays = try container.decodeIfPresent(Int.self, forKey: .logRetentionDays)
            ?? fallback.logRetentionDays
        self.gapAlertThresholdMinutes = try container.decodeIfPresent(Int.self, forKey: .gapAlertThresholdMinutes)
            ?? fallback.gapAlertThresholdMinutes
        self.replaceDefaultLists = try container.decodeIfPresent(Bool.self, forKey: .replaceDefaultLists)
            ?? fallback.replaceDefaultLists
        self.orgPatterns = try container.decodeIfPresent([String].self, forKey: .orgPatterns)
            ?? fallback.orgPatterns
        self.remoteControlExtra = try container.decodeIfPresent([String].self, forKey: .remoteControlExtra)
            ?? fallback.remoteControlExtra
        self.systemNoiseExtra = try container.decodeIfPresent([String].self, forKey: .systemNoiseExtra)
            ?? fallback.systemNoiseExtra
        self.allowlist = try container.decodeIfPresent([String].self, forKey: .allowlist)
            ?? fallback.allowlist
    }
}

// MARK: - ConfigStore

/// Owns `~/.config/nopeek/config.json`: reads it, merges the built-in lists,
/// writes it back, and reloads when it changes on disk (spec §7).
///
/// **Reading.**
/// - Missing file → the default file is written (parent directories included)
///   and the store reports the defaults with `lastError == nil`.
/// - Broken file — invalid JSON, or a wrong-typed key → *every* key falls back
///   to its default and `lastError` explains why. Nothing partial is ever
///   applied, so the org rules survive a malformed file (Review Focus #3); the
///   broken file itself is left untouched for the user to fix.
/// - Missing keys in an otherwise valid file fall back per key.
///
/// **Writing (ruling F2).** `update(_:)` applies the mutation to the current
/// config, writes the whole config back as pretty-printed JSON (atomically,
/// so readers never see a half-written file), then runs the same reload path
/// as a file change — `config` always reports what is on disk, never a value
/// that failed to persist.
///
/// **Watching.** `startWatching()` attaches a `DispatchSource` to the file
/// itself (`O_EVTONLY`, no read permission needed) and fires `onChange` on the
/// store's private serial queue after a short debounce — writers emit several
/// events per save and a reload mid-write would see partial JSON.
/// - *Delete / rename* (a plain delete, or the atomic "write temp, rename
///   over" save pattern): the watched vnode is gone. The dead source is
///   dropped, the file is read again — a truly deleted file is recreated from
///   the defaults — and the watcher re-attaches to the path *before*
///   `onChange` fires, so no later write is missed.
/// - If the path cannot be opened at all, `armWatcher` retries briefly and
///   records the reason in `lastError`.
/// - `stopWatching()` detaches and cancels pending work.
///
/// **Threading.** `config` and `lastError` are lock-protected and safe to read
/// from any thread. `onChange` is invoked on the calling thread for
/// `update(_:)` and on the store's private queue for watcher events; hop to
/// the main actor in the app layer when UI is touched. Consumers must be
/// idempotent: an update made while watching surfaces once for the update and
/// once more when the watcher observes the write.
public final class ConfigStore: @unchecked Sendable {

    // MARK: - Defaults

    /// Alias for `NoPeekConfig.default` (plan T10 names it here).
    public static let defaultConfig = NoPeekConfig.default

    // MARK: - Pinned interface

    private let url: URL
    private let onChange: (NoPeekConfig) -> Void

    /// Guards `_config` / `_lastError`: written by reloads (watcher queue or
    /// the caller of `update`), read by the public getters from anywhere.
    private let lock = NSLock()
    private var _config: NoPeekConfig
    private var _lastError: String?

    /// The config most recently applied from disk. Defaults until the first
    /// successful `load()`.
    public private(set) var config: NoPeekConfig {
        get { lock.withLock { _config } }
        set { lock.withLock { _config = newValue } }
    }

    /// Why the last read failed (invalid JSON, wrong-typed key, unreadable or
    /// un-creatable file); `nil` when the last read succeeded.
    public private(set) var lastError: String? {
        get { lock.withLock { _lastError } }
        set { lock.withLock { _lastError = newValue } }
    }

    // MARK: - Watch state (watchQueue's domain; `deinit` is the one exception)

    /// Marks the watch queue so start/stop can be called from a callback.
    private static let watchQueueKey = DispatchSpecificKey<UInt8>()
    private let watchQueue: DispatchQueue
    /// Gap between a file event and the reload it triggers.
    private static let debounceInterval: TimeInterval = 0.1
    /// How long `armWatcher` waits before retrying an unopenable path.
    private static let armRetryDelay: TimeInterval = 0.5
    private static let maxArmAttempts = 10

    private var source: DispatchSourceFileSystemObject?
    /// Bumped whenever the source is replaced, so events queued by a source we
    /// already dropped are ignored.
    private var generation = 0
    private var isWatching = false
    private var debounce: DispatchWorkItem?
    private var retry: DispatchWorkItem?

    // MARK: - Init

    public init(url: URL, onChange: @escaping (NoPeekConfig) -> Void) {
        self.url = url
        self.onChange = onChange
        self._config = NoPeekConfig.default
        self._lastError = nil
        self.watchQueue = DispatchQueue(label: "com.sinsombat.nopeek.config.watch")
        watchQueue.setSpecific(key: Self.watchQueueKey, value: 1)
    }

    deinit {
        // Cancel from the deinit side: the handlers capture `self` weakly, so
        // nothing else can be touching this state anymore. The source's cancel
        // handler closes its descriptor.
        debounce?.cancel()
        retry?.cancel()
        source?.cancel()
    }

    // MARK: - Loading

    /// Reads the config from disk and applies it.
    ///
    /// Never throws and never notifies `onChange`: this is the bootstrap read,
    /// not a change. Failures are reported through `lastError` while the
    /// all-defaults config stays in force (Review Focus #3).
    public func load() {
        reload(notify: false)
    }

    /// Applies `mutate` to the current config, persists the whole config as
    /// pretty-printed JSON, then reloads through the same path as a file
    /// change (so `config` and observers only ever see what is on disk) and
    /// notifies `onChange`.
    ///
    /// Throws when the file cannot be written; the in-memory config is left
    /// untouched in that case.
    public func update(_ mutate: (inout NoPeekConfig) -> Void) throws {
        var draft = config
        mutate(&draft)
        try write(Self.encode(draft))
        reload(notify: true)
    }

    // MARK: - Watching

    /// Attaches the file watcher (idempotent). Returns once the file is being
    /// watched, or — when it cannot be opened yet — with a retry scheduled;
    /// a missing file is (re)created along the way as `load()` would.
    public func startWatching() {
        syncOnWatchQueue { [self] in
            guard !isWatching else { return }
            isWatching = true
            armWatcher(attempt: 0)
        }
    }

    /// Detaches the watcher and cancels pending reload/retry work.
    /// `onChange` stops firing. Safe to call when not watching.
    public func stopWatching() {
        syncOnWatchQueue { [self] in
            isWatching = false
            debounce?.cancel()
            debounce = nil
            retry?.cancel()
            retry = nil
            cancelSource()
        }
    }

    /// Runs `body` on the watch queue, reentrantly when already there.
    private func syncOnWatchQueue(_ body: () -> Void) {
        if DispatchQueue.getSpecific(key: Self.watchQueueKey) != nil {
            body()
        } else {
            watchQueue.sync(execute: body)
        }
    }

    /// Opens the file and starts a fresh source. A dead file (open fails) is
    /// answered with a reload — which recreates the default file when the path
    /// is missing — and a bounded retry.
    private func armWatcher(attempt: Int) {
        guard isWatching, source == nil else { return }

        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else {
            reload(notify: true)
            guard attempt < Self.maxArmAttempts else {
                lastError = "could not watch the config at \(url.path)"
                return
            }
            let work = DispatchWorkItem { [weak self] in
                self?.armWatcher(attempt: attempt + 1)
            }
            retry?.cancel()
            retry = work
            watchQueue.asyncAfter(deadline: .now() + Self.armRetryDelay, execute: work)
            return
        }

        generation += 1
        let generation = generation
        let added = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .link, .delete, .rename, .revoke],
            queue: watchQueue
        )
        // The handler captures only `self` (weakly) and the generation — never
        // the source itself, so there is no retain cycle to cancel out of.
        added.setEventHandler { [weak self] in
            guard let self,
                  generation == self.generation,
                  let source = self.source
            else { return }
            self.handle(source.data)
        }
        added.setCancelHandler {
            close(descriptor)
        }
        source = added
        added.resume()
    }

    private func cancelSource() {
        generation += 1
        source?.cancel()
        source = nil
    }

    private func handle(_ event: DispatchSource.FileSystemEvent) {
        if event.contains(.delete) || event.contains(.rename) || event.contains(.revoke) {
            // The watched vnode is gone — a plain delete, or an atomic save
            // that replaced the file. Drop the dead source, then recreate/read
            // and re-attach before notifying, so observers never see a config
            // the watcher is not yet following.
            cancelSource()
            debounceReload(rearm: true)
        } else {
            // write / extend / attrib / link: the content may still be
            // arriving; the debounce coalesces the burst into one reload.
            debounceReload(rearm: false)
        }
    }

    private func debounceReload(rearm: Bool) {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isWatching else { return }
            if rearm {
                // Silent read first: recreates a truly deleted file, and for an
                // atomic save picks up the new content.
                self.reload(notify: false)
                self.armWatcher(attempt: 0)
            }
            self.reload(notify: true)
        }
        debounce = work
        watchQueue.asyncAfter(deadline: .now() + Self.debounceInterval, execute: work)
    }

    // MARK: - Disk I/O

    private func reload(notify: Bool) {
        let (next, error) = Self.resolve(at: url)
        config = next
        lastError = error
        if notify {
            onChange(next)
        }
    }

    private func write(_ data: Data) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    /// Reads `url` and produces the config to apply plus the error to record.
    /// A missing file is materialized first, so "the file exists" is an
    /// invariant after any `load()` or watched reload.
    private static func resolve(at url: URL) -> (config: NoPeekConfig, error: String?) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            do {
                try writeDefaultFile(to: url)
                return (NoPeekConfig.default, nil)
            } catch {
                return (
                    NoPeekConfig.default,
                    "could not create the default config at \(url.path): \(describe(error))"
                )
            }
        }

        do {
            let data = try Data(contentsOf: url)
            return (try JSONDecoder().decode(NoPeekConfig.self, from: data), nil)
        } catch {
            // Review Focus #3: an unreadable or malformed file applies nothing.
            // Every key — including the org rules — stays at its default.
            return (
                NoPeekConfig.default,
                "could not read the config at \(url.path): \(describe(error))"
            )
        }
    }

    private static func writeDefaultFile(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encode(NoPeekConfig.default).write(to: url, options: .atomic)
    }

    /// Pretty-printed JSON with sorted keys and unescaped slashes: stable
    /// diffs, and `/Library/ManageEngine/` stays readable, exactly the spec §7
    /// file shape.
    private static func encode(_ config: NoPeekConfig) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(config)
        data.append(0x0A) // trailing newline, so the file behaves in editors
        return data
    }

    private static func describe(_ error: Error) -> String {
        if let decoding = error as? DecodingError {
            return String(describing: decoding)
        }
        return error.localizedDescription
    }
}
