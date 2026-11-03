import Foundation
import UserNotifications

@MainActor
class NotificationService: ObservableObject {
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "notificationsEnabled")
        }
    }
    @Published var notifyOnCrash: Bool {
        didSet {
            UserDefaults.standard.set(notifyOnCrash, forKey: "notifyOnCrash")
        }
    }
    @Published var notifyOnStop: Bool {
        didSet {
            UserDefaults.standard.set(notifyOnStop, forKey: "notifyOnStop")
        }
    }

    private var deliveredEventIDs: Set<Int64> = []

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: "notificationsEnabled")
        notifyOnCrash = UserDefaults.standard.object(forKey: "notifyOnCrash") as? Bool ?? true
        notifyOnStop = UserDefaults.standard.object(forKey: "notifyOnStop") as? Bool ?? false

        if isEnabled {
            requestPermission()
        }
    }

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            Task { @MainActor in
                if !granted {
                    self.isEnabled = false
                }
            }
        }
    }

    func handleEvent(_ event: ActivityEvent, pinnedLabels: Set<String>) {
        guard isEnabled else { return }
        // Only notify for pinned agents
        guard pinnedLabels.contains(event.serviceID ?? event.label) else { return }
        guard !deliveredEventIDs.contains(event.id) else { return }
        deliveredEventIDs.insert(event.id)
        if deliveredEventIDs.count > 500 { deliveredEventIDs = Set(deliveredEventIDs.sorted().suffix(250)) }

        switch event.eventType {
        case .crashed:
            if notifyOnCrash {
                sendNotification(
                    title: "Agent Crashed",
                    body: "\(event.label) exited with code \(event.exitCode ?? -1)",
                    identifier: "crash-\(event.label)-\(event.id)"
                )
            }
        case .stopped:
            if notifyOnStop {
                sendNotification(
                    title: "Agent Stopped",
                    body: "\(event.label) has stopped",
                    identifier: "stop-\(event.label)-\(event.id)"
                )
            }
        default:
            break
        }
    }

    private func sendNotification(title: String, body: String, identifier: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil  // deliver immediately
        )

        UNUserNotificationCenter.current().add(request)
    }
}
