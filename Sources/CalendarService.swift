import EventKit
import Foundation

/// Reads the calendars already added to macOS Calendar (Google accounts included) through EventKit.
@MainActor
final class CalendarService {
    private let store = EKEventStore()
    private var observer: NSObjectProtocol?
    var onChange: (() -> Void)?

    init() {
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.onChange?() }
        }
    }

    var hasAccess: Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *) { return status == .fullAccess }
        return status.rawValue == 3 // .authorized before macOS 14
    }

    var accessDenied: Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        return status == .denied || status == .restricted
    }

    func requestAccess() async -> Bool {
        if hasAccess { return true }
        do {
            if #available(macOS 14.0, *) {
                return try await store.requestFullAccessToEvents()
            }
            return try await store.requestAccess(to: .event)
        } catch {
            return false
        }
    }

    func events(from start: Date, to end: Date) -> [CalendarEventInfo] {
        guard hasAccess else { return [] }
        store.refreshSourcesIfNecessary()
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).map(Self.info)
    }

    private static func info(_ event: EKEvent) -> CalendarEventInfo {
        let attendees = (event.attendees ?? []).compactMap { participant -> String? in
            if let name = participant.name, !name.isEmpty { return name }
            let address = participant.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
            return address.isEmpty ? nil : address
        }
        let declined = event.attendees?.first(where: \.isCurrentUser)?.participantStatus == .declined
        return CalendarEventInfo(
            id: event.calendarItemExternalIdentifier ?? event.eventIdentifier ?? UUID().uuidString,
            title: (event.title?.isEmpty == false ? event.title : nil) ?? "Untitled meeting",
            start: event.startDate,
            end: event.endDate,
            calendar: event.calendar?.title ?? "",
            account: event.calendar?.source?.title ?? "",
            joinURL: MeetingFormat.joinURL(in: [event.url?.absoluteString, event.location, event.notes]),
            attendees: attendees,
            isAllDay: event.isAllDay,
            isDeclined: declined || event.status == .canceled
        )
    }
}
