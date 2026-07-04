import Foundation
import Combine

@MainActor
class ApprovalsViewModel: ObservableObject {
    @Published var pending: [Approval] = []
    @Published var history: [Approval] = []

    func load() async {
        pending = await DatabaseManagerIOS.shared.pendingApprovals()
        history = await DatabaseManagerIOS.shared.historyApprovals()
    }

    func resolve(_ approval: Approval, decision: Decision) {
        Task {
            await DatabaseManagerIOS.shared.resolve(approval.id, decision: decision)
            await WebSocketServiceIOS.shared.notifyDecision(approvalId: approval.id, decision: decision)
            await load()
        }
    }
}