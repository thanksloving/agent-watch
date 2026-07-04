import SwiftUI

@main
struct WatchApproveApp: App {
    @StateObject private var connectivity = WatchConnectivityServiceWatch()

    var body: some Scene {
        WindowGroup {
            ContentViewWatch().environmentObject(connectivity)
        }
    }
}

struct ContentViewWatch: View {
    @EnvironmentObject var connectivity: WatchConnectivityServiceWatch

    var body: some View {
        TabView {
            if let approval = connectivity.pendingApproval {
                ApprovalDetailViewWatch(approval: approval)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "applewatch").font(.largeTitle)
                    Text(connectivity.isCaffeinateActive ? "☕ 防休眠" : "💤 正常")
                        .font(.caption)
                }
            }
        }
    }
}