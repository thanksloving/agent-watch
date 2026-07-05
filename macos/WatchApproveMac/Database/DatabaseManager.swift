import Foundation
import SQLite3

class DatabaseManager: @unchecked Sendable {
    static let shared = DatabaseManager()
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.watchapprove.db")

    private init() { openDB() }

    private func openDB() {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("WatchApprove")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let dbPath = url.appendingPathComponent("approvals.sqlite").path
        if sqlite3_open(dbPath, &db) != SQLITE_OK { print("Failed to open DB") }
        let createSQL = "CREATE TABLE IF NOT EXISTS approvals (id TEXT PRIMARY KEY, tool_name TEXT, command TEXT, hook_session_id TEXT, cwd TEXT, status TEXT, created_at REAL, resolved_at REAL)"
        sqlite3_exec(db, createSQL, nil, nil, nil)
    }

    func pendingCount() async -> Int {
        await withCheckedContinuation { cont in
            queue.async {
                var stmt: OpaquePointer?
                sqlite3_prepare_v2(self.db, "SELECT COUNT(*) FROM approvals WHERE status='pending'", -1, &stmt, nil)
                var count = 0
                if sqlite3_step(stmt) == SQLITE_ROW {
                    count = Int(sqlite3_column_int64(stmt, 0))
                }
                sqlite3_finalize(stmt)
                cont.resume(returning: count)
            }
        }
    }

    func allApprovals() async -> [Approval] {
        await withCheckedContinuation { cont in
            queue.async {
                var approvals: [Approval] = []
                var stmt: OpaquePointer?
                sqlite3_prepare_v2(self.db, "SELECT * FROM approvals ORDER BY created_at DESC LIMIT 100", -1, &stmt, nil)
                while sqlite3_step(stmt) == SQLITE_ROW { approvals.append(self.rowToApproval(stmt)) }
                sqlite3_finalize(stmt)
                cont.resume(returning: approvals)
            }
        }
    }

    func saveApproval(_ approval: Approval) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                var stmt: OpaquePointer?
                let sql = "INSERT OR REPLACE INTO approvals (id, tool_name, command, hook_session_id, cwd, status, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)"
                sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil)
                approval.id.withCString { p in sqlite3_bind_text(stmt, 1, p, -1, nil) }
                approval.toolName.withCString { p in sqlite3_bind_text(stmt, 2, p, -1, nil) }
                approval.command.withCString { p in sqlite3_bind_text(stmt, 3, p, -1, nil) }
                approval.hookSessionId.withCString { p in sqlite3_bind_text(stmt, 4, p, -1, nil) }
                (approval.cwd ?? "").withCString { p in sqlite3_bind_text(stmt, 5, p, -1, nil) }
                approval.status.rawValue.withCString { p in sqlite3_bind_text(stmt, 6, p, -1, nil) }
                sqlite3_bind_double(stmt, 7, approval.createdAt.timeIntervalSince1970)
                sqlite3_step(stmt); sqlite3_finalize(stmt)
                cont.resume()
            }
        }
    }

    func resolveApproval(id: String, decision: Decision) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                var stmt: OpaquePointer?
                let sql = "UPDATE approvals SET status=?, resolved_at=? WHERE id=?"
                sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil)
                let statusStr = decision == .allow ? "approved" : "denied"
                statusStr.withCString { p in sqlite3_bind_text(stmt, 1, p, -1, nil) }
                sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
                id.withCString { p in sqlite3_bind_text(stmt, 3, p, -1, nil) }
                sqlite3_step(stmt); sqlite3_finalize(stmt)
                cont.resume()
            }
        }
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
