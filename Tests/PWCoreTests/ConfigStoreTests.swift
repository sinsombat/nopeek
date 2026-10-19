import Foundation
import Testing

import PWCore

/// Tests for `NoPeekConfig` + `ConfigStore` (spec §7, plan T10).
///
/// Every test works in a throwaway directory under
/// `FileManager.temporaryDirectory` — never `~/.config/nopeek` — so the suite
/// can neither read nor rewrite the real config, and no TCC-sensitive path is
/// touched.
///
/// Watcher tests block on `onChange` through a bounded poll (≤ 2 s) and always
/// stop watching before their scratch directory is removed. No test assumes
/// which thread the callback arrives on: the store may call back from its
/// watcher queue.
@Suite struct ConfigStoreTests {

    // MARK: - Helpers

    /// Collects `onChange` values; safe to read and write from any thread.
    private final class CallbackRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [NoPeekConfig] = []

        func record(_ config: NoPeekConfig) {
            lock.lock()
            defer { lock.unlock() }
            values.append(config)
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return values.count
        }

        var last: NoPeekConfig? {
            lock.lock()
            defer { lock.unlock() }
            return values.last
        }
    }

    private static func scratchDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("nopeek-config-\(UUID().uuidString)")
    }

    private static func cleanup(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Writes `text` to `url`, creating missing parent directories.
    private static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
    }

    /// Polls `condition` every 20 ms until it is true or `timeout` elapses and
    /// reports the final result. Bounded on purpose: a missed watcher event
    /// fails the assertion instead of hanging the suite.
    private static func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    private static func decodeConfig(at url: URL) throws -> NoPeekConfig {
        try JSONDecoder().decode(NoPeekConfig.self, from: Data(contentsOf: url))
    }

    // MARK: - Spec §7 defaults

    @Test func testDefaultsMatchSpec() {
        let config = NoPeekConfig.default

        // Scalars (spec §7, literal).
        #expect(config.language == "th")
        #expect(config.sound == true)
        #expect(config.bannerOnForRemote == true)
        #expect(config.bannerLevel == "screenSaver")
        #expect(config.orgBannerCooldownSeconds == 60)
        #expect(config.logRetentionDays == 30)
        #expect(config.gapAlertThresholdMinutes == 15)
        #expect(config.replaceDefaultLists == false)

        // User lists start empty: defaults are merged at read time, never
        // copied into the file.
        #expect(config.orgPatterns.isEmpty)
        #expect(config.remoteControlExtra.isEmpty)
        #expect(config.systemNoiseExtra.isEmpty)
        #expect(config.allowlist.isEmpty)

        // Default org patterns (spec §7): count, spot checks and full order.
        #expect(NoPeekConfig.defaultOrgPatterns.count == 23)
        #expect(NoPeekConfig.defaultOrgPatterns.contains("/Library/ManageEngine/"))
        #expect(NoPeekConfig.defaultOrgPatterns.contains("TaniumClient"))
        #expect(NoPeekConfig.defaultOrgPatterns == [
            "/Library/ManageEngine/", "dcondemand", "PanGPS", "GlobalProtect",
            "CloudflareWARP", "TeamViewer", "AnyDesk", "ScreenConnect",
            "ConnectWise", "Splashtop", "SRService", "RustDesk", "LogMeIn",
            "LMIGuardianSvc", "GoToAssist", "AteraAgent", "winagent", "dwagent",
            "KaseyaAgent", "AgentMon", "ZohoAssist", "TaniumClient", "Tanium",
        ])

        // Remote-control watchlist (spec §7).
        #expect(NoPeekConfig.defaultRemoteControl.count == 12)
        #expect(NoPeekConfig.defaultRemoteControl.contains("screensharingd"))
        #expect(NoPeekConfig.defaultRemoteControl == [
            "screensharingd", "ARDAgent", "RemoteManagement", "remoting_host",
            "AnyDesk", "TeamViewer", "ScreenConnect", "SRService", "Splashtop",
            "rustdesk", "dwagent", "winagent",
        ])

        // System noise (spec §7).
        #expect(NoPeekConfig.defaultSystemNoise.count == 3)
        #expect(NoPeekConfig.defaultSystemNoise == ["WindowManager", "Dock", "ControlCenter"])

        #expect(ConfigStore.defaultConfig == NoPeekConfig.default)
    }

    // MARK: - Effective lists (ruling F1)

    @Test func testMergeUnion() {
        let config = NoPeekConfig(
            orgPatterns: ["CustomAgent", "Tanium", "CustomAgent"],
            remoteControlExtra: ["CustomRemote", "winagent"],
            systemNoiseExtra: ["CustomNoise", "Dock"]
        )

        // Defaults first, then the user's additions, deduped on exact string
        // match (first occurrence wins).
        let org = config.effectiveOrgPatterns
        #expect(org.count == 24) // 23 defaults + 1 unique custom
        #expect(org.first == "/Library/ManageEngine/")
        #expect(org.last == "CustomAgent")
        #expect(org.filter { $0 == "Tanium" }.count == 1)
        #expect(org.filter { $0 == "CustomAgent" }.count == 1)

        let remote = config.effectiveRemoteControl
        #expect(remote.count == 13) // 12 defaults + 1 unique custom
        #expect(remote.first == "screensharingd")
        #expect(remote.last == "CustomRemote")
        #expect(remote.filter { $0 == "winagent" }.count == 1)

        let noise = config.effectiveSystemNoise
        #expect(noise.count == 4) // 3 defaults + 1 unique custom
        #expect(noise.first == "WindowManager")
        #expect(noise.last == "CustomNoise")
        #expect(noise.filter { $0 == "Dock" }.count == 1)

        // The allowlist is a passthrough — never merged with anything.
        #expect(config.allowlist.isEmpty)
        #expect(NoPeekConfig(allowlist: ["/Applications/Trusted.app"]).allowlist == ["/Applications/Trusted.app"])
    }

    @Test func testReplaceDefaultLists() {
        let replaced = NoPeekConfig(
            replaceDefaultLists: true,
            orgPatterns: ["OnlyThis"],
            remoteControlExtra: ["OnlyThat"]
        )
        #expect(replaced.effectiveOrgPatterns == ["OnlyThis"])
        #expect(replaced.effectiveRemoteControl == ["OnlyThat"])
        #expect(replaced.effectiveSystemNoise.isEmpty)

        // With replaceDefaultLists the listed entries are used *instead*, so an
        // empty user list means "catch nothing" — the documented escape hatch,
        // not a silent fallback to the defaults.
        let emptied = NoPeekConfig(replaceDefaultLists: true)
        #expect(emptied.effectiveOrgPatterns.isEmpty)
        #expect(emptied.effectiveRemoteControl.isEmpty)
        #expect(emptied.effectiveSystemNoise.isEmpty)
    }

    // MARK: - Loading

    @Test func testMissingFileCreatesDefault() throws {
        let directory = Self.scratchDirectory()
        defer { Self.cleanup(directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("config.json")

        let store = ConfigStore(url: url) { _ in }
        store.load()

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(store.config == NoPeekConfig.default)
        #expect(store.lastError == nil)

        // The written file is a complete config, not a stub: it decodes back
        // to the defaults.
        #expect(try Self.decodeConfig(at: url) == NoPeekConfig.default)
    }

    @Test func testMissingParentDirectoryIsCreated() throws {
        let directory = Self.scratchDirectory()
        defer { Self.cleanup(directory) }
        // `nested/` does not exist yet — first run on a clean machine.
        let url = directory.appendingPathComponent("nested/config.json")

        let store = ConfigStore(url: url) { _ in }
        store.load()

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(store.config == NoPeekConfig.default)
        #expect(store.lastError == nil)
    }

    @Test func testPartialFileUsesPerKeyDefaults() throws {
        let directory = Self.scratchDirectory()
        defer { Self.cleanup(directory) }
        let url = directory.appendingPathComponent("config.json")
        // Hand-edited file with two keys; everything else must fall back to
        // its spec §7 default instead of failing the whole read.
        try Self.write(#"{"sound": false, "orgPatterns": ["CustomAgent"]}"#, to: url)

        let store = ConfigStore(url: url) { _ in }
        store.load()

        #expect(store.lastError == nil)
        #expect(store.config.sound == false)
        #expect(store.config.language == "th")
        #expect(store.config.bannerOnForRemote == true)
        #expect(store.config.bannerLevel == "screenSaver")
        #expect(store.config.orgBannerCooldownSeconds == 60)
        #expect(store.config.logRetentionDays == 30)
        #expect(store.config.gapAlertThresholdMinutes == 15)
        #expect(store.config.replaceDefaultLists == false)
        #expect(store.config.orgPatterns == ["CustomAgent"])
        #expect(store.config.remoteControlExtra.isEmpty)
        #expect(store.config.systemNoiseExtra.isEmpty)
        #expect(store.config.allowlist.isEmpty)
        // The partial read still merges onto the full default lists.
        #expect(store.config.effectiveOrgPatterns.count == 24)
    }

    @Test func testInvalidJSONFallsBackToDefaultsAndSetsLastError() throws {
        let directory = Self.scratchDirectory()
        defer { Self.cleanup(directory) }
        let url = directory.appendingPathComponent("config.json")
        let contents = "{ this is not json"
        try Self.write(contents, to: url)

        let store = ConfigStore(url: url) { _ in }
        store.load()

        // Review Focus #3: a broken file must not half-apply. Every key —
        // especially the org rules — falls back to its default, so the app
        // still catches org agents.
        #expect(store.config == NoPeekConfig.default)
        #expect(store.config.effectiveOrgPatterns == NoPeekConfig.defaultOrgPatterns)
        #expect(store.lastError != nil)
        // A broken user file is left exactly as written for the user to fix.
        #expect(try String(contentsOf: url, encoding: .utf8) == contents)
    }

    @Test func testTypeMismatchFallsBackToDefaults() throws {
        let directory = Self.scratchDirectory()
        defer { Self.cleanup(directory) }
        let url = directory.appendingPathComponent("config.json")
        // `orgPatterns` has the wrong type; `sound` is valid but must not be
        // applied either — the read is all-or-nothing.
        try Self.write(#"{"orgPatterns": "not-an-array", "sound": false}"#, to: url)

        let store = ConfigStore(url: url) { _ in }
        store.load()

        #expect(store.config == NoPeekConfig.default)
        #expect(store.lastError != nil)
    }

    // MARK: - Watching (spec §7 auto-reload)

    @Test func testReloadCallback() async throws {
        let directory = Self.scratchDirectory()
        let url = directory.appendingPathComponent("config.json")
        try Self.write(#"{"sound": false}"#, to: url)
        let recorder = CallbackRecorder()
        let store = ConfigStore(url: url) { recorder.record($0) }
        defer {
            store.stopWatching()
            Self.cleanup(directory)
        }

        store.load()
        #expect(store.config.sound == false)
        #expect(recorder.count == 0) // load() is a read, not a change

        store.startWatching()
        try Self.write(#"{"sound": true, "allowlist": ["/Applications/Trusted.app"]}"#, to: url)

        let fired = await Self.waitUntil { recorder.count >= 1 }
        #expect(fired)
        #expect(recorder.last?.sound == true)
        #expect(recorder.last?.allowlist == ["/Applications/Trusted.app"])
        #expect(store.config.allowlist == ["/Applications/Trusted.app"])
        #expect(store.lastError == nil)
    }

    @Test func testWatcherRecreatesDeletedFileAndKeepsWorking() async throws {
        let directory = Self.scratchDirectory()
        let url = directory.appendingPathComponent("config.json")
        try Self.write(#"{"sound": false}"#, to: url)
        let recorder = CallbackRecorder()
        let store = ConfigStore(url: url) { recorder.record($0) }
        defer {
            store.stopWatching()
            Self.cleanup(directory)
        }

        store.load()
        store.startWatching()

        try FileManager.default.removeItem(at: url)

        // Documented delete policy: the default file is recreated and the
        // store falls back to the default config; the re-arm happens before
        // the notification, so a write observed after this point is seen.
        let notified = await Self.waitUntil { recorder.last == NoPeekConfig.default }
        #expect(notified)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(store.config == NoPeekConfig.default)

        // The watcher re-armed on the recreated file: later writes arrive.
        try Self.write(#"{"sound": true, "allowlist": ["/Applications/Trusted.app"]}"#, to: url)
        let fired = await Self.waitUntil { recorder.last?.allowlist == ["/Applications/Trusted.app"] }
        #expect(fired)
        #expect(store.config.sound == true)
    }

    // MARK: - Update (ruling F2)

    @Test func testUpdateWhileWatchingKeepsWatcherArmed() async throws {
        let directory = Self.scratchDirectory()
        let url = directory.appendingPathComponent("config.json")
        try Self.write(#"{"sound": false}"#, to: url)
        let recorder = CallbackRecorder()
        let store = ConfigStore(url: url) { recorder.record($0) }
        defer {
            store.stopWatching()
            Self.cleanup(directory)
        }

        store.load()
        store.startWatching()

        // Our own save is atomic, so it replaces the vnode the watcher is
        // attached to: the watcher must re-arm by itself. The reload count
        // reaching 2 proves it observed the save (one callback for the update,
        // one for the watcher — documented behaviour).
        try store.update { $0.allowlist = ["/Applications/Trusted.app"] }
        #expect(store.config.allowlist == ["/Applications/Trusted.app"])
        let rearmed = await Self.waitUntil { recorder.count >= 2 }
        #expect(rearmed)

        // An external edit after our own save must still be seen.
        try Self.write(#"{"sound": true, "allowlist": ["/Applications/Other.app"]}"#, to: url)
        let fired = await Self.waitUntil { recorder.last?.allowlist == ["/Applications/Other.app"] }
        #expect(fired)
        #expect(store.config.sound == true)
    }

    @Test func testUpdatePersistsAndReloads() throws {
        let directory = Self.scratchDirectory()
        let url = directory.appendingPathComponent("config.json")
        let recorder = CallbackRecorder()
        let store = ConfigStore(url: url) { recorder.record($0) }
        defer { Self.cleanup(directory) }

        store.load() // missing file → default written

        try store.update { config in
            config.allowlist = ["/Applications/Trusted.app"]
            config.sound = false
        }

        // Same reload path as the watcher: observers see the new value and
        // `config` reports what is on disk.
        #expect(store.config.allowlist == ["/Applications/Trusted.app"])
        #expect(store.config.sound == false)
        #expect(store.lastError == nil)
        #expect(recorder.count == 1)
        #expect(recorder.last?.allowlist == ["/Applications/Trusted.app"])

        // The file really is the full config, pretty-printed JSON.
        let decoded = try Self.decodeConfig(at: url)
        #expect(decoded.allowlist == ["/Applications/Trusted.app"])
        #expect(decoded.sound == false)
        #expect(decoded.language == "th")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("\n"))
        // Slashes are not escaped, so paths stay readable in the file.
        #expect(text.contains("\"/Applications/Trusted.app\""))
        #expect(!text.contains("\\/"))

        // A second update mutates the *current* config (allowlist survives).
        try store.update { $0.orgPatterns.append("CustomAgent") }
        #expect(store.config.allowlist == ["/Applications/Trusted.app"])
        #expect(store.config.orgPatterns == ["CustomAgent"])
    }

    @Test func testUpdateThrowsWhenWriteFails() throws {
        let directory = Self.scratchDirectory()
        defer { Self.cleanup(directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A path whose parent "directory" is a regular file: both the default
        // write and the update write must fail.
        let blocker = directory.appendingPathComponent("blocker")
        try Self.write("not a directory", to: blocker)
        let url = blocker.appendingPathComponent("config.json")

        let store = ConfigStore(url: url) { _ in }
        store.load()
        #expect(store.config == NoPeekConfig.default)
        #expect(store.lastError != nil)

        var threw = false
        do {
            try store.update { $0.sound = false }
        } catch {
            threw = true
        }
        #expect(threw)
        // A failed write leaves the in-memory config untouched.
        #expect(store.config == NoPeekConfig.default)
    }

    // MARK: - Auto-kill keys (T21, spec §7/§6d)

    @Test func testAutoKillDefaultsAreOptedOut() {
        // Ruling R17: auto-kill is off unless the user turns it on and names
        // the processes themselves.
        let config = NoPeekConfig.default
        #expect(config.autoKillEnabled == false)
        #expect(config.autoKillNames.isEmpty)
        #expect(config.autoKillMaxPerHour == 5)

        // The three keys are part of the written shape, so an existing install
        // picks the defaults up from its own file.
        #expect(
            NoPeekConfig(
                autoKillEnabled: true,
                autoKillNames: ["sleep"],
                autoKillMaxPerHour: 2
            ).autoKillEnabled == true
        )
    }

    @Test func testAutoKillKeysDecodeFromTheFile() throws {
        let directory = Self.scratchDirectory()
        defer { Self.cleanup(directory) }
        let url = directory.appendingPathComponent("config.json")
        try Self.write(
            #"{"autoKillEnabled": true, "autoKillNames": ["sleep", "dwagent"], "autoKillMaxPerHour": 2}"#,
            to: url
        )

        let store = ConfigStore(url: url) { _ in }
        store.load()

        #expect(store.lastError == nil)
        #expect(store.config.autoKillEnabled == true)
        #expect(store.config.autoKillNames == ["sleep", "dwagent"])
        #expect(store.config.autoKillMaxPerHour == 2)
        // Per-key tolerance is unchanged: everything else is still spec §7.
        #expect(store.config.sound == true)
        #expect(store.config.logRetentionDays == 30)
    }

    @Test func testAutoKillKeysPersistThroughTheDefaultFile() throws {
        let directory = Self.scratchDirectory()
        defer { Self.cleanup(directory) }
        let url = directory.appendingPathComponent("config.json")

        let store = ConfigStore(url: url) { _ in }
        store.load() // missing file → the default file is written

        #expect(try Self.decodeConfig(at: url) == NoPeekConfig.default)
        let text = try String(contentsOf: url, encoding: .utf8)
        for key in ["autoKillEnabled", "autoKillNames", "autoKillMaxPerHour"] {
            #expect(text.contains("\"\(key)\""), "the default file must carry \(key)")
        }

        // Writes go through the same store path T23's Settings window will use.
        try store.update { config in
            config.autoKillEnabled = true
            config.autoKillNames = ["sleep"]
            config.autoKillMaxPerHour = 3
        }

        let reread = try Self.decodeConfig(at: url)
        #expect(reread.autoKillEnabled == true)
        #expect(reread.autoKillNames == ["sleep"])
        #expect(reread.autoKillMaxPerHour == 3)
        #expect(store.config == reread)
    }
}
