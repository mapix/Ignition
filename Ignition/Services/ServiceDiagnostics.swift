import Foundation

struct ServiceDiagnostics: Sendable {
    let rawState: String
    let reason: String
    let issues: [String]
    let checkedAt: Date
    static func redactSecrets(_ text: String) -> String {
        text.components(separatedBy: .newlines).map { line in
            let pieces = line.components(separatedBy: " => ")
            guard pieces.count == 2 else { return line }
            let key = pieces[0].uppercased()
            if ["TOKEN", "SECRET", "PASSWORD", "KEY", "CREDENTIAL", "AUTHORIZATION"].contains(where: key.contains) {
                return pieces[0] + " => [redacted]"
            }
            return line
        }.joined(separator: "\n")
    }

    static func inspect(_ agent: LaunchAgent) async -> ServiceDiagnostics {
        async let state = CommandRunner.run("/bin/launchctl", ["print", agent.serviceTarget])
        async let blame = CommandRunner.run("/bin/launchctl", ["blame", agent.serviceTarget])
        let results = await (state, blame)
        var issues: [String] = []
        if let error = agent.discoveryError { issues.append(error) }
        if agent.hasPlist {
            do { try PlistWriteService.validate(agent.plistContents) }
            catch { issues.append(error.localizedDescription) }
            if let program = agent.program {
                let expanded = NSString(string: program).expandingTildeInPath
                if !expanded.hasPrefix("/") { issues.append("Program is relative; launchd's executable search may differ from your shell.") }
                else if !FileManager.default.isExecutableFile(atPath: expanded) {
                    issues.append("Program does not exist or is not executable: \(expanded)")
                }
                if program.hasPrefix("~") { issues.append("launchd does not expand ~ in Program or ProgramArguments. Use an absolute path.") }
            }
            for (key, path) in [("stdout", agent.standardOutPath), ("stderr", agent.standardErrorPath)] {
                if let path {
                    if !path.hasPrefix("/") { issues.append("\(key) log path should be absolute.") }
                    let parent = (path as NSString).deletingLastPathComponent
                    if !FileManager.default.fileExists(atPath: parent) { issues.append("\(key) log folder does not exist: \(parent)") }
                }
            }
        } else {
            issues.append("Runtime registration has no standalone plist. Its owning application may recreate it after unloading.")
        }
        if agent.isDisabled { issues.append("Disabled in launchd. Enable it before loading.") }
        if let exit = agent.lastExitStatus, exit != 0 { issues.append("Last exit status: \(exit). Check logs for the program's reason.") }
        if agent.isKeepAlive { issues.append("KeepAlive can restart a stopped process. Unload or Disable to prevent relaunch.") }
        return ServiceDiagnostics(rawState: results.0.success ? redactSecrets(results.0.output) : results.0.failureDescription,
                                  reason: results.1.success ? results.1.output : results.1.failureDescription,
                                  issues: issues, checkedAt: Date())
    }
}

extension LaunchAgentManager {
    @discardableResult
    func saveConfiguration(_ dict: [String: Any], for original: LaunchAgent, reload: Bool) async -> Bool {
        let agent = current(original)
        guard agent.canDelete, !busyServiceIDs.contains(agent.id) else {
            errorMessage = agent.protectionReason ?? "Configuration is not editable."
            return false
        }
        busyServiceIDs.insert(agent.id)
        do {
            let destination = URL(fileURLWithPath: agent.plistPath)
            try validateDestination(destination, domain: agent.domain)
            guard (try destination.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
                throw PlistWriteError(message: "Editing symlinked service files is not supported.")
            }
            try PlistWriteService.validate(dict)
            guard dict["Label"] as? String == agent.label else {
                throw PlistWriteError(message: "Label identifies the registered service. Create a new service to change it.")
            }
            if agent.domain == .userAgents {
                try PlistWriteService.write(dict, to: agent.plistPath, requiresAdmin: false)
            } else {
                let fm = FileManager.default
                let directory = fm.temporaryDirectory.appendingPathComponent("Ignition-save-" + UUID().uuidString)
                try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                defer { try? fm.removeItem(at: directory) }
                let temp = directory.appendingPathComponent("service.plist")
                let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
                try data.write(to: temp)
                let backup = await CommandRunner.run("/bin/cp", [agent.plistPath, agent.plistPath + ".backup"], admin: true)
                guard backup.success else { throw PlistWriteError(message: "Backup failed: \(backup.failureDescription)") }
                let result = await CommandRunner.run("/bin/cp", [temp.path, agent.plistPath], admin: true)
                guard result.success else { throw PlistWriteError(message: result.failureDescription) }
            }
            busyServiceIDs.remove(agent.id)
            record(agent, "Save Configuration", true, "Previous configuration backed up.")
            await loadAllAgents()
            if reload { return await perform(.reload, on: current(agent)) }
            notice = "Saved \(agent.label). Reload Configuration to apply changes to launchd."
            return true
        } catch {
            busyServiceIDs.remove(agent.id)
            errorMessage = error.localizedDescription
            record(agent, "Save Configuration", false, error.localizedDescription)
            return false
        }
    }
}
