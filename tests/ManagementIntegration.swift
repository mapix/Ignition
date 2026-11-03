import Foundation
import Combine
import AppKit

@main
struct ManagementIntegration {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("Ignition-integration-" + UUID().uuidString)
        let directory = root.appendingPathComponent("agents")
        let storage = root.appendingPathComponent("storage")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let label = "org.ignition.qa." + UUID().uuidString.lowercased()
        let target = "\(AgentDomain.userAgents.launchdDomain)/\(label)"
        let suite = "org.ignition.qa." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let manager = LaunchAgentManager(userAgentsDirectory: directory.path, storageDirectory: storage,
                                         defaults: defaults, automaticRefresh: false)
        let history = ActivityHistoryService(storageDirectory: storage)
        manager.historyService = history
        var passed = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw PlistWriteError(message: "FAIL: \(message). \(manager.errorMessage ?? "")") }
            passed += 1; FileHandle.standardOutput.write(Data("PASS: \(message)\n".utf8))
        }
        func current() throws -> LaunchAgent {
            guard let agent = manager.agents.first(where: { $0.label == label && $0.domain == .userAgents }) else {
                throw PlistWriteError(message: "Fixture not found")
            }
            return agent
        }
        func waitFor(_ condition: (LaunchAgent) -> Bool) async throws -> LaunchAgent {
            for _ in 0..<30 {
                await manager.refreshStatus()
                let agent = try current()
                if condition(agent) { return agent }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw PlistWriteError(message: "Timed out waiting for fixture state: \(try current().status)")
        }
        do {
            let output = await CommandRunner.run("/usr/bin/awk", ["BEGIN { for(i=0;i<20000;i++) print \"0123456789abcdefghijklmnopqrstuvwxyz\" }"])
            try check(output.success && output.output.count > 500_000, "Large output does not deadlock")
            let timeout = await CommandRunner.run("/bin/sleep", ["5"], timeout: 0.1)
            try check(timeout.status == -1, "Bounded command timeout")
            try Data("invalid".utf8).write(to: directory.appendingPathComponent("org.ignition.invalid.plist"))
            var form = AgentFormData()
            form.label = label; form.program = "/bin/sleep"; form.arguments = ["117"]; form.runAtLoad = true
            form.standardOutPath = root.appendingPathComponent("stdout.log").path
            form.standardErrorPath = root.appendingPathComponent("stderr.log").path
            try await manager.createAgent(from: form, andLoad: false)
            var agent = try current()
            try check(agent.status == .unloaded, "Create without loading")
            let fullBackup = try ImportExportService.backupUserAgents(from: directory.path, storageDirectory: storage)
            try check(fm.fileExists(atPath: fullBackup.appendingPathComponent(label + ".plist").path), "Backup uses the requested service directory")
            var otherDomain = agent; otherDomain.id = "Global Agents:\(label)"; otherDomain.plistContents = agent.plistContents
            let other = LaunchAgent(id: otherDomain.id, label: label, domain: .globalAgents, plistPath: agent.plistPath,
                                    status: .unloaded, plistContents: agent.plistContents)
            let exported = try ImportExportService.exportAgents([agent, other], to: root)
            let exportFiles = try fm.contentsOfDirectory(atPath: exported.path).filter { $0 != "manifest.plist" }
            try check(exportFiles.count == 2, "Cross-domain export avoids label filename collisions")
            try check(manager.agents.contains { $0.label == "org.ignition.invalid" && $0.status == .unknown && $0.discoveryError != nil }, "Malformed plist remains visible")
            try check(manager.agents.contains { $0.label == "com.apple.logd" && $0.status == .running }, "Correct system domain status")
            try check(manager.agents.contains { $0.domain.isRuntime }, "Runtime registration discovery")
            let broken = manager.agents.first { $0.label == "org.ignition.invalid" }!
            try check(await manager.deleteAgent(broken), "Malformed service can be safely deleted")
            let brokenBackup = manager.deletedServices.first { $0.label == "org.ignition.invalid" }!
            try check(await manager.restore(brokenBackup), "Malformed file can be recovered without executing")
            let recoveredBytes = try Data(contentsOf: directory.appendingPathComponent("org.ignition.invalid.plist"))
            try check(recoveredBytes == Data("invalid".utf8), "Recovery preserves exact malformed bytes")
            var changedSnapshot = agent; changedSnapshot.status = .running; changedSnapshot.pid = 12345
            try check(agent != changedSnapshot, "Model equality reflects changed state for SwiftUI refresh")
            let redacted = ServiceDiagnostics.redactSecrets("API_KEY => fixture-secret\nHOME => /tmp")
            try check(!redacted.contains("fixture-secret") && redacted.contains("HOME => /tmp"), "Diagnostic secrets redacted")
            try check(await manager.perform(.load, on: agent), "Bootstrap in explicit GUI domain")
            agent = try await waitFor { $0.pid != nil }
            let duplicate = directory.appendingPathComponent("duplicate.plist")
            let duplicateData = try Data(contentsOf: URL(fileURLWithPath: agent.plistPath))
            try duplicateData.write(to: duplicate)
            await manager.loadAllAgents()
            let duplicateAgents = manager.agents.filter { $0.domain == .userAgents && $0.label == label }
            try check(duplicateAgents.count == 2 && Set(duplicateAgents.map(\.id)).count == 2 &&
                      duplicateAgents.allSatisfy { !$0.canControl }, "Duplicate labels have distinct inventory identities")
            let duplicateAgent = duplicateAgents.first { $0.plistPath == duplicate.path }!
            try check(await manager.deleteAgent(duplicateAgent), "Delete duplicate file without unloading other registration")
            agent = try await waitFor { $0.status == .running }
            let firstPID = agent.pid!
            let details = try await ProcessDetailsService.fetch(pid: firstPID)
            try check(details.process.uid == Int(getuid()) && details.process.command.contains("sleep 117") && !details.started.isEmpty, "Real process details")
            try check(!details.openFiles.isEmpty, "Real open files")
            let diagnostics = await ServiceDiagnostics.inspect(agent)
            try check(diagnostics.rawState.contains("pid = \(firstPID)"), "Raw launchctl diagnostics")
            try check(await manager.sendSignal(.suspend, to: agent, expected: details), "Verified SIGSTOP")
            let suspended = try await ProcessDetailsService.fetch(pid: firstPID)
            try check(suspended.process.state.contains("T"), "Process actually suspended")
            try check(await manager.sendSignal(.resume, to: agent, expected: suspended), "Verified SIGCONT")
            try check(await manager.perform(.restart, on: agent), "Kickstart restart")
            agent = try await waitFor { $0.pid != nil && $0.pid != firstPID }
            try check(!(await manager.sendSignal(.terminate, to: agent, expected: details)), "Reject stale PID")
            try check(await manager.perform(.stop, on: agent), "Graceful stop")
            agent = try await waitFor { $0.status == .loaded }
            try check(history.eventsForAgent(agent.id).allSatisfy { $0.eventType != .crashed },
                      "Intentional stop and restart are not recorded as crashes")
            try check(await manager.perform(.start, on: agent), "Start loaded service")
            agent = try await waitFor { $0.status == .running }
            try check(await manager.perform(.disable, on: agent), "Disable and unload")
            agent = try await waitFor { $0.status == .unloaded && $0.isDisabled }
            try check(!manager.available(.load, for: agent), "Disabled load prevented")
            try check(await manager.perform(.enable, on: agent), "Enable override")
            agent = try current()
            var dict = agent.plistContents; dict["ProgramArguments"] = ["/bin/sleep", "118"]
            try check(await manager.saveConfiguration(dict, for: agent, reload: true), "Save and reload")
            agent = try await waitFor { $0.status == .running }
            try check(fm.fileExists(atPath: agent.plistPath + ".backup"), "Save backup retained")
            let changed = try await ProcessDetailsService.fetch(pid: agent.pid!)
            try check(changed.process.command.contains("sleep 118"), "New configuration applied")
            try check(await manager.deleteAgent(agent), "Back up, unload and delete")
            try check(!fm.fileExists(atPath: agent.plistPath), "Plist removed")
            let removed = await CommandRunner.run("/bin/launchctl", ["print", target])
            try check(!removed.success, "Job removed from launchd")
            guard let backup = manager.deletedServices.first(where: { $0.label == label }) else { throw PlistWriteError(message: "Missing backup") }
            try check(fm.fileExists(atPath: backup.backupPath), "Recovery backup exists")
            try check(await manager.restore(backup), "Restore backup")
            agent = try current()
            try check(agent.status == .unloaded && agent.pid == nil, "Restore never starts service")
            try check(!(await manager.restore(backup)), "Restore refuses overwrite")
            try check(manager.operations.contains { $0.action == "Delete" && $0.success } && manager.operations.contains { $0.action == "Restore" && $0.success }, "Management history outcomes")
            let protected = LaunchAgent(id: "System Daemons:com.apple.logd", label: "com.apple.logd", domain: .systemDaemons,
                                        plistPath: "/System/Library/LaunchDaemons/com.apple.logd.plist", status: .running, pid: 100, plistContents: [:])
            let protectedDelete = await manager.deleteAgent(protected)
            try check(!manager.available(.stop, for: protected) && !protectedDelete, "System protection below UI")
            manager.statusFilter = .unloaded
            try check(manager.filteredAgents.contains { $0.label == label }, "Status filtering")
            manager.togglePin(agent); manager.statusFilter = .pinned
            try check(manager.filteredAgents.contains { $0.id == agent.id }, "Domain-qualified pins")
            manager.selectedLabels = [agent.id]; await manager.bulk(.load)
            agent = try await waitFor { $0.status == .running }
            try check(manager.selectedLabels.isEmpty, "Bulk action completion")
            let logURL = root.appendingPathComponent("follow.log")
            try Data("first\n".utf8).write(to: logURL)
            let logs = LogTailService(); logs.startTailing(stdoutPath: logURL.path, stderrPath: nil)
            try check(logs.lines.contains { $0.text == "first" }, "Initial logs")
            try fm.moveItem(at: logURL, to: root.appendingPathComponent("follow.old"))
            try Data("rotated\n".utf8).write(to: logURL)
            for _ in 0..<20 where !logs.lines.contains(where: { $0.text == "rotated" }) { try await Task.sleep(for: .milliseconds(100)) }
            try check(logs.lines.contains { $0.text == "rotated" }, "Log rotation")
            try Data("truncate\n".utf8).write(to: logURL)
            for _ in 0..<20 where !logs.lines.contains(where: { $0.text == "truncate" }) { try await Task.sleep(for: .milliseconds(100)) }
            try check(logs.lines.contains { $0.text == "truncate" }, "Log truncation")
            logs.stop(); try check(!logs.isActive, "Log descriptor ownership")
            let otherID = "Global Agents:\(label)"
            history.recordEvent(label: label, serviceID: otherID, type: .loaded)
            try check(history.eventsForAgent(otherID).allSatisfy { $0.serviceID == otherID }, "Separate domain activity history")
            let tree = Process()
            tree.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            tree.arguments = ["-c", "import socket,subprocess,time; s=socket.socket(); s.bind(('127.0.0.1',0)); s.listen(); child=subprocess.Popen(['/bin/sleep','129']); time.sleep(15)"]
            try tree.run()
            var processTree: ProcessDetails?
            for _ in 0..<20 {
                processTree = try await ProcessDetailsService.fetch(pid: Int(tree.processIdentifier))
                if processTree?.descendants.isEmpty == false { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            if let processTree {
                for child in processTree.descendants { Darwin.kill(Int32(child.pid), SIGTERM) }
            }
            tree.terminate()
            try check(processTree?.descendants.contains { $0.command.contains("sleep 129") } == true, "Real descendant process tree")
            try check(processTree?.network.contains("LISTEN") == true, "Real loopback network inspection")
            print("COMPLETED: \(passed) integration checks")
        } catch {
            _ = await CommandRunner.run("/bin/launchctl", ["bootout", target])
            _ = await CommandRunner.run("/bin/launchctl", ["enable", target])
            defaults.removePersistentDomain(forName: suite); try? fm.removeItem(at: root)
            throw error
        }
        _ = await CommandRunner.run("/bin/launchctl", ["bootout", target])
        _ = await CommandRunner.run("/bin/launchctl", ["enable", target])
        defaults.removePersistentDomain(forName: suite); try fm.removeItem(at: root)
        print("CLEANUP: disposable job and files removed")
    }
}
