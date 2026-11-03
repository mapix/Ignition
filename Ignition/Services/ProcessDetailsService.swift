import Foundation

struct ProcessSnapshot: Identifiable, Sendable {
    var id: Int { pid }
    let pid: Int
    let parentPID: Int
    let uid: Int
    let user: String
    let cpu: Double
    let memoryPercent: Double
    let residentKB: Int
    let virtualKB: Int
    let elapsed: String
    let state: String
    let command: String
}

struct ProcessDetails: Sendable {
    let process: ProcessSnapshot
    let started: String
    let descendants: [ProcessSnapshot]
    let openFiles: String
    let network: String
    let fileWarning: String?
    let capturedAt: Date
}

enum ProcessSignal: String, CaseIterable, Identifiable {
    case terminate = "SIGTERM", interrupt = "SIGINT", hangup = "SIGHUP"
    case suspend = "SIGSTOP", resume = "SIGCONT", forceKill = "SIGKILL"
    var id: String { rawValue }
    var explanation: String {
        switch self {
        case .terminate: return "Request a graceful exit. KeepAlive may restart it."
        case .interrupt: return "Send an interrupt, equivalent to Ctrl-C."
        case .hangup: return "Request configuration reload if the program supports SIGHUP."
        case .suspend: return "Pause the process until SIGCONT is sent."
        case .resume: return "Resume a paused process."
        case .forceKill: return "Immediately terminate without allowing cleanup. KeepAlive may restart it."
        }
    }
}

enum ProcessDetailsService {
    static func parseTable(_ text: String) -> [ProcessSnapshot] {
        text.components(separatedBy: .newlines).compactMap { line in
            let c = line.split(maxSplits: 10, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            guard c.count == 11, let pid = Int(c[0]), let parent = Int(c[1]), let uid = Int(c[2]),
                  let cpu = Double(c[4]), let percent = Double(c[5]), let rss = Int(c[6]), let vsz = Int(c[7]) else { return nil }
            return ProcessSnapshot(pid: pid, parentPID: parent, uid: uid, user: String(c[3]), cpu: cpu,
                                   memoryPercent: percent, residentKB: rss, virtualKB: vsz,
                                   elapsed: String(c[8]), state: String(c[9]), command: String(c[10]))
        }
    }

    static func fetch(pid: Int) async throws -> ProcessDetails {
        guard pid > 1 else { throw PlistWriteError(message: "Invalid process ID.") }
        async let table = CommandRunner.run("/bin/ps", ["-ww", "-axo", "pid=,ppid=,uid=,user=,pcpu=,pmem=,rss=,vsz=,etime=,state=,command="])
        async let start = CommandRunner.run("/bin/ps", ["-p", String(pid), "-o", "lstart="])
        async let files = CommandRunner.run("/usr/sbin/lsof", ["-nP", "-p", String(pid)], timeout: 8, outputLimit: 512_000)
        let results = await (table, start, files)
        guard results.0.success else { throw PlistWriteError(message: results.0.failureDescription) }
        let processes = parseTable(results.0.output)
        guard let main = processes.first(where: { $0.pid == pid }), results.1.success else {
            throw PlistWriteError(message: "The process exited. Refresh the service to get its current PID.")
        }
        var descendants: [ProcessSnapshot] = []
        var parents: Set<Int> = [pid]
        for _ in 0..<32 {
            let children = processes.filter { parents.contains($0.parentPID) && !parents.contains($0.pid) }
            if children.isEmpty { break }
            descendants.append(contentsOf: children)
            parents.formUnion(children.map(\.pid))
        }
        let network = results.2.output.components(separatedBy: .newlines)
            .filter { $0.contains("IPv4") || $0.contains("IPv6") || $0.contains(" unix ") }.joined(separator: "\n")
        return ProcessDetails(process: main, started: results.1.output.trimmingCharacters(in: .whitespacesAndNewlines),
                              descendants: descendants, openFiles: results.2.output, network: network,
                              fileWarning: results.2.success ? (results.2.error.isEmpty ? nil : results.2.error) : results.2.failureDescription,
                              capturedAt: Date())
    }
}

extension LaunchAgentManager {
    @discardableResult
    func sendSignal(_ signal: ProcessSignal, to original: LaunchAgent, expected: ProcessDetails) async -> Bool {
        let agent = current(original)
        guard agent.canControl, agent.pid == expected.process.pid, !busyServiceIDs.contains(agent.id) else {
            errorMessage = agent.protectionReason ?? "The service PID changed. Refresh process details before sending a signal."
            return false
        }
        busyServiceIDs.insert(agent.id)
        defer { busyServiceIDs.remove(agent.id) }
        do {
            let fresh = try await ProcessDetailsService.fetch(pid: expected.process.pid)
            guard fresh.started == expected.started, fresh.process.uid == expected.process.uid,
                  fresh.process.command == expected.process.command else {
                throw PlistWriteError(message: "The process identity changed; the signal was not sent.")
            }
            let state = await CommandRunner.run("/bin/launchctl", ["print", agent.serviceTarget])
            let pidLine = state.output.components(separatedBy: .newlines)
                .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("pid = ") }
            guard state.success, pidLine?.trimmingCharacters(in: .whitespaces) == "pid = \(expected.process.pid)" else {
                throw PlistWriteError(message: "launchd now owns a different process; the signal was not sent.")
            }
            if [.terminate, .interrupt, .forceKill, .hangup].contains(signal) {
                historyService?.expectStop(serviceID: agent.id, pid: expected.process.pid)
            }
            let result = await CommandRunner.run("/bin/launchctl", ["kill", signal.rawValue, agent.serviceTarget], admin: agent.domain.requiresAdmin)
            guard result.success else {
                historyService?.cancelExpectedStop(serviceID: agent.id)
                throw PlistWriteError(message: result.failureDescription)
            }
            record(agent, signal.rawValue, true, "Sent to PID \(expected.process.pid).")
            notice = "\(signal.rawValue) sent to \(agent.label), PID \(expected.process.pid)."
            await refreshStatus()
            return true
        } catch {
            errorMessage = error.localizedDescription
            record(agent, signal.rawValue, false, error.localizedDescription)
            return false
        }
    }
}
