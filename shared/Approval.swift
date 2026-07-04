// shared/Approval.swift
import Foundation

public struct Approval: Identifiable, Codable {
    public let id: String
    public let toolName: String
    public let command: String
    public let hookSessionId: String
    public let cwd: String?
    public var status: ApprovalStatus
    public let createdAt: Date

    public init(id: String, toolName: String, command: String,
                hookSessionId: String, cwd: String?,
                status: ApprovalStatus, createdAt: Date) {
        self.id = id
        self.toolName = toolName
        self.command = command
        self.hookSessionId = hookSessionId
        self.cwd = cwd
        self.status = status
        self.createdAt = createdAt
    }
}

public enum ApprovalStatus: String, Codable {
    case pending, approved, denied, timeout
}

public enum Decision: String {
    case allow, deny
}
