import SwiftUI

struct ProcessDetailsView: View {
    @EnvironmentObject var manager: LaunchAgentManager
    @Environment(\.dismiss) private var dismiss
    let agent: LaunchAgent
    @State private var details: ProcessDetails?
    @State private var error: String?
    @State private var refreshing = false
    @State private var tab = 0
    @State private var pendingSignal: ProcessSignal?
    @State private var automaticRefresh = true
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Process Details").font(.title2.bold())
                    Text(agent.label).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Live", isOn: $automaticRefresh).toggleStyle(.switch).controlSize(.small)
                Button("Refresh") { Task { await refresh() } }.disabled(refreshing)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red) }
            if let details {
                HStack {
                    Text("PID \(details.process.pid) · updated \(details.capturedAt.formatted(date: .omitted, time: .standard))")
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                    Spacer()
                    Menu("Send Signal") {
                        ForEach(ProcessSignal.allCases) { signal in
                            Button(signal.rawValue) { pendingSignal = signal }
                        }
                    }.disabled(!agent.canControl || manager.busyServiceIDs.contains(agent.id) || error != nil)
                }
                Picker("Process information", selection: $tab) {
                    Text("Overview").tag(0); Text("Children (\(details.descendants.count))").tag(1)
                    Text("Open Files").tag(2); Text("Network").tag(3)
                }.pickerStyle(.segmented)
                if tab == 0 {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], spacing: 10) {
                                PropertyChip(title: "PID / Parent", value: "\(details.process.pid) / \(details.process.parentPID)", icon: "point.3.connected.trianglepath.dotted")
                                PropertyChip(title: "User / UID", value: "\(details.process.user) / \(details.process.uid)", icon: "person")
                                PropertyChip(title: "CPU", value: String(format: "%.1f%%", details.process.cpu), icon: "gauge")
                                PropertyChip(title: "Resident Memory", value: String(format: "%.1f MB", Double(details.process.residentKB) / 1024), icon: "memorychip")
                                PropertyChip(title: "Virtual Memory", value: String(format: "%.1f MB", Double(details.process.virtualKB) / 1024), icon: "memorychip")
                                PropertyChip(title: "Elapsed / State", value: "\(details.process.elapsed) / \(details.process.state)", icon: "clock")
                            }
                            PropertyRow(title: "Started", value: details.started, icon: "calendar")
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Full Command Line").font(.caption.bold()).foregroundStyle(.secondary)
                                Text(details.process.command).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                            Text("CPU is ps's lifetime average. RSS is resident memory; virtual memory includes mapped address space. Process state: R running, S sleeping, T stopped, Z zombie.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 8)
                    }
                } else if tab == 1 {
                    List(details.descendants) { child in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("PID \(child.pid) · parent \(child.parentPID) · \(child.user) · \(child.state)").font(.caption.bold())
                            Text("\(String(format: "%.1f", child.cpu))% CPU · \(String(format: "%.1f", Double(child.residentKB) / 1024)) MB · elapsed \(child.elapsed)")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(child.command).font(.caption.monospaced()).textSelection(.enabled)
                        }.padding(.vertical, 4)
                    }.overlay { if details.descendants.isEmpty { Text("No child processes").foregroundStyle(.secondary) } }
                } else {
                    if let warning = details.fileWarning { Text(warning).font(.caption).foregroundStyle(.orange) }
                    ScrollView([.horizontal, .vertical]) {
                        let text = tab == 2 ? details.openFiles : details.network
                        Text(text.isEmpty ? "No entries visible to the current user." : text)
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else if refreshing { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            Spacer(minLength: 0)
        }.padding(24).frame(width: 820, height: 640)
        .task {
            await refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if !Task.isCancelled && automaticRefresh && pendingSignal == nil { await refresh() }
            }
        }
        .confirmationDialog("Send \(pendingSignal?.rawValue ?? "Signal") to \(agent.label)?",
                            isPresented: Binding(get: { pendingSignal != nil }, set: { if !$0 { pendingSignal = nil } }),
                            titleVisibility: .visible) {
            if let signal = pendingSignal, let details {
                Button("Send \(signal.rawValue)", role: signal == .forceKill ? .destructive : nil) {
                    Task {
                        _ = await manager.sendSignal(signal, to: agent, expected: details)
                        error = manager.errorMessage
                        await refresh()
                    }
                }
            }
            Button("Cancel", role: .cancel) { pendingSignal = nil }
        } message: { Text(pendingSignal?.explanation ?? "") }
    }
    private func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        guard let pid = manager.current(agent).pid else { error = "Service has no running process."; return }
        do { details = try await ProcessDetailsService.fetch(pid: pid); error = nil }
        catch { self.error = error.localizedDescription }
    }
}
