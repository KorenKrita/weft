import Darwin
import Foundation

public struct ProcessOutput: Sendable, Equatable {
    public var status: Int32
    public var stdout: Data
    public var stderr: Data
}

public enum ProcessRunnerError: Error, Equatable {
    case launchFailed(String)
    case timedOut
    case outputTooLarge
}

/// Runs a command and collects its output. Both pipes are drained as data arrives, so a
/// command that prints more than a pipe holds (64 KB) can't block on a full pipe.
public enum ProcessRunner {
    public static func run(_ executable: URL, arguments: [String], environment: [String: String]? = nil,
                           timeout: TimeInterval = 60, maxOutput: Int = 16 << 20) async throws -> ProcessOutput {
        let run = Running(executable: executable, arguments: arguments, environment: environment, maxOutput: maxOutput)
        return try await withCheckedThrowingContinuation { continuation in
            run.start(timeout: timeout) { continuation.resume(with: $0) }
        }
    }
}

/// One process and its output. Its callbacks arrive on Foundation's queues, hence the lock.
private final class Running: @unchecked Sendable {
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let maxOutput: Int
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()
    private var failure: ProcessRunnerError?
    private var completion: ((Result<ProcessOutput, any Error>) -> Void)?

    init(executable: URL, arguments: [String], environment: [String: String]?, maxOutput: Int) {
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        self.maxOutput = maxOutput
    }

    func start(timeout: TimeInterval, completion: @escaping (Result<ProcessOutput, any Error>) -> Void) {
        self.completion = completion
        stdoutPipe.fileHandleForReading.readabilityHandler = { [self] handle in collect(handle.availableData, isStdout: true) }
        stderrPipe.fileHandleForReading.readabilityHandler = { [self] handle in collect(handle.availableData, isStdout: false) }
        process.terminationHandler = { [self] _ in finish() }
        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            complete(.failure(ProcessRunnerError.launchFailed(error.localizedDescription)))
            return
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [self] in stop(.timedOut) }
    }

    private func collect(_ data: Data, isStdout: Bool) {
        guard !data.isEmpty else { return }
        let tooLarge = lock.withLock {
            if isStdout { stdout.append(data) } else { stderr.append(data) }
            return stdout.count + stderr.count > maxOutput
        }
        if tooLarge { stop(.outputTooLarge) }
    }

    /// Asks the process to quit, then kills it if it doesn't.
    private func stop(_ reason: ProcessRunnerError) {
        guard process.isRunning else { return }
        lock.withLock { if failure == nil { failure = reason } }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [self] in
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    private func finish() {
        // The handlers hold on to this object; letting go of them frees it.
        process.terminationHandler = nil
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        // Whatever arrived after the last readability callback.
        collect(stdoutPipe.fileHandleForReading.readDataToEndOfFile(), isStdout: true)
        collect(stderrPipe.fileHandleForReading.readDataToEndOfFile(), isStdout: false)
        let (output, failure) = lock.withLock {
            (ProcessOutput(status: process.terminationStatus, stdout: stdout, stderr: stderr), self.failure)
        }
        complete(failure.map { .failure($0) } ?? .success(output))
    }

    private func complete(_ result: Result<ProcessOutput, any Error>) {
        let completion = lock.withLock {
            defer { self.completion = nil }
            return self.completion
        }
        completion?(result)
    }
}
