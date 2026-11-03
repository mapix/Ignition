import Foundation

struct ServiceTag: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var name: String
    var colorIndex: Int
}

struct ServiceTagState: Codable, Sendable {
    var tags: [ServiceTag] = []
    var assignments: [String: Set<String>] = [:]
}

enum ServiceTagFilter: Equatable {
    case all
    case untagged
    case tag(String)
}
