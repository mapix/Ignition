import SwiftUI

@main
struct IgnitionApp: App {
    @StateObject private var agentManager = LaunchAgentManager()
    @StateObject private var historyService = ActivityHistoryService()
    @StateObject private var healthMonitor = HealthMonitorService()
    @StateObject private var notificationService = NotificationService()

    var body: some Scene {
        Window("Ignition", id: "main") {
            ContentView()
                .environmentObject(agentManager)
                .environmentObject(historyService)
                .environmentObject(healthMonitor)
                .environmentObject(notificationService)
                .frame(minWidth: 1050, minHeight: 600)
                .onAppear {
                    agentManager.historyService = historyService
                    agentManager.notificationService = notificationService
                    agentManager.healthMonitor = healthMonitor
                    healthMonitor.startMonitoring()
                }
        }
        .windowStyle(.automatic)
        .defaultSize(width: 1280, height: 750)

        MenuBarExtra {
            MenuBarView()
                .environmentObject(agentManager)
        } label: {
            Image(systemName: "flame")
        }
        .menuBarExtraStyle(.window)
    }
}
