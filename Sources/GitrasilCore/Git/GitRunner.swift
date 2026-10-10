import Foundation

/// Result of one `git` invocation.
public struct GitOutput: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data

    public init(status: Int32, stdout: Data, stderr: Data) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }

    /// stdout decoded as UTF-8 (nil if not valid UTF-8).
    public var stdoutString: String? { String(data: stdout, encoding: .utf8) }
    /// stderr decoded as UTF-8 (nil if not valid UTF-8).
    public var stderrString: String? { String(data: stderr, encoding: .utf8) }

    /// stdout trimmed of surrounding whitespace/newlines — for single-value queries.
    public var trimmedStdout: String { (stdoutString ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
}

public enum GitError: Error, Sendable {
    /// git exited non-zero. Carries argv and stderr so callers can surface the real failure.
    case commandFailed(args: [String], status: Int32, stderr: String)
    /// The process could not be launched at all.
    case launchFailed(underlying: String)
    /// git ran longer than the runner's timeout (a sleeping network volume, files not yet downloaded)
    /// and was stopped. The repository isn't tried again before `retryAt`.
    case timedOut(args: [String], seconds: Double, retryAt: Date)
    /// An earlier call in this repository timed out, so this one wasn't tried: not before `retryAt`.
    case backingOff(retryAt: Date)
}

extension GitError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .commandFailed(let args, let status, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "git \(args.joined(separator: " ")) failed (\(status))" + (detail.isEmpty ? "." : ": \(detail)")
        case .launchFailed(let underlying):
            return "git couldn’t be started: \(underlying)"
        case .timedOut(_, let seconds, let retryAt):
            return "git didn’t answer in \(Int(seconds.rounded())) seconds, so it was stopped (a sleeping drive or an "
                + "unreachable network volume?). It will be tried again at \(Self.time(retryAt))."
        case .backingOff(let retryAt):
            return "This repository didn’t answer earlier, so it’s being left alone until \(Self.time(retryAt))."
        }
    }

    private static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }
}

/// Everything that shells out to `git` goes through this. A protocol so tests can inject
/// a fake (slow/recording) runner for concurrency tests without touching disk.
public protocol GitRunning: Sendable {
    /// Run `git <args>` and return the raw result. Does **not** throw on non-zero status —
    /// callers decide whether a non-zero exit is an error (e.g. `merge-base` returning 1
    /// means "no common ancestor", which is data, not a failure).
    func run(_ args: [String]) async throws -> GitOutput
}

public extension GitRunning {
    /// Convenience: run and require success, else throw `GitError.commandFailed`.
    @discardableResult
    func runChecked(_ args: [String]) async throws -> GitOutput {
        let out = try await run(args)
        guard out.status == 0 else {
            throw GitError.commandFailed(args: args, status: out.status, stderr: out.stderrString ?? "")
        }
        return out
    }
}

public extension GitRunner {
    /// Environment shared by the app's git runners:
    /// - `GIT_EDITOR`/`GIT_SEQUENCE_EDITOR=true` never open an interactive editor.
    /// - `GIT_OPTIONAL_LOCKS=0` keeps our frequent reads truly read-only, so a watcher on the git
    ///   dir isn't woken by our own `git status` refreshing the index (an FSEvents lock-loop).
    static let appEnvironment: [String: String] = [
        "GIT_EDITOR": "true", "GIT_SEQUENCE_EDITOR": "true", "GIT_OPTIONAL_LOCKS": "0"
    ]

    /// Inherited variables that point git at a repository other than the runner's working
    /// directory — `git rev-parse --local-env-vars`, the set git itself clears when it enters a
    /// submodule. A process launched from inside a git command (a terminal in an editor that
    /// `git difftool` opened, a hook) inherits `GIT_DIR`/`GIT_WORK_TREE`, and git obeys them over the
    /// cwd, so every runner would read that one repository.
    static let repositoryEnvironment: Set<String> = [
        "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_CONFIG", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT",
        "GIT_OBJECT_DIRECTORY", "GIT_DIR", "GIT_WORK_TREE", "GIT_IMPLICIT_WORK_TREE", "GIT_GRAFT_FILE",
        "GIT_INDEX_FILE", "GIT_NO_REPLACE_OBJECTS", "GIT_REPLACE_REF_BASE", "GIT_PREFIX",
        "GIT_SHALLOW_FILE", "GIT_COMMON_DIR"
    ]

    /// The environment a runner launches git with: the inherited one without the repository
    /// selectors, then `extra` on top.
    static func environment(inherited: [String: String], extra: [String: String]) -> [String: String] {
        var environment = inherited.filter { !repositoryEnvironment.contains($0.key) }
        for (key, value) in extra { environment[key] = value }
        return environment
    }
}

/// Why a call is stopped by its timer; the runner turns it into `GitError.timedOut` with the retry time.
private enum Stop: Error { case timedOut }

/// One `git` invocation in flight: finished by whichever comes first of its exit with its output read,
/// its timeout and its task's cancellation, once; the others find it done. Output is read as it arrives
/// (no thread waits on a pipe), so a stop closes the pipes and nothing stays blocked behind a child of
/// git that holds them open; the process is terminated, and killed if it hasn't gone after a moment.
/// Nothing the process or the pipes hold refers back to the call strongly, so it frees once the run is over.
private final class Call: @unchecked Sendable {
    private let lock = NSLock()
    private let grace: TimeInterval
    private var continuation: CheckedContinuation<GitOutput, Error>?
    private var process: Process?
    private var pipes: [Pipe] = []
    private var pipesClosed = false
    private var timer: DispatchSourceTimer?
    private var stopped: Error?
    private var done = false
    private var out = Data()
    private var err = Data()
    private var openPipes = 2
    private var status: Int32?

    /// `grace`: how long the pipes may stay open after the process has exited before the call answers with
    /// what it has read (something git started, like `gc --auto`, can hold them).
    init(pipeGrace grace: TimeInterval) {
        self.grace = grace
    }

    var isStopped: Bool { lock.withLock { stopped != nil } }

    func begin(_ continuation: CheckedContinuation<GitOutput, Error>) {
        let error = lock.withLock { () -> Error? in
            if stopped == nil { self.continuation = continuation }
            return stopped
        }
        if let error { continuation.resume(throwing: error) }
    }

    /// The process is running: read its output and time it. Called once, after `process.run()` succeeded.
    func attach(_ process: Process, _ pipes: (out: Pipe, err: Pipe), timeout: TimeInterval, onTimeout: @escaping @Sendable () -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler(handler: onTimeout)
        // The readers are installed under the lock `closePipes` takes, so a stop can't close the pipes
        // before they're there, nor between a reader's check and its read.
        let doomed = lock.withLock { () -> Bool in
            self.process = process
            self.pipes = [pipes.out, pipes.err]
            self.timer = timer
            if stopped != nil || done { return true }
            for (pipe, isError) in [(pipes.out, false), (pipes.err, true)] {
                pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    self?.drain(handle, isError: isError)
                }
            }
            return false
        }
        // A timer must be resumed once before it's released, even when it's cancelled at once.
        timer.resume()
        if doomed {
            timer.cancel()
            if isStopped { Self.kill(process); closePipes() }
        }
    }

    /// Reads what's there. The lock is held across the read so `closePipes` can't close the handle under it
    /// (a read on a closed handle is an Objective-C exception, which can't be caught).
    private func drain(_ handle: FileHandle, isError: Bool) {
        let open = lock.withLock { () -> Bool in
            guard !pipesClosed else { return false }
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                openPipes -= 1
            } else if isError {
                err.append(data)
            } else {
                out.append(data)
            }
            return true
        }
        if open { finishIfComplete() }
    }

    func exited(_ status: Int32) {
        lock.withLock { self.status = status }
        finishIfComplete()
        if !lock.withLock({ done }) {
            DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [weak self] in self?.finishWithWhatWasRead() }
        }
    }

    /// Done once the process has exited and both its pipes have run dry.
    private func finishIfComplete() {
        let output = lock.withLock { () -> GitOutput? in
            guard let status, openPipes <= 0, !done else { return nil }
            return GitOutput(status: status, stdout: out, stderr: err)
        }
        if let output { finish(.success(output)) }
    }

    /// The process has been gone for the grace period and something still holds a pipe: answer with the output so far.
    private func finishWithWhatWasRead() {
        let output = lock.withLock { () -> GitOutput? in
            guard let status, !done, stopped == nil else { return nil }
            return GitOutput(status: status, stdout: out, stderr: err)
        }
        if let output { finish(.success(output)) }
    }

    func finish(_ result: Result<GitOutput, Error>) {
        let (continuation, timer) = lock.withLock { () -> (CheckedContinuation<GitOutput, Error>?, DispatchSourceTimer?) in
            done = true
            defer { self.continuation = nil; self.timer = nil }
            return (self.continuation, self.timer)
        }
        timer?.cancel()
        closePipes()
        continuation?.resume(with: result)
    }

    func stop(_ error: Error) {
        let (continuation, process, timer) = lock.withLock { () -> (CheckedContinuation<GitOutput, Error>?, Process?, DispatchSourceTimer?) in
            guard !done, stopped == nil else { return (nil, nil, nil) }
            stopped = error
            defer { self.continuation = nil; self.timer = nil }
            return (self.continuation, self.process, self.timer)
        }
        timer?.cancel()
        continuation?.resume(throwing: error)
        if let process { Self.kill(process) }
        closePipes()
    }

    private func closePipes() {
        lock.withLock {
            guard !pipesClosed else { return }
            pipesClosed = true
            for pipe in pipes {
                pipe.fileHandleForReading.readabilityHandler = nil
                try? pipe.fileHandleForReading.close()
            }
        }
    }

    private static func kill(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning { Foundation.kill(process.processIdentifier, SIGKILL) }
        }
    }
}

/// The real runner: launches `git` via `/usr/bin/env` so it honors the user's PATH,
/// exactly like their own terminal (the whole reason we shell out instead of using libgit2).
public struct GitRunner: GitRunning {
    private let workdir: URL
    private let extraEnvironment: [String: String]
    private let timeout: TimeInterval
    private let gate: GitGate
    private let command: [String]
    private let pipeGrace: TimeInterval

    /// How long the pipes may stay open once git has exited, before the call answers with what it has read.
    static let defaultPipeGrace: TimeInterval = 1.5

    /// How long a git process may run before it's stopped (GITRASIL_GIT_TIMEOUT seconds; default 60). The
    /// app only reads: a `git log` taking a minute is a repository that isn't answering. A repository
    /// that times out isn't tried again for a while (`GitGate`'s back-off).
    static let defaultTimeout: TimeInterval = ProcessInfo.processInfo.environment["GITRASIL_GIT_TIMEOUT"].flatMap { Double($0) } ?? 60

    /// - Parameters:
    ///   - workdir: the worktree directory; becomes the process cwd.
    ///   - extraEnvironment: overrides merged onto the inherited environment
    ///     (used by tests to pin `GIT_AUTHOR_DATE` etc. for reproducible fixtures).
    public init(workdir: URL, extraEnvironment: [String: String] = [:]) {
        self.init(workdir: workdir, extraEnvironment: extraEnvironment, timeout: Self.defaultTimeout, gate: .shared)
    }

    /// `command` is what's launched with the arguments after it: git through `env`; a test swaps in a program that hangs.
    init(workdir: URL, extraEnvironment: [String: String] = [:], timeout: TimeInterval, gate: GitGate,
         command: [String] = ["/usr/bin/env", "git"], pipeGrace: TimeInterval = GitRunner.defaultPipeGrace) {
        self.workdir = workdir
        self.extraEnvironment = extraEnvironment
        self.timeout = timeout
        self.gate = gate
        self.command = command
        self.pipeGrace = pipeGrace
    }

    public func run(_ args: [String]) async throws -> GitOutput {
        let key = workdir.path
        try gate.checkBackoff(key)
        try await gate.enter()
        defer { gate.leave() }
        // Checked again with the place held: the repository may have timed out while this call waited.
        let probe = try gate.admit(key)
        let call = Call(pipeGrace: pipeGrace)
        do {
            let output = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    call.begin(continuation)
                    guard !call.isStopped else { return }
                    launch(args, call)
                }
            } onCancel: {
                call.stop(CancellationError())
            }
            gate.succeeded(key, probe: probe)
            return output
        } catch Stop.timedOut {
            throw GitError.timedOut(args: args, seconds: timeout, retryAt: gate.timedOut(key, probe: probe))
        } catch {
            if probe { gate.abandoned(key) }
            throw error
        }
    }

    private func launch(_ args: [String], _ call: Call) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst()) + args
        process.currentDirectoryURL = workdir

        // The workdir decides the repository, never an inherited GIT_DIR.
        process.environment = GitRunner.environment(
            inherited: ProcessInfo.processInfo.environment, extra: extraEnvironment)

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.terminationHandler = { [weak call] proc in call?.exited(proc.terminationStatus) }

        do {
            try process.run()
        } catch {
            call.finish(.failure(GitError.launchFailed(underlying: String(describing: error))))
            return
        }
        call.attach(process, (outPipe, errPipe), timeout: timeout) { [weak call] in
            call?.stop(Stop.timedOut)
        }
    }
}
