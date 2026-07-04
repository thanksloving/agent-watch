import Foundation
import WatchConnectivity

class WatchConnectivityManager: NSObject, WCSessionDelegate {
    static let shared = WatchConnectivityManager()
    private var session: WCSession?
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
        session.sendMessage([
            "type": "approval", "id": approval.id, "toolName": approval.toolName,
            "command": approval.command, "status": approval.status.rawValue
        ], replyHandler: nil)
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}
}