import Foundation

// MARK: - CalibrationStep

/// One detector the wizard proves on this machine (plan T18, spec §6).
///
/// `CaseIterable` order is the run order and the summary's read order:
/// screen → camera → mic, the three signals NoPeek's M3/M4 gates cover.
/// Raw values are the on-disk `step` strings in `calibration.json`.
public enum CalibrationStep: String, CaseIterable, Codable, Equatable, Sendable {
    case screen
    case camera
    case mic
}

// MARK: - StepResult

/// One step's verdict (plan T18).
///
/// - `.passed(actor:)` — the step's event arrived inside its window; `actor` is
///   the process that caused it (`screencaptureui`, `Photo Booth`, `mic`), so
///   the wizard can show *who* proved the detector.
/// - `.failed(reason:)` — the step ended for a reason other than its window
///   elapsing. In v1 this is the cancel path (`"cancelled"`): abandoning a run
///   records why it stopped instead of pretending it simply ended.
/// - `.timedOut` — the step's window elapsed with no matching event.
public enum StepResult: Equatable, Sendable {
    case passed(actor: String)
    case failed(reason: String)
    case timedOut
}

extension StepResult: Codable {

    private enum CodingKeys: String, CodingKey {
        case status, actor, reason
    }

    /// The on-disk discriminator. `timed-out` keeps the JSON readable and
    /// leaves room for future statuses without renumbering anything.
    private enum Status: String, Codable {
        case passed
        case failed
        case timedOut = "timed-out"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Status.self, forKey: .status) {
        case .passed:
            self = .passed(actor: try container.decode(String.self, forKey: .actor))
        case .failed:
            self = .failed(reason: try container.decode(String.self, forKey: .reason))
        case .timedOut:
            self = .timedOut
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .passed(let actor):
            try container.encode(Status.passed, forKey: .status)
            try container.encode(actor, forKey: .actor)
        case .failed(let reason):
            try container.encode(Status.failed, forKey: .status)
            try container.encode(reason, forKey: .reason)
        case .timedOut:
            try container.encode(Status.timedOut, forKey: .status)
        }
    }
}

// MARK: - CalibrationSummary

/// A calibration run's outcome: when it started and what each detector proved
/// (plan T18; `~/Library/Application Support/NoPeek/calibration.json`).
///
/// Codable shape — one entry per step, in `CalibrationStep.allCases` order:
///
/// ```json
/// {
///   "date" : "2026-10-18T09:41:02.114+07:00",
///   "results" : [
///     { "result" : { "actor" : "screencaptureui", "status" : "passed" },
///       "step" : "screen" },
///     { "result" : { "status" : "timed-out" }, "step" : "camera" },
///     { "result" : { "actor" : "mic", "status" : "passed" }, "step" : "mic" }
///   ]
/// }
/// ```
///
/// The array (rather than a dictionary keyed by step) keeps the file in the
/// wizard's own step order and makes a partial run's missing steps visibly
/// missing. `date` uses the spec §8 timestamp form (ISO8601, milliseconds,
/// local offset), so the file reads like the evidence log it sums up.
public struct CalibrationSummary: Codable, Equatable, Sendable {

    /// When the run started — the wizard's own timestamp for "last calibrated
    /// at …". A run that never started reports the moment `summary()` was read.
    public var date: Date

    /// The verdicts collected so far: one entry per resolved step, absent for a
    /// step that has not run yet.
    public var results: [CalibrationStep: StepResult]

    public init(date: Date, results: [CalibrationStep: StepResult]) {
        self.date = date
        self.results = results
    }

    /// Every step has a verdict — the run reached its natural end (by passing
    /// or by timing out). A cancelled run can also satisfy this; the wizard
    /// persists a summary only when `onComplete` fired.
    public var isComplete: Bool {
        CalibrationStep.allCases.allSatisfy { results[$0] != nil }
    }

    /// Every step passed. This is what "this machine is calibrated" means: the
    /// first-launch auto-start gate reads exactly this (ruling R24), so a run
    /// whose steps timed out, were cancelled, or have not run yet is not a
    /// calibration — no matter that it was persisted.
    public var allPassed: Bool {
        CalibrationStep.allCases.allSatisfy { results[$0]?.isPassed == true }
    }

    /// How many steps passed; the wizard's `ผ่าน N จาก 3` line.
    public var passedCount: Int {
        CalibrationStep.allCases.count { results[$0]?.isPassed == true }
    }

    // MARK: - Codable

    /// One `{step, result}` pair, so the file is a list of steps rather than a
    /// dictionary whose key order JSONEncoder would sort away.
    private struct Entry: Codable {
        let step: CalibrationStep
        let result: StepResult

        enum CodingKeys: String, CodingKey {
            case step, result
        }

        init(step: CalibrationStep, result: StepResult) {
            self.step = step
            self.result = result
        }

        init(from decoder: Decoder) throws {
            // `result` is inline with `step` (`{"step": "screen", "status":
            // "passed", "actor": "…"}`) rather than nested: the file is small,
            // and one object per step is easier to read with `jq` than a
            // wrapper key would be.
            let nested = try decoder.container(keyedBy: CodingKeys.self)
            self.step = try nested.decode(CalibrationStep.self, forKey: .step)
            self.result = try StepResult(from: decoder)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(step, forKey: .step)
            try result.encode(to: encoder)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case date, results
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let date = try container.decode(String.self, forKey: .date)
        guard let parsed = ISO8601Timestamp.date(from: date) else {
            throw DecodingError.dataCorruptedError(
                forKey: .date,
                in: container,
                debugDescription: "expected ISO8601 timestamp with milliseconds, got \"\(date)\""
            )
        }
        self.date = parsed

        let entries = try container.decode([Entry].self, forKey: .results)
        self.results = Dictionary(
            entries.map { ($0.step, $0.result) },
            uniquingKeysWith: { first, _ in first }  // a hand-edited duplicate: first wins
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ISO8601Timestamp.string(from: date), forKey: .date)
        try container.encode(
            CalibrationStep.allCases.compactMap { step in
                results[step].map { Entry(step: step, result: $0) }
            },
            forKey: .results
        )
    }
}

extension StepResult {
    /// Whether this verdict is a pass (see `CalibrationSummary.allPassed`).
    var isPassed: Bool {
        if case .passed = self { return true }
        return false
    }
}

// MARK: - CalibrationStatus

/// A live snapshot of the wizard for its window (plan T18): what the run is
/// doing right now, per step.
///
/// `remaining` is the current step's window in seconds, clamped at 0, or `nil`
/// when no step is in flight — the countdown the window shows while it waits.
public struct CalibrationStatus: Equatable, Sendable {
    public var isRunning: Bool
    public var currentStep: CalibrationStep?
    public var results: [CalibrationStep: StepResult]
    public var remaining: TimeInterval?

    public init(
        isRunning: Bool,
        currentStep: CalibrationStep?,
        results: [CalibrationStep: StepResult],
        remaining: TimeInterval?
    ) {
        self.isRunning = isRunning
        self.currentStep = currentStep
        self.results = results
        self.remaining = remaining
    }

    /// Every step's verdict is a pass so far (the window's all-✅ line).
    public var allPassed: Bool {
        CalibrationStep.allCases.allSatisfy { results[$0]?.isPassed == true }
    }

    /// How many steps passed so far (the window's `ผ่าน N จาก 3` line).
    public var passedCount: Int {
        CalibrationStep.allCases.count { results[$0]?.isPassed == true }
    }
}

// MARK: - CalibrationService

/// The Calibration Wizard's state machine (plan T18, spec §6,
/// acceptance 12): it walks the three detectors in `CalibrationStep` order,
/// passes each one on the single event kind that proves that detector works on
/// *this* machine, and records a verdict per step.
///
/// **Pass rules** (pinned):
///
/// | Step | Proves out on | Why |
/// |---|---|---|
/// | screen | `.screenCapture` from any actor **except `WindowManager`** | R16: Mission Control's `.screenCapture` echo (R14) must not count, so the wizard's ⌘⇧5 is a real capture |
/// | camera | `.cameraOn` | the T14 log-based signal, actor = capturing app |
/// | mic | `.micOn` | the v1.1 log-based recorder-client start (`coreaudiod`) |
///
/// Every other event — other kinds, other steps' events — is ignored. A later
/// step's event arriving while an earlier step is current is deliberately *not*
/// banked: the wizard's instructions are sequential, and an app that was
/// already using the camera when step 1 was on screen must not answer step 2.
///
/// **Windows.** Each step gets its own `timeout` (60 s in production) counted
/// from the moment that step became current. A window that elapses records
/// `.timedOut` and **advances** the run — all three detectors always get their
/// turn, so the summary is the whole story rather than the first problem. The
/// next step's window starts at the deadline the previous one ended at, so the
/// run's schedule is a fixed chain of windows and a single late consult can
/// resolve several elapsed steps at once.
///
/// **Interaction, not timers.** The service owns no timer. It consults its
/// clock whenever it is asked something — `ingest(_:)`, `status()`,
/// `summary()` — and resolves any elapsed windows then. The app pumps it on
/// both sides: every incoming `RawEvent` from the reader's queue, and the
/// wizard window's 1 s refresh on the main thread, which is what makes a
/// countdown and a timeout visible while the user does nothing.
///
/// **Life cycle.** `start()` begins (or restarts) a run: the results reset and
/// the screen step goes first. `cancel()` abandons it — the step in flight is
/// recorded `.failed(reason: "cancelled")` and the run is *not* announced as
/// complete, so an abandoned run is never persisted by the app. A run that
/// reaches its natural end (every step has a verdict) calls `onComplete`
/// exactly once with the finished summary.
///
/// **Threading.** `ingest` runs on the log reader's serial queue while the
/// wizard window reads `status()` on the main thread, so all state sits behind
/// one lock; callbacks are delivered outside it, which lets a handler call back
/// into the service (`summary()`, `persist(to:)`) without deadlocking.
/// `onComplete` is set once, before the first `start()`.
public final class CalibrationService: @unchecked Sendable {

    // MARK: - Configuration

    /// How long each step waits for its event, counted from the moment the step
    /// became current (spec: 60 s per detector).
    public let timeout: TimeInterval

    /// The reason `cancel()` records on the step in flight.
    public static let cancelledReason = "cancelled"

    /// The one actor a `.screenCapture` event must **not** carry to satisfy the
    /// screen step (R16): Mission Control's `WindowManager` "Change expose
    /// mode" line is a `.screenCapture` event (R14) and is not a capture.
    private static let windowManagerActor = "WindowManager"

    /// Called once per run that reaches its natural end, with the finished
    /// summary. Never called for a cancelled run. Set once, before `start()`.
    /// Delivered outside the lock (see the class note on threading).
    public var onComplete: ((CalibrationSummary) -> Void)?

    private let now: () -> Date
    private let lock = NSLock()

    // MARK: - State (lock-protected)

    /// A run is in flight (every interaction resolves elapsed windows first).
    private var running = false
    /// When the current run began; the summary's `date`.
    private var startedAt: Date?
    /// Index into `CalibrationStep.allCases` of the step in flight.
    private var currentIndex = 0
    /// When the current step's window opened.
    private var stepStartedAt: Date?
    private var results: [CalibrationStep: StepResult] = [:]
    /// Whether the current run's completion has already been delivered — set
    /// by the completion itself and by `cancel()`, so neither repeats.
    private var announced = true

    // MARK: - Init

    /// - Parameters:
    ///   - timeout: seconds each step waits for its event (spec: 60).
    ///   - now: the service's clock. Injected so tests drive time exactly; the
    ///     production default is the system clock.
    public init(timeout: TimeInterval = 60, now: @escaping () -> Date = Date.init) {
        self.timeout = timeout
        self.now = now
    }

    // MARK: - Life cycle

    /// Begins a run: results reset, the screen step goes first, and both the
    /// run's and the first step's window start now. Calling it while a run is
    /// in flight starts a fresh run (the menu's `Calibration Wizard…` re-run).
    public func start() {
        lock.withLock {
            let started = now()
            running = true
            startedAt = started
            currentIndex = 0
            stepStartedAt = started
            results.removeAll()
            announced = false
        }
    }

    /// Abandons the run: the step in flight is recorded
    /// `.failed(reason: "cancelled")`, nothing further is accepted, and the
    /// completion callback does not fire (the window-closed path). No-op when
    /// no run is in flight.
    public func cancel() {
        lock.withLock {
            guard running else { return }
            if let step = currentStepLocked {
                results[step] = .failed(reason: Self.cancelledReason)
            }
            finishLocked()
            announced = true  // abandoned runs are never announced
        }
    }

    // MARK: - Ingest

    /// Offers one observed event to the run. Ignored unless a run is in flight
    /// (the app feeds every event it sees; this is the gate) and unless the
    /// event is the current step's proof.
    public func ingest(_ raw: RawEvent) {
        let completion: CalibrationSummary? = lock.withLock {
            // Windows that already elapsed end before this event is judged: an
            // event past a deadline belongs to the step after it, if any.
            resolveElapsedLocked()

            if running, let step = currentStepLocked, matches(step, raw) {
                results[step] = .passed(actor: raw.actor)
                advanceLocked(from: now())
            }
            return completionLocked()
        }
        announce(completion)
    }

    // MARK: - Reading the run

    /// The live snapshot the wizard window draws, after resolving any elapsed
    /// windows (see the class note on interaction).
    public func status() -> CalibrationStatus {
        let (status, completion): (CalibrationStatus, CalibrationSummary?) = lock.withLock {
            resolveElapsedLocked()
            return (statusLocked(), completionLocked())
        }
        announce(completion)
        return status
    }

    /// The run's verdicts. Like `status()`, this resolves elapsed windows
    /// first, so a summary read long after the fact reflects the timeouts that
    /// happened while nobody looked.
    public func summary() -> CalibrationSummary {
        let completion: CalibrationSummary? = lock.withLock {
            resolveElapsedLocked()
            return completionLocked()
        }
        announce(completion)
        return lock.withLock { summaryLocked() }
    }

    // MARK: - Persistence

    /// Writes `summary` to `url` as JSON, creating the parent directory when it
    /// is missing (`~/Library/Application Support/NoPeek/` does not exist on a
    /// fresh Mac until something is written there). Atomic: a crash mid-write
    /// cannot leave a half summary behind for the next launch's auto-start gate
    /// to mistake for a completed calibration.
    public func persist(_ summary: CalibrationSummary, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(summary)

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    /// Persists the current summary. Mid-run that is a partial summary (only
    /// the resolved steps); the app persists from `onComplete`, where all three
    /// are on record.
    public func persist(to url: URL) throws {
        try persist(summary(), to: url)
    }

    /// Reads a persisted summary. `nil` when no file exists — "never calibrated
    /// yet" is the normal first-launch state, not an error — and throws when a
    /// file exists but cannot be read or decoded.
    public static func load(from url: URL) throws -> CalibrationSummary? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(CalibrationSummary.self, from: data)
    }

    /// The first-launch gate's predicate (ruling R24): whether the summary
    /// stored at `url` proves **every** detector.
    ///
    /// `false` when no file exists, when a file exists but cannot be read or
    /// decoded (a corrupt record must not claim the machine is calibrated), and
    /// when the record holds anything less than three `.passed` verdicts. A run
    /// that only timed out — or was cancelled — proves nothing, so the wizard
    /// stays eligible to open by itself until the machine really passes.
    public static func hasPassedCalibration(at url: URL) -> Bool {
        (try? load(from: url))?.allPassed == true
    }

    // MARK: - Matching

    /// Whether `raw` is `step`'s proof (the pinned pass rules — see the class
    /// documentation).
    private func matches(_ step: CalibrationStep, _ raw: RawEvent) -> Bool {
        switch step {
        case .screen:
            // R16: any capture actor except WindowManager. The comparison is
            // case-insensitive so a future `windowmanager` spelling of the same
            // Mission Control signal cannot sneak through.
            return raw.kind == .screenCapture
                && raw.actor.caseInsensitiveCompare(Self.windowManagerActor) != .orderedSame
        case .camera:
            return raw.kind == .cameraOn
        case .mic:
            return raw.kind == .micOn
        }
    }

    // MARK: - State machine (lock held)

    /// The step in flight, or `nil` when the run is over (or never started).
    private var currentStepLocked: CalibrationStep? {
        guard running, CalibrationStep.allCases.indices.contains(currentIndex) else { return nil }
        return CalibrationStep.allCases[currentIndex]
    }

    /// Records `.timedOut` for every step whose window has already elapsed and
    /// moves the run along the fixed chain of windows (see the class note on
    /// windows). Ends the run when the last step's window has elapsed.
    private func resolveElapsedLocked() {
        guard running else { return }
        let t = now()
        while let step = currentStepLocked, let started = stepStartedAt {
            let deadline = started.addingTimeInterval(timeout)
            guard t >= deadline else { break }
            results[step] = .timedOut
            advanceLocked(from: deadline)
        }
    }

    /// Moves to the next step, whose window opens at `start`, or ends the run.
    private func advanceLocked(from start: Date) {
        currentIndex += 1
        if currentIndex >= CalibrationStep.allCases.count {
            finishLocked()
        } else {
            stepStartedAt = start
        }
    }

    private func finishLocked() {
        running = false
        stepStartedAt = nil
    }

    /// The summary to deliver when the run has just reached its natural end;
    /// `nil` while it is still running, when it was cancelled, or when that
    /// completion has already been announced. Marks it announced.
    private func completionLocked() -> CalibrationSummary? {
        guard !running, !announced else { return nil }
        let summary = summaryLocked()
        guard summary.isComplete else { return nil }
        announced = true
        return summary
    }

    /// Delivers a completion outside the lock (the handler may call back in).
    private func announce(_ completion: CalibrationSummary?) {
        guard let completion else { return }
        onComplete?(completion)
    }

    // MARK: - Snapshots (lock held)

    private func statusLocked() -> CalibrationStatus {
        var remaining: TimeInterval?
        if let started = stepStartedAt, currentStepLocked != nil {
            remaining = max(0, started.addingTimeInterval(timeout).timeIntervalSince(now()))
        }
        return CalibrationStatus(
            isRunning: running,
            currentStep: currentStepLocked,
            results: results,
            remaining: remaining
        )
    }

    /// The summary's `date` is the run's start. A service that was never
    /// started reports the moment it was asked — there is no run to date.
    private func summaryLocked() -> CalibrationSummary {
        CalibrationSummary(date: startedAt ?? now(), results: results)
    }
}
