import CoreAudio
import Foundation

// MARK: - MicWatch

/// Edge-triggered watch over the system microphone (spec §3/§4-E; plan T15).
///
/// The camera can be watched through the log stream — the capturing app's own
/// `AVCaptureSession` lifecycle lines (the T14 field-test fix) — but macOS
/// emits no comparable line for microphone use, so this watch **polls a system
/// property every 2 s** and reports the transitions:
///
/// - `micOn` on the first tick that sees an input device running;
/// - `micOff` on the first tick that sees it still down **more than
///   `offDebounce`** (5 s) after the off stretch was first observed.
///
/// Nothing else is ever emitted: a mic that stays in use across ticks is not
/// news (a 2 s poll would otherwise write 30 identical lines a minute), and one
/// that stays down is not news at all. A mic that goes down and comes back
/// inside the debounce window is **one continuous usage** — neither a `micOff`
/// nor a second `micOn` (`testOffDebounce`) — which is what the debounce is for:
/// push-to-talk releases, app switches and mute toggles are seconds long, and
/// "off" moments measured in a couple of seconds are not a story the user needs
/// told.
///
/// **The device rule is narrower than "audio hardware is running" (spec §4-E).**
/// A device counts as in use only when it has **input streams**
/// (`kAudioDevicePropertyStreamConfiguration` in the input scope) *and*
/// `kAudioDevicePropertyDeviceIsRunningSomewhere` is `1`. The conjunction is not
/// belt-and-braces: `DeviceIsRunningSomewhere` answers "is any IO running on
/// this device", which the built-in speakers raise for mere playback — on the
/// development machine `MacBook Pro Speakers` reports `1` while the microphone
/// reports `0`, and a watch built on the property alone would call every sound
/// the user hears a microphone event. Filtering to devices that actually have
/// input streams is what keeps speaker playback and output-only virtual drivers
/// out of the mic tier.
///
/// **No microphone permission is asked for, ever.** Reading whether a device is
/// running is not audio capture: nothing here opens an IO proc, starts a device,
/// taps a stream, requests authorization, or declares a usage description (spec
/// §3: NoPeek never captures; it reads state). `kAudioDevicePropertyDeviceIsRunningSomewhere`
/// is precisely the property that answers that question *without* joining the
/// set of processes it reports on. Only notification delivery carries a
/// permission anywhere in NoPeek.
///
/// **The tccd side effect, measured.** Touching the HAL at all — even a bare
/// `kAudioHardwarePropertyDevices` enumeration — makes `coreaudiod` run a few
/// *preflights* through `tccd` once per process, attributed to the responsible
/// process (for the app: NoPeek): `kTCCServiceMicrophone` and
/// `kTCCServiceAudioCapture` answered allowed, `kTCCServiceScreenCapture`
/// answered denied-system-set, all with `preflight=yes` and `promptPolicy = 0`,
/// never as a prompt. Measured on the development machine over 8 ticks at the
/// full 2 s cadence: the same three preflights at the first tick and **zero**
/// tccd traffic afterwards — no per-poll cost. It is the HAL's own behaviour for
/// reading device state (the T14 A/B measured the same trio when the
/// since-removed `AVCaptureDevice` poll enumerated devices — AVFoundation
/// touches the same HAL), not a request NoPeek makes; measured evidence and the
/// decision live in the T15 report.
///
/// **Attribution is deliberately absent in v1.** Spec §4-E asks for best-effort
/// actor attribution by correlating the mic transition with log lines within
/// ±3 s, but the reader's predicate (`LogStreamReader.defaultPredicate`) carries
/// no microphone lines at all — the `tccd` clause is ScreenCapture-only — so
/// there is no data to correlate against and the actor stays the literal `"mic"`
/// (the T14 ruling, applied to T15; see the T15 report).
///
/// **Threading.** Like `ProcessWatch` and `Throttler` this class keeps state
/// across ticks and is deliberately not thread-safe: one owner drives it. In
/// the app that owner is the reader's serial callback queue (see
/// `LogStreamReader.performSerialized`), so the polls serialize with the log
/// lines and the process-watch polls feeding the same `Pipeline`.
public final class MicWatch {

    // MARK: - System probe

    /// `true` when any input device on the machine is running somewhere
    /// (spec §4-E).
    ///
    /// This is the production `inUse` closure and the only place NoPeek touches
    /// CoreAudio. Every audio device the HAL knows is enumerated, then narrowed
    /// to the ones that have input streams and are actually running; a device a
    /// *different* app is running reports `true` here, and NoPeek's own process
    /// never starts any audio IO, so it can never see itself.
    public static var systemInUse: Bool {
        deviceIDs().contains { hasInputStreams($0) && isRunningSomewhere($0) }
    }

    /// Every audio device the HAL knows right now: the system object's
    /// `kAudioHardwarePropertyDevices` list. A fresh read per call: a cached
    /// list could freeze the device set, and at a 2 s cadence the enumeration
    /// is cheap enough that freshness wins (a headset plugged in mid-meeting
    /// must show up).
    static func deviceIDs() -> [AudioDeviceID] {
        var address = propertyAddress(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return [] }

        var devices = [AudioDeviceID](
            repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices
        ) == noErr else { return [] }
        return devices
    }

    /// Whether the device has any input streams — the half of the rule that
    /// keeps output-only hardware (built-in speakers, output-only virtual
    /// drivers) out of the mic tier. See the class documentation.
    ///
    /// A device without an input scope, or one that answers with an empty
    /// stream list, is not an input device. Every failure answers `false`: an
    /// unreadable device must never be reported as a microphone in use.
    static func hasInputStreams(_ device: AudioDeviceID) -> Bool {
        var address = propertyAddress(
            kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size > 0
        else { return false }

        // `kAudioDevicePropertyStreamConfiguration` is a variable-length
        // `AudioBufferList`: one buffer per stream, each with the channel count.
        // Allocate to the reported size, then read it as a buffer list and keep
        // the device only if at least one buffer carries channels.
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr
        else { return false }

        let streams = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self)
        )
        return streams.contains { $0.mNumberChannels > 0 }
    }

    /// Whether anything at all is running IO on the device (spec §4-E's pinned
    /// `kAudioDevicePropertyDeviceIsRunningSomewhere` == 1). Read-only: this is
    /// the property that reports on IO, not one that starts it. A property the
    /// device does not implement, or any read failure, answers `false` — never
    /// a spurious `micOn`.
    static func isRunningSomewhere(_ device: AudioDeviceID) -> Bool {
        var address = propertyAddress(kAudioDevicePropertyDeviceIsRunningSomewhere)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var running: UInt32 = 0
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr
        else { return false }
        return running != 0
    }

    /// One HAL property address on the global scope's main element — the shape
    /// every device-level read here needs.
    private static func propertyAddress(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    // MARK: - Configuration

    /// The cadence the watch is built for (spec §3: every 2 s). The watch does
    /// **not** own a timer — the app does — but it carries the cadence so the
    /// two cannot drift apart: `AppController` schedules its timer with this
    /// value, and the tests reason about the debounce in these steps.
    public let interval: TimeInterval

    /// How long the mic must have been observed off, continuously, before
    /// `micOff` is emitted (spec §3: 5 s). "Observed off" starts at the first
    /// tick that saw it off, so the real off moment — somewhere in the
    /// `interval` before that tick — is never under-counted.
    public let offDebounce: TimeInterval

    /// The microphone state. Injected so tests drive fixed timelines;
    /// production is `MicWatch.systemInUse`.
    private let inUse: () -> Bool

    /// Source of "now" for the emitted timestamps and the debounce. Injected so
    /// tests pin both; production is the system clock.
    private let now: () -> Date

    // MARK: - State

    /// Whether the current usage spell has already been reported — the whole
    /// event edge state. `true` means a `micOn` is outstanding, so only a
    /// `micOff` may follow it; `false` means the next transition to in-use is
    /// the edge that fires.
    private var on = false

    /// When the current off stretch was first observed while `on` was `true`.
    /// `nil` whenever the mic is on or was never reported on; cleared by a tick
    /// that sees it back on — which is exactly the "continuously false" rule of
    /// spec §3.
    private var offSince: Date?

    // MARK: - Init

    public init(
        interval: TimeInterval = 2,
        offDebounce: TimeInterval = 5,
        inUse: @escaping () -> Bool = { MicWatch.systemInUse },
        now: @escaping () -> Date = Date.init
    ) {
        self.interval = interval
        self.offDebounce = offDebounce
        self.inUse = inUse
        self.now = now
    }

    // MARK: - Polling

    /// Polls the microphone once.
    ///
    /// Returns a `micOn` on the first tick that sees an input device running, a
    /// `micOff` on the first tick that sees it off for strictly longer than
    /// `offDebounce`, and `nil` on every other tick.
    ///
    /// Must be called from one serial queue (see the class documentation).
    public func tick() -> RawEvent? {
        let ts = now()

        if inUse() {
            // Back on (or still on): any off stretch was a blip, so the
            // debounce starts over on the next off tick.
            offSince = nil
            guard !on else { return nil }
            on = true
            return RawEvent(
                ts: ts,
                source: .mic,
                kind: .micOn,
                actor: Self.actor,
                rawSummary: Self.onSummary
            )
        }

        // Off. Nothing is outstanding unless a `micOn` was reported — a mic
        // that is never used is never news.
        guard on else { return nil }

        guard let since = offSince else {
            // First off tick of this spell: this timestamp — not the unknown
            // moment between the previous tick and this one — starts the
            // window, so the mic is never reported off early.
            offSince = ts
            return nil
        }

        guard ts.timeIntervalSince(since) > offDebounce else { return nil }

        on = false
        offSince = nil
        return RawEvent(
            ts: ts,
            source: .mic,
            kind: .micOff,
            actor: Self.actor,
            rawSummary: Self.offSummary
        )
    }

    // MARK: - Emitted event constants

    /// `actor` for every event this watch emits. Mic usage carries no app name
    /// in v1 (see the class documentation), so the tier falls through to NORMAL
    /// and the actor is the signal itself.
    private static let actor = "mic"

    /// Evidence-log summaries (spec §8's `rawSummary`): the raw record of the
    /// poll, like the log-line excerpt the parser writes for log events — not
    /// UI copy, so they live here rather than in the `Strings` table, which
    /// holds what the user reads (menus, notifications, banners).
    private static let onSummary = "ไมค์ถูกใช้ (poll)"
    private static let offSummary = "ไมค์ว่างแล้ว"
}
