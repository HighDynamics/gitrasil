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
    /// and was stopped.
    case timedOut(args: [String], seconds: Double)
    /// An earlier call in this repository timed out, so this one wasn't tried: not before `retryAt`.
    case backingOff(retryAt: Date)
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

/// One `git` invocation in flight: finished by whichever comes first of its exit with its output read,
/// its timeout and its task's cancellation, once; the others find it done. Output is read as it arrives
/// (no thread waits on a pipe), so a stop closes the pipes and nothing stays blocked behind a child of
/// git that holds them open; the process is terminated, and killed if it hasn't gone after a moment.
private final class Call: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<GitOutput, Error>?
    private var process: Process?
    private var pipes: [Pipe] = []
    private var timer: DispatchSourceTimer?
    private var stopped: Error?
    private var done = false
    private var out = Data()
    private var err = Data()
    private var openPipes = 2
    private var status: Int32?

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
        let doomed = lock.withLock { () -> Bool in
            self.process = process
            self.pipes = [pipes.out, pipes.err]
            self.timer = timer
            return stopped != nil || done
        }
        // A timer must be resumed once before it's released, even when it's cancelled at once.
        timer.resume()
        if doomed {
            timer.cancel()
            if isStopped { Self.kill(process); closePipes() }
            return
        }
        for (pipe, isError) in [(pipes.out, false), (pipes.err, true)] {
            pipe.fileHandleForReading.readabilityHandler = { [self] handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil }
                read(data, isError: isError)
            }
        }
    }

    private func read(_ data: Data, isError: Bool) {
        lock.withLock {
            if data.isEmpty { openPipes -= 1 } else if isError { err.append(data) } else { out.append(data) }
        }
        finishIfComplete()
    }

    func exited(_ status: Int32) {
        lock.withLock { self.status = status }
        finishIfComplete()
    }

    /// Done once the process has exited and both its pipes have run dry.
    private func finishIfComplete() {
        let output = lock.withLock { () -> GitOutput? in
            guard let status, openPipes <= 0, !done else { return nil }
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
        let pipes = lock.withLock { self.pipes }
        for pipe in pipes {
            pipe.fileHandleForReading.readabilityHandler = nil
            try? pipe.fileHandleForReading.close()
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
         command: [String] = ["/usr/bin/env", "git"]) {
        self.workdir = workdir
        self.extraEnvironment = extraEnvironment
        self.timeout = timeout
        self.gate = gate
        self.command = command
    }

    public func run(_ args: [String]) async throws -> GitOutput {
        let key = workdir.path
        try gate.checkBackoff(key)
        try await gate.enter()
        defer { gate.leave() }
        let call = Call()
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
            gate.succeeded(key)
            return output
        } catch let error as GitError {
            if case .timedOut = error { gate.timedOut(key) }
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
        process.terminationHandler = { proc in call.exited(proc.terminationStatus) }

        do {
            try process.run()
        } catch {
            call.finish(.failure(GitError.launchFailed(underlying: String(describing: error))))
            return
        }
        let seconds = timeout
        call.attach(process, (outPipe, errPipe), timeout: seconds) { [weak call] in
            call?.stop(GitError.timedOut(args: args, seconds: seconds))
        }
    }
}
