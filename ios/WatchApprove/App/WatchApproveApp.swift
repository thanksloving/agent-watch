import SwiftUI

@main
struct WatchApproveApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            TabView {
                ApprovalsView()
                    .tabItem { Label("审批", systemImage: "bell") }
                SettingsView()
                    .tabItem { Label("设置", systemImage: "gear") }
            }
        }
    }
}