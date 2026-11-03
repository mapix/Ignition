import SwiftUI
import AppKit

struct ServiceControlBar: View {
    @EnvironmentObject var manager: LaunchAgentManager
    let agent: LaunchAgent

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let reason = agent.protectionReason {
                Label(reason, systemImage: "lock.shield")
                    .font(.callout).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 115), spacing: 8)], spacing: 8) {
                ForEach(ServiceAction.allCases) { action in
                    Button {
                        Task { await manager.perform(action, on: agent) }
                    } label: {
                        Label(action.rawValue, systemImage: action.icon).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!manager.available(action, for: agent))
                    .help(action == .stop ? "SIGTERM requests an exit. KeepAlive may restart the process." :
                            action == .disable ? "Persistently disable and unload this service." : action.rawValue)
                }
            }
            HStack {
                Button("Process Details", systemImage: "cpu") { manager.processAgent = agent }
                    .disabled(agent.pid == nil)
                Button("Diagnostics", systemImage: "stethoscope") { manager.diagnosticsAgent = agent }
                Spacer()
                if manager.busyServiceIDs.contains(agent.id) { ProgressView().controlSize(.small) }
                Menu {
                    Button("Reveal in Finder") { manager.revealInFinder(agent) }.disabled(!agent.hasPlist)
                    Button("Open Plist") { manager.openInEditor(agent) }.disabled(!agent.hasPlist)
                    Button("Export Plist…") { ImportExportService.exportSingleAgent(agent) }.disabled(!agent.hasPlist)
                    Divider()
                    Button("Delete Service…", role: .destructive) { manager.requestDeletion([agent]) }
                        .disabled(!agent.canDelete || manager.busyServiceIDs.contains(agent.id))
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .font(.caption)
            .buttonStyle(.bordered)
            if agent.domain.requiresAdmin && agent.canControl {
                Text("Changes to this system domain require macOS administrator authorization.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !agent.hasPlist {
                Text("Registered at runtime. Unload removes this registration; its owning app may recreate it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct DeleteServicesView: View {
    @EnvironmentObject var manager: LaunchAgentManager
    @Environment(\.dismiss) private var dismiss
    let agents: [LaunchAgent]
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Delete \(agents.count == 1 ? "Service" : "\(agents.count) Services")", systemImage: "trash")
                .font(.title2.bold())
            Text("Running services will be unloaded. Their plist files and original paths will be backed up before removal. Restore them later from Deleted Services.")
                .fixedSize(horizontal: false, vertical: true)
            List(agents) { agent in
                VStack(alignment: .leading, spacing: 4) {
                    Text(agent.label).font(.headline)
                    Text(agent.plistPath).font(.caption).foregroundStyle(.secondary)
                    Text("\(agent.domain.rawValue) · \(agent.status.rawValue)")
                        .font(.caption).foregroundStyle(.secondary)
                    if let reason = agent.protectionReason { Text(reason).foregroundStyle(.red).font(.caption) }
                }
            }
            .frame(minHeight: 100, maxHeight: 220)
            Text("Program binaries, logs, and application data are retained. Restoring a plist does not start the service.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { manager.pendingDeletion = []; dismiss() }.keyboardShortcut(.cancelAction)
                Button("Back Up and Delete", role: .destructive) {
                    busy = true
                    Task { await manager.deletePending(); busy = false; dismiss() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy || agents.contains { !$0.canDelete })
                if busy { ProgressView().controlSize(.small) }
            }
        }
        .padding(24).frame(width: 560)
        .interactiveDismissDisabled(busy)
    }
}

struct DeletedServicesView: View {
    @EnvironmentObject var manager: LaunchAgentManager
    @Environment(\.dismiss) private var dismiss
    @State private var restoring: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Deleted Services").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Restore configurations to their original locations. Services stay unloaded until you choose Load.")
                .font(.callout).foregroundStyle(.secondary)
            if manager.deletedServices.isEmpty {
                ContentUnavailableView("No Deleted Services", systemImage: "archivebox",
                                       description: Text("Backups created when deleting services will appear here."))
            } else {
                List(manager.deletedServices) { entry in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.label).font(.headline)
                            Text(entry.originalPath).font(.caption).textSelection(.enabled)
                            Text(entry.deletedAt.formatted()).font(.caption).foregroundStyle(.secondary)
                            if FileManager.default.fileExists(atPath: entry.originalPath) {
                                Text("Original path exists. This backup will not overwrite it.")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                        Button("Show Backup") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.backupPath)]) }
                        Button("Restore") {
                            restoring = entry.id
                            Task { _ = await manager.restore(entry); restoring = nil }
                        }
                        .disabled(restoring != nil || FileManager.default.fileExists(atPath: entry.originalPath))
                    }.buttonStyle(.borderless).padding(.vertical, 4)
                }
            }
            if let error = manager.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .padding(24).frame(width: 760, height: 520)
        .onAppear { manager.refreshDeletedServices() }
    }
}

struct OperationHistoryView: View {
    @EnvironmentObject var manager: LaunchAgentManager
    var serviceID: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Management History").font(.headline)
            let records = manager.operations.filter { serviceID == nil || $0.serviceID == serviceID }
            if records.isEmpty {
                Text("No management operations recorded.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(records.prefix(30)) { record in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: record.success ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(record.success ? Color.green : .red)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(record.action) · \(record.label)").font(.caption.bold())
                        Text(record.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Text(record.timestamp.formatted()).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
}

struct DiagnosticsView: View {
    let agent: LaunchAgent
    @Environment(\.dismiss) private var dismiss
    @State private var diagnostics: ServiceDiagnostics?
    @State private var refreshing = false
    @State private var tab = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Service Diagnostics").font(.title2.bold())
                    Text(agent.serviceTarget).font(.caption.monospaced()).textSelection(.enabled)
                }
                Spacer()
                Button("Refresh") { Task { await refresh() } }.disabled(refreshing)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let diagnostics {
                Text("Checked \(diagnostics.checkedAt.formatted(date: .omitted, time: .standard))")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Diagnostics", selection: $tab) {
                    Text("Checks").tag(0); Text("launchctl State").tag(1); Text("Run Reason").tag(2)
                }.pickerStyle(.segmented)
                ScrollView([.vertical, .horizontal]) {
                    if tab == 0 {
                        VStack(alignment: .leading, spacing: 12) {
                            if diagnostics.issues.isEmpty { Label("No configuration issues detected", systemImage: "checkmark.circle") }
                            ForEach(Array(diagnostics.issues.enumerated()), id: \.offset) { _, issue in
                                Label(issue, systemImage: "info.circle").font(.callout)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    } else {
                        Text(tab == 1 ? diagnostics.rawState : diagnostics.reason)
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    }
                }
            } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.padding(24).frame(width: 800, height: 600)
            .task { await refresh() }
    }
    private func refresh() async {
        refreshing = true
        diagnostics = await ServiceDiagnostics.inspect(agent)
        refreshing = false
    }
}
