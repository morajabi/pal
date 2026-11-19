import Foundation
import EventKit
import Contacts

/// Reminders, Calendar and Contacts through Apple's frameworks.
enum MacDataTools {
    @MainActor
    static var all: [PalTool] { reminders + calendar + contacts }

    @MainActor private static var store: EKEventStore { Permissions.shared.eventStore }

    // MARK: Reminders

    @MainActor
    static var reminders: [PalTool] {
        [
            PalTool("list_reminders", "List reminders", category: .reminders,
                    description: "List incomplete reminders, optionally from one list or due before a date.",
                    props: ["list": .string("Reminders list name"), "due_before": .string("ISO 8601 date-time"),
                            "include_completed": .boolean("Include completed ones")]) { a, _ in
                try await Permissions.shared.require(.reminders)
                let calendars = try reminderLists(a.string("list"))
                let predicate: NSPredicate = a.bool("include_completed") == true
                    ? store.predicateForReminders(in: calendars)
                    : store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: ToolDates.parse(a.string("due_before")), calendars: calendars)
                let items = await withCheckedContinuation { (c: CheckedContinuation<[EKReminder], Never>) in
                    store.fetchReminders(matching: predicate) { c.resume(returning: $0 ?? []) }
                }
                let lines = items.prefix(60).map { r -> String in
                    var s = "- \(r.title ?? "(untitled)")"
                    if let d = r.dueDateComponents?.date { s += " · due \(ToolDates.human(d))" }
                    s += " · \(r.calendar.title) · id \(r.calendarItemIdentifier)"
                    if r.isCompleted { s += " · done" }
                    return s
                }
                return .text(lines.isEmpty ? "No reminders." : lines.joined(separator: "\n"))
            },
            PalTool("create_reminder", "Add a reminder", category: .reminders,
                    description: "Add a reminder to Apple Reminders.",
                    props: ["title": .string("What to remember"), "due": .string("ISO 8601 local date-time (optional)"),
                            "notes": .string("Notes"), "list": .string("List name (default list if omitted)")],
                    required: ["title"]) { a, _ in
                try await Permissions.shared.require(.reminders)
                let r = EKReminder(eventStore: store)
                r.title = try a.required("title")
                r.notes = a.string("notes")
                r.calendar = try reminderLists(a.string("list"))?.first ?? store.defaultCalendarForNewReminders()
                if let due = ToolDates.parse(a.string("due")) {
                    r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
                    r.addAlarm(EKAlarm(absoluteDate: due))
                }
                try store.save(r, commit: true)
                return .text("Added “\(r.title ?? "")” to \(r.calendar.title).")
            },
            PalTool("complete_reminder", "Complete a reminder", category: .reminders,
                    description: "Mark a reminder done by id (from list_reminders).",
                    props: ["id": .string("Reminder id")], required: ["id"]) { a, _ in
                try await Permissions.shared.require(.reminders)
                guard let r = store.calendarItem(withIdentifier: try a.required("id")) as? EKReminder else { return .error("No such reminder.") }
                r.isCompleted = true
                try store.save(r, commit: true)
                return .text("Marked “\(r.title ?? "")” done.")
            },
        ]
    }

    @MainActor private static func reminderLists(_ name: String?) throws -> [EKCalendar]? {
        guard let name else { return nil }
        let match = store.calendars(for: .reminder).filter { $0.title.localizedCaseInsensitiveContains(name) }
        guard !match.isEmpty else { throw PalError("No reminders list called “\(name)”.") }
        return match
    }

    // MARK: Calendar

    @MainActor
    static var calendar: [PalTool] {
        [
            PalTool("list_events", "List events", category: .calendar,
                    description: "List calendar events in a date range (defaults to today).",
                    props: ["start": .string("ISO 8601 start (default: now)"), "end": .string("ISO 8601 end (default: end of today)"),
                            "calendar": .string("Only this calendar")]) { a, _ in
                try await Permissions.shared.require(.calendars)
                let start = ToolDates.parse(a.string("start")) ?? Calendar.current.startOfDay(for: Date())
                let end = ToolDates.parse(a.string("end")) ?? Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: start))!
                var cals: [EKCalendar]?
                if let name = a.string("calendar") { cals = store.calendars(for: .event).filter { $0.title.localizedCaseInsensitiveContains(name) } }
                let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: cals))
                let f = DateFormatter()
                f.dateFormat = "EEE d MMM HH:mm"
                let lines = events.prefix(80).map { e -> String in
                    var s = "- \(e.isAllDay ? "All day" : f.string(from: e.startDate)) \(e.title ?? "(untitled)")"
                    if !e.isAllDay { s += " (until \(f.string(from: e.endDate)))" }
                    if let loc = e.location, !loc.isEmpty { s += " @ \(loc)" }
                    s += " · \(e.calendar.title)"
                    return s
                }
                return .text(lines.isEmpty ? "Nothing on the calendar then." : lines.joined(separator: "\n"))
            },
            PalTool("create_event", "Add an event", category: .calendar,
                    description: "Add an event to the calendar.",
                    props: ["title": .string("Title"), "start": .string("ISO 8601 local start"), "end": .string("ISO 8601 end (default: 1 hour later)"),
                            "location": .string("Location"), "notes": .string("Notes"), "calendar": .string("Calendar name"),
                            "all_day": .boolean("All-day event")],
                    required: ["title", "start"]) { a, _ in
                try await Permissions.shared.require(.calendars)
                guard let start = ToolDates.parse(a.string("start")) else { return .error("Couldn't read the start time.") }
                let e = EKEvent(eventStore: store)
                e.title = try a.required("title")
                e.startDate = start
                e.endDate = ToolDates.parse(a.string("end")) ?? start.addingTimeInterval(3600)
                e.isAllDay = a.bool("all_day") ?? false
                e.location = a.string("location")
                e.notes = a.string("notes")
                if let name = a.string("calendar"),
                   let cal = store.calendars(for: .event).first(where: { $0.title.localizedCaseInsensitiveContains(name) && $0.allowsContentModifications }) {
                    e.calendar = cal
                } else {
                    e.calendar = store.defaultCalendarForNewEvents
                }
                try store.save(e, span: .thisEvent, commit: true)
                return .text("Added “\(e.title ?? "")” on \(ToolDates.human(start)) to \(e.calendar.title).")
            },
        ]
    }

    // MARK: Contacts

    @MainActor
    static var contacts: [PalTool] {
        [
            PalTool("search_contacts", "Find a contact", category: .contacts,
                    description: "Look up people in Contacts by name, returning phones, emails, birthday and address.",
                    props: ["query": .string("Name or part of it")], required: ["query"]) { a, _ in
                try await Permissions.shared.require(.contacts)
                let query = try a.required("query")
                let keys: [CNKeyDescriptor] = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactOrganizationNameKey,
                                               CNContactPhoneNumbersKey, CNContactEmailAddressesKey, CNContactBirthdayKey,
                                               CNContactPostalAddressesKey, CNContactRelationsKey] as [CNKeyDescriptor]
                let results = try await Task.detached {
                    try CNContactStore().unifiedContacts(matching: CNContact.predicateForContacts(matchingName: query), keysToFetch: keys)
                }.value
                let lines = results.prefix(10).map { c -> String in
                    var s = "## \([c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " "))"
                    if !c.nickname.isEmpty { s += " (\(c.nickname))" }
                    if !c.organizationName.isEmpty { s += "\nOrganization: \(c.organizationName)" }
                    for p in c.phoneNumbers { s += "\nPhone (\(CNLabeledValue<NSString>.localizedString(forLabel: p.label ?? ""))): \(p.value.stringValue)" }
                    for e in c.emailAddresses { s += "\nEmail: \(e.value)" }
                    if let b = c.birthday, let d = Calendar.current.date(from: b) { s += "\nBirthday: \(DateFormatter.localizedString(from: d, dateStyle: .long, timeStyle: .none))" }
                    for addr in c.postalAddresses { s += "\nAddress: \(CNPostalAddressFormatter.string(from: addr.value, style: .mailingAddress).replacingOccurrences(of: "\n", with: ", "))" }
                    for r in c.contactRelations { s += "\n\(CNLabeledValue<CNContactRelation>.localizedString(forLabel: r.label ?? "")): \(r.value.name)" }
                    return s
                }
                return .text(lines.isEmpty ? "No contacts match “\(query)”." : lines.joined(separator: "\n\n"))
            },
        ]
    }
}
