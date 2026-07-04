import Foundation

class WebSocketServiceIOS: NSObject, ObservableObject {
    static let shared = WebSocketServiceIOS()

    @Published private(set) var isConnected = false
    private var webSocketTask: URLSessionWebSocketTask?

    private override init() { super.init() }

    func connect() {
        guard let urlStr = UserDefaults.standard.string(forKey: "relayURL"),
              !urlStr.isEmpty,
              var components = URLComponents(url: URL(string: urlStr)!, resolvingAgainstBaseURL: false) else { return }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = (components.path ?? "") + "/ws/device/" + deviceToken
        webSocketTask = URLSession(configuration: .default).webSocketTask(with: components.url!)
        webSocketTask?.resume()
        isConnected = true
        receive()
    }

    private func receive() {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .success(let msg):
                if case .string(let text) = msg { self?.handle(text) }
                self?.receive()
            case .failure:
                self?.isConnected = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self?.connect() }
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let msg = try? JSONDecoder().decode(WSMessage.self, from: data) else { return }
        if msg.type == "new_approval" {
            let approval = Approval(
                id: msg.approval_id ?? UUID().uuidString,
                toolName: msg.tool_name ?? "Bash",
                command: msg.command ?? "",
                hookSessionId: msg.hook_session_id ?? "",
                cwd: nil, status: .pending,
                createdAt: Date(timeIntervalSince1970: TimeInterval(msg.created_at ?? 0))
            )
            Task { @MainActor in
                await DatabaseManagerIOS.shared.save(approval)
                NotificationCenter.default.post(name: .newApprovalIOS, object: nil)
            }
        }
    }

    func notifyDecision(approvalId: String, decision: Decision) {
        let url = (UserDefaults.standard.string(forKey: "relayURL") ?? "") + "/approve/\(approvalId)"
        guard let data = try? JSONSerialization.data(withJSONObject: ["approval_id": approvalId, "decision": decision.rawValue, "device_id": deviceToken]) else { return }
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"; req.httpBody = data
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        URLSession.shared.dataTask(with: req).resume()
    }

    private var deviceToken: String {
        if let t = UserDefaults.standard.string(forKey: "deviceToken") { return t }
        let t = UUID().uuidString
        UserDefaults.standard.set(t, forKey: "deviceToken"); return t
    }
}

extension Notification.Name {
    static let newApprovalIOS = Notification.Name("newApprovalIOS")
}