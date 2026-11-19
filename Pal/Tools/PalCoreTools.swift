import Foundation

/// Agents, schedules, timers, notifications: the tools that make Pal one coherent assistant.
enum PalCoreTools {
    @MainActor
    static var all: [PalTool] { agents + schedules + timers }

    @MainActor
    static var agents: [PalTool] {
        let sm = SessionManager.shared
        return [
            PalTool("start_agent", "Start an agent", category: .pal,
                    description: "Hand a bigger task to a background agent with full access to the Mac (shell, files, apps, browser, computer use). It reports back through Pal. Returns the agent id.",
                    props: [
                        "task": .string("Complete, self-contained instructions including everything the user said"),
                        "title": .string("2–5 word title, e.g. 'Watch Claude sessions'"),
                        "provider": .oneOf(["claude", "codex", "claudeAPI"], "Only if the user asked: claude, codex (ChatGPT) or claudeAPI"),
                        "model": .string("Only if the user asked for a model, e.g. opus, sonnet, gpt-6.2-astra"),
                        "effort": .oneOf(["low", "medium", "high", "xhigh", "max"], "Only if the user asked for more or less thinking"),
                    ], required: ["task", "title"]) { a, ctx in
                let s = try sm.start(task: try a.required("task"), title: a.string("title"),
                                     provider: a.string("provider").flatMap(ProviderID.init(rawValue:)),
                                     model: a.string("model"), effort: a.string("effort"),
                                     origin: ctx.tier == .agent ? "agent \(ctx.sessionID)" : "user")
                return .text("Started agent \(s.id) “\(s.title)” on \(s.provider.title) (\(s.model.model), \(s.model.effort)). It will report back when done.")
            },
            PalTool("list_agents", "List agents", category: .pal,
                    description: "List background agents with status and latest update.") { _, _ in
                let list = sm.sessions.prefix(15).map {
                    "- \($0.id) “\($0.title)” · \($0.status.title)\($0.activity.isEmpty ? "" : " (\($0.activity))") · \($0.provider.title) \($0.model.model) · updated \(ToolDates.human($0.updated))\($0.summary.isEmpty ? "" : "\n  latest: \($0.summary)")"
                }
                return .text(list.isEmpty ? "No agents yet." : list.joined(separator: "\n"))
            },
            PalTool("agent_status", "Check an agent", category: .pal,
                    description: "Read an agent's task and recent activity.",
                    props: ["id": .string("Agent id")], required: ["id"]) { a, _ in
                guard let s = sm.session(try a.required("id")) else { return .error("No such agent.") }
                let recent = s.entries.suffix(12).map { "[\($0.role.rawValue)] \($0.text.prefix(600))" }.joined(separator: "\n")
                return .text("“\(s.title)” · \(s.status.title)\nTask: \(s.task)\n\nRecent:\n\(recent)")
            },
            PalTool("message_agent", "Message an agent", category: .pal,
                    description: "Send instructions or information to a background agent (it wakes up if it was idle).",
                    props: ["id": .string("Agent id"), "message": .string("What to tell it")], required: ["id", "message"]) { a, ctx in
                try sm.send(try a.required("id"), try a.required("message"), from: ctx.tier == .agent ? "agent \(ctx.sessionID)" : "user")
                return .text("Sent.")
            },
            PalTool("stop_agent", "Stop an agent", category: .pal,
                    description: "Stop a background agent.",
                    props: ["id": .string("Agent id")], required: ["id"]) { a, _ in
                let id = try a.required("id")
                guard sm.session(id) != nil else { return .error("No such agent.") }
                sm.stop(id)
                return .text("Stopped.")
            },
            PalTool("notify_user", "Notify the user", category: .pal, tiers: [.agent],
                    description: "Tell the user something now: shows on screen by the Pal dot and as a notification. Use for results that matter, questions you're blocked on, or anything urgent.",
                    props: ["message": .string("What to tell them, one or two sentences"),
                            "urgent": .boolean("True if they should see it right away (plays a sound and speaks if voice is on)")],
                    required: ["message"]) { a, ctx in
                sm.notify(from: ctx.sessionID, try a.required("message"), urgent: a.bool("urgent") ?? false)
                return .text("The user has been notified.")
            },
        ]
    }

    @MainActor
    static var schedules: [PalTool] {
        let sched = Scheduler.shared
        return [
            PalTool("wake_me_in", "Wake an agent later", category: .pal, tiers: [.agent],
                    description: "Schedule yourself to be woken with a message later (for monitoring and waiting). End your turn after calling it.",
                    props: ["minutes": .number("How long to wait"), "note": .string("What to do when you wake up")],
                    required: ["minutes", "note"]) { a, ctx in
                let minutes = max(1, a.double("minutes") ?? 10)
                let job = sched.add(ScheduledJob(title: "Wake \(ctx.sessionID)", prompt: try a.required("note"), repeatRule: .once,
                                                 target: .session(ctx.sessionID), nextRun: Date().addingTimeInterval(minutes * 60),
                                                 createdBy: ctx.sessionID))
                return .text("I'll wake you at \(ToolDates.human(job.nextRun)). End your turn now.")
            },
            PalTool("schedule_task", "Schedule a task", category: .pal,
                    description: "Run something later or on repeat. action 'agent' starts an agent with the prompt (for checks, reports, monitoring); 'notify' just reminds the user with the prompt text. Give exactly one of at, in_minutes, every_minutes, daily_at, weekdays_at.",
                    props: [
                        "title": .string("Short title"),
                        "prompt": .string("For agent: the full task. For notify: the reminder text."),
                        "action": .oneOf(["agent", "notify"], "agent (default) or notify"),
                        "at": .string("ISO 8601 local date-time for a one-off, e.g. 2026-11-20T09:00"),
                        "in_minutes": .number("One-off, this many minutes from now"),
                        "every_minutes": .integer("Repeat every N minutes"),
                        "daily_at": .string("Repeat daily at HH:MM (24h)"),
                        "weekdays_at": .string("Repeat Monday–Friday at HH:MM (24h)"),
                    ], required: ["title", "prompt"]) { a, ctx in
                let (rule, first) = try parseWhen(a)
                let target: ScheduledJob.Target = a.string("action") == "notify" ? .notify : .newAgent
                let job = sched.add(ScheduledJob(title: try a.required("title"), prompt: try a.required("prompt"),
                                                 repeatRule: rule, target: target, nextRun: first, createdBy: ctx.sessionID))
                return .text("Scheduled \(job.id) “\(job.title)”: \(rule.title), next \(ToolDates.human(job.nextRun)).")
            },
            PalTool("list_schedules", "List schedules", category: .pal,
                    description: "List scheduled tasks and wake-ups.") { _, _ in
                let list = sched.jobs.map { "- \($0.id) “\($0.title)” · \($0.repeatRule.title) · next \(ToolDates.human($0.nextRun))\($0.enabled ? "" : " (paused)")" }
                return .text(list.isEmpty ? "Nothing scheduled." : list.joined(separator: "\n"))
            },
            PalTool("cancel_schedule", "Cancel a schedule", category: .pal,
                    description: "Cancel a scheduled task by id.",
                    props: ["id": .string("Schedule id")], required: ["id"]) { a, _ in
                sched.remove(try a.required("id"))
                return .text("Cancelled.")
            },
        ]
    }

    @MainActor
    static var timers: [PalTool] {
        let tc = TimerCenter.shared
        return [
            PalTool("set_timer", "Set a timer", category: .timers,
                    description: "Start a countdown timer. Pal rings and shows it when done.",
                    props: ["minutes": .number("Length in minutes (may be fractional)"), "label": .string("e.g. 'Pasta'")],
                    required: ["minutes"]) { a, _ in
                let minutes = a.double("minutes") ?? 0
                guard minutes > 0 else { return .error("Give a length in minutes.") }
                let t = tc.add(label: a.string("label") ?? "Timer", at: Date().addingTimeInterval(minutes * 60), alarm: false)
                return .text("Timer “\(t.label)” set for \(Self.duration(minutes * 60)), done at \(ToolDates.human(t.fireDate)).")
            },
            PalTool("set_alarm", "Set an alarm", category: .timers,
                    description: "Ring at a specific time.",
                    props: ["at": .string("ISO 8601 local date-time, or HH:MM for the next occurrence"), "label": .string("Label")],
                    required: ["at"]) { a, _ in
                let raw = try a.required("at")
                guard let date = ToolDates.parse(raw) ?? Self.nextTime(raw) else { return .error("Couldn't read the time “\(raw)”.") }
                let t = tc.add(label: a.string("label") ?? "Alarm", at: date, alarm: true)
                return .text("Alarm “\(t.label)” set for \(ToolDates.human(t.fireDate)).")
            },
            PalTool("list_timers", "List timers", category: .timers,
                    description: "List running timers and alarms with time left.") { _, _ in
                let list = tc.timers.map { "- \($0.id) “\($0.label)” · \($0.isAlarm ? "alarm" : "timer") · \(Self.duration($0.fireDate.timeIntervalSinceNow)) left" }
                return .text(list.isEmpty ? "No timers running." : list.joined(separator: "\n"))
            },
            PalTool("cancel_timer", "Cancel a timer", category: .timers,
                    description: "Cancel a timer or alarm by id or label.",
                    props: ["id": .string("Timer id or label")], required: ["id"]) { a, _ in
                tc.cancel(try a.required("id"))
                return .text("Cancelled.")
            },
            PalTool("world_clock", "World clock", category: .timers,
                    description: "Current local time in one or more time zones or cities.",
                    props: ["places": .array(.string("IANA time zone like Asia/Tokyo, or a city name"), "Places to show")],
                    required: ["places"]) { a, _ in
                let f = DateFormatter()
                f.dateFormat = "EEE HH:mm (zzz)"
                let lines = a.strings("places").map { place -> String in
                    let tz = TimeZone(identifier: place) ?? TimeZone.knownTimeZoneIdentifiers
                        .first { $0.lowercased().hasSuffix(place.lowercased().replacingOccurrences(of: " ", with: "_")) }
                        .flatMap(TimeZone.init(identifier:))
                    guard let tz else { return "- \(place): unknown time zone" }
                    f.timeZone = tz
                    return "- \(place): \(f.string(from: Date()))"
                }
                return .text(lines.joined(separator: "\n"))
            },
        ]
    }

    // MARK: Helpers

    @MainActor private static func parseWhen(_ a: ToolArgs) throws -> (ScheduledJob.Repeat, Date) {
        if let at = a.string("at") {
            guard let d = ToolDates.parse(at) ?? nextTime(at) else { throw PalError("Couldn't read “\(at)”.") }
            return (.once, d)
        }
        if let m = a.double("in_minutes") { return (.once, Date().addingTimeInterval(m * 60)) }
        if let every = a.int("every_minutes") {
            let rule = ScheduledJob.Repeat.everyMinutes(max(every, 1))
            return (rule, Date().addingTimeInterval(TimeInterval(max(every, 1) * 60)))
        }
        for (key, weekdays) in [("daily_at", false), ("weekdays_at", true)] {
            guard let s = a.string(key) else { continue }
            let parts = s.split(separator: ":").compactMap { Int($0) }
            guard parts.count >= 2 else { throw PalError("Use HH:MM for \(key).") }
            let rule: ScheduledJob.Repeat = weekdays ? .weekdays(hour: parts[0], minute: parts[1]) : .daily(hour: parts[0], minute: parts[1])
            guard let next = Scheduler.next(after: Date(), rule) else { throw PalError("Couldn't schedule that.") }
            return (rule, next)
        }
        throw PalError("Say when: at, in_minutes, every_minutes, daily_at or weekdays_at.")
    }

    static func nextTime(_ hhmm: String) -> Date? {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        return Calendar.current.nextDate(after: Date(), matching: DateComponents(hour: parts[0], minute: parts[1]), matchingPolicy: .nextTime)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds.rounded()))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return s % 60 == 0 ? "\(s / 60) min" : "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }
}
