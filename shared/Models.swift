// shared/Models.swift
import Foundation

public struct Device: Identifiable, Codable {
    public let id: String
    public let platform: Platform
    public var apnsToken: String?
    public var lastSeen: Date

    public init(id: String, platform: Platform, apnsToken: String?, lastSeen: Date) {
        self.id = id
        self.platform = platform
        self.apnsToken = apnsToken
        self.lastSeen = lastSeen
    }
}

public enum Platform: String, Codable {
    case ios, macos, watchos
}

public struct AntiSleepRule: Identifiable, Codable {
    public let id: UUID
    public var startHour: Int
    public var startMinute: Int
    public var endHour: Int
    public var endMinute: Int
    public var weekdays: Set<Int>  // 1=Mon, 7=Sun
    public var isEnabled: Bool

    public init(id: UUID = UUID(), startHour: Int, startMinute: Int,
                endHour: Int, endMinute: Int, weekdays: Set<Int>, isEnabled: Bool) {
        self.id = id
        self.startHour = startHour
        self.startMinute = startMinute
        self.endHour = endHour
        self.endMinute = endMinute
        self.weekdays = weekdays
        self.isEnabled = isEnabled
    }
}
