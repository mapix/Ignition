import Foundation

enum AgentDomain: String, CaseIterable, Identifiable, Codable, Sendable {
    case userAgents = "User Agents"
    case globalAgents = "Global Agents"
    case globalDaemons = "Global Daemons"
    case systemAgents = "System Agents"
    case systemDaemons = "System Daemons"
    case userRuntime = "Other User Services"
    case systemRuntime = "Other System Services"

    var id: String { rawValue }

    var path: String {
        switch self {
        case .userAgents: return "\(NSHomeDirectory())/Library/LaunchAgents"
        case .globalAgents: return "/Library/LaunchAgents"
        case .globalDaemons: return "/Library/LaunchDaemons"
        case .systemAgents: return "/System/Library/LaunchAgents"
        case .systemDaemons: return "/System/Library/LaunchDaemons"
        case .userRuntime, .systemRuntime: return ""
        }
    }

    var icon: String {
        switch self {
        case .userAgents: return "person.fill"
        case .globalAgents: return "person.2.fill"
        case .globalDaemons: return "gearshape.2.fill"
        case .systemAgents: return "apple.logo"
        case .systemDaemons: return "cpu"
        case .userRuntime: return "app.connected.to.app.below.fill"
        case .systemRuntime: return "server.rack"
        }
    }

    var isEditable: Bool {
        switch self {
        case .userAgents: return true
        case .globalAgents, .globalDaemons: return true
        case .systemAgents, .systemDaemons, .userRuntime, .systemRuntime: return false
        }
    }

    var launchdDomain: String {
        switch self {
        case .globalDaemons, .systemDaemons, .systemRuntime: return "system"
        default: return "gui/\(getuid())"
        }
    }

    var requiresAdmin: Bool { launchdDomain == "system" }
    var isSystem: Bool { self == .systemAgents || self == .systemDaemons }
    var isRuntime: Bool { self == .userRuntime || self == .systemRuntime }
}

enum AgentStatus: String, Sendable {
    case loaded = "Loaded"
    case unloaded = "Unloaded"
    case running = "Running"
    case error = "Error"
    case unknown = "Unknown"

    var color: String {
        switch self {
        case .running: return "green"
        case .loaded: return "blue"
        case .unloaded: return "gray"
        case .error: return "red"
        case .unknown: return "orange"
        }
    }

    var icon: String {
        switch self {
        case .running: return "circle.fill"
        case .loaded: return "circle.lefthalf.filled"
        case .unloaded: return "circle"
        case .error: return "exclamationmark.circle.fill"
        case .unknown: return "questionmark.circle"
        }
    }
}

struct LaunchAgent: Identifiable, Hashable, @unchecked Sendable {
    var id: String
    let label: String
    let domain: AgentDomain
    let plistPath: String
    var status: AgentStatus
    var pid: Int?
    var lastExitStatus: Int?
    var plistContents: [String: Any]
    var disabledOverride: Bool? = nil
    var discoveryError: String? = nil

    var serviceTarget: String { "\(domain.launchdDomain)/\(label)" }
    var hasPlist: Bool { !plistPath.isEmpty }
    var canControl: Bool {
        !domain.isSystem && !label.hasPrefix("com.apple.") && discoveryError == nil
            && !label.contains("/") && !label.contains("\\")
            && label.rangeOfCharacter(from: .controlCharacters) == nil
    }
    var canDelete: Bool { hasPlist && domain.isEditable && !domain.isSystem && !label.hasPrefix("com.apple.") }
    var protectionReason: String? {
        if domain.isSystem || label.hasPrefix("com.apple.") { return "Apple system service — management is read only." }
        if let discoveryError { return discoveryError }
        return nil
    }

    var program: String? {
        if let prog = plistContents["Program"] as? String {
            return prog
        }
        if let args = plistContents["ProgramArguments"] as? [String], let first = args.first {
            return first
        }
        return nil
    }

    var programArguments: [String]? {
        plistContents["ProgramArguments"] as? [String]
    }

    var isKeepAlive: Bool {
        if let keepAlive = plistContents["KeepAlive"] as? Bool {
            return keepAlive
        }
        if plistContents["KeepAlive"] is [String: Any] {
            return true
        }
        return false
    }

    var runAtLoad: Bool {
        plistContents["RunAtLoad"] as? Bool ?? false
    }

    var startInterval: Int? {
        plistContents["StartInterval"] as? Int
    }

    var watchPaths: [String]? {
        plistContents["WatchPaths"] as? [String]
    }

    var standardOutPath: String? {
        plistContents["StandardOutPath"] as? String
    }

    var standardErrorPath: String? {
        plistContents["StandardErrorPath"] as? String
    }

    var isDisabled: Bool {
        disabledOverride ?? (plistContents["Disabled"] as? Bool ?? false)
    }

    var displayName: String {
        // Try to make a friendly name from the label
        let parts = label.split(separator: ".")
        if parts.count >= 3 {
            return String(parts.last!)
        }
        return label
    }

    static func == (lhs: LaunchAgent, rhs: LaunchAgent) -> Bool {
        lhs.id == rhs.id && lhs.status == rhs.status && lhs.pid == rhs.pid
            && lhs.lastExitStatus == rhs.lastExitStatus && lhs.isDisabled == rhs.isDisabled
            && lhs.discoveryError == rhs.discoveryError
            && NSDictionary(dictionary: lhs.plistContents).isEqual(to: rhs.plistContents)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
