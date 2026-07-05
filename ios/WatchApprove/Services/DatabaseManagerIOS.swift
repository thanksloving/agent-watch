import Foundation
import SQLite3

actor DatabaseManagerIOS {
    static let shared = DatabaseManagerIOS()
    private var db: OpaquePointer?

    private init() { openDB() }

    private func openDB() {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("approvals.sqlite")
        sqlite3_open(url.path, &db)
        let sql = "CREATE TABLE IF NOT EXISTS approvals (id TEXT PRIMARY KEY, tool_name TEXT, command TEXT, hook_session_id TEXT, cwd TEXT, status TEXT, created_at REAL, resolved_at REAL)"
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    func pendingApprovals() -> [Approval] {
        var approvals: [Approval] = []
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT * FROM approvals WHERE status='pending' ORDER BY created_at DESC", -1, &stmt, nil)
        while sqlite3_step(stmt) == SQLITE_ROW { approvals.append(rowToApproval(stmt)) }
        sqlite3_finalize(stmt)
        return approvals
    }

    func historyApprovals() -> [Approval] {
        var approvals: [Approval] = []
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT * FROM approvals WHERE status!='pending' ORDER BY created_at DESC LIMIT 100", -1, &stmt, nil)
        while sqlite3_step(stmt) == SQLITE_ROW { approvals.append(rowToApproval(stmt)) }
        sqlite3_finalize(stmt)
        return approvals
    }

    func save(_ approval: Approval) {
        var stmt: OpaquePointer?
        let sql = "INSERT OR REPLACE INTO approvals (id, tool_name, command, hook_session_id, cwd, status, created_at) VALUES (?,?,?,?,?,?,?)"
        sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        approval.id.withCString { p in sqlite3_bind_text(stmt, 1, p, -1, nil) }
        approval.toolName.withCString { p in sqlite3_bind_text(stmt, 2, p, -1, nil) }
        approval.command.withCString { p in sqlite3_bind_text(stmt, 3, p, -1, nil) }
        approval.hookSessionId.withCString { p in sqlite3_bind_text(stmt, 4, p, -1, nil) }
        (approval.cwd ?? "").withCString { p in sqlite3_bind_text(stmt, 5, p, -1, nil) }
        approval.status.rawValue.withCString { p in sqlite3_bind_text(stmt, 6, p, -1, nil) }
        sqlite3_bind_double(stmt, 7, approval.createdAt.timeIntervalSince1970)
        sqlite3_step(stmt); sqlite3_finalize(stmt)
    }

    func resolve(_ id: String, decision: Decision) {
        var stmt: OpaquePointer?
        let sql = "UPDATE approvals SET status=?, resolved_at=? WHERE id=?"
        sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        let statusStr = decision == .allow ? "approved" : "denied"
        statusStr.withCString { p in sqlite3_bind_text(stmt, 1, p, -1, nil) }
        sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
        id.withCString { p in sqlite3_bind_text(stmt, 3, p, -1, nil) }
        sqlite3_step(stmt); sqlite3_finalize(stmt)
    }

    private func rowToApproval(_ stmt: OpaquePointer?) -> Approval {
        func cs(_ i: Int32) -> String? {
            guard let p = sqlite3_column_text(stmt, i) else { return nil }
            return String(cString: p)
        }
        return Approval(
            id: cs(0) ?? "", toolName: cs(1) ?? "", command: cs(2) ?? "",
            hookSessionId: cs(3) ?? "", cwd: cs(4),
            status: ApprovalStatus(rawValue: cs(5) ?? "pending") ?? .pending,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6)))
    }
}
