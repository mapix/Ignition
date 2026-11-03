import Foundation

struct AgentHealthInfo: Identifiable, Equatable {
    var id: String { label }
    let label: String
    var cpuPercent: Double
    var memoryMB: Double
    var pid: Int
}

@MainActor
class HealthMonitorService: ObservableObject {
    @Published var healthInfo: [String: AgentHealthInfo] = [:]
    @Published var crashLoopLabels: [String: Int] = [:]  // label → crash count in last hour

    private var pollTimer: Timer?
    var trackedAgents: [LaunchAgent] = []
    private var polling = false

    func startMonitoring() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.pollProcessStats()
            }
        }
        Task { await pollProcessStats() }
    }

    func stopMonitoring() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func updateCrashLoops(from historyService: ActivityHistoryService) {
        crashLoopLabels = historyService.crashLoopAgents()
    }

    func healthFor(_ label: String) -> AgentHealthInfo? {
        healthInfo[label]
    }

    /// Problem agents: crash-looping or high CPU
    var problemAgents: [(label: String, reason: String)] {
        var problems: [(String, String)] = []

        for (label, count) in crashLoopLabels {
            problems.append((label, "Crash looping (\(count)x in last hour)"))
        }

        for agent in trackedAgents {
            if let pid = agent.pid, let info = statsForPID(pid), info.cpuPercent > 90,
               !problems.contains(where: { $0.0 == agent.id }) {
                problems.append((agent.id, String(format: "High CPU: %.0f%%", info.cpuPercent)))
            }
        }

        return problems.sorted { $0.0 < $1.0 }
    }

    private func pollProcessStats() async {
        guard !polling else { return }
        polling = true
        defer { polling = false }
        let result = await runPS()
        var newInfo: [String: AgentHealthInfo] = [:]

        for line in result.split(separator: "\n").dropFirst() {
            let cols = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard cols.count >= 4 else { continue }

            guard let pid = Int(cols[0]),
                  let cpu = Double(cols[1]),
                  let memKB = Double(cols[2]) else { continue }

            let command = String(cols[3])

            // Store by PID for now; we'll correlate with agents later
            let info = AgentHealthInfo(
                label: command,
                cpuPercent: cpu,
                memoryMB: memKB / 1024.0,
                pid: pid
            )
            newInfo["\(pid)"] = info
        }

        healthInfo = newInfo
    }

    func statsForPID(_ pid: Int) -> AgentHealthInfo? {
        healthInfo["\(pid)"]
    }

    private func runPS() async -> String {
        let result = await CommandRunner.run("/bin/ps", ["-eo", "pid,pcpu,rss,comm"])
        return result.success ? result.output : ""
    }
}
