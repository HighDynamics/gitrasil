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

/// Holds the two drained pipe buffers. Each is written by exactly one I/O queue and read only
/// after `DispatchGroup.wait()` establishes the happens-before, so the access is race-free —
/// `@unchecked` because the compiler can't see that ordering.
private final class DataBox: @unchecked Sendable {
    var out = Data()
    var err = Data()
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

/// The real runner: launches `git` via `/usr/bin/env` so it honors the user's PATH,
/// exactly like their own terminal (the whole reason we shell out instead of using libgit2).
public struct GitRunner: GitRunning {
    private let workdir: URL
    private let extraEnvironment: [String: String]

    /// - Parameters:
    ///   - workdir: the worktree directory; becomes the process cwd.
    ///   - extraEnvironment: overrides merged onto the inherited environment
    ///     (used by tests to pin `GIT_AUTHOR_DATE` etc. for reproducible fixtures).
    public init(workdir: URL, extraEnvironment: [String: String] = [:]) {
        self.workdir = workdir
        self.extraEnvironment = extraEnvironment
    }

    public func run(_ args: [String]) async throws -> GitOutput {
        await GitGate.shared.enter()
        defer { GitGate.shared.leave() }
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git"] + args
            process.currentDirectoryURL = workdir

            // The workdir decides the repository, never an inherited GIT_DIR.
            process.environment = GitRunner.environment(
                inherited: ProcessInfo.processInfo.environment, extra: extraEnvironment)

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            // Drain both pipes concurrently to avoid the classic fill-the-buffer deadlock
            // (a full stderr pipe stalling the child while we block reading stdout).
            let box = DataBox()
            let group = DispatchGroup()
            let ioQueue = DispatchQueue(label: "gitrasil.git.io", attributes: .concurrent)
            group.enter()
            ioQueue.async { box.out = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
            group.enter()
            ioQueue.async { box.err = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }

            process.terminationHandler = { proc in
                group.wait()
                continuation.resume(returning: GitOutput(status: proc.terminationStatus, stdout: box.out, stderr: box.err))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: GitError.launchFailed(underlying: String(describing: error)))
            }
        }
    }
}
