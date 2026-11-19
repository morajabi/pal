import Foundation

enum ToolCategory: String, CaseIterable, Identifiable {
    case pal, memory, skills, reminders, calendar, contacts, timers, apps, system, computer
    var id: String { rawValue }

    var title: String {
        switch self {
        case .pal: "Agents & Schedules"
        case .memory: "Memory"
        case .skills: "Skills"
        case .reminders: "Reminders"
        case .calendar: "Calendar"
        case .contacts: "Contacts"
        case .timers: "Timers & Alarms"
        case .apps: "Apps & Shortcuts"
        case .system: "System"
        case .computer: "Computer Use"
        }
    }

    var icon: String {
        switch self {
        case .pal: "sparkles"
        case .memory: "brain"
        case .skills: "book.closed"
        case .reminders: "checklist"
        case .calendar: "calendar"
        case .contacts: "person.crop.circle"
        case .timers: "timer"
        case .apps: "square.grid.2x2"
        case .system: "gearshape"
        case .computer: "cursorarrow.motionlines"
        }
    }

    var permission: PermissionKind? {
        switch self {
        case .reminders: .reminders
        case .calendar: .calendars
        case .contacts: .contacts
        case .computer: .accessibility
        default: nil
        }
    }
}

/// JSON-schema property, kept small on purpose.
indirect enum Prop {
    case string(String)
    case integer(String)
    case number(String)
    case boolean(String)
    case oneOf([String], String)
    case array(Prop, String)

    var json: [String: Any] {
        switch self {
        case .string(let d): return ["type": "string", "description": d]
        case .integer(let d): return ["type": "integer", "description": d]
        case .number(let d): return ["type": "number", "description": d]
        case .boolean(let d): return ["type": "boolean", "description": d]
        case .oneOf(let values, let d): return ["type": "string", "enum": values, "description": d]
        case .array(let item, let d): return ["type": "array", "items": item.json, "description": d]
        }
    }
}

struct ToolContext {
    /// "main" for the quick answerer, otherwise the agent session id.
    var sessionID: String
    var tier: Tier
}

enum ToolContent {
    case text(String)
    case image(Data, mime: String)
}

struct ToolOutput {
    var content: [ToolContent]
    var isError = false

    static func text(_ s: String) -> ToolOutput { ToolOutput(content: [.text(s)]) }
    static func error(_ s: String) -> ToolOutput { ToolOutput(content: [.text(s)], isError: true) }
    static func json(_ value: Any) -> ToolOutput {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return .text(String(data: data, encoding: .utf8) ?? "{}")
    }
}

/// Arguments from the model, with forgiving accessors.
struct ToolArgs {
    let raw: [String: Any]

    func string(_ k: String) -> String? {
        if let s = raw[k] as? String { return s.isEmpty ? nil : s }
        if let n = raw[k] as? NSNumber { return n.stringValue }
        return nil
    }
    func required(_ k: String) throws -> String {
        guard let s = string(k) else { throw PalError("Missing “\(k)”.") }
        return s
    }
    func int(_ k: String) -> Int? {
        if let n = raw[k] as? NSNumber { return n.intValue }
        if let s = raw[k] as? String { return Int(s) }
        return nil
    }
    func double(_ k: String) -> Double? {
        if let n = raw[k] as? NSNumber { return n.doubleValue }
        if let s = raw[k] as? String { return Double(s) }
        return nil
    }
    func bool(_ k: String) -> Bool? {
        if let b = raw[k] as? Bool { return b }
        if let s = raw[k] as? String { return ["true", "yes", "1"].contains(s.lowercased()) }
        return nil
    }
    func strings(_ k: String) -> [String] {
        (raw[k] as? [Any])?.compactMap { $0 as? String } ?? []
    }
}

struct PalTool {
    typealias Handler = @MainActor (ToolArgs, ToolContext) async throws -> ToolOutput

    let name: String
    /// Short, human: shown in Settings.
    let title: String
    /// For the model.
    let description: String
    let category: ToolCategory
    let tiers: Set<Tier>
    let props: [String: Prop]
    let required: [String]
    let run: Handler

    init(_ name: String, _ title: String, category: ToolCategory, tiers: Set<Tier> = [.quick, .agent],
         description: String, props: [String: Prop] = [:], required: [String] = [], run: @escaping Handler) {
        self.name = name
        self.title = title
        self.description = description
        self.category = category
        self.tiers = tiers
        self.props = props
        self.required = required
        self.run = run
    }

    var mcpDescriptor: [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": [
                "type": "object",
                "properties": props.mapValues { $0.json },
                "required": required,
            ] as [String: Any],
        ]
    }
}

/// Every tool Pal offers. Tool groups register themselves at launch.
@MainActor
final class ToolRegistry {
    static let shared = ToolRegistry()
    private(set) var tools: [PalTool] = []

    func register(_ group: [PalTool]) { tools += group }

    func tools(in category: ToolCategory) -> [PalTool] { tools.filter { $0.category == category } }

    func available(for tier: Tier) -> [PalTool] {
        let c = PalSettings.c
        return tools.filter { tool in
            guard tool.tiers.contains(tier), c.isToolEnabled(tool.name) else { return false }
            if (tool.category == .memory) && !c.memoryEnabled { return false }
            return true
        }
    }

    func call(_ name: String, args: [String: Any], context: ToolContext) async -> ToolOutput {
        guard let tool = available(for: context.tier).first(where: { $0.name == name }) else {
            return .error("The tool “\(name)” is turned off or doesn't exist.")
        }
        do {
            log.notice("tool \(name, privacy: .public) from \(context.sessionID, privacy: .public)")
            return try await tool.run(ToolArgs(raw: args), context)
        } catch {
            return .error(error.localizedDescription)
        }
    }
}

// MARK: - Dates the models send us

enum ToolDates {
    static func parse(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = .current
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    static func format(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    static func human(_ d: Date) -> String {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: d)
    }
}
