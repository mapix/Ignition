import Foundation

enum ServiceAction: String, CaseIterable, Identifiable, Sendable {
    case load = "Load", unload = "Unload", start = "Start", stop = "Stop"
    case restart = "Restart", reload = "Reload Configuration"
    case enable = "Enable", disable = "Disable"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .load: return "arrow.down.circle"
        case .unload: return "arrow.up.circle"
        case .start: return "play"
        case .stop: return "stop"
        case .restart: return "arrow.clockwise"
        case .reload: return "arrow.triangle.2.circlepath"
        case .enable: return "checkmark.circle"
        case .disable: return "nosign"
        }
    }
}

enum ServiceFilter: String, CaseIterable, Identifiable {
    case all = "All", running = "Running", loaded = "Loaded", unloaded = "Unloaded"
    case disabled = "Disabled", problems = "Problems", pinned = "Pinned"
    var id: String { rawValue }
}

struct ServiceOperation: Identifiable, Codable, Sendable {
    var id = UUID()
    var timestamp = Date()
    let serviceID: String
    let label: String
    let action: String
    let success: Bool
    let detail: String
}

struct DeletedService: Identifiable, Codable, Sendable {
    let id: UUID
    let label: String
    let domain: AgentDomain
    let originalPath: String
    let backupPath: String
    let deletedAt: Date
    let wasLoaded: Bool
}

struct RuntimeService: Sendable {
    let pid: Int?
    let exitStatus: Int?
}

enum LaunchctlParser {
    static func services(_ text: String) -> [String: RuntimeService] {
        var result: [String: RuntimeService] = [:]
        var inServices = false
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "services = {" { inServices = true; continue }
            if inServices && trimmed == "}" { break }
            guard inServices else { continue }
            let columns = trimmed.split(whereSeparator: \.isWhitespace)
            guard columns.count >= 3, let pid = Int(columns[0]) else { continue }
            let label = columns.dropFirst(2).joined(separator: " ")
            result[label] = RuntimeService(pid: pid > 0 ? pid : nil, exitStatus: Int(columns[1]))
        }
        return result
    }

    static func disabled(_ text: String) -> [String: Bool] {
        var result: [String: Bool] = [:]
        for line in text.components(separatedBy: .newlines) {
            let parts = line.components(separatedBy: " => ")
            guard parts.count == 2 else { continue }
            let label = parts[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let state = parts[1].trimmingCharacters(in: .whitespaces)
            if state == "disabled" || state == "enabled" { result[label] = state == "disabled" }
        }
        return result
    }
}
