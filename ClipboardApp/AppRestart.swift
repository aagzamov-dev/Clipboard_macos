import Foundation
import Darwin

struct AppRestart {
    static let helperArgument = "--restart-helper"
    static let permissionsArgument = "--open-permissions"

    static func schedule(bundle: Bundle = .main) async throws {
        guard let executable = bundle.executableURL else { throw RestartError.missingExecutable }
        let helper = Process()
        helper.executableURL = executable
        helper.arguments = [helperArgument, String(ProcessInfo.processInfo.processIdentifier)]
        let readiness = Pipe()
        helper.standardOutput = readiness
        let descriptor = readiness.fileHandleForReading.fileDescriptor
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) != -1 else { throw RestartError.helperFailed }
        try helper.run()
        do {
            let deadline = ContinuousClock.now + .seconds(3)
            while ContinuousClock.now < deadline {
                var token: UInt8 = 0
                if read(descriptor, &token, 1) == 1, token == 1 { return }
                guard helper.isRunning else { throw RestartError.helperFailed }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw RestartError.helperFailed
        } catch {
            if helper.isRunning { helper.terminate() }
            throw error
        }
    }

    static func runHelper(arguments: [String], bundleURL: URL, parentPID: pid_t = getppid(), isRunning: (pid_t) -> Bool = { kill($0, 0) == 0 || errno == EPERM }, wait: () -> Void = { Thread.sleep(forTimeInterval: 0.1) }, ready: () throws -> Void = { try FileHandle.standardOutput.write(contentsOf: Data([1])) }, launch: (URL) throws -> Void = launchApplication) throws {
        guard arguments.count == 3, arguments[1] == helperArgument,
              let pid = pid_t(arguments[2]), pid > 1, pid == parentPID else { throw RestartError.invalidParent }
        try ready()
        for _ in 0..<300 {
            if !isRunning(pid) { try launch(bundleURL); return }
            wait()
        }
        throw RestartError.stillRunning
    }

    private static func launchApplication(_ url: URL) throws {
        let opener = Process()
        opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        opener.arguments = ["-n", "-a", url.path, "--args", permissionsArgument]
        try opener.run()
        opener.waitUntilExit()
        guard opener.terminationStatus == 0 else { throw RestartError.launchFailed }
    }

    enum RestartError: LocalizedError {
        case missingExecutable, invalidParent, stillRunning, launchFailed, helperFailed
        var errorDescription: String? {
            switch self {
            case .helperFailed: "The restart helper could not get ready. Clipboard has not quit; try again."
            case .missingExecutable: "Clipboard could not find its executable. The app has not quit."
            case .invalidParent: "The restart request did not match the running app."
            case .stillRunning: "Clipboard did not finish quitting, so no second copy was opened."
            case .launchFailed: "Clipboard could not reopen. Open it from Applications."
            }
        }
    }
}
