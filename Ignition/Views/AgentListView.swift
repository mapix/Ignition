import SwiftUI
import AppKit

struct AgentListView: View {
    @EnvironmentObject var manager: LaunchAgentManager
    @Binding var selectedAgent: LaunchAgent?
    @State private var showingCreateSheet = false
    @State private var bulkMode = false
    private var selection: Binding<String?> {
        Binding(get: { selectedAgent?.id },
                set: { id in selectedAgent = manager.agents.first { $0.id == id } })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Status", selection: $manager.statusFilter) {
                    ForEach(ServiceFilter.allCases) { filter in Text(filter.rawValue).tag(filter) }
                }.frame(maxWidth: 170)
                Toggle("All domains", isOn: $manager.includeAllDomains).toggleStyle(.checkbox).font(.caption)
                    .disabled(manager.tagFilter != .all)
                Spacer()
            }.padding(10)
            if let refreshed = manager.lastRefreshed {
                Text("\(manager.filteredAgents.count) services · refreshed \(refreshed.formatted(date: .omitted, time: .standard))")
                    .font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12)
            }
            // Bulk operations bar
            if bulkMode {
                BulkOperationsBar()
            }

            Group {
                if manager.isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.large)
                        Text("Loading agents...")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
                } else if manager.filteredAgents.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 40))
                            .foregroundStyle(.tertiary)
                        Text("No agents found")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
                } else {
                    List(manager.filteredAgents, selection: selection) { agent in
                        HStack(spacing: 0) {
                            if bulkMode {
                                Button {
                                    manager.toggleSelection(agent)
                                } label: {
                                    Image(systemName: manager.isSelected(agent) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(manager.isSelected(agent) ? Color.accentColor : .secondary)
                                        .font(.system(size: 16))
                                }
                                .buttonStyle(.plain)
                                .padding(.trailing, 8)
                            }
                            AgentRowView(agent: agent)
                        }
                        .tag(agent.id)
                        .contextMenu {
                            AgentContextMenu(agent: agent)
                        }
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                    .animation(.smooth, value: manager.filteredAgents.map(\.id))
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: manager.isLoading)
        .navigationTitle(manager.inventoryTitle)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    withAnimation { bulkMode.toggle() }
                    if !bulkMode { manager.deselectAll() }
                } label: {
                    Image(systemName: bulkMode ? "checkmark.circle.fill" : "checkmark.circle")
                }
                .help(bulkMode ? "Exit bulk mode" : "Bulk operations")

                StatusSummary()
            }
        }
        .sheet(isPresented: $showingCreateSheet) {
            CreateAgentView()
                .environmentObject(manager)
        }
    }
}

struct BulkOperationsBar: View {
    @EnvironmentObject var manager: LaunchAgentManager
    @State private var isBusy = false

    var body: some View {
        HStack(spacing: 10) {
            Text("\(manager.selectedLabels.count) selected")
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(.secondary)

            Button("All") { manager.selectAll() }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)

            Button("None") { manager.deselectAll() }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)

            Spacer()

            if isBusy {
                ProgressView()
                    .controlSize(.small)
            } else {
                Menu("Actions") {
                    Button("Edit Tags…") { manager.taggingAgents = manager.selectedAgents }
                    Divider()
                    ForEach(ServiceAction.allCases) { action in
                        Button(action.rawValue) {
                            isBusy = true
                            Task { await manager.bulk(action); isBusy = false }
                        }
                    }
                    Divider()
                    Button("Delete Services…", role: .destructive) { manager.requestDeletion(manager.selectedAgents) }
                        .disabled(manager.selectedAgents.contains { !$0.canDelete })
                }
                .font(.system(.caption, weight: .medium))
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(manager.selectedLabels.isEmpty)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)

        Divider()
    }
}

struct StatusSummary: View {
    @EnvironmentObject var manager: LaunchAgentManager

    var body: some View {
        let agents = manager.filteredAgents
        let running = agents.filter { $0.status == .running }.count
        let loaded = agents.filter { $0.status == .loaded }.count

        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
                Text("\(running)")
                    .font(.caption)
                    .monospacedDigit()
            }
            .help("\(running) running")

            HStack(spacing: 4) {
                Circle()
                    .fill(.blue)
                    .frame(width: 8, height: 8)
                Text("\(loaded)")
                    .font(.caption)
                    .monospacedDigit()
            }
            .help("\(loaded) loaded")

            HStack(spacing: 4) {
                Circle()
                    .fill(.gray.opacity(0.5))
                    .frame(width: 8, height: 8)
                Text("\(agents.count - running - loaded)")
                    .font(.caption)
                    .monospacedDigit()
            }
            .help("\(agents.count - running - loaded) unloaded")
        }
    }
}

struct AgentContextMenu: View {
    @EnvironmentObject var manager: LaunchAgentManager
    @Environment(\.openWindow) private var openWindow
    let agent: LaunchAgent

    var body: some View {
        ForEach(ServiceAction.allCases) { action in
            Button(action.rawValue) { Task { await manager.perform(action, on: agent) } }
                .disabled(!manager.available(action, for: agent))
        }
        Button("Process Details…") { openWindow(id: "main"); manager.processAgent = agent }.disabled(agent.pid == nil)
        Button("Diagnostics…") { openWindow(id: "main"); manager.diagnosticsAgent = agent }
        Button("Edit Tags…") { openWindow(id: "main"); manager.taggingAgents = [agent] }
        Divider()

        Button(manager.isPinned(agent) ? "Unpin from Menu Bar" : "Pin to Menu Bar") {
            manager.togglePin(agent)
        }

        Divider()

        Button("Reveal in Finder") {
            manager.revealInFinder(agent)
        }.disabled(!agent.hasPlist)

        Button("Open Plist") {
            manager.openInEditor(agent)
        }.disabled(!agent.hasPlist)

        Button("Export Plist...") {
            ImportExportService.exportSingleAgent(agent)
        }.disabled(!agent.hasPlist)

        Divider()
        Button("Delete Service…", role: .destructive) { openWindow(id: "main"); manager.requestDeletion([agent]) }
            .disabled(!agent.canDelete || manager.busyServiceIDs.contains(agent.id))
        Divider()

        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(agent.label, forType: .string)
        } label: {
            Text("Copy Label")
        }

        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(agent.plistPath, forType: .string)
        } label: {
            Text("Copy Path")
        }
    }
}
