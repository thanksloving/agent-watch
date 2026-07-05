import Foundation
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

class WatchConnectivityManager: NSObject, WCSessionDelegate {
    static let shared = WatchConnectivityManager()
    #if canImport(WatchConnectivity)
    private var session: WCSession?
    #endif
    var onWatchDecision: ((String, Decision) -> Void)?

    private override init() {
        super.init()
        #if canImport(WatchConnectivity)
        if WCSession.isSupported() {
            session = WCSession.default
            session?.delegate = self
            session?.activate()
        }
        #endif
    }

    func syncApproval(_ approval: Approval) {
        #if canImport(WatchConnectivity)
        guard let session = session, session.isReachable else { return }
        let dict: [String: Any] = [
            "id": approval.id,
            "toolName": approval.toolName,
            "command": approval.command,
            "status": approval.status.rawValue
        ]
        session.sendMessage(["type": "approval", "approval": dict], replyHandler: nil)
        #endif
    }

    // MARK: - WCSessionDelegate

    #if canImport(WatchConnectivity)
    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        DispatchQueue.main.async {
            if message["type"] as? String == "approval_response",
               let approvalId = message["approvalId"] as? String,
               let decisionStr = message["decision"] as? String,
               let decision = Decision(rawValue: decisionStr) {
                self.onWatchDecision?(approvalId, decision)
            }
        }
    }
    #endif
}
