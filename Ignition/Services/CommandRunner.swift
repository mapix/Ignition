import Foundation

struct CommandResult: Sendable {
    let status: Int32
    let output: String
    let error: String
    var success: Bool { status == 0 }
    var failureDescription: String {
        let message = error.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "Command failed (exit \(status))." : message
    }
}

enum CommandRunner {
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScriptLiteral(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    static func installNewPlist(from source: String, to destination: String) async -> CommandResult {
        let input = shellQuote(source)
        let output = shellQuote(destination)
        // cp -n retains an existing file, cmp detects a collision, and launchd needs a readable plist.
        let command = "/bin/cp -n \(input) \(output) && /usr/bin/cmp -s \(input) \(output) && /bin/chmod 0644 \(output)"
        return await run("/bin/sh", ["-c", command], admin: true)
    }

    /// File-backed output avoids pipe deadlocks for large launchctl/ps/lsof responses.
    static func run(_ executable: String, _ arguments: [String], admin: Bool = false,
                    timeout: TimeInterval = 15, outputLimit: Int = 2_000_000) async -> CommandResult {
        await Task.detached(priority: .userInitiated) {
            execute(executable, arguments, admin: admin, timeout: timeout, outputLimit: outputLimit)
        }.value
    }

    private static func execute(_ executable: String, _ arguments: [String], admin: Bool,
                                timeout: TimeInterval, outputLimit: Int) -> CommandResult {
            let fm = FileManager.default
            let directory = fm.temporaryDirectory.appendingPathComponent("Ignition-command-" + UUID().uuidString)
            do {
                try fm.createDirectory(at: directory, withIntermediateDirectories: false,
                                       attributes: [.posixPermissions: 0o700])
                defer { try? fm.removeItem(at: directory) }
                let outURL = directory.appendingPathComponent("stdout")
                let errURL = directory.appendingPathComponent("stderr")
                fm.createFile(atPath: outURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
                fm.createFile(atPath: errURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
                let out = try FileHandle(forWritingTo: outURL)
                let err = try FileHandle(forWritingTo: errURL)
                defer { try? out.close(); try? err.close() }
                let process = Process()
                if admin {
                    let command = ([executable] + arguments).map(shellQuote).joined(separator: " ")
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                    process.arguments = ["-e", "do shell script \(appleScriptLiteral(command)) with administrator privileges"]
                } else {
                    process.executableURL = URL(fileURLWithPath: executable)
                    process.arguments = arguments
                }
                process.standardOutput = out
                process.standardError = err
                let finished = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in finished.signal() }
                try process.run()
                let effectiveTimeout = admin ? max(timeout, 120) : timeout
                let didTimeout = finished.wait(timeout: .now() + effectiveTimeout) == .timedOut
                if didTimeout {
                    process.terminate()
                    if finished.wait(timeout: .now() + 1) == .timedOut {
                        Darwin.kill(process.processIdentifier, SIGKILL)
                        process.waitUntilExit()
                    }
                }
                func read(_ url: URL) -> String {
                    guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
                    defer { try? handle.close() }
                    let data = (try? handle.read(upToCount: outputLimit + 1)) ?? Data()
                    return String(decoding: data.prefix(outputLimit), as: UTF8.self)
                        + (data.count > outputLimit ? "\n[Output truncated]" : "")
                }
                return CommandResult(status: didTimeout ? -1 : process.terminationStatus,
                                     output: read(outURL),
                                     error: didTimeout ? "Command timed out after \(Int(effectiveTimeout)) seconds." : read(errURL))
            } catch {
                return CommandResult(status: -1, output: "", error: error.localizedDescription)
            }
    }
}
