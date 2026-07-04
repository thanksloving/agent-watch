import SwiftUI

extension Notification.Name {
    static let approvalReceived = Notification.Name("approvalReceived")
}

struct ApprovalPopoverView: View {
    @ObservedObject var caffeinateManager: CaffeinateManager
    @State private var pendingApprovals: [Approval] = []
    @State private var history: [Approval] = []
    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "applewatch").font(.title2)
                Text("WatchApprove").font(.headline)
                Spacer()
                Button { showingSettings = true } label: {
                    Image(systemName: "gear")
                }.buttonStyle(.plain)
            }
            .padding()

            Divider()

            HStack {
                Image(systemName: caffeinateManager.isActive ? "moon.fill" : "moon")
                    .foregroundColor(caffeinateManager.isActive ? .orange : .secondary)
                Text(caffeinateManager.isActive ? "☕ 防休眠已开启" : "💤 防休眠已关闭")
                    .font(.caption)
                Spacer()
            }
            .padding(.horizontal).padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.1))

            Divider()

            if pendingApprovals.isEmpty {
                VStack { Spacer(); Text("没有待审批").foregroundColor(.secondary); Spacer() }
            } else {
                List(pendingApprovals) { approval in
                    ApprovalRow(approval: approval) { decision in
                        resolveApproval(approval, decision: decision)
                    }
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 380, height: 480)
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .onReceive(NotificationCenter.default.publisher(for: .approvalReceived)) { _ in loadApprovals() }
        .task { loadApprovals() }
    }

    private func loadApprovals() {
        Task {
            let all = await DatabaseManager.shared.allApprovals()
            pendingApprovals = all.filter { $0.status == .pending }
            history = all.filter { $0.status != .pending }
        }
    }

    private func resolveApproval(_ approval: Approval, decision: Decision) {
        Task {
            await DatabaseManager.shared.resolveApproval(id: approval.id, decision: decision)
            RelayWSClient.shared?.notifyDecision(approvalId: approval.id, decision: decision)
            loadApprovals()
        }
    }
}

struct ApprovalRow: View {
    let approval: Approval
    let onDecision: (Decision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(approval.toolName.lowercased().contains("claude") ? "🦀" : "🤖").font(.caption)
                Text(approval.toolName).font(.caption).foregroundColor(.secondary)
                Spacer()
                Text(ago(approval.createdAt)).font(.caption2).foregroundColor(.secondary)
            }
            Text(approval.command).font(.caption).lineLimit(2)
            HStack(spacing: 8) {
                Button("✅ 允许") { onDecision(.allow) }.buttonStyle(.borderedProminent).controlSize(.small)
                Button("❌ 拒绝") { onDecision(.deny) }.buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(.vertical, 6)
    }

    private func ago(_ date: Date) -> String {
        let s = Int(-date.timeIntervalSinceNow)
        return s < 60 ? "\(s)s ago" : "\(s/60)m ago"
    }
}