import SwiftUI

struct HealthDashboardView: View {
    @EnvironmentObject var manager: LaunchAgentManager
    @EnvironmentObject var healthMonitor: HealthMonitorService
    @EnvironmentObject var historyService: ActivityHistoryService

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Overview cards
                overviewSection
                    .padding(.horizontal, 24)
                    .padding(.top, 24)

                Divider()

                // Problem agents
                problemSection
                    .padding(.horizontal, 24)

                Divider()

                // Running agents with resource usage
                runningAgentsSection
                    .padding(.horizontal, 24)

                Divider()

                // Recent activity
                OperationHistoryView().padding(.horizontal, 24)
                ActivityHistoryView(agentLabel: nil)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
            }
        }
        .navigationTitle("Health Dashboard")
        .onAppear {
            healthMonitor.startMonitoring()
            healthMonitor.updateCrashLoops(from: historyService)
        }
    }

    // MARK: - Overview

    private var overviewSection: some View {
        HStack(spacing: 16) {
            OverviewCard(
                title: "Total Agents",
                value: "\(manager.agents.count)",
                icon: "square.grid.2x2",
                color: .blue
            )
            OverviewCard(
                title: "Running",
                value: "\(manager.runningCount)",
                icon: "play.circle.fill",
                color: .green
            )
            OverviewCard(
                title: "Problems",
                value: "\(healthMonitor.problemAgents.count)",
                icon: "exclamationmark.triangle.fill",
                color: healthMonitor.problemAgents.isEmpty ? .gray : .red
            )
            OverviewCard(
                title: "Crash Loops",
                value: "\(healthMonitor.crashLoopLabels.count)",
                icon: "arrow.triangle.2.circlepath",
                color: healthMonitor.crashLoopLabels.isEmpty ? .gray : .orange
            )
        }
    }

    // MARK: - Problems

    private var problemSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text("Problem Agents")
                    .font(.headline)
            }

            if healthMonitor.problemAgents.isEmpty {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("All agents healthy")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            } else {
                ForEach(healthMonitor.problemAgents, id: \.label) { problem in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(.red)
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(manager.agents.first { $0.id == problem.label }?.label ?? problem.label)
                                .font(.system(.caption, weight: .medium))
                                .lineLimit(1)
                            Text(problem.reason)
                                .font(.system(size: 10))
                                .foregroundStyle(.red)
                        }
                        Spacer()
                    }
                    .padding(8)
                    .background(Color.red.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    // MARK: - Running Agents Resources

    private var runningAgentsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .foregroundStyle(.blue)
                Text("Running Agents")
                    .font(.headline)
            }

            let runningAgents = manager.agents.filter { $0.status == .running }

            if runningAgents.isEmpty {
                Text("No agents currently running")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                LazyVStack(spacing: 4) {
                    // Header
                    HStack {
                        Text("Agent")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("PID")
                            .frame(width: 60, alignment: .trailing)
                        Text("CPU")
                            .frame(width: 60, alignment: .trailing)
                        Text("Memory")
                            .frame(width: 70, alignment: .trailing)
                    }
                    .font(.system(.caption2, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)

                    ForEach(runningAgents) { agent in
                        let stats = agent.pid.flatMap { healthMonitor.statsForPID($0) }
                        HStack {
                            Text(agent.displayName)
                                .font(.system(.caption, weight: .medium))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Text(agent.pid.map { "\($0)" } ?? "-")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 60, alignment: .trailing)

                            Text(stats.map { String(format: "%.1f%%", $0.cpuPercent) } ?? "-")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(cpuColor(stats?.cpuPercent))
                                .frame(width: 60, alignment: .trailing)

                            Text(stats.map { String(format: "%.1f MB", $0.memoryMB) } ?? "-")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 70, alignment: .trailing)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.gray.opacity(0.04))
                        )
                    }
                }
            }
        }
    }

    private func cpuColor(_ cpu: Double?) -> Color {
        guard let cpu else { return .secondary }
        if cpu > 90 { return .red }
        if cpu > 50 { return .orange }
        return .secondary
    }
}

struct OverviewCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(color)

            Text(value)
                .font(.system(.title2, design: .rounded, weight: .bold))
                .monospacedDigit()

            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isHovered ? color.opacity(0.08) : color.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(color.opacity(0.15), lineWidth: 1)
        )
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .onHover { isHovered = $0 }
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isHovered)
    }
}
