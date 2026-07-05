import Foundation
import UserNotifications
import AppKit

class NotificationManager: NSObject {
    static let shared = NotificationManager()
    private override init() { super.init() }

    func requestPermissions() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            if granted {
                DispatchQueue.main.async { NSApp.registerForRemoteNotifications() }
            }
        }
        let allow = UNNotificationAction(identifier: "ALLOW", title: "✅ 允许", options: [.foreground])
        let deny = UNNotificationAction(identifier: "DENY", title: "❌ 拒绝", options: [.foreground])
        let terminal = UNNotificationAction(identifier: "TERMINAL", title: "🖥️ 终端", options: [.foreground])
        let cat = UNNotificationCategory(identifier: "APPROVAL", actions: [allow, deny, terminal], intentIdentifiers: [], options: [.customDismissAction])
        UNUserNotificationCenter.current().setNotificationCategories([cat])
    }

    func showApprovalNotification(for approval: Approval) {
        let content = UNMutableNotificationContent()
        content.title = "🦀 Claude 待批准"
        content.body = approval.command
        content.subtitle = approval.toolName
        content.categoryIdentifier = "APPROVAL"
        content.userInfo = ["approvalId": approval.id]
        content.interruptionLevel = .active
        content.relevanceScore = 100
        content.sound = .default
        let request = UNNotificationRequest(identifier: approval.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}