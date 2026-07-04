import Foundation
import WatchConnectivity

class WatchConnectivityServiceWatch: NSObject, ObservableObject {
    @Published var pendingApproval: Approval?
    @Published var isCaffeinateActive = false
    private var session: WCSession?

    override init() {
        super.init()
        if WCSession.isSupported() {
            session = WCSession.default
            session?.delegate = self
            session?.activate()
        }
    }

    func respond(_ id: String, decision: Decision) {
        session?.sendMessage(["type": "approval_response", "approvalId": id, "decision": decision.rawValue], replyHandler: nil)
        pendingApproval = nil
    }
}

extension WatchConnectivityServiceWatch: WCSessionDelegate {
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        DispatchQueue.main.async {
            if message["type"] as? String == "approval", let dict = message["approval"] as? [String: Any] {
                self.pendingApproval = Approval(
                    id: dict["id"] as? String ?? UUID().uuidString,
                    toolName: dict["toolName"] as? String ?? "Bash",
                    command: dict["command"] as? String ?? "",
                    hookSessionId: "",
                    cwd: nil, status: .pending, createdAt: Date()
                )
            }
            if let caffeinate = message["caffeinateActive"] as? Bool {
                self.isCaffeinateActive = caffeinate
            }
        }
    }
}