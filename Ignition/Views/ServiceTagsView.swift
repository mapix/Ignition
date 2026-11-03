import SwiftUI

extension ServiceTag {
    var color: Color {
        [Color.blue, .green, .orange, .purple, .pink, .teal, .gray, .brown][max(0, min(7, colorIndex))]
    }
}

struct ServiceTagPill: View {
    let tag: ServiceTag
    var body: some View {
        Text(tag.name).font(.caption2).lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .foregroundStyle(tag.color)
            .background(tag.color.opacity(0.13), in: Capsule())
            .help(tag.name)
    }
}

struct ServiceTagsSection: View {
    @EnvironmentObject var manager: LaunchAgentManager
    let agent: LaunchAgent
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Tags", systemImage: "tag").font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                Button("Edit Tags…") { manager.taggingAgents = [agent] }.font(.caption).buttonStyle(.bordered)
            }
            let tags = manager.tags(for: agent)
            if tags.isEmpty { Text("No tags").font(.caption).foregroundStyle(.tertiary) }
            else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 8)], alignment: .leading) {
                    ForEach(tags) { tag in ServiceTagPill(tag: tag) }
                }
            }
        }
    }
}

struct TagEditorView: View {
    @EnvironmentObject var manager: LaunchAgentManager
    @Environment(\.dismiss) private var dismiss
    let agents: [LaunchAgent]
    @State private var newName = ""
    @State private var newColor = 0
    @State private var error: String?
    @State private var editingTag: ServiceTag?
    @State private var deletingTag: ServiceTag?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(agents.isEmpty ? "Manage Tags" : "Service Tags").font(.title2.bold())
                Spacer()
                Button("Done") { manager.taggingAgents = []; dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(agents.isEmpty ? "Create, rename and organize tags. Select a tag in the sidebar to see its services." :
                 agents.count == 1 ? agents[0].label : "\(agents.count) selected services")
                .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            List(manager.sortedTags) { tag in
                HStack(spacing: 12) {
                    if !agents.isEmpty {
                        let selected = agents.filter { manager.tags(for: $0).contains(where: { $0.id == tag.id }) }.count
                        Button {
                            apply { try manager.setTag(tag, for: agents, enabled: selected < agents.count) }
                        } label: {
                            Image(systemName: selected == agents.count ? "checkmark.square.fill" : selected == 0 ? "square" : "minus.square.fill")
                                .foregroundStyle(tag.color)
                        }.buttonStyle(.plain).help("Toggle \(tag.name) for selected services")
                    }
                    ServiceTagPill(tag: tag)
                    Spacer()
                    Text("\(manager.serviceCount(for: tag)) services").font(.caption).foregroundStyle(.secondary)
                    Button("Rename") { editingTag = tag }
                    Button("Delete", role: .destructive) { deletingTag = tag }
                }.buttonStyle(.borderless).padding(.vertical, 3)
                .contextMenu {
                    if !agents.isEmpty {
                        Button("Apply to Selected") { apply { try manager.setTag(tag, for: agents, enabled: true) } }
                        Button("Remove from Selected") { apply { try manager.setTag(tag, for: agents, enabled: false) } }
                    }
                }
            }
            .overlay { if manager.sortedTags.isEmpty { Text("Create your first tag below.").foregroundStyle(.secondary) } }
            GroupBox("New Tag") {
                HStack {
                    TextField("Tag name", text: $newName).textFieldStyle(.roundedBorder)
                        .onSubmit { create() }
                    TagColorPicker(selection: $newColor)
                    Button(agents.isEmpty ? "Create" : "Create & Apply") { create() }
                        .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.padding(6)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            if !agents.isEmpty {
                Text("Tags are stored locally and can be applied to any service, including read-only system services.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(24).frame(width: 660, height: 520)
        .sheet(item: $editingTag) { tag in
            RenameTagView(tag: tag).environmentObject(manager)
        }
        .confirmationDialog("Delete tag “\(deletingTag?.name ?? "")”?",
                            isPresented: Binding(get: { deletingTag != nil }, set: { if !$0 { deletingTag = nil } }),
                            titleVisibility: .visible) {
            if let tag = deletingTag {
                Button("Delete Tag", role: .destructive) { apply { try manager.deleteTag(tag) } }
            }
            Button("Cancel", role: .cancel) { deletingTag = nil }
        } message: { Text("This removes the tag from every service. Service files and launchd registrations are retained.") }
    }
    private func apply(_ operation: () throws -> Void) {
        do { try operation(); error = nil } catch { self.error = error.localizedDescription }
    }
    private func create() {
        apply {
            try manager.createTag(name: newName, colorIndex: newColor, assigningTo: agents)
            newName = ""
        }
    }
}

struct TagColorPicker: View {
    @Binding var selection: Int
    var body: some View {
        Picker("Color", selection: $selection) {
            ForEach(Array(["Blue", "Green", "Orange", "Purple", "Pink", "Teal", "Gray", "Brown"].enumerated()), id: \.offset) { index, name in
                Text(name).tag(index)
            }
        }.labelsHidden().frame(width: 100)
    }
}

struct RenameTagView: View {
    @EnvironmentObject var manager: LaunchAgentManager
    @Environment(\.dismiss) private var dismiss
    let tag: ServiceTag
    @State private var name: String
    @State private var colorIndex: Int
    @State private var error: String?
    init(tag: ServiceTag) {
        self.tag = tag
        _name = State(initialValue: tag.name)
        _colorIndex = State(initialValue: tag.colorIndex)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Tag").font(.title2.bold())
            TextField("Tag name", text: $name).textFieldStyle(.roundedBorder)
            TagColorPicker(selection: $colorIndex)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    do { try manager.updateTag(tag, name: name, colorIndex: colorIndex); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 380)
    }
}
