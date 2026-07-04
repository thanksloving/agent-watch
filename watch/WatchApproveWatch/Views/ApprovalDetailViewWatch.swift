import SwiftUI

struct ApprovalDetailViewWatch: View {
    let approval: Approval
    @EnvironmentObject var connectivity: WatchConnectivityServiceWatch

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text(approval.toolName).font(.caption).foregroundColor(.secondary)
                Text(approval.command).font(.headline).multilineTextAlignment(.center)
                Divider()
                HStack(spacing: 12) {
                    Button {
                        connectivity.respond(approval.id, decision: .allow)
                    } label: {
                        Label("允许", systemImage: "checkmark")
                    }
                    .buttonStyle(.borderedProminent).tint(.green)

                    Button {
                        connectivity.respond(approval.id, decision: .deny)
                    } label: {
                        Label("拒绝", systemImage: "xmark")
                    }
                    .buttonStyle(.borderedProminent).tint(.red)
                }
            }
            .padding()
        }
    }
}