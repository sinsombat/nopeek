import AVFoundation
import Foundation

// MARK: - CameraWatch

/// Edge-triggered watch over the system camera (spec §3/§4-D; plan T14).
///
/// macOS has no log stream NoPeek can politely subscribe to for camera use, so
/// — like the mic watch that follows it — this watch **polls a system property
/// every 2 s** and reports the transitions:
///
/// - `cameraOn` on the first tick that sees a camera in use by another app;
/// - `cameraOff` on the first tick that sees the camera still off **more than
///   `offDebounce`** (5 s) after the off stretch was first observed.
///
/// Nothing else is ever emitted: a camera that stays in use across ticks is not
/// news (a 2 s poll would otherwise write 30 identical lines a minute), and one
/// that stays off is not news at all. A camera that goes off and comes back
/// inside the debounce window is **one continuous usage** — neither a
/// `cameraOff` nor a second `cameraOn` (`testOffDebounce`) — which is what the
/// debounce is for: cameras are stopped and started routinely while a call
/// switches between apps, and "off" moments measured in a couple of seconds are
/// not a story the user needs told.
///
/// **No camera permission is asked for, ever.** Reading whether a device is in
/// use is not camera access: nothing here opens a capture session, requests
/// authorization, or declares a usage description (spec §3: NoPeek never
/// captures; it reads state). Only notification delivery carries a permission
/// anywhere in NoPeek.
///
/// **One tccd side effect, for the record.** Initializing AVFoundation's device
/// list makes macOS run a few *preflights* once per process — the T14 boot check
/// saw `kTCCServiceMicrophone`, `kTCCServiceAudioCapture` and
/// `kTCCServiceScreenCapture` answered that way at the first poll, never as
/// prompts, with `kTCCServiceCamera` never among them and no tccd traffic on any
/// later poll. It is the framework's own enumeration behaviour, not a call
/// NoPeek makes; measured evidence and the decision live in the T14 report.
///
/// **Attribution is deliberately absent in v1.** Spec §4-D asks for best-effort
/// actor attribution by correlating the camera transition with `cameracaptured`
/// / `tccd` log lines within ±3 s, but the reader's predicate
/// (`LogStreamReader.defaultPredicate`) carries no camera lines at all — the
/// `tccd` clause is ScreenCapture-only — so there is no data to correlate
/// against and the actor stays the literal `"camera"` (see the T14 report).
///
/// **Threading.** Like `ProcessWatch` and `Throttler` this class keeps state
/// across ticks and is deliberately not thread-safe: one owner drives it. In
/// the app that owner is the reader's serial callback queue (see
/// `LogStreamReader.performSerialized`), so the polls serialize with the log
/// lines and the process-watch polls feeding the same `Pipeline`.
public final class CameraWatch {

    // MARK: - System probe

    /// `true` when any camera on the machine is in use by another application
    /// (spec §4-D).
    ///
    /// This is the production `inUse` closure and the only place NoPeek touches
    /// AVFoundation. A device that a *different* app has open reports `true`
    /// here; NoPeek's own process never opens a capture session, so it can
    /// never see itself.
    public static var systemInUse: Bool {
        cameraDevices().contains(where: \.isInUseByAnotherApplication)
    }

    /// Every camera the system will enumerate right now.
    ///
    /// `AVCaptureDevice.devices()` would be the one-liner the plan sketches, but
    /// it is deprecated since macOS 10.15 and it answers with **audio devices
    /// too**: on the development machine it returned the built-in microphone
    /// and a virtual audio driver alongside the camera, so a watch built on it
    /// would report `cameraOn` when the user merely recorded audio — an event
    /// that belongs to `MicWatch` (T15) and a false accusation against the
    /// camera. `AVCaptureDeviceDiscoverySession` is the framework's replacement
    /// and the `mediaType: .video` filter keeps this list to cameras.
    ///
    /// The four types are every camera flavour macOS has: `builtInWideAngleCamera`
    /// (which Continuity cameras report as unless the app opts into the specific
    /// type), `continuityCamera`, `deskViewCamera`, and external/UVC devices —
    /// the type third-party virtual cameras register as. A fresh session per
    /// call: a cached one could freeze the device list, and at a 2 s cadence the
    /// enumeration is cheap enough that freshness wins.
    static func cameraDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .deskViewCamera, .external],
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    // MARK: - Configuration

    /// The cadence the watch is built for (spec §3: every 2 s). The watch does
    /// **not** own a timer — the app does — but it carries the cadence so the
    /// two cannot drift apart: `AppController` schedules its timer with this
    /// value, and the tests reason about the debounce in these steps.
    public let interval: TimeInterval

    /// How long the camera must have been observed off, continuously, before
    /// `cameraOff` is emitted (spec §3: 5 s). "Observed off" starts at the
    /// first tick that saw it off, so the real off moment — somewhere in the
    /// `interval` before that tick — is never under-counted.
    public let offDebounce: TimeInterval

    /// The camera state. Injected so tests drive fixed timelines; production is
    /// `CameraWatch.systemInUse`.
    private let inUse: () -> Bool

    /// Source of "now" for the emitted timestamps and the debounce. Injected so
    /// tests pin both; production is the system clock.
    private let now: () -> Date

    // MARK: - State

    /// Whether the current usage spell has already been reported — the whole
    /// event edge state. `true` means a `cameraOn` is outstanding, so only a
    /// `cameraOff` may follow it; `false` means the next transition to in-use
    /// is the edge that fires.
    private var on = false

    /// When the current off stretch was first observed while `on` was `true`.
    /// `nil` whenever the camera is on or was never reported on; cleared by a
    /// tick that sees the camera back on — which is exactly the "continuously
    /// false" rule of spec §3.
    private var offSince: Date?

    // MARK: - Init

    public init(
        interval: TimeInterval = 2,
        offDebounce: TimeInterval = 5,
        inUse: @escaping () -> Bool = { CameraWatch.systemInUse },
        now: @escaping () -> Date = Date.init
    ) {
        self.interval = interval
        self.offDebounce = offDebounce
        self.inUse = inUse
        self.now = now
    }

    // MARK: - Polling

    /// Polls the camera once.
    ///
    /// Returns a `cameraOn` on the first tick that sees the camera in use, a
    /// `cameraOff` on the first tick that sees it off for strictly longer than
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
                source: .camera,
                kind: .cameraOn,
                actor: Self.actor,
                rawSummary: Self.onSummary
            )
        }

        // Off. Nothing is outstanding unless a `cameraOn` was reported — a
        // camera that is never used is never news.
        guard on else { return nil }

        guard let since = offSince else {
            // First off tick of this spell: this timestamp — not the unknown
            // moment between the previous tick and this one — starts the
            // window, so the camera is never reported off early.
            offSince = ts
            return nil
        }

        guard ts.timeIntervalSince(since) > offDebounce else { return nil }

        on = false
        offSince = nil
        return RawEvent(
            ts: ts,
            source: .camera,
            kind: .cameraOff,
            actor: Self.actor,
            rawSummary: Self.offSummary
        )
    }

    // MARK: - Emitted event constants

    /// `actor` for every event this watch emits. Camera usage carries no app
    /// name in v1 (see the class documentation), so the tier falls through to
    /// NORMAL and the actor is the signal itself.
    private static let actor = "camera"

    /// Evidence-log summaries (spec §8's `rawSummary`): the raw record of the
    /// poll, like the log-line excerpt the parser writes for log events — not
    /// UI copy, so they live here rather than in the `Strings` table, which
    /// holds what the user reads (menus, notifications, banners).
    private static let onSummary = "กล้องถูกใช้ (poll)"
    private static let offSummary = "กล้องว่างแล้ว"
}
