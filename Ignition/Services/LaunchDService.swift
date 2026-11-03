import Foundation
import Combine
import AppKit

@MainActor
class LaunchAgentManager: ObservableObject {
    @Published var agents: [LaunchAgent] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var notice: String?
    @Published var lastRefreshed: Date?
    @Published var selectedDomain: AgentDomain? = .userAgents
    @Published var searchText = ""
    @Published var statusFilter: ServiceFilter = .all
    @Published var includeAllDomains = false
    @Published var busyServiceIDs: Set<String> = []
    @Published var selectedLabels: Set<String> = []
    @Published var operations: [ServiceOperation] = []
    @Published var deletedServices: [DeletedService] = []
    @Published var pendingDeletion: [LaunchAgent] = []
    @Published var processAgent: LaunchAgent?
    @Published var diagnosticsAgent: LaunchAgent?
    @Published var newlyCreatedID: String?
    @Published var tagState = ServiceTagState()
    @Published var tagFilter: ServiceTagFilter = .all
    @Published var taggingAgents: [LaunchAgent] = []
    let tagsURL: URL
    var tagStorageError: String?
    @Published var pinnedLabels: Set<String> {
        didSet { defaults.set(Array(pinnedLabels), forKey: "pinnedAgentLabels") }
    }
    private var refreshTimer: Timer?
    private var refreshInProgress = false
    private let defaults: UserDefaults
    let userAgentsDirectory: String
    let recoveryDirectory: URL
    private let operationsURL: URL
    var historyService: ActivityHistoryService?
    var notificationService: NotificationService?
    var healthMonitor: HealthMonitorService?

    init(userAgentsDirectory: String? = nil, storageDirectory: URL? = nil,
         defaults: UserDefaults = .standard, automaticRefresh: Bool = true) {
        self.defaults = defaults
        self.userAgentsDirectory = userAgentsDirectory
            ?? ProcessInfo.processInfo.environment["IGNITION_TEST_AGENT_DIRECTORY"] ?? AgentDomain.userAgents.path
        let testStorage = ProcessInfo.processInfo.environment["IGNITION_TEST_STORAGE_DIRECTORY"].map { URL(fileURLWithPath: $0) }
        let storage = storageDirectory ?? testStorage ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Ignition", isDirectory: true)
        recoveryDirectory = storage.appendingPathComponent("DeletedServices", isDirectory: true)
        operationsURL = storage.appendingPathComponent("operations.json")
        tagsURL = storage.appendingPathComponent("tags.json")
        pinnedLabels = Set(defaults.stringArray(forKey: "pinnedAgentLabels") ?? [])
        if let data = try? Data(contentsOf: operationsURL),
           let saved = try? JSONDecoder().decode([ServiceOperation].self, from: data) { operations = saved }
        do {
            if FileManager.default.fileExists(atPath: tagsURL.path) {
                tagState = try JSONDecoder().decode(ServiceTagState.self, from: Data(contentsOf: tagsURL))
            }
        } catch {
            tagStorageError = "Could not read service tags: \(error.localizedDescription)"
            errorMessage = tagStorageError
        }
        refreshDeletedServices()
        if automaticRefresh {
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in await self?.refreshStatus() }
            }
        }
    }

    var pinnedAgents: [LaunchAgent] { agents.filter(isPinned).sorted { $0.label < $1.label } }
    var runningCount: Int { agents.filter { $0.status == .running }.count }
    func current(_ agent: LaunchAgent) -> LaunchAgent {
        if let latest = agents.first(where: { $0.id == agent.id || (agent.hasPlist && $0.plistPath == agent.plistPath) }) { return latest }
        var missing = agent
        missing.status = .unknown; missing.pid = nil
        missing.discoveryError = "Service is no longer in the current inventory. Refresh before managing it."
        return missing
    }
    func togglePin(_ agent: LaunchAgent) {
        if isPinned(agent) { pinnedLabels.remove(agent.id); pinnedLabels.remove(agent.label) }
        else { pinnedLabels.insert(agent.id) }
    }
    func isPinned(_ agent: LaunchAgent) -> Bool { pinnedLabels.contains(agent.id) || pinnedLabels.contains(agent.label) }
    var filteredAgents: [LaunchAgent] {
        agents.filter { agent in
            guard includeAllDomains || agent.domain == selectedDomain else { return false }
            switch tagFilter {
            case .all: break
            case .untagged: if !tags(for: agent).isEmpty { return false }
            case .tag(let id): if !tagState.assignments[agent.serviceTarget, default: []].contains(id) { return false }
            }
            switch statusFilter {
            case .all: break
            case .running: if agent.status != .running { return false }
            case .loaded: if agent.status != .loaded { return false }
            case .unloaded: if agent.status != .unloaded { return false }
            case .disabled: if !agent.isDisabled { return false }
            case .problems: if agent.discoveryError == nil && (agent.lastExitStatus ?? 0) == 0 && healthMonitor?.crashLoopLabels[agent.id] == nil { return false }
            case .pinned: if !isPinned(agent) { return false }
            }
            return searchText.isEmpty || [agent.label, agent.program ?? "", agent.plistPath, agent.pid.map(String.init) ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(searchText) }
        }.sorted { $0.label == $1.label ? $0.domain.rawValue < $1.domain.rawValue : $0.label < $1.label }
    }
    var domainCounts: [AgentDomain: Int] { Dictionary(grouping: agents, by: \.domain).mapValues(\.count) }
    var selectedAgents: [LaunchAgent] { agents.filter { selectedLabels.contains($0.id) } }
    func isSelected(_ agent: LaunchAgent) -> Bool { selectedLabels.contains(agent.id) }
    func toggleSelection(_ agent: LaunchAgent) {
        if isSelected(agent) { selectedLabels.remove(agent.id) } else { selectedLabels.insert(agent.id) }
    }
    func selectAll() { selectedLabels = Set(filteredAgents.map(\.id)) }
    func deselectAll() { selectedLabels.removeAll() }
    func loadAllAgents() async { await refresh(showLoading: true) }
    func refreshStatus() async { await refresh(showLoading: false) }

    private func refresh(showLoading: Bool) async {
        guard !refreshInProgress else { return }
        refreshInProgress = true
        if showLoading { isLoading = true }
        defer { refreshInProgress = false; isLoading = false }
        let gui = AgentDomain.userAgents.launchdDomain
        async let guiResult = CommandRunner.run("/bin/launchctl", ["print", gui])
        async let systemResult = CommandRunner.run("/bin/launchctl", ["print", "system"])
        async let guiDisabled = CommandRunner.run("/bin/launchctl", ["print-disabled", gui])
        async let systemDisabled = CommandRunner.run("/bin/launchctl", ["print-disabled", "system"])
        let results = await (guiResult, systemResult, guiDisabled, systemDisabled)
        let userPath = userAgentsDirectory
        let discovered = await Task.detached {
            var all: [LaunchAgent] = []
            let fm = FileManager.default
            for domain in AgentDomain.allCases where !domain.isRuntime {
                let path = domain == .userAgents ? userPath : domain.path
                let snapshot = domain.requiresAdmin ? results.1 : results.0
                let override = domain.requiresAdmin ? results.3 : results.2
                let services = LaunchctlParser.services(snapshot.output)
                let disabled = LaunchctlParser.disabled(override.output)
                for file in (try? fm.contentsOfDirectory(atPath: path)) ?? [] where file.hasSuffix(".plist") {
                    let fullPath = (path as NSString).appendingPathComponent(file)
                    var contents: [String: Any] = [:]
                    var problem: String?
                    do {
                        let data = try Data(contentsOf: URL(fileURLWithPath: fullPath))
                        guard let dictionary = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                              let label = dictionary["Label"] as? String, !label.isEmpty else {
                            throw PlistWriteError(message: "Missing Label or invalid plist dictionary.")
                        }
                        contents = dictionary
                    } catch { problem = "Cannot read configuration: \(error.localizedDescription)" }
                    let label = contents["Label"] as? String ?? (file as NSString).deletingPathExtension
                    let info = services[label]
                    all.append(LaunchAgent(id: "\(domain.rawValue):\(label)", label: label, domain: domain, plistPath: fullPath,
                        status: !snapshot.success || problem != nil ? .unknown : info == nil ? .unloaded : info?.pid == nil ? .loaded : .running,
                        pid: info?.pid, lastExitStatus: info?.exitStatus, plistContents: contents, disabledOverride: disabled[label],
                        discoveryError: problem ?? (!snapshot.success ? "Domain query failed: \(snapshot.failureDescription)" : nil)))
                }
            }
            for domain in [AgentDomain.userRuntime, .systemRuntime] {
                let snapshot = domain.requiresAdmin ? results.1 : results.0
                let override = domain.requiresAdmin ? results.3 : results.2
                let disabled = LaunchctlParser.disabled(override.output)
                let known = Set(all.filter { $0.domain.launchdDomain == domain.launchdDomain }.map(\.label))
                for (label, info) in LaunchctlParser.services(snapshot.output) where !known.contains(label) {
                    all.append(LaunchAgent(id: "\(domain.rawValue):\(label)", label: label, domain: domain, plistPath: "",
                        status: info.pid == nil ? .loaded : .running, pid: info.pid, lastExitStatus: info.exitStatus,
                        plistContents: [:], disabledOverride: disabled[label]))
                }
            }
            let duplicates = Dictionary(grouping: all.filter(\.hasPlist), by: \.serviceTarget)
                .filter { $0.value.count > 1 }
            for index in all.indices where duplicates[all[index].serviceTarget] != nil {
                all[index].discoveryError = "Multiple plists declare this label in the same launchd domain. Resolve the duplicate before managing it."
            }
            let duplicateIDs = Dictionary(grouping: all, by: \.id).filter { $0.value.count > 1 }
            for index in all.indices where duplicateIDs[all[index].id] != nil {
                all[index].id += "#\((all[index].plistPath as NSString).lastPathComponent)"
            }
            return all
        }.value
        agents = discovered
        healthMonitor?.trackedAgents = agents
        selectedLabels.formIntersection(Set(agents.map(\.id)))
        lastRefreshed = Date()
        let failures = [results.0, results.1, results.2, results.3].filter { !$0.success }
        if !failures.isEmpty { errorMessage = failures.map(\.failureDescription).joined(separator: "\n") }
        historyService?.detectChanges(agents: agents)
        if let history = historyService {
            healthMonitor?.updateCrashLoops(from: history)
            for event in history.recentEvents where Date().timeIntervalSince(event.timestamp) < 10 {
                notificationService?.handleEvent(event, pinnedLabels: Set(pinnedAgents.map(\.id)))
            }
        }
    }

    func available(_ action: ServiceAction, for agent: LaunchAgent) -> Bool {
        guard agent.canControl, !busyServiceIDs.contains(agent.id) else { return false }
        switch action {
        case .load: return agent.hasPlist && agent.status == .unloaded && !agent.isDisabled
        case .unload: return agent.status == .loaded || agent.status == .running
        case .start: return agent.status == .loaded && !agent.isDisabled
        case .stop: return agent.status == .running
        case .restart: return agent.status == .running || agent.status == .loaded
        case .reload: return agent.hasPlist
        case .enable: return agent.isDisabled
        case .disable: return !agent.isDisabled
        }
    }

    @discardableResult
    func perform(_ action: ServiceAction, on original: LaunchAgent) async -> Bool {
        let agent = current(original)
        guard available(action, for: agent) else {
            errorMessage = agent.protectionReason ?? "\(action.rawValue) is unavailable for this service."
            return false
        }
        busyServiceIDs.insert(agent.id)
        defer { busyServiceIDs.remove(agent.id) }
        errorMessage = nil
        notice = nil
        let target = agent.serviceTarget
        if [.stop, .restart, .unload, .disable, .reload].contains(action), let pid = agent.pid {
            historyService?.expectStop(serviceID: agent.id, pid: pid)
        }
        var commands: [[String]]
        switch action {
        case .load: commands = [["bootstrap", agent.domain.launchdDomain, agent.plistPath]]
        case .unload: commands = [["bootout", target]]
        case .start: commands = [["kickstart", target]]
        case .stop: commands = [["kill", "SIGTERM", target]]
        case .restart: commands = [["kickstart", "-k", target]]
        case .enable: commands = [["enable", target]]
        case .disable:
            commands = [["disable", target]]
            if agent.status == .running || agent.status == .loaded { commands.append(["bootout", target]) }
        case .reload:
            commands = []
            if agent.status == .running || agent.status == .loaded { commands.append(["bootout", target]) }
            if !agent.isDisabled { commands.append(["bootstrap", agent.domain.launchdDomain, agent.plistPath]) }
        }
        for arguments in commands {
            let result = await CommandRunner.run("/bin/launchctl", arguments, admin: agent.domain.requiresAdmin)
            if !result.success {
                historyService?.cancelExpectedStop(serviceID: agent.id)
                errorMessage = "\(action.rawValue) \(agent.label): \(result.failureDescription)"
                record(agent, action.rawValue, false, result.failureDescription)
                await refreshStatus()
                return false
            }
        }
        let detail = action == .stop && agent.isKeepAlive ? "SIGTERM sent. KeepAlive may restart the process." :
            action == .enable ? "Enabled for future loading; not automatically started." :
            action == .reload && agent.isDisabled ? "Service remains disabled and unloaded." : "Completed in \(agent.domain.launchdDomain)."
        record(agent, action.rawValue, true, detail)
        notice = "\(action.rawValue): \(agent.label). \(detail)"
        try? await Task.sleep(for: .milliseconds(250))
        await refreshStatus()
        return true
    }

    func bulk(_ action: ServiceAction) async {
        let selected = selectedAgents
        var completed = 0
        var failures: [String] = []
        for agent in selected {
            if available(action, for: agent), await perform(action, on: agent) { completed += 1 }
            else { failures.append("\(agent.label): \(agent.protectionReason ?? errorMessage ?? "Action unavailable")") }
        }
        notice = "\(action.rawValue): \(completed) of \(selected.count) completed."
        if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
        deselectAll()
    }
    func bulkLoad() async { await bulk(.load) }
    func bulkUnload() async { await bulk(.unload) }
    func bulkStart() async { await bulk(.start) }
    func bulkStop() async { await bulk(.stop) }
    @discardableResult func loadAgent(_ agent: LaunchAgent) async -> Bool { await perform(.load, on: agent) }
    @discardableResult func unloadAgent(_ agent: LaunchAgent) async -> Bool { await perform(.unload, on: agent) }
    @discardableResult func startAgent(_ agent: LaunchAgent) async -> Bool { await perform(.start, on: agent) }
    @discardableResult func stopAgent(_ agent: LaunchAgent) async -> Bool { await perform(.stop, on: agent) }
    func reloadAgent(_ agent: LaunchAgent) async { await perform(.reload, on: agent) }
    func requestDeletion(_ agents: [LaunchAgent]) { pendingDeletion = agents }

    @discardableResult
    func deleteAgent(_ original: LaunchAgent) async -> Bool {
        let agent = current(original)
        guard agent.canDelete, !busyServiceIDs.contains(agent.id) else {
            errorMessage = agent.protectionReason ?? "This service has no removable plist."
            return false
        }
        busyServiceIDs.insert(agent.id)
        defer { busyServiceIDs.remove(agent.id); refreshDeletedServices() }
        let fm = FileManager.default
        let id = UUID()
        let directory = recoveryDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        do {
            let source = URL(fileURLWithPath: agent.plistPath)
            try validateDestination(source, domain: agent.domain)
            guard (try source.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
                throw PlistWriteError(message: "Refusing to delete a symlink.")
            }
            let labelIsValid = (try? PlistWriteService.validateLabel(agent.label)) != nil
            let runtime = labelIsValid ? await CommandRunner.run("/bin/launchctl", ["print", agent.serviceTarget])
                : CommandResult(status: 113, output: "", error: "")
            if !runtime.success && runtime.status != 113 {
                throw PlistWriteError(message: "Cannot confirm launchd state: \(runtime.failureDescription)")
            }
            let registeredPath = runtime.output.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { $0.hasPrefix("path = ") }.map { String($0.dropFirst(7)) }
            let ownsRegistration = registeredPath.map {
                URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath() == source.standardizedFileURL.resolvingSymlinksInPath()
            } ?? false
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let backup = directory.appendingPathComponent("service.plist")
            try fm.copyItem(at: source, to: backup)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            let entry = DeletedService(id: id, label: agent.label, domain: agent.domain, originalPath: agent.plistPath,
                backupPath: backup.path, deletedAt: Date(), wasLoaded: ownsRegistration)
            try JSONEncoder().encode(entry).write(to: directory.appendingPathComponent("metadata.json"), options: .atomic)
            if ownsRegistration {
                if let pid = agent.pid { historyService?.expectStop(serviceID: agent.id, pid: pid) }
                let result = await CommandRunner.run("/bin/launchctl", ["bootout", agent.serviceTarget], admin: agent.domain.requiresAdmin)
                guard result.success else { throw PlistWriteError(message: result.failureDescription) }
            }
            if agent.domain == .userAgents { try fm.removeItem(at: source) }
            else {
                let result = await CommandRunner.run("/bin/rm", [agent.plistPath], admin: true)
                guard result.success else { throw PlistWriteError(message: result.failureDescription) }
            }
            pinnedLabels.remove(agent.id); selectedLabels.remove(agent.id)
            record(agent, "Delete", true, "Configuration backed up to \(backup.path).")
            notice = "Deleted \(agent.label). Restore it from Deleted Services."
            await loadAllAgents()
            return true
        } catch {
            errorMessage = "Delete \(agent.label): \(error.localizedDescription). Any created backup has been retained."
            historyService?.cancelExpectedStop(serviceID: agent.id)
            record(agent, "Delete", false, error.localizedDescription)
            await loadAllAgents()
            return false
        }
    }

    func deletePending() async {
        let selected = pendingDeletion
        pendingDeletion = []
        var failures: [String] = []
        for agent in selected {
            if !(await deleteAgent(agent)) { failures.append(errorMessage ?? agent.label) }
        }
        if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
    }
    func refreshDeletedServices() {
        deletedServices = ((try? FileManager.default.contentsOfDirectory(at: recoveryDirectory, includingPropertiesForKeys: nil)) ?? [])
            .compactMap { url in
                guard let data = try? Data(contentsOf: url.appendingPathComponent("metadata.json")) else { return nil }
                return try? JSONDecoder().decode(DeletedService.self, from: data)
            }.sorted { $0.deletedAt > $1.deletedAt }
    }

    func validateDestination(_ url: URL, domain: AgentDomain) throws {
        let expected = URL(fileURLWithPath: domain == .userAgents ? userAgentsDirectory : domain.path)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard domain.isEditable, !domain.isSystem, url.pathExtension == "plist",
              url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath() == expected else {
            throw PlistWriteError(message: "Refusing a file outside its launchd folder.")
        }
    }
    @discardableResult
    func restore(_ entry: DeletedService) async -> Bool {
        do {
            guard !entry.label.hasPrefix("com.apple.") else { throw PlistWriteError(message: "Protected service.") }
            let destination = URL(fileURLWithPath: entry.originalPath)
            try validateDestination(destination, domain: entry.domain)
            let backup = recoveryDirectory.appendingPathComponent(entry.id.uuidString).appendingPathComponent("service.plist")
            guard URL(fileURLWithPath: entry.backupPath).standardizedFileURL == backup.standardizedFileURL,
                  (try backup.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
                throw PlistWriteError(message: "Invalid recovery source.")
            }
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw PlistWriteError(message: "Original path is occupied; it was not overwritten.")
            }
            let data = try Data(contentsOf: backup)
            if let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
               let label = dict["Label"] as? String, !label.isEmpty, label != entry.label {
                throw PlistWriteError(message: "Backup service identity does not match the recovery record.")
            }
            if entry.domain == .userAgents {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: destination, options: .withoutOverwriting)
            }
            else {
                let result = await CommandRunner.installNewPlist(from: backup.path, to: entry.originalPath)
                guard result.success else { throw PlistWriteError(message: result.failureDescription) }
            }
            let metadata = backup.deletingLastPathComponent().appendingPathComponent("metadata.json")
            try FileManager.default.moveItem(at: metadata, to: metadata.deletingLastPathComponent().appendingPathComponent("restored.json"))
            refreshDeletedServices()
            notice = "Restored \(entry.label). Use Load when ready; it was not started."
            operations.insert(ServiceOperation(serviceID: "\(entry.domain.rawValue):\(entry.label)", label: entry.label,
                action: "Restore", success: true, detail: "Restored without loading."), at: 0)
            saveOperations()
            await loadAllAgents()
            return true
        } catch { errorMessage = "Restore \(entry.label): \(error.localizedDescription)"; return false }
    }

    func record(_ agent: LaunchAgent, _ action: String, _ success: Bool, _ detail: String) {
        operations.insert(ServiceOperation(serviceID: agent.id, label: agent.label, action: action, success: success, detail: detail), at: 0)
        saveOperations()
    }
    private func saveOperations() {
        operations = Array(operations.prefix(500))
        do {
            try FileManager.default.createDirectory(at: operationsURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(operations).write(to: operationsURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: operationsURL.path)
        } catch { errorMessage = "Could not save operation history: \(error.localizedDescription)" }
    }
    func revealInFinder(_ agent: LaunchAgent) {
        guard agent.hasPlist else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: agent.plistPath)])
    }
    func openInEditor(_ agent: LaunchAgent) {
        guard agent.hasPlist else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: agent.plistPath))
    }
    func reloadPlistContents(for agent: LaunchAgent) async { await loadAllAgents() }
    func createAgent(from formData: AgentFormData, andLoad: Bool) async throws {
        let errors = formData.validate()
        guard errors.isEmpty else { throw PlistWriteError(message: errors.joined(separator: "\n")) }
        var dict = formData.toPlistDictionary()
        try PlistWriteService.validate(dict)
        let logDirectory = NSHomeDirectory() + "/Library/Logs/Ignition"
        for (key, suffix) in [("StandardOutPath", "stdout"), ("StandardErrorPath", "stderr")] {
            if dict[key] as? String == logDirectory + "/agent.\(suffix).log" {
                try FileManager.default.createDirectory(atPath: logDirectory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                dict[key] = logDirectory + "/\(formData.label).\(suffix).log"
            }
        }
        guard [.userAgents, .globalAgents, .globalDaemons].contains(formData.domain),
              !formData.label.hasPrefix("com.apple.") else { throw PlistWriteError(message: "Choose a writable launchd domain and a non-system label.") }
        let folder = formData.domain == .userAgents ? userAgentsDirectory : formData.domain.path
        let path = (folder as NSString).appendingPathComponent("\(formData.label).plist")
        if formData.domain == .userAgents { try PlistWriteService.create(dict, at: path) }
        else {
            let fm = FileManager.default
            guard !fm.fileExists(atPath: path) else { throw PlistWriteError(message: "File already exists.") }
            let temp = fm.temporaryDirectory.appendingPathComponent("Ignition-create-" + UUID().uuidString + ".plist")
            let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
            try data.write(to: temp)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
            defer { try? fm.removeItem(at: temp) }
            let result = await CommandRunner.installNewPlist(from: temp.path, to: path)
            guard result.success else { throw PlistWriteError(message: result.failureDescription) }
            let installed = try Data(contentsOf: URL(fileURLWithPath: path))
            guard installed == data else { throw PlistWriteError(message: "Destination changed during creation; existing file was retained.") }
        }
        await loadAllAgents()
        if let created = agents.first(where: { $0.label == formData.label && $0.domain == formData.domain }) {
            record(created, "Create", true, "Configuration created in \(formData.domain.rawValue).")
            newlyCreatedID = created.id
            selectedDomain = created.domain
            statusFilter = .all
            tagFilter = .all
            includeAllDomains = false
            notice = "Created \(created.label)."
        }
        if andLoad, let agent = agents.first(where: { $0.label == formData.label && $0.domain == formData.domain }),
           !(await loadAgent(agent)) { throw PlistWriteError(message: errorMessage ?? "Created, but loading failed.") }
    }
}
