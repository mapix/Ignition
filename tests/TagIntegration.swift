import Foundation
import Combine
import AppKit

@main
struct TagIntegration {
    @MainActor static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("Ignition-tags-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let suite = "org.ignition.tags." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = LaunchAgentManager(storageDirectory: root, defaults: defaults, automaticRefresh: false)
        let user = LaunchAgent(id: "User Agents:org.example.demo", label: "org.example.demo", domain: .userAgents,
                               plistPath: "/fixture/user.plist", status: .loaded, plistContents: ["Program": "/bin/echo"])
        let system = LaunchAgent(id: "Global Daemons:org.example.demo", label: "org.example.demo", domain: .globalDaemons,
                                 plistPath: "/fixture/system.plist", status: .running, pid: 1234, plistContents: ["Program": "/bin/echo"])
        let apple = LaunchAgent(id: "System Daemons:com.apple.fixture", label: "com.apple.fixture", domain: .systemDaemons,
                                plistPath: "/System/fixture.plist", status: .loaded, plistContents: [:])
        let runtime = LaunchAgent(id: "Other User Services:org.example.demo", label: "org.example.demo", domain: .userRuntime,
                                  plistPath: "", status: .loaded, plistContents: [:])
        manager.agents = [user, system, apple]
        var checks = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw PlistWriteError(message: "FAIL: \(message)") }
            checks += 1
            print("PASS: \(message)")
        }
        let tag = try manager.createTag(name: "  Development  ", colorIndex: 2, assigningTo: [user])
        try check(tag.name == "Development" && manager.tags(for: user).count == 1, "Create and assign tag")
        try check(manager.tags(for: system).isEmpty, "Same label in another launchd domain has separate tags")
        try check(manager.tags(for: runtime).first?.id == tag.id, "Tags follow runtime service identity")
        let second = try manager.createTag(name: "数据库", colorIndex: 5, assigningTo: [user, system])
        try check(manager.tags(for: user).count == 2 && manager.tags(for: system).count == 1, "Multiple tags and batch assignment")
        try manager.setTag(second, for: [user], enabled: false)
        try check(manager.tags(for: system).count == 1 && manager.tags(for: user).first?.id == tag.id, "Removing a tag preserves other assignments")
        try manager.setTag(tag, for: [apple], enabled: true)
        try check(!apple.canControl && manager.tags(for: apple).count == 1, "Read-only system services can be tagged without control permissions")
        manager.includeAllDomains = true
        manager.tagFilter = .tag(second.id)
        try check(manager.filteredAgents.map(\.id) == [system.id], "Sidebar tag filter spans domains")
        manager.tagFilter = .untagged
        try check(manager.filteredAgents.isEmpty, "Untagged filter excludes all tagged services")
        try manager.setTag(tag, for: [apple], enabled: false)
        try check(manager.filteredAgents.map(\.id) == [apple.id], "Untagged filter updates after tag removal")
        manager.tagFilter = .tag(tag.id)
        try manager.updateTag(tag, name: "Work", colorIndex: 4)
        try check(manager.inventoryTitle == "Work" && manager.tags(for: user).first?.id == tag.id, "Rename keeps associations and active filter")
        var rejected = false
        do { _ = try manager.createTag(name: "work") } catch { rejected = true }
        try check(rejected, "Duplicate names are rejected case-insensitively")
        rejected = false
        do { _ = try manager.createTag(name: "bad\nname") } catch { rejected = true }
        try check(rejected, "Invalid names are rejected")
        let reloaded = LaunchAgentManager(storageDirectory: root, defaults: defaults, automaticRefresh: false)
        reloaded.agents = manager.agents
        try check(reloaded.tags(for: user).first?.name == "Work" && reloaded.tags(for: system).first?.name == "数据库",
                  "Tag names, colors and assignments survive restart")
        let permissions = try fm.attributesOfItem(atPath: manager.tagsURL.path)[.posixPermissions] as? NSNumber
        try check(permissions?.intValue == 0o600, "Tag storage is private")
        try manager.deleteTag(manager.sortedTags.first { $0.id == tag.id }!)
        try check(manager.tagFilter == .all && manager.tags(for: user).isEmpty && manager.tags(for: system).count == 1,
                  "Deleting active tag clears filter and preserves unrelated tags")
        try check(manager.agents == [user, system, apple], "Tag operations leave service configurations and status unchanged")
        let corrupt = root.appendingPathComponent("corrupt")
        try fm.createDirectory(at: corrupt, withIntermediateDirectories: true)
        let corruptURL = corrupt.appendingPathComponent("tags.json")
        let invalidData = Data("not json".utf8)
        try invalidData.write(to: corruptURL)
        let invalid = LaunchAgentManager(storageDirectory: corrupt, defaults: defaults, automaticRefresh: false)
        rejected = false
        do { _ = try invalid.createTag(name: "replacement") } catch { rejected = true }
        let retained = try Data(contentsOf: corruptURL)
        try check(rejected && retained == invalidData, "Unreadable tag storage is retained without overwriting")
        print("COMPLETED: \(checks) tag integration checks")
    }
}
