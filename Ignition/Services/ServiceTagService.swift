import Foundation

extension LaunchAgentManager {
    var sortedTags: [ServiceTag] { tagState.tags.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    var inventoryTitle: String {
        switch tagFilter {
        case .all: return includeAllDomains ? "All Services" : selectedDomain?.rawValue ?? "Services"
        case .untagged: return "Untagged Services"
        case .tag(let id): return tagState.tags.first { $0.id == id }?.name ?? "Tagged Services"
        }
    }
    func tags(for agent: LaunchAgent) -> [ServiceTag] {
        let ids = tagState.assignments[agent.serviceTarget, default: []]
        return sortedTags.filter { ids.contains($0.id) }
    }
    func serviceCount(for tag: ServiceTag) -> Int {
        Set(agents.filter { tagState.assignments[$0.serviceTarget, default: []].contains(tag.id) }.map(\.serviceTarget)).count
    }
    var untaggedServiceCount: Int { Set(agents.filter { tags(for: $0).isEmpty }.map(\.serviceTarget)).count }

    private func validatedTagName(_ value: String, excluding id: String? = nil) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40, name.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw PlistWriteError(message: "Tag names must contain 1–40 characters without control characters.")
        }
        guard !tagState.tags.contains(where: { $0.id != id && $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) else {
            throw PlistWriteError(message: "A tag with this name already exists.")
        }
        return name
    }
    private func saveTags(_ state: ServiceTagState) throws {
        if let tagStorageError { throw PlistWriteError(message: tagStorageError + " The existing file has been retained.") }
        try FileManager.default.createDirectory(at: tagsURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(state).write(to: tagsURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tagsURL.path)
        tagState = state
    }
    @discardableResult
    func createTag(name: String, colorIndex: Int = 0, assigningTo agents: [LaunchAgent] = []) throws -> ServiceTag {
        let tag = ServiceTag(id: UUID().uuidString, name: try validatedTagName(name), colorIndex: max(0, min(7, colorIndex)))
        var state = tagState
        state.tags.append(tag)
        for agent in agents { state.assignments[agent.serviceTarget, default: []].insert(tag.id) }
        try saveTags(state)
        return tag
    }
    func updateTag(_ tag: ServiceTag, name: String, colorIndex: Int) throws {
        guard let index = tagState.tags.firstIndex(where: { $0.id == tag.id }) else { throw PlistWriteError(message: "Tag no longer exists.") }
        var state = tagState
        state.tags[index].name = try validatedTagName(name, excluding: tag.id)
        state.tags[index].colorIndex = max(0, min(7, colorIndex))
        try saveTags(state)
    }
    func setTag(_ tag: ServiceTag, for agents: [LaunchAgent], enabled: Bool) throws {
        guard tagState.tags.contains(where: { $0.id == tag.id }) else { throw PlistWriteError(message: "Tag no longer exists.") }
        var state = tagState
        for agent in agents {
            if enabled { state.assignments[agent.serviceTarget, default: []].insert(tag.id) }
            else {
                state.assignments[agent.serviceTarget]?.remove(tag.id)
                if state.assignments[agent.serviceTarget]?.isEmpty == true { state.assignments.removeValue(forKey: agent.serviceTarget) }
            }
        }
        try saveTags(state)
    }
    func deleteTag(_ tag: ServiceTag) throws {
        var state = tagState
        state.tags.removeAll { $0.id == tag.id }
        for key in Array(state.assignments.keys) {
            state.assignments[key]?.remove(tag.id)
            if state.assignments[key]?.isEmpty == true { state.assignments.removeValue(forKey: key) }
        }
        try saveTags(state)
        if tagFilter == .tag(tag.id) { tagFilter = .all }
    }
}
