import UIKit
import UserNotifications

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                    didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            if granted { DispatchQueue.main.async { application.registerForRemoteNotifications() } }
        }
        let allow = UNNotificationAction(identifier: "ALLOW", title: "✅ 允许", options: [.foreground])
        let deny = UNNotificationAction(identifier: "DENY", title: "❌ 拒绝", options: [.foreground])
        let cat = UNNotificationCategory(identifier: "APPROVAL", actions: [allow, deny], intentIdentifiers: [])
        UNUserNotificationCenter.current().setNotificationCategories([cat])
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler: @escaping () -> Void) {
        let id = response.notification.request.identifier
        let decision: Decision = response.actionIdentifier == "ALLOW" ? .allow : .deny
        Task {
            await DatabaseManagerIOS.shared.resolve(id, decision: decision)
            await WebSocketServiceIOS.shared.notifyDecision(approvalId: id, decision: decision)
        }
        withCompletionHandler()
    }
}