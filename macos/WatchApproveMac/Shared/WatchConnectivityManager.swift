import Foundation
import WatchConnectivity

class WatchConnectivityManager: NSObject, WCSessionDelegate {
    static let shared = WatchConnectivityManager()
    private var session: WCSession?
    var onWatchDecision: ((String, Decision) -> Void)?

    private override init() {
        super.init()
        if WCSession.isSupported() {
            session = WCSession.default
            session?.delegate = self
            session?.activate()
        }
    }

    func syncApproval(_ approval: Approval) {
        guard let session = session, session.isReachable else { return }
        let dict: [String: Any] = [
            "id": approval.id,
            "toolName": approval.toolName,
            "command": approval.command,
            "status": approval.status.rawValue
        ]
        session.sendMessage(["type": "approval", "approval": dict], replyHandler: nil)
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        // Required by WCSessionDelegate when used with iOS
        session.activate()
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        // Receive messages from watch (e.g., approval responses)
        DispatchQueue.main.async {
            if message["type"] as? String == "approval_response",
               let approvalId = message["approvalId"] as? String,
               let decisionStr = message["decision"] as? String,
               let decision = Decision(rawValue: decisionStr) {
                self.onWatchDecision?(approvalId, decision)
            }
        }
    }
}
