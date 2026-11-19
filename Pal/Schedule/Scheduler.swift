import Foundation

/// A job that runs later or repeatedly.
struct ScheduledJob: Codable, Identifiable, Equatable {
    enum Repeat: Codable, Equatable {
        case once
        case everyMinutes(Int)
        case daily(hour: Int, minute: Int)
        case weekdays(hour: Int, minute: Int)

        var title: String {
            switch self {
            case .once: return "Once"
            case .everyMinutes(let m): return m % 60 == 0 ? "Every \(m / 60)h" : "Every \(m) min"
            case .daily(let h, let m): return String(format: "Daily at %02d:%02d", h, m)
            case .weekdays(let h, let m): return String(format: "Weekdays at %02d:%02d", h, m)
            }
        }
    }

    enum Target: Codable, Equatable {
        /// Start a new agent with the prompt.
        case newAgent
        /// Wake an existing agent session with the prompt.
        case session(String)
        /// Just tell the user (a reminder-style nudge).
        case notify
    }

    var id = String(UUID().uuidString.lowercased().prefix(8))
    var title: String
    var prompt: String
    var repeatRule: Repeat
    var target: Target
    var nextRun: Date
    var enabled = true
    var lastRun: Date?
    var createdBy = "user"
}

/// Runs scheduled jobs: agent wake-ups, recurring checks, nudges.
@MainActor
final class Scheduler: ObservableObject {
    static let shared = Scheduler()
    @Published private(set) var jobs: [ScheduledJob] = []
    private var timer: Timer?
    var onNotify: ((ScheduledJob) -> Void)?

    func start() {
        jobs = Store.load([ScheduledJob].self, "schedules.json") ?? []
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
    }

    @discardableResult
    func add(_ job: ScheduledJob) -> ScheduledJob {
        jobs.append(job)
        jobs.sort { $0.nextRun < $1.nextRun }
        save()
        return job
    }

    func remove(_ id: String) {
        jobs.removeAll { $0.id == id || $0.id.hasPrefix(id) }
        save()
    }

    func setEnabled(_ id: String, _ on: Bool) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i].enabled = on
        if on && jobs[i].nextRun < Date() { jobs[i].nextRun = Self.next(after: Date(), jobs[i].repeatRule) ?? Date() }
        save()
    }

    func runNow(_ id: String) {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        fire(job)
    }

    private func tick() {
        let now = Date()
        for job in jobs where job.enabled && job.nextRun <= now {
            // Skip one-offs that were missed by more than 12 hours (Mac was off).
            if job.repeatRule == .once && now.timeIntervalSince(job.nextRun) > 12 * 3600 {
                remove(job.id)
                continue
            }
            fire(job)
        }
    }

    private func fire(_ job: ScheduledJob) {
        guard let i = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        jobs[i].lastRun = Date()
        if let next = Self.next(after: Date(), job.repeatRule) {
            jobs[i].nextRun = next
        } else {
            jobs.remove(at: i)
        }
        save()
        log.notice("schedule fired: \(job.title, privacy: .public)")
        switch job.target {
        case .notify:
            onNotify?(job)
        case .newAgent:
            _ = try? SessionManager.shared.start(task: job.prompt, title: job.title, origin: "scheduled task “\(job.title)”")
        case .session(let id):
            if (try? SessionManager.shared.send(id, job.prompt, from: "wake-up")) == nil {
                _ = try? SessionManager.shared.start(task: job.prompt, title: job.title, origin: "scheduled task “\(job.title)”")
            }
        }
    }

    nonisolated static func next(after date: Date, _ rule: ScheduledJob.Repeat) -> Date? {
        let cal = Calendar.current
        switch rule {
        case .once:
            return nil
        case .everyMinutes(let m):
            return date.addingTimeInterval(TimeInterval(max(m, 1) * 60))
        case .daily(let h, let m):
            return cal.nextDate(after: date, matching: DateComponents(hour: h, minute: m), matchingPolicy: .nextTime)
        case .weekdays(let h, let m):
            var d = date
            for _ in 0..<8 {
                guard let n = cal.nextDate(after: d, matching: DateComponents(hour: h, minute: m), matchingPolicy: .nextTime) else { return nil }
                if !cal.isDateInWeekend(n) { return n }
                d = n
            }
            return nil
        }
    }

    private func save() { Store.save(jobs, "schedules.json") }
}

/// Plain timers and alarms (the Siri kind).
@MainActor
final class TimerCenter: ObservableObject {
    static let shared = TimerCenter()

    struct PalTimer: Codable, Identifiable, Equatable {
        var id = String(UUID().uuidString.lowercased().prefix(6))
        var label: String
        var fireDate: Date
        var isAlarm: Bool
    }

    @Published private(set) var timers: [PalTimer] = []
    var onFire: ((PalTimer) -> Void)?
    private var ticker: Timer?

    func start() {
        timers = (Store.load([PalTimer].self, "timers.json") ?? []).filter { $0.fireDate > Date().addingTimeInterval(-3600) }
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    @discardableResult
    func add(label: String, at date: Date, alarm: Bool) -> PalTimer {
        let t = PalTimer(label: label, fireDate: date, isAlarm: alarm)
        timers.append(t)
        timers.sort { $0.fireDate < $1.fireDate }
        save()
        return t
    }

    func cancel(_ id: String) {
        timers.removeAll { $0.id == id || $0.id.hasPrefix(id) || $0.label.localizedCaseInsensitiveCompare(id) == .orderedSame }
        save()
    }

    private func tick() {
        let now = Date()
        let due = timers.filter { $0.fireDate <= now }
        guard !due.isEmpty else { return }
        timers.removeAll { $0.fireDate <= now }
        save()
        due.forEach { onFire?($0) }
    }

    private func save() { Store.save(timers, "timers.json") }
}
