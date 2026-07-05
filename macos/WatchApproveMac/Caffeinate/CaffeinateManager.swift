import Foundation
import Combine

extension Notification.Name {
    static let caffeinateChanged = Notification.Name("caffeinateChanged")
}

class CaffeinateManager: ObservableObject {
    @Published private(set) var isActive: Bool = false
    private var caffeinatePID: pid_t = 0
    private var scheduledTimer: Timer?
    private var rules: [AntiSleepRule] = []

    init() {
        loadRules()
        if rules.contains(where: { $0.isEnabled }) {
            startScheduleEvaluator()
        }
    }

    func prevent(reason: String = "WatchApprove Pro") {
        guard !isActive else { return }
        // caffeinate -s (system), -m (prevent disk idle), -i (prevent idle sleep), -t 0 (no timeout = kill to release)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        task.arguments = ["-s", "-m", "-i", "-t", "0"]
        task.launch()
        caffeinatePID = task.processIdentifier
        isActive = true
        NotificationCenter.default.post(name: .caffeinateChanged, object: nil)
    }

    func release() {
        guard isActive, caffeinatePID != 0 else { return }
        kill(caffeinatePID, SIGTERM)
        caffeinatePID = 0
        isActive = false
        NotificationCenter.default.post(name: .caffeinateChanged, object: nil)
    }

    func onClaudeWorking() { prevent(reason: "WatchApprove Pro: Claude Code active") }
    func onClaudeStopped() { release() }

    func updateRules(_ rules: [AntiSleepRule]) {
        self.rules = rules
        startScheduleEvaluator()
    }

    private func startScheduleEvaluator() {
        scheduledTimer?.invalidate()
        scheduledTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.evaluateSchedule()
        }
    }

    private func evaluateSchedule() {
        let now = Date()
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: now)
        let hour = calendar.component(.hour, from: now)
        let minute = calendar.component(.minute, from: now)
        let nowMinutes = hour * 60 + minute

        let activeNow = rules.filter { $0.isEnabled && $0.weekdays.contains(weekday) }.contains { rule in
            let start = rule.startHour * 60 + rule.startMinute
            let end = rule.endHour * 60 + rule.endMinute
            if start <= end {
                return nowMinutes >= start && nowMinutes < end
            } else {
                return nowMinutes >= start || nowMinutes < end
            }
        }

        if activeNow && !isActive { prevent(reason: "WatchApprove Pro: Scheduled") }
        else if !activeNow && isActive { release() }
    }

    private func loadRules() {
        if let data = UserDefaults.standard.data(forKey: "antiSleepRules"),
           let rules = try? JSONDecoder().decode([AntiSleepRule].self, from: data) {
            self.rules = rules
        }
    }

    func saveRules(_ rules: [AntiSleepRule]) {
        self.rules = rules
        if let data = try? JSONEncoder().encode(rules) {
            UserDefaults.standard.set(data, forKey: "antiSleepRules")
        }
    }
}
