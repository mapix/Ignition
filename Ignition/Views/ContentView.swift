import SwiftUI

struct ContentView: View {
    @EnvironmentObject var manager: LaunchAgentManager
    @EnvironmentObject var historyService: ActivityHistoryService
    @EnvironmentObject var healthMonitor: HealthMonitorService
    @EnvironmentObject var notificationService: NotificationService
    @State private var selectedAgent: LaunchAgent?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showingCreateSheet = false
    @State private var showingImportAlert = false
    @State private var importMessage = ""
    @State private var showingRecovery = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selectedAgent: $selectedAgent)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } content: {
            if manager.selectedDomain != nil {
                AgentListView(selectedAgent: $selectedAgent)
                    .navigationSplitViewColumnWidth(min: 350, ideal: 450, max: 600)
            } else {
                // Health dashboard takes full width
                Text("")
                    .navigationSplitViewColumnWidth(min: 0, ideal: 0, max: 0)
            }
        } detail: {
            Group {
                if manager.selectedDomain == nil {
                    HealthDashboardView()
                } else if let selected = selectedAgent, let agent = manager.agents.first(where: { $0.id == selected.id }) {
                    AgentDetailView(agent: agent)
                        .id(agent.id)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                } else {
                    EmptyDetailView()
                }
            }
            .animation(.smooth(duration: 0.25), value: selectedAgent?.id)
        }
        .searchable(text: $manager.searchText, prompt: "Filter agents...")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingCreateSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .help("Create new agent")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Import Plists...") { importPlists() }
                    Button("Export Selected...") { exportSelected() }
                    Divider()
                    Button("Backup User Agents") { backupUserAgents() }
                    Divider()
                    Button("Deleted Services…") { showingRecovery = true }
                } label: {
                    Image(systemName: "square.and.arrow.up.on.square")
                }
                .help("Import / Export")
            }
        }
        .sheet(isPresented: $showingCreateSheet) {
            CreateAgentView()
                .environmentObject(manager)
        }
        .sheet(isPresented: $showingRecovery) { DeletedServicesView().environmentObject(manager) }
        .sheet(item: $manager.processAgent) { agent in
            ProcessDetailsView(agent: agent).environmentObject(manager)
        }
        .sheet(item: $manager.diagnosticsAgent) { agent in DiagnosticsView(agent: agent) }
        .sheet(isPresented: Binding(get: { !manager.taggingAgents.isEmpty },
                                    set: { if !$0 { manager.taggingAgents = [] } })) {
            TagEditorView(agents: manager.taggingAgents).environmentObject(manager)
        }
        .sheet(isPresented: Binding(get: { !manager.pendingDeletion.isEmpty },
                                    set: { if !$0 { manager.pendingDeletion = [] } })) {
            DeleteServicesView(agents: manager.pendingDeletion).environmentObject(manager)
        }
        .safeAreaInset(edge: .bottom) {
            if let message = manager.errorMessage ?? manager.notice {
                HStack(alignment: .top) {
                    Image(systemName: manager.errorMessage == nil ? "checkmark.circle" : "exclamationmark.triangle")
                    ScrollView { Text(message).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(maxHeight: 64)
                    Button("Dismiss") { manager.errorMessage = nil; manager.notice = nil }.font(.caption)
                }.padding(10).background(.bar)
                    .foregroundStyle(manager.errorMessage == nil ? Color.primary : .red)
            }
        }
        .alert("Import", isPresented: $showingImportAlert) {
            Button("OK") {}
        } message: {
            Text(importMessage)
        }
        .task {
            await manager.loadAllAgents()
        }
        .onChange(of: manager.newlyCreatedID) {
            selectedAgent = manager.agents.first { $0.id == manager.newlyCreatedID }
        }
    }

    private func importPlists() {
        guard let imports = ImportExportService.importPlists() else { return }
        var imported = 0
        var failures: [String] = []
        for item in imports {
            let path = manager.userAgentsDirectory + "/\(item.suggestedLabel).plist"
            do {
                try PlistWriteService.create(item.dict, at: path)
                imported += 1
            } catch {
                failures.append("\(item.suggestedLabel): \(error.localizedDescription)")
            }
        }
        importMessage = "Imported \(imported) of \(imports.count) agent(s)."
        if !failures.isEmpty { importMessage += "\n" + failures.joined(separator: "\n") }
        showingImportAlert = true
        Task { await manager.loadAllAgents() }
    }

    private func exportSelected() {
        let agentsToExport = manager.selectedAgents.isEmpty ? manager.filteredAgents : manager.selectedAgents
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.message = "Choose export destination"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let exportURL = try ImportExportService.exportAgents(agentsToExport, to: url)
                NSWorkspace.shared.activateFileViewerSelecting([exportURL])
            } catch {
                importMessage = "Export failed: \(error.localizedDescription)"
                showingImportAlert = true
            }
        }
    }

    private func backupUserAgents() {
        do {
            let backupURL = try ImportExportService.backupUserAgents(from: manager.userAgentsDirectory,
                storageDirectory: manager.recoveryDirectory.deletingLastPathComponent())
            importMessage = "Backed up to:\n\(backupURL.path)"
            showingImportAlert = true
        } catch {
            importMessage = "Backup failed: \(error.localizedDescription)"
            showingImportAlert = true
        }
    }
}

enum SidebarSelection: Hashable {
    case domain(AgentDomain)
    case healthDashboard
    case allServices
    case tag(String)
    case untagged
}

struct SidebarView: View {
    @EnvironmentObject var manager: LaunchAgentManager
    @EnvironmentObject var healthMonitor: HealthMonitorService
    @Binding var selectedAgent: LaunchAgent?
    @State private var isRefreshing = false
    @State private var sidebarSelection: SidebarSelection? = .domain(.userAgents)
    @State private var showingTags = false

    var body: some View {
        List(selection: $sidebarSelection) {
            Section {
                Label {
                    HStack {
                        Text("Health Dashboard")
                        Spacer()
                        if !healthMonitor.problemAgents.isEmpty {
                            Text("\(healthMonitor.problemAgents.count)")
                                .font(.caption)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(.red, in: Capsule())
                        }
                    }
                } icon: {
                    Image(systemName: "heart.text.square")
                        .foregroundColor(.red)
                }
                .tag(SidebarSelection.healthDashboard)
                Label("All Services", systemImage: "square.grid.2x2")
                    .tag(SidebarSelection.allServices)
            }

            Section("Domains") {
                ForEach(AgentDomain.allCases) { domain in
                    SidebarRow(domain: domain, count: manager.domainCounts[domain] ?? 0)
                        .tag(SidebarSelection.domain(domain))
                }
            }
            Section("Tags") {
                Label {
                    HStack { Text("Untagged"); Spacer(); Text("\(manager.untaggedServiceCount)").font(.caption).foregroundStyle(.secondary) }
                } icon: { Image(systemName: "tag.slash") }
                    .tag(SidebarSelection.untagged)
                ForEach(manager.sortedTags) { tag in
                    Label {
                        HStack { Text(tag.name).lineLimit(1); Spacer(); Text("\(manager.serviceCount(for: tag))").font(.caption).foregroundStyle(.secondary) }
                    } icon: { Image(systemName: "tag.fill").foregroundStyle(tag.color) }
                        .tag(SidebarSelection.tag(tag.id))
                        .help(tag.name)
                }
                Button("Manage Tags…", systemImage: "plus") { showingTags = true }
                    .buttonStyle(.plain)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Ignition")
        .toolbar {
            ToolbarItem {
                Button {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        isRefreshing = true
                    }
                    Task {
                        await manager.loadAllAgents()
                        withAnimation(.easeInOut(duration: 0.3)) {
                            isRefreshing = false
                        }
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                        .animation(
                            isRefreshing
                                ? .linear(duration: 0.8).repeatForever(autoreverses: false)
                                : .default,
                            value: isRefreshing
                        )
                }
                .help("Refresh all agents")
            }
        }
        .onChange(of: sidebarSelection) {
            syncSelection()
        }
        .onChange(of: manager.selectedDomain) {
            syncFromManager()
        }
        .onChange(of: manager.tagFilter) { syncFromManager() }
        .onChange(of: manager.includeAllDomains) { syncFromManager() }
        .onAppear {
            syncSelection()
        }
        .animation(.smooth, value: sidebarSelection)
        .sheet(isPresented: $showingTags) { TagEditorView(agents: []).environmentObject(manager) }
    }

    private func syncSelection() {
        manager.deselectAll()
        switch sidebarSelection {
        case .domain(let domain):
            manager.tagFilter = .all
            manager.includeAllDomains = false
            manager.selectedDomain = domain
            manager.statusFilter = .all
            selectedAgent = nil
        case .healthDashboard:
            manager.tagFilter = .all
            manager.selectedDomain = nil
        case .allServices:
            manager.tagFilter = .all
            manager.includeAllDomains = true
            if manager.selectedDomain == nil { manager.selectedDomain = .userAgents }
            selectedAgent = nil
        case .tag(let id):
            manager.tagFilter = .tag(id)
            manager.includeAllDomains = true
            if manager.selectedDomain == nil { manager.selectedDomain = .userAgents }
            manager.statusFilter = .all
            selectedAgent = nil
        case .untagged:
            manager.tagFilter = .untagged
            manager.includeAllDomains = true
            if manager.selectedDomain == nil { manager.selectedDomain = .userAgents }
            manager.statusFilter = .all
            selectedAgent = nil
        case nil:
            break
        }
    }
    private func syncFromManager() {
        guard let domain = manager.selectedDomain else { sidebarSelection = .healthDashboard; return }
        switch manager.tagFilter {
        case .tag(let id): sidebarSelection = .tag(id)
        case .untagged: sidebarSelection = .untagged
        case .all: sidebarSelection = manager.includeAllDomains ? .allServices : .domain(domain)
        }
    }
}

struct SidebarRow: View {
    let domain: AgentDomain
    let count: Int
    @State private var isHovered = false

    var body: some View {
        Label {
            HStack {
                Text(domain.rawValue)
                Spacer()
                Text("\(count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
        } icon: {
            Image(systemName: domain.icon)
                .foregroundColor(domain.isEditable ? .accentColor : .secondary)
                .scaleEffect(isHovered ? 1.15 : 1.0)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isHovered)
        }
        .onHover { isHovered = $0 }
    }
}

struct EmptyDetailView: View {
    @State private var flameScale: CGFloat = 0.9
    @State private var flameOpacity: Double = 0.3

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "flame")
                .font(.system(size: 64))
                .foregroundStyle(.tertiary)
                .scaleEffect(flameScale)
                .opacity(flameOpacity)
                .onAppear {
                    withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                        flameScale = 1.05
                        flameOpacity = 0.5
                    }
                }
            Text("Select an agent")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Choose a launch agent from the list to view its details")
                .font(.body)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
