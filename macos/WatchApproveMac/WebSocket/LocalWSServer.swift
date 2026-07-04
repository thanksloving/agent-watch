import Foundation
import Network

class LocalWSServer {
    let port: NWEndpoint.Port
    private var listener: NWListener?
    var onApproval: ((Approval) async -> Void)?

    init(port: UInt16 = 18792) {
        self.port = NWEndpoint.Port(integerLiteral: port)
    }

    func start() {
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            listener = try NWListener(using: parameters, on: port)
            listener?.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            listener?.start(queue: .main)
            print("Local approval server listening on http://localhost:\(port)")
        } catch {
            print("Failed to start local server: \(error)")
        }
    }

    private func handle(_ conn: NWConnection) {
        conn.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.receiveHTTP(conn) }
        }
        conn.start(queue: .main)
    }

    private func receiveHTTP(_ conn: NWConnection) {
        var received = Data()
        func recv() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
                if let data = data { received.append(data) }
                if isComplete || error != nil { self?.processRequest(received, conn: conn) }
                else { recv() }
            }
        }
        recv()
    }

    private func processRequest(_ data: Data, conn: NWConnection) {
        guard let text = String(data: data, encoding: .utf8),
              let headerEnd = text.range(of: "\r\n\r\n") else {
            conn.cancel(); return
        }
        let body = String(text[headerEnd.upperBound...])
        guard let jsonData = body.data(using: .utf8),
              let json = try? JSONDecoder().decode(HTTPApprovalJSON.self, from: jsonData) else {
            conn.cancel(); return
        }
        let approval = Approval(
            id: UUID().uuidString,
            toolName: json.tool_name ?? "Bash",
            command: json.command ?? "",
            hookSessionId: json.hook_session_id ?? "",
            cwd: json.cwd,
            status: .pending,
            createdAt: Date()
        )
        Task { await self.onApproval?(approval) }
        let bodyResp = "{\"ok\":true}".data(using: .utf8)!
        let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(bodyResp.count)\r\nConnection: close\r\n\r\n".data(using: .utf8)! + bodyResp
        conn.send(content: response, completion: .contentProcessed { _ in conn.cancel() })
    }

    func stop() { listener?.cancel() }
}

struct HTTPApprovalJSON: Codable {
    let tool_name: String?
    let command: String?
    let hook_session_id: String?
    let cwd: String?
}