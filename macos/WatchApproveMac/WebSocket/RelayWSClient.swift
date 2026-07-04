import Foundation
import Combine

class RelayWSClient: ObservableObject {
    static var shared: RelayWSClient?
    let relayURL: String
    private var webSocketTask: URLSessionWebSocketTask?
    private let session: URLSession
    @Published private(set) var isConnected = false
    var onApproval: ((Approval) async -> Void)?

    init(relayURL: String) {
        self.relayURL = relayURL
        self.session = URLSession(configuration: .default)
        RelayWSClient.shared = self
    }

    func connect() {
        guard var components = URLComponents(url: URL(string: relayURL)!, resolvingAgainstBaseURL: false) else { return }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = (components.path ?? "") + "/ws/device/" + deviceToken
        guard let wsURL = components.url else { return }
        webSocketTask = session.webSocketTask(with: wsURL)
        webSocketTask?.resume()
        isConnected = true
        receiveLoop()
    }

    private func receiveLoop() {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .success(let msg):
                if case .string(let text) = msg { self?.handleMessage(text) }
                self?.receiveLoop()
            case .failure:
                self?.isConnected = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self?.connect() }
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let msg = try? JSONDecoder().decode(WSMessage.self, from: data) else { return }
        if msg.type == "new_approval" {
            let approval = Approval(
                id: msg.approval_id ?? UUID().uuidString,
                toolName: msg.tool_name ?? "Bash",
                command: msg.command ?? "",
                hookSessionId: msg.hook_session_id ?? "",
                cwd: nil,
                status: .pending,
                createdAt: Date(timeIntervalSince1970: TimeInterval(msg.created_at ?? 0))
            )
            Task { @MainActor in
                await DatabaseManager.shared.saveApproval(approval)
                NotificationCenter.default.post(name: .approvalReceived, object: nil)
            }
        } else if msg.type == "approval_resolved", let id = msg.approval_id, let decision = msg.decision {
            Task { @MainActor in
                await DatabaseManager.shared.resolveApproval(id: id, decision: Decision(rawValue: decision) ?? .deny)
                NotificationCenter.default.post(name: .approvalReceived, object: nil)
            }
        } else if msg.type == "relay_notification" {
            // Completion notification from watch_done.py — show as system notification
            let title = msg.title ?? "任务完成"
            let body = msg.body ?? ""
            Task { @MainActor in
                NotificationManager.shared.showDoneNotification(title: title, body: body)
            }
        }
    }

    func notifyDecision(approvalId: String, decision: Decision) {
        let url = relayURL + "/approve/\(approvalId)"
        guard let data = try? JSONSerialization.data(withJSONObject: ["approval_id": approvalId, "decision": decision.rawValue, "device_id": deviceToken]) else { return }
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.httpBody = data
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        URLSession.shared.dataTask(with: req).resume()
    }

    private var deviceToken: String {
        if let t = UserDefaults.standard.string(forKey: "deviceToken") { return t }
        let t = UUID().uuidString
        UserDefaults.standard.set(t, forKey: "deviceToken"); return t
    }
}

struct WSMessage: Codable {
    let type: String
    let approval_id: String?
    let tool_name: String?
    let command: String?
    let hook_session_id: String?
    let created_at: Int?
    let decision: String?
    let title: String?
    let body: String?
}