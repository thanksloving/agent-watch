import SwiftUI

struct ApprovalCard: View {
    let approval: Approval
    let onDecision: (Decision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(approval.toolName.lowercased().contains("claude") ? "🦀" : "🤖")
                Text(approval.toolName).font(.caption).foregroundColor(.secondary)
                Spacer()
                Text(timeAgo(approval.createdAt)).font(.caption2).foregroundColor(.secondary)
            }
            Text(approval.command).font(.body)
            HStack(spacing: 12) {
                Button { onDecision(.allow) } label: {
                    Label("允许", systemImage: "checkmark.circle.fill").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).tint(.green)
                Button { onDecision(.deny) } label: {
                    Label("拒绝", systemImage: "xmark.circle.fill").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).tint(.red)
            }
        }
        .padding(.vertical, 4)
    }

    private func timeAgo(_ date: Date) -> String {
        let s = Int(-date.timeIntervalSinceNow)
        if s < 60 { return "\(s)秒前" }
        if s < 3600 { return "\(s/60)分钟前" }
        return "\(s/3600)小时前"
    }
}