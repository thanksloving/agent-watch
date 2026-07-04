import AppKit
import UserNotifications

class WatchApproveMacAppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController!
    private var caffeinateManager: CaffeinateManager!
    private var localWSServer: LocalWSServer!
    private var relayWSClient: RelayWSClient!

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        NotificationManager.shared.requestPermissions()

        caffeinateManager = CaffeinateManager()
        menuBarController = MenuBarController(caffeinateManager: caffeinateManager)

        localWSServer = LocalWSServer(port: 18792)
        localWSServer.onApproval = { [weak self] approval in
            self?.handleIncomingApproval(approval)
        }
        localWSServer.start()

        if let relayURL = UserDefaults.standard.string(forKey: "relayURL"), !relayURL.isEmpty {
            relayWSClient = RelayWSClient(relayURL: relayURL)
            relayWSClient.onApproval = { [weak self] approval in
                self?.handleIncomingApproval(approval)
            }
            relayWSClient.connect()
        }
    }

    private func handleIncomingApproval(_ approval: Approval) {
        Task { @MainActor in
            await DatabaseManager.shared.saveApproval(approval)
            NotificationManager.shared.showApprovalNotification(for: approval)
            WatchConnectivityManager.shared.syncApproval(approval)
            menuBarController.updateBadge()
            NotificationCenter.default.post(name: .approvalReceived, object: nil)
        }
    }
}

extension WatchApproveMacAppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler: @escaping () -> Void) {
        let approvalId = response.notification.request.identifier
        let decision: Decision
        switch response.actionIdentifier {
        case "ALLOW": decision = .allow
        case "DENY":  decision = .deny
        default: return withCompletionHandler()
        }
        Task {
            await DatabaseManager.shared.resolveApproval(id: approvalId, decision: decision)
            RelayWSClient.shared?.notifyDecision(approvalId: approvalId, decision: decision)
        }
        withCompletionHandler()
    }
}