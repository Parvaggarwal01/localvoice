import Foundation

// Pure, Foundation-only meeting logic. Everything here is covered by Tests/MeetingsTests.swift.
// Contract: hive/shared/meetings-contract.md (localvoice.agenda/1, localvoice.meeting/1).

enum MeetingDeviceType: String, Codable, CaseIterable {
    case personal
    case company

    var defaultLabel: String { self == .personal ? "Personal Mac" : "Company Mac" }
}

enum MeetingSource: String, Codable {
    case calendar
    case detected
    case manual
}

struct MeetingSettings: Equatable {
    var enabled = false
    var meetingsChannelID = ""
    var syncChannelID = ""
    var deviceType: MeetingDeviceType = .personal
    var deviceLabel = MeetingDeviceType.personal.defaultLabel
    var reminderLeadMinutes = 5
    /// Delete meeting audio once the day it was recorded is over (transcripts are kept). Default on.
    var deleteAudioAfterDay = true

    private enum Key {
        static let enabled = "meetings.enabled"
        static let meetingsChannel = "meetings.meetingsChannelID"
        static let syncChannel = "meetings.syncChannelID"
        static let deviceType = "meetings.deviceType"
        static let deviceLabel = "meetings.deviceLabel"
        static let reminderLead = "meetings.reminderLeadMinutes"
        static let deleteAudio = "meetings.deleteAudioAfterDay"
    }

    static func load(from defaults: UserDefaults) -> MeetingSettings {
        var settings = MeetingSettings()
        settings.enabled = defaults.bool(forKey: Key.enabled)
        settings.meetingsChannelID = defaults.string(forKey: Key.meetingsChannel) ?? ""
        settings.syncChannelID = defaults.string(forKey: Key.syncChannel) ?? ""
        settings.deviceType = defaults.string(forKey: Key.deviceType).flatMap(MeetingDeviceType.init(rawValue:)) ?? .personal
        settings.deviceLabel = defaults.string(forKey: Key.deviceLabel) ?? settings.deviceType.defaultLabel
        if defaults.object(forKey: Key.reminderLead) != nil {
            settings.reminderLeadMinutes = max(0, min(60, defaults.integer(forKey: Key.reminderLead)))
        }
        if defaults.object(forKey: Key.deleteAudio) != nil {
            settings.deleteAudioAfterDay = defaults.bool(forKey: Key.deleteAudio)
        }
        return settings
    }

    func save(to defaults: UserDefaults) {
        defaults.set(enabled, forKey: Key.enabled)
        defaults.set(meetingsChannelID.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Key.meetingsChannel)
        defaults.set(syncChannelID.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Key.syncChannel)
        defaults.set(deviceType.rawValue, forKey: Key.deviceType)
        defaults.set(deviceLabel, forKey: Key.deviceLabel)
        defaults.set(reminderLeadMinutes, forKey: Key.reminderLead)
        defaults.set(deleteAudioAfterDay, forKey: Key.deleteAudio)
    }

    var trimmedMeetingsChannel: String { meetingsChannelID.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedSyncChannel: String { syncChannelID.trimmingCharacters(in: .whitespacesAndNewlines) }
    var effectiveLabel: String {
        let label = deviceLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? deviceType.defaultLabel : label
    }
}

/// A calendar event, decoupled from EventKit so the agenda logic is testable.
struct CalendarEventInfo: Equatable, Identifiable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var calendar: String
    var account: String
    var joinURL: String?
    var attendees: [String]
    var isAllDay: Bool
    var isDeclined: Bool

    /// Distinguishes occurrences of a recurring event, which share one external identifier.
    var occurrenceKey: String { "\(id)@\(Int(start.timeIntervalSince1970))" }
}

enum MeetingFormat {
    static func iso(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }

    static func clock(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// "42 min", "1 h 05 min", "45 s"
    static func duration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(max(0, seconds)) s" }
        let minutes = Int((Double(seconds) / 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        return String(format: "%d h %02d min", minutes / 60, minutes % 60)
    }

    /// Slack mrkdwn control characters.
    static func slackEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// JSON that Slack will not rewrite: &, <, > become \u escapes (only legal inside JSON strings,
    /// so this is lossless) and JSONEncoder already escapes "/" so URLs are not auto-linked.
    static func slackSafeJSON(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "&", with: "\\u0026")
            .replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: ">", with: "\\u003e")
    }

    private static let joinURLPattern = try! NSRegularExpression(
        pattern: #"https://(?:meet\.google\.com/[a-z0-9-]+|[a-z0-9.-]*zoom\.us/(?:j|my|w)/[^\s<>"')]+|teams\.microsoft\.com/l/meetup-join/[^\s<>"')]+|teams\.live\.com/meet/[^\s<>"')]+|app\.slack\.com/huddle/[^\s<>"')]+)"#,
        options: [.caseInsensitive]
    )

    /// First video-call link found in the event URL, location or notes.
    static func joinURL(in texts: [String?]) -> String? {
        for text in texts.compactMap({ $0 }) where !text.isEmpty {
            let range = NSRange(text.startIndex..., in: text)
            if let match = joinURLPattern.firstMatch(in: text, range: range), let swiftRange = Range(match.range, in: text) {
                return String(text[swiftRange])
            }
        }
        return nil
    }
}

// MARK: - Agenda (contract section 1)

struct AgendaEventPayload: Encodable, Equatable {
    let id: String
    let title: String
    let start: String
    let end: String
    let calendar: String
    let account: String
    let joinURL: String?
    let attendees: [String]
    let allDay: Bool

    enum CodingKeys: String, CodingKey {
        case id, title, start, end, calendar, account, attendees
        case joinURL = "join_url"
        case allDay = "all_day"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(start, forKey: .start)
        try container.encode(end, forKey: .end)
        try container.encode(calendar, forKey: .calendar)
        try container.encode(account, forKey: .account)
        try container.encode(joinURL, forKey: .joinURL) // explicit null when missing
        try container.encode(attendees, forKey: .attendees)
        try container.encode(allDay, forKey: .allDay)
    }
}

struct AgendaPayload: Encodable, Equatable {
    let schema = "localvoice.agenda/1"
    let device: String
    let deviceLabel: String
    let updatedAt: String
    let events: [AgendaEventPayload]

    enum CodingKeys: String, CodingKey {
        case schema, device, events
        case deviceLabel = "device_label"
        case updatedAt = "updated_at"
    }
}

enum AgendaBuilder {
    static let window: TimeInterval = 36 * 3600

    /// Events from now to +36 h, without all-day or declined events, sorted by start.
    static func agendaEvents(_ events: [CalendarEventInfo], now: Date) -> [CalendarEventInfo] {
        let limit = now.addingTimeInterval(window)
        return events
            .filter { !$0.isAllDay && !$0.isDeclined && $0.end > now && $0.start < limit }
            .sorted { $0.start == $1.start ? $0.title < $1.title : $0.start < $1.start }
    }

    static func payload(events: [CalendarEventInfo], settings: MeetingSettings, now: Date, timeZone: TimeZone = .current) -> AgendaPayload {
        AgendaPayload(
            device: settings.deviceType.rawValue,
            deviceLabel: settings.effectiveLabel,
            updatedAt: MeetingFormat.iso(now, timeZone: timeZone),
            events: agendaEvents(events, now: now).map {
                AgendaEventPayload(
                    id: $0.id,
                    title: $0.title,
                    start: MeetingFormat.iso($0.start, timeZone: timeZone),
                    end: MeetingFormat.iso($0.end, timeZone: timeZone),
                    calendar: $0.calendar,
                    account: $0.account,
                    joinURL: $0.joinURL,
                    attendees: $0.attendees,
                    allDay: false
                )
            }
        )
    }

    static func json(_ payload: AgendaPayload) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(payload)) ?? Data("{}".utf8)
        return MeetingFormat.slackSafeJSON(data)
    }

    /// Human line, then the JSON in a code block (contract section 1).
    static func messageText(_ payload: AgendaPayload) -> String {
        let count = payload.events.count
        let noun = count == 1 ? "meeting" : "meetings"
        return "🗓 \(MeetingFormat.slackEscape(payload.deviceLabel)) agenda · \(count) \(noun) · updated \(payload.updatedAt)\n```\n\(json(payload))\n```"
    }
}

// MARK: - Transcript (contract section 2)

struct MeetingSegment: Codable, Equatable {
    var speaker: String
    var start: Double
    var end: Double
    var text: String
}

/// Persisted with the History item, so a failed meeting can be retried after a relaunch.
struct MeetingHistoryInfo: Codable, Equatable {
    var title: String
    var source: MeetingSource
    var calendarEventID: String?
    var startedAt: Date
    var endedAt: Date?
    var attendees: [String]
    var hasSystemAudio: Bool
    var jsonFilename: String?
    var slackPosted: Bool?
    var slackStatus: String?
    /// Set when "Delete meeting audio after the day" removed the audio; the transcript is kept.
    var audioDeletedAt: Date?
}

struct MeetingTranscriptPayload: Encodable {
    struct Channels: Encodable {
        let me = "microphone"
        let others = "system audio"
    }

    let schema = "localvoice.meeting/1"
    let id: String
    let device: String
    let deviceLabel: String
    let title: String
    let calendarEventID: String?
    let startedAt: String
    let endedAt: String
    let durationSec: Int
    let attendees: [String]
    let language: String
    let source: String
    let channels = Channels()
    let segments: [MeetingSegment]
    let text: String

    enum CodingKeys: String, CodingKey {
        case schema, id, device, title, attendees, language, source, channels, segments, text
        case deviceLabel = "device_label"
        case calendarEventID = "calendar_event_id"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case durationSec = "duration_sec"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encode(id, forKey: .id)
        try container.encode(device, forKey: .device)
        try container.encode(deviceLabel, forKey: .deviceLabel)
        try container.encode(title, forKey: .title)
        try container.encode(calendarEventID, forKey: .calendarEventID) // explicit null
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(endedAt, forKey: .endedAt)
        try container.encode(durationSec, forKey: .durationSec)
        try container.encode(attendees, forKey: .attendees)
        try container.encode(language, forKey: .language)
        try container.encode(source, forKey: .source)
        try container.encode(channels, forKey: .channels)
        try container.encode(segments, forKey: .segments)
        try container.encode(text, forKey: .text)
    }
}

enum TranscriptBuilder {
    static func filename(id: UUID) -> String { "meeting-\(id.uuidString.lowercased()).json" }

    static func plainText(_ segments: [MeetingSegment]) -> String {
        segments.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
    }

    static func payload(id: UUID, info: MeetingHistoryInfo, endedAt: Date, settings: MeetingSettings, segments: [MeetingSegment], language: String, timeZone: TimeZone = .current) -> MeetingTranscriptPayload {
        MeetingTranscriptPayload(
            id: id.uuidString.lowercased(),
            device: settings.deviceType.rawValue,
            deviceLabel: settings.effectiveLabel,
            title: info.title,
            calendarEventID: info.calendarEventID,
            startedAt: MeetingFormat.iso(info.startedAt, timeZone: timeZone),
            endedAt: MeetingFormat.iso(endedAt, timeZone: timeZone),
            durationSec: max(0, Int(endedAt.timeIntervalSince(info.startedAt).rounded())),
            attendees: info.attendees,
            language: language,
            source: info.source.rawValue,
            segments: segments,
            text: plainText(segments)
        )
    }

    static func jsonData(_ payload: MeetingTranscriptPayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(payload)
    }

    static func initialComment(title: String, startedAt: Date, endedAt: Date, deviceLabel: String, timeZone: TimeZone = .current) -> String {
        let seconds = max(0, Int(endedAt.timeIntervalSince(startedAt).rounded()))
        return "🎙 Meeting recorded: *\(MeetingFormat.slackEscape(title))* · \(MeetingFormat.clock(startedAt, timeZone: timeZone))–\(MeetingFormat.clock(endedAt, timeZone: timeZone)) · \(MeetingFormat.duration(seconds)) · \(MeetingFormat.slackEscape(deviceLabel))"
    }
}

// MARK: - Deepgram multichannel / diarized response

enum DeepgramMeetingParser {
    enum Layout {
        /// Channel 0 = microphone ("Me"), channel 1 = system audio (diarized "Speaker N").
        case stereo
        /// Microphone only: every voice is on channel 0, so diarization names all speakers.
        case micOnly
    }

    private struct Response: Decodable {
        struct Results: Decodable {
            struct Utterance: Decodable {
                let start: Double
                let end: Double
                let transcript: String
                let channel: Int?
                let speaker: Int?
            }
            struct Channel: Decodable {
                struct Alternative: Decodable {
                    struct Word: Decodable {
                        let word: String
                        let punctuated_word: String?
                        let start: Double
                        let end: Double
                        let speaker: Int?
                    }
                    let transcript: String?
                    let words: [Word]?
                    let languages: [String]?
                }
                let alternatives: [Alternative]
                let detected_language: String?
            }
            let channels: [Channel]
            let utterances: [Utterance]?
        }
        let results: Results
    }

    static func speakerLabel(channel: Int, speaker: Int?, layout: Layout) -> String {
        switch layout {
        case .stereo where channel == 0: return "Me"
        default: return "Speaker \((speaker ?? 0) + 1)"
        }
    }

    static func parse(_ data: Data, layout: Layout) throws -> (segments: [MeetingSegment], language: String) {
        let response = try JSONDecoder().decode(Response.self, from: data)
        var segments: [MeetingSegment] = []
        if let utterances = response.results.utterances, !utterances.isEmpty {
            segments = utterances.compactMap { utterance in
                let text = utterance.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return MeetingSegment(speaker: speakerLabel(channel: utterance.channel ?? 0, speaker: utterance.speaker, layout: layout), start: utterance.start, end: utterance.end, text: text)
            }
        } else {
            for (channelIndex, channel) in response.results.channels.enumerated() {
                for word in channel.alternatives.first?.words ?? [] {
                    let speaker = speakerLabel(channel: channelIndex, speaker: word.speaker, layout: layout)
                    // One segment per word; sorting then mergeTurns rebuilds the turns across channels.
                    segments.append(MeetingSegment(speaker: speaker, start: word.start, end: word.end, text: word.punctuated_word ?? word.word))
                }
            }
        }
        segments.sort { $0.start == $1.start ? $0.speaker < $1.speaker : $0.start < $1.start }
        let first = response.results.channels.first
        let language = first?.detected_language ?? first?.alternatives.first?.languages?.first ?? "en"
        return (mergeTurns(segments), language)
    }

    /// Joins consecutive segments of the same speaker separated by a short pause.
    static func mergeTurns(_ segments: [MeetingSegment], maxGap: Double = 1.5) -> [MeetingSegment] {
        var merged: [MeetingSegment] = []
        for segment in segments {
            if var last = merged.last, last.speaker == segment.speaker, segment.start - last.end <= maxGap {
                last.end = max(last.end, segment.end)
                last.text += " " + segment.text
                merged[merged.count - 1] = last
            } else {
                merged.append(segment)
            }
        }
        return merged
    }
}

// MARK: - Detection and timing rules

enum MeetingApps {
    /// Human name of a meeting app for a process bundle ID (helpers included), or nil.
    static func name(forBundleID bundleID: String) -> String? {
        let id = bundleID.lowercased()
        let table: [(String, String)] = [
            ("us.zoom.", "Zoom"),
            ("com.microsoft.teams", "Microsoft Teams"),
            ("com.tinyspeck.slackmacgap", "Slack huddle"),
            ("com.cisco.webexmeetings", "Webex"),
            ("com.webex.", "Webex"),
            ("com.apple.facetime", "FaceTime"),
            ("com.google.chrome", "Browser call"),
            ("com.apple.safari", "Browser call"),
            ("com.apple.webkit", "Browser call"),
            ("company.thebrowser.", "Browser call"),
            ("com.microsoft.edgemac", "Browser call"),
            ("com.brave.browser", "Browser call"),
            ("org.mozilla.firefox", "Browser call"),
            ("com.vivaldi.vivaldi", "Browser call"),
            ("com.operasoftware.opera", "Browser call")
        ]
        return table.first { id.hasPrefix($0.0) }?.1
    }

    static func isBrowser(bundleID: String) -> Bool { name(forBundleID: bundleID) == "Browser call" }

    /// Window titles that show a browser tab is a call.
    static func browserCallName(windowTitles: [String]) -> String? {
        for title in windowTitles {
            let lower = title.lowercased()
            if lower.contains("meet.google.com") || lower.hasPrefix("meet - ") || lower.contains("google meet") { return "Google Meet" }
            if lower.contains("teams.microsoft.com") || lower.contains("microsoft teams") { return "Microsoft Teams" }
            if lower.contains("zoom meeting") || lower.contains("app.zoom.us") { return "Zoom" }
            if lower.contains("huddle") { return "Slack huddle" }
        }
        return nil
    }
}

enum MeetingTiming {
    /// The pop-up appears from 1 min before start until 10 min after start (or the end, if sooner).
    static func isInPromptWindow(_ event: CalendarEventInfo, now: Date) -> Bool {
        now >= event.start.addingTimeInterval(-60) && now < min(event.end, event.start.addingTimeInterval(600))
    }

    static func eventToPrompt(_ events: [CalendarEventInfo], now: Date, alreadyPrompted: Set<String>) -> CalendarEventInfo? {
        events
            .filter { !$0.isAllDay && !$0.isDeclined && !alreadyPrompted.contains($0.occurrenceKey) && isInPromptWindow($0, now: now) }
            .min { $0.start < $1.start }
    }

    /// The event the user is most likely in right now: running, or starting within 5 min.
    static func currentEvent(_ events: [CalendarEventInfo], now: Date) -> CalendarEventInfo? {
        events
            .filter { !$0.isAllDay && !$0.isDeclined && $0.start.addingTimeInterval(-300) <= now && $0.end > now }
            .min { abs($0.start.timeIntervalSince(now)) < abs($1.start.timeIntervalSince(now)) }
    }

    static func reminderDate(for event: CalendarEventInfo, leadMinutes: Int) -> Date {
        event.start.addingTimeInterval(-Double(leadMinutes) * 60)
    }

    /// Offer to stop once the calendar event (if any) has ended and the call's mic has been idle a while.
    static func shouldOfferStop(eventEnd: Date?, now: Date, callIdleSince: Date?, alreadyOffered: Bool, idleThreshold: TimeInterval = 45) -> Bool {
        guard !alreadyOffered, let callIdleSince, now.timeIntervalSince(callIdleSince) >= idleThreshold else { return false }
        if let eventEnd { return now >= eventEnd }
        return true
    }
}
