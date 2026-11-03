import SwiftUI

struct AgentDetailView: View {
    @EnvironmentObject var manager: LaunchAgentManager
    @EnvironmentObject var historyService: ActivityHistoryService
    @EnvironmentObject var healthMonitor: HealthMonitorService
    let agent: LaunchAgent
    @State private var showingRawPlist = false
    @State private var showingLogs = true
    @State private var showingHistory = false
    @State private var plistValue: PlistValue
    @State private var isDirty = false
    @State private var saveError: String?
    @State private var showSaveSuccess = false

    init(agent: LaunchAgent) {
        self.agent = agent
        self._plistValue = State(initialValue: PlistValue(fromAny: agent.plistContents))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                headerSection
                    .padding(24)

                Divider()

                actionsSection
                    .padding(24)
                ServiceTagsSection(agent: agent).padding(.horizontal, 24).padding(.bottom, 24)

                Divider()

                propertiesSection
                    .padding(24)

                // Log viewer section
                if agent.standardOutPath != nil || agent.standardErrorPath != nil {
                    Divider()
                    logSection
                        .padding(24)
                }

                Divider()

                // Activity history section
                historySection
                    .padding(24)
                OperationHistoryView(serviceID: agent.id)
                    .padding(24)

                Divider()

                if agent.hasPlist {
                    plistEditorSection.padding(24)
                }
            }
            .frame(minWidth: 360)
        }
        .navigationTitle(agent.displayName)
        .textSelection(.enabled)
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(statusGradient)
                        .frame(width: 52, height: 52)

                    Image(systemName: agent.domain.icon)
                        .font(.system(size: 24))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(agent.label)
                        .font(.system(.title3, weight: .bold))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        StatusBadge(status: agent.status)

                        if let pid = agent.pid, pid > 0 {
                            Text("PID \(pid)")
                                .font(.system(.caption, design: .monospaced))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(.fill.tertiary, in: Capsule())
                        }

                        Text(agent.domain.rawValue)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Path
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Text(agent.hasPlist ? agent.plistPath : agent.serviceTarget)
                    .font(.system(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        ServiceControlBar(agent: agent)
    }

    // MARK: - Properties

    private var propertiesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Configuration")
                .font(.headline)

            if let program = agent.program {
                PropertyRow(title: "Program", value: program, icon: "terminal.fill")
            }

            if let args = agent.programArguments, args.count > 1 {
                PropertyRow(
                    title: "Arguments",
                    value: args.dropFirst().joined(separator: " "),
                    icon: "text.alignleft"
                )
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))], spacing: 10) {
                PropertyChip(title: "KeepAlive", value: agent.isKeepAlive ? "Yes" : "No", icon: "heart.fill")
                PropertyChip(title: "Run at Load", value: agent.runAtLoad ? "Yes" : "No", icon: "play.circle.fill")
                PropertyChip(title: "Disabled", value: agent.isDisabled ? "Yes" : "No", icon: "nosign")
                if let exitStatus = agent.lastExitStatus {
                    PropertyChip(
                        title: "Last Exit",
                        value: exitStatus == 0 ? "0 (OK)" : "\(exitStatus)",
                        icon: "flag.fill"
                    )
                }
                // Resource stats for running agents
                if let pid = agent.pid, let stats = healthMonitor.statsForPID(pid) {
                    PropertyChip(title: "CPU", value: String(format: "%.1f%%", stats.cpuPercent), icon: "gauge.with.dots.needle.67percent")
                    PropertyChip(title: "Memory", value: String(format: "%.1f MB", stats.memoryMB), icon: "memorychip")
                }
            }

            if let interval = agent.startInterval {
                PropertyRow(
                    title: "Start Interval",
                    value: formatInterval(interval),
                    icon: "clock.fill"
                )
            }

            if let paths = agent.watchPaths {
                PropertyRow(
                    title: "Watch Paths",
                    value: paths.joined(separator: "\n"),
                    icon: "eye.fill"
                )
            }

            if let out = agent.standardOutPath {
                PropertyRow(title: "Stdout", value: out, icon: "arrow.right.square.fill")
            }

            if let err = agent.standardErrorPath {
                PropertyRow(title: "Stderr", value: err, icon: "exclamationmark.square.fill")
            }
        }
    }

    // MARK: - Log Viewer

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showingLogs.toggle()
                }
            } label: {
                HStack {
                    Image(systemName: showingLogs ? "chevron.down" : "chevron.right")
                        .font(.caption)
                    Text("Logs")
                        .font(.headline)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showingLogs {
                LogViewerView(
                    stdoutPath: agent.standardOutPath,
                    stderrPath: agent.standardErrorPath
                )
            }
        }
    }

    // MARK: - Activity History

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showingHistory.toggle()
                }
            } label: {
                HStack {
                    Image(systemName: showingHistory ? "chevron.down" : "chevron.right")
                        .font(.caption)
                    Text("Activity History")
                        .font(.headline)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showingHistory {
                ActivityHistoryView(agentLabel: agent.id)
            }
        }
    }

    // MARK: - Plist Editor

    private var isReadOnly: Bool {
        !agent.canDelete
    }

    private var plistEditorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showingRawPlist.toggle()
                    }
                } label: {
                    HStack {
                        Image(systemName: showingRawPlist ? "chevron.down" : "chevron.right")
                            .font(.caption)
                        Text("Plist Editor")
                            .font(.headline)
                        if isReadOnly {
                            Text("Read Only")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.orange.opacity(0.12), in: Capsule())
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if showingRawPlist && isDirty && !isReadOnly {
                    Button {
                        savePlist()
                    } label: {
                        Label("Save", systemImage: "square.and.arrow.down")
                            .font(.system(.caption, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(saving)
                    Button("Save & Reload") { savePlist(reload: true) }
                        .buttonStyle(.bordered).controlSize(.small).disabled(saving)
                }

                if showSaveSuccess {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }
            }

            if let error = saveError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if showingRawPlist {
                PlistEditorView(plistValue: $plistValue, isReadOnly: isReadOnly)
                    .onChange(of: plistValue) {
                        isDirty = true
                    }
            }
        }
    }

    @State private var saving = false

    private func savePlist(reload: Bool = false) {
        guard !saving else { return }
        let dict = plistValue.toAny() as? [String: Any] ?? [:]
        saving = true
        Task {
            let saved = await manager.saveConfiguration(dict, for: agent, reload: reload)
            saving = false
            if saved {
                isDirty = false
                saveError = nil
                showSaveSuccess = true
            } else {
                saveError = manager.errorMessage
            }
        }
    }

    // MARK: - Helpers

    private var statusGradient: LinearGradient {
        let color: Color = {
            switch agent.status {
            case .running: return .green
            case .loaded: return .blue
            case .unloaded: return .gray
            case .error: return .red
            case .unknown: return .orange
            }
        }()
        return LinearGradient(
            colors: [color, color.opacity(0.7)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func formatInterval(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }

    private func formatPlist(_ dict: [String: Any]) -> String {
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: dict,
            format: .xml,
            options: 0
        ), let string = String(data: data, encoding: .utf8) else {
            return "Unable to serialize plist"
        }
        return string
    }
}

// MARK: - Components

struct StatusBadge: View {
    let status: AgentStatus

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(status.rawValue)
                .font(.system(.caption, weight: .semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(color.opacity(0.12), in: Capsule())
    }

    private var color: Color {
        switch status {
        case .running: return .green
        case .loaded: return .blue
        case .unloaded: return .gray
        case .error: return .red
        case .unknown: return .orange
        }
    }
}

struct ActionButton: View {
    let title: String
    let icon: String
    let color: Color
    var isLoading: Bool = false
    let action: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        Button {
            guard !isLoading else { return }
            action()
        } label: {
            HStack(spacing: 6) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Image(systemName: icon)
                        .transition(.scale.combined(with: .opacity))
                }
                Text(title)
            }
            .font(.system(.caption, weight: .semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered ? color.opacity(0.15) : color.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(color.opacity(0.3), lineWidth: 1)
            )
            .foregroundStyle(color)
            .scaleEffect(isPressed ? 0.94 : 1.0)
            .opacity(isLoading ? 0.7 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .pressEvents(onPress: { isPressed = true }, onRelease: { isPressed = false })
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: isHovered)
        .animation(.spring(response: 0.2, dampingFraction: 0.5), value: isPressed)
        .animation(.easeInOut(duration: 0.2), value: isLoading)
    }
}

// Helper for detecting press state
struct PressModifier: ViewModifier {
    var onPress: () -> Void
    var onRelease: () -> Void

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in onPress() }
                    .onEnded { _ in onRelease() }
            )
    }
}

extension View {
    func pressEvents(onPress: @escaping () -> Void, onRelease: @escaping () -> Void) -> some View {
        modifier(PressModifier(onPress: onPress, onRelease: onRelease))
    }
}

/// Full-width row for long values like paths
struct PropertyRow: View {
    let title: String
    let value: String
    let icon: String
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(isHovered ? .primary : .secondary)
                .frame(width: 20, alignment: .center)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(.caption2, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                Text(value)
                    .font(.system(.callout))
                    .lineLimit(4)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered ? Color.gray.opacity(0.12) : Color.gray.opacity(0.06))
        )
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
    }
}

/// Compact chip for boolean/short values
struct PropertyChip: View {
    let title: String
    let value: String
    let icon: String
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(isHovered ? .primary : .secondary)
            Text(value)
                .font(.system(.caption, weight: .semibold))
            Text(title)
                .font(.system(.caption2))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered ? Color.gray.opacity(0.12) : Color.gray.opacity(0.06))
        )
        .scaleEffect(isHovered ? 1.04 : 1.0)
        .onHover { isHovered = $0 }
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isHovered)
    }
}
