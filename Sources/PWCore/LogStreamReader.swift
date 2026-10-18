import Darwin
import Foundation

// MARK: - LogStreamReader

/// Owns the `log stream` child process that feeds the log-stream watcher
/// (spec §4) and keeps it alive across child deaths (spec §3 auto-restart).
///
/// - `start()` launches `command` and reports `.running`. The child's stdout
///   is split on `\n` and every complete line is handed to `onLine` as raw
///   `Data`; parsing is `LogLineParser`'s job, so malformed lines are
///   delivered too. A child that dies mid-line has its remaining bytes
///   flushed as one final line.
/// - When the child ends — crash, clean exit, or a command that cannot even
///   be launched — the reader reports `.degraded(retryIn:)` and restarts
///   after that delay, stepping through `backoff`. A run that lasted at least
///   `stableResetInterval` resets the backoff to its first step, so a stream
///   that was healthy for minutes retries in 1 s, not 30 s.
/// - `stop()` terminates the child — SIGTERM, then SIGKILL after
///   `sigkillGracePeriod` if it refuses to die — and suppresses every later
///   callback. `start()` after `stop()` begins a fresh stream.
///
/// Threading: all state transitions and both callbacks run on one internal
/// serial queue, so calls are ordered and callbacks never race each other.
/// `start()`/`stop()` block until their transition is applied and are safe to
/// call from inside a callback. The child's stdout is drained on a second,
/// dedicated queue, one run at a time.
///
/// The reader never throws and never traps on child failure: a dead child is
/// the normal path, not an error.
public final class LogStreamReader: @unchecked Sendable {

    // MARK: - State

    /// What the reader is doing, as reported to `onState`.
    public enum State: Equatable, Sendable {
        /// The child is running; lines are flowing.
        case running
        /// The child is not running; a restart is scheduled in `retryIn`
        /// seconds (the current `backoff` step).
        case degraded(retryIn: TimeInterval)
    }

    // MARK: - Defaults

    /// The canonical predicate: byte-for-byte the content of
    /// `scripts/log-predicate.txt` (minus that file's trailing newline, which
    /// the shell also strips when `capture-probe.sh` reads it). The cross-check
    /// lives in `LogStreamReaderTests.testDefaultPredicateMatchesFile`; keep
    /// this string in sync with the file, never independently.
    public static let defaultPredicate =
        #"subsystem == "com.apple.ScreenCaptureKit" OR process == "replayd" OR process == "ScreenCaptureApprovalUI" OR process == "screencapture" OR process == "screencaptureui" OR process == "screensharingd" OR (process == "tccd" AND composedMessage CONTAINS "ScreenCapture") OR process == "WindowManager""#

    /// The child the reader spawns by default: an ndjson log stream limited to
    /// the capture / remote-control / Mission-Control signals (spec §4).
    public static let defaultCommand: [String] = [
        "/usr/bin/log",
        "stream",
        "--style", "ndjson",
        "--predicate", defaultPredicate,
    ]

    // MARK: - Configuration

    private let command: [String]
    private let backoff: [TimeInterval]
    private let stableResetInterval: TimeInterval
    private let sigkillGracePeriod: TimeInterval
    private let onLine: @Sendable (Data) -> Void
    private let onState: @Sendable (State) -> Void

    /// Serializes every state transition, the line buffer, and the callbacks.
    private let queue: DispatchQueue

    /// One child run at a time; a run's poll/read loop lives here.
    private let readerQueue = DispatchQueue(label: "com.sinsombat.nopeek.logstream.reader")

    /// Marks the state queue so callbacks can call `start()`/`stop()` without
    /// deadlocking (they run on that queue).
    private static let queueKey = DispatchSpecificKey<UInt8>()

    private static let pollTimeoutMilliseconds: Int32 = 100

    // MARK: - State (queue-owned)

    /// `start()` has been called and `stop()` has not.
    private var isStreaming = false
    /// Bumped for every spawn; tags which run owns the state.
    private var generation = 0
    private var activeRun: RunContext?
    private var childStartedAt: Date?
    /// Consecutive runs that died before `stableResetInterval`; index into
    /// `backoff` for the next retry delay.
    private var consecutiveFailures = 0
    private var restartWorkItem: DispatchWorkItem?
    /// Bytes of a line not yet terminated by `\n` (at most one line).
    private var lineBuffer: [UInt8] = []

    // MARK: - Init

    public init(
        command: [String] = LogStreamReader.defaultCommand,
        backoff: [TimeInterval] = [1, 2, 4, 8, 16, 30],
        stableResetInterval: TimeInterval = 60,
        sigkillGracePeriod: TimeInterval = 2,
        onLine: @escaping @Sendable (Data) -> Void,
        onState: @escaping @Sendable (State) -> Void
    ) {
        self.command = command
        // An empty schedule would mean a restart storm; one second is the
        // safest fallback.
        self.backoff = backoff.isEmpty ? [1] : backoff
        self.stableResetInterval = stableResetInterval
        self.sigkillGracePeriod = sigkillGracePeriod
        self.onLine = onLine
        self.onState = onState
        self.queue = DispatchQueue(label: "com.sinsombat.nopeek.logstream.state")
        queue.setSpecific(key: Self.queueKey, value: 1)
    }

    // MARK: - Lifecycle

    /// Starts streaming; a no-op while already started.
    public func start() {
        withStateLock { startLocked() }
    }

    /// Stops streaming, terminates the child, and suppresses every callback
    /// that would otherwise follow. Safe to call from inside a callback.
    public func stop() {
        withStateLock { stopLocked() }
    }

    // MARK: - Serialization with the callbacks

    /// Runs `body` on the reader's serial queue — the same one that delivers
    /// `onLine` and `onState` — so a second event source feeding the same
    /// `Pipeline` (the process watch, T13) serializes with log lines instead of
    /// racing the non-thread-safe `Throttler` and `EvidenceLog` inside it.
    ///
    /// Asynchronous by design: the caller is a timer and must never block on
    /// the reader. Bodies run in submission order, and — unlike `onLine` /
    /// `onState` — a body submitted before `stop()` is **not** suppressed by
    /// it, so a caller with its own life cycle cancels its own timer.
    public func performSerialized(_ body: @escaping @Sendable () -> Void) {
        queue.async(execute: body)
    }

    // MARK: - State queue

    /// Runs `body` on the state queue — inline when already there, so a
    /// callback calling `start()`/`stop()` cannot deadlock.
    @discardableResult
    private func withStateLock<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            return body()
        }
        return queue.sync(execute: body)
    }

    private func startLocked() {
        guard !isStreaming else { return }
        isStreaming = true
        consecutiveFailures = 0
        lineBuffer.removeAll()
        spawnLocked()
    }

    private func stopLocked() {
        guard isStreaming else { return }
        isStreaming = false
        restartWorkItem?.cancel()
        restartWorkItem = nil
        if let activeRun {
            terminateLocked(activeRun)
        }
    }

    private func spawnLocked() {
        guard isStreaming else { return }
        generation += 1

        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.first ?? Self.defaultCommand[0])
        process.arguments = Array(command.dropFirst())
        // stderr stays inherited on purpose: `log stream` diagnostics belong
        // in the app's stderr (the LaunchAgent's StandardErrorPath), and they
        // are not stream lines.
        let pipe = Pipe()
        process.standardOutput = pipe

        let context = RunContext(
            generation: generation,
            process: process,
            handle: pipe.fileHandleForReading
        )
        activeRun = context
        readerQueue.async { [weak self] in
            // The child is launched inside `runChild`, so a reader that is
            // already gone never leaves an orphan behind.
            guard let self else { return }
            self.runChild(context)
        }
    }

    /// True while `generation` is the run that owns the state.
    private func isCurrent(_ generation: Int) -> Bool {
        isStreaming && generation == self.generation
    }

    private func scheduleRestartLocked(after delay: TimeInterval) {
        let item = DispatchWorkItem { [weak self] in
            self?.restartLocked()
        }
        restartWorkItem = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func restartLocked() {
        restartWorkItem = nil
        guard isStreaming else { return }
        spawnLocked()
    }

    /// SIGTERM, then SIGKILL when the child is still alive after
    /// `sigkillGracePeriod` (a child that ignores SIGTERM must not pin the
    /// reader for good). `kill(2)` on an already-reaped pid is a no-op; the
    /// pid could in theory be recycled in the instant between the liveness
    /// check and the signal, which is accepted.
    private func terminateLocked(_ context: RunContext) {
        guard context.process.isRunning else { return }
        context.process.terminate()
        queue.asyncAfter(deadline: .now() + sigkillGracePeriod) {
            guard context.process.isRunning else { return }
            kill(context.process.processIdentifier, SIGKILL)
        }
    }

    /// A run ended: flush the final partial line, step the backoff, report
    /// `.degraded`, and schedule the restart.
    private func finalizeRun(_ generation: Int) {
        guard generation == self.generation else { return }  // a newer run owns the state
        activeRun = nil
        let ranFor = childStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        childStartedAt = nil

        guard isStreaming else {
            lineBuffer.removeAll()
            return
        }

        if !lineBuffer.isEmpty {
            let lastLine = Data(lineBuffer)
            lineBuffer.removeAll()
            onLine(lastLine)
        }

        if ranFor >= stableResetInterval {
            consecutiveFailures = 0  // the stream proved stable: back to step one
        }
        let delay = backoff[min(consecutiveFailures, backoff.count - 1)]
        consecutiveFailures = min(consecutiveFailures + 1, backoff.count - 1)

        onState(.degraded(retryIn: delay))
        scheduleRestartLocked(after: delay)
    }

    private func consumeLocked(_ data: Data) {
        guard isStreaming else { return }
        lineBuffer.append(contentsOf: data)

        // Collect first, call back after: a callback may call stop()/start()
        // and mutate the buffer out from under an in-flight loop otherwise.
        var lines: [Data] = []
        var start = 0
        for index in lineBuffer.indices where lineBuffer[index] == UInt8(ascii: "\n") {
            lines.append(Data(lineBuffer[start..<index]))
            start = index + 1
        }
        if start > 0 {
            lineBuffer.removeFirst(start)
        }
        for line in lines {
            // stop() inside an earlier callback suppresses the rest too.
            guard isStreaming else { return }
            onLine(line)
        }
    }

    // MARK: - Reader thread

    /// One child run, passed across the `@Sendable` reader-queue hop as a unit
    /// (`Process` and `FileHandle` are not `Sendable`). A context is only
    /// touched by its own reader thread plus `queue`-serialized state.
    private final class RunContext: @unchecked Sendable {
        let generation: Int
        let process: Process
        let handle: FileHandle

        init(generation: Int, process: Process, handle: FileHandle) {
            self.generation = generation
            self.process = process
            self.handle = handle
        }
    }

    private func runChild(_ context: RunContext) {
        let fd = context.handle.fileDescriptor
        // Non-blocking: the loop polls first, so a stalled child can never
        // park this thread inside read(2).
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)

        // A stop() that landed between spawnLocked() and here wins: the child
        // was never launched and there is nothing to clean up.
        guard withStateLock({ self.isCurrent(context.generation) }) else { return }

        do {
            try context.process.run()
        } catch {
            // The command itself cannot be launched (missing binary, …).
            // Reported exactly like a child that died immediately.
            withStateLock { self.finalizeRun(context.generation) }
            return
        }

        let adopted = withStateLock { () -> Bool in
            guard self.isCurrent(context.generation) else { return false }
            self.childStartedAt = Date()
            self.onState(.running)
            return true
        }
        if !adopted {
            // stop() raced the spawn: the child exists now, so terminate it.
            withStateLock { self.terminateLocked(context) }
        }

        // Drain until the child's end of the pipe closes (EOF) or the run is
        // over. poll(2) wakes on data and on hang-up; the timeout only exists
        // to notice stop() and children that died without closing the pipe.
        var reachedEnd = false
        while !reachedEnd {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let result = poll(&descriptor, 1, Self.pollTimeoutMilliseconds)
            if result < 0 {
                if errno == EINTR { continue }
                reachedEnd = true
                break
            }
            if result == 0 {
                let stillCurrent = withStateLock { self.isCurrent(context.generation) }
                if !stillCurrent || !context.process.isRunning {
                    _ = drain(fd: fd)  // best effort: whatever is still buffered
                    reachedEnd = true
                }
                continue
            }
            reachedEnd = drain(fd: fd)
        }

        // Reap. With a stubborn child this blocks until the SIGKILL
        // escalation lands; normally it returns at once.
        if context.process.isRunning {
            context.process.waitUntilExit()
        }
        withStateLock { self.finalizeRun(context.generation) }
    }

    /// Reads everything currently buffered in the pipe. Returns `true` when
    /// the stream ended (EOF, or a read error that ends the run).
    private func drain(fd: Int32) -> Bool {
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count > 0 {
                withStateLock { self.consumeLocked(Data(chunk[0..<count])) }
                continue
            }
            if count == 0 { return true }  // every writer closed the pipe
            if errno == EAGAIN || errno == EWOULDBLOCK { return false }
            if errno == EINTR { continue }
            return true  // EBADF and friends: end the run
        }
    }
}
