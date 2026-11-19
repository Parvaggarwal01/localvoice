import Foundation

// Deterministic checks for the meetings payload builders, Deepgram parsing, timing rules and the
// Slack client (against a mocked URLSession; no network). Build and run:
//   swiftc -parse-as-library -swift-version 5 Sources/MeetingModels.swift Sources/SlackClient.swift Tests/MeetingsTests.swift -o /tmp/LocalVoice-meetings-check && /tmp/LocalVoice-meetings-check

private var failures = 0
private var checks = 0

private func check(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    checks += 1
    if !condition() {
        failures += 1
        print("FAIL (line \(line)): \(message)")
    }
}

private func object(_ string: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(string.utf8))) as? [String: Any] ?? [:]
}

private let utc = TimeZone(identifier: "UTC")!
private let now = ISO8601DateFormatter().date(from: "2026-11-19T07:46:40Z")!

private func event(_ id: String, _ title: String, startIn minutes: Double, length: Double = 30, allDay: Bool = false, declined: Bool = false, url: String? = nil) -> CalendarEventInfo {
    CalendarEventInfo(id: id, title: title, start: now.addingTimeInterval(minutes * 60), end: now.addingTimeInterval((minutes + length) * 60),
                      calendar: "Work", account: "parv@example.com", joinURL: url, attendees: ["Asha", "ben@example.com"], isAllDay: allDay, isDeclined: declined)
}

// MARK: Mock Slack

private final class MockSlack: URLProtocol {
    struct Seen { let path: String; let body: String; let auth: String? }
    nonisolated(unsafe) static var seen: [Seen] = []
    nonisolated(unsafe) static var handler: ((URLRequest, String) -> (Int, String)) = { _, _ in (200, #"{"ok":true}"#) }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
        }
        let text = String(decoding: body, as: UTF8.self)
        Self.seen.append(Seen(path: request.url?.absoluteString ?? "", body: text, auth: request.value(forHTTPHeaderField: "Authorization")))
        let (status, reply) = Self.handler(request, text)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func mockClient() -> SlackClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockSlack.self]
    return SlackClient(token: "xoxb-test", session: URLSession(configuration: configuration))
}

@main
enum MeetingsTests {
    static func main() async {
        agendaTests()
        transcriptTests()
        deepgramTests()
        timingTests()
        detectionTests()
        await slackTests()
        print(failures == 0 ? "meetings: all \(checks) checks passed" : "meetings: \(failures) of \(checks) checks FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    static func agendaTests() {
        var settings = MeetingSettings()
        settings.deviceType = .company
        settings.deviceLabel = "Work <MBP> & co"
        let events = [
            event("b", "Later sync", startIn: 120, url: "https://meet.google.com/abc-defg-hij"),
            event("a", "Standup", startIn: 10),
            event("allday", "Holiday", startIn: 60, allDay: true),
            event("declined", "Declined", startIn: 30, declined: true),
            event("past", "Already over", startIn: -60),
            event("far", "Too far", startIn: 37 * 60),
            event("running", "In progress", startIn: -10)
        ]
        let filtered = AgendaBuilder.agendaEvents(events, now: now)
        check(filtered.map(\.id) == ["running", "a", "b"], "agenda keeps now→+36h, drops all-day/declined/past, sorted; got \(filtered.map(\.id))")

        let payload = AgendaBuilder.payload(events: events, settings: settings, now: now, timeZone: utc)
        let text = AgendaBuilder.messageText(payload)
        let lines = text.components(separatedBy: "\n")
        check(lines.first == "🗓 Work &lt;MBP&gt; &amp; co agenda · 3 meetings · updated 2026-11-19T07:46:40Z", "human line; got \(lines.first ?? "")")
        check(lines[1] == "```" && lines.last == "```" && lines.count == 4, "JSON sits in one code block")
        check(!lines[2].contains("<") && !lines[2].contains(">") && !lines[2].contains("&") && !lines[2].contains("https://"), "code block is Slack-safe (no raw <>& and no linkable URL)")
        let json = object(lines[2])
        check(json["schema"] as? String == "localvoice.agenda/1", "schema")
        check(json["device"] as? String == "company", "device")
        check(json["device_label"] as? String == "Work <MBP> & co", "device_label round-trips through \\u escapes")
        check(json["updated_at"] as? String == "2026-11-19T07:46:40Z", "updated_at")
        let list = json["events"] as? [[String: Any]] ?? []
        check(list.count == 3, "three events")
        let standup = list[1]
        check(standup["id"] as? String == "a" && standup["title"] as? String == "Standup", "event id/title")
        check(standup["start"] as? String == "2026-11-19T07:56:40Z" && standup["end"] as? String == "2026-11-19T08:26:40Z", "event times")
        check(standup["join_url"] is NSNull, "missing join_url is explicit null")
        check(standup["all_day"] as? Bool == false, "all_day false")
        check(standup["calendar"] as? String == "Work" && standup["account"] as? String == "parv@example.com", "calendar/account")
        check((standup["attendees"] as? [String]) == ["Asha", "ben@example.com"], "attendees")
        check(list[2]["join_url"] as? String == "https://meet.google.com/abc-defg-hij", "join_url survives JSON escaping")
        check(Set(standup.keys) == ["id", "title", "start", "end", "calendar", "account", "join_url", "attendees", "all_day"], "exact event keys")

        let empty = AgendaBuilder.messageText(AgendaBuilder.payload(events: [], settings: MeetingSettings(), now: now, timeZone: utc))
        check(empty.hasPrefix("🗓 Personal Mac agenda · 0 meetings"), "empty agenda still posts")

        check(MeetingFormat.joinURL(in: [nil, "Join: https://meet.google.com/xyz-abcd-efg now"]) == "https://meet.google.com/xyz-abcd-efg", "Meet link from notes")
        check(MeetingFormat.joinURL(in: ["Zoom https://us02web.zoom.us/j/123456?pwd=abc"]) == "https://us02web.zoom.us/j/123456?pwd=abc", "Zoom link")
        check(MeetingFormat.joinURL(in: ["<https://teams.microsoft.com/l/meetup-join/19%3ameeting_x/0>"]) == "https://teams.microsoft.com/l/meetup-join/19%3ameeting_x/0", "Teams link without brackets")
        check(MeetingFormat.joinURL(in: ["Room 4", "https://example.com"]) == nil, "no call link")

        let defaults = UserDefaults(suiteName: "lv.meetings.tests.\(UUID().uuidString)")!
        var saved = MeetingSettings()
        saved.enabled = true
        saved.meetingsChannelID = " C123 "
        saved.syncChannelID = "C456"
        saved.deviceType = .company
        saved.deviceLabel = "Company Mac"
        saved.reminderLeadMinutes = 7
        saved.save(to: defaults)
        let loaded = MeetingSettings.load(from: defaults)
        check(loaded.enabled && loaded.meetingsChannelID == "C123" && loaded.syncChannelID == "C456" && loaded.deviceType == .company && loaded.reminderLeadMinutes == 7, "settings round-trip (channel trimmed)")
        check(MeetingSettings.load(from: UserDefaults(suiteName: "lv.meetings.tests.\(UUID().uuidString)")!).reminderLeadMinutes == 5, "default reminder lead is 5 min")
    }

    static func transcriptTests() {
        let id = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
        let started = now
        let ended = now.addingTimeInterval(42 * 60 + 10)
        let info = MeetingHistoryInfo(title: "Weekly sync", source: .calendar, calendarEventID: "evt-1", startedAt: started, endedAt: ended,
                                      attendees: ["Asha"], hasSystemAudio: true, jsonFilename: nil, slackPosted: nil, slackStatus: nil)
        let segments = [
            MeetingSegment(speaker: "Me", start: 0.5, end: 2.0, text: "Hi all."),
            MeetingSegment(speaker: "Speaker 1", start: 2.4, end: 5.0, text: "Hello, let's start.")
        ]
        let payload = TranscriptBuilder.payload(id: id, info: info, endedAt: ended, settings: MeetingSettings(), segments: segments, language: "en", timeZone: utc)
        let json = (try? JSONSerialization.jsonObject(with: TranscriptBuilder.jsonData(payload))) as? [String: Any] ?? [:]
        check(json["schema"] as? String == "localvoice.meeting/1", "meeting schema")
        check(json["id"] as? String == "6f9619ff-8b86-d011-b42d-00c04fc964ff", "lowercase uuid id")
        check(json["device"] as? String == "personal" && json["device_label"] as? String == "Personal Mac", "device fields")
        check(json["title"] as? String == "Weekly sync" && json["calendar_event_id"] as? String == "evt-1", "title / event id")
        check(json["started_at"] as? String == "2026-11-19T07:46:40Z" && json["ended_at"] as? String == "2026-11-19T08:28:50Z", "times")
        check(json["duration_sec"] as? Int == 2530, "duration_sec")
        check(json["source"] as? String == "calendar" && json["language"] as? String == "en", "source/language")
        check((json["channels"] as? [String: String]) == ["me": "microphone", "others": "system audio"], "channels map")
        let segs = json["segments"] as? [[String: Any]] ?? []
        check(segs.count == 2 && segs[0]["speaker"] as? String == "Me" && segs[1]["start"] as? Double == 2.4, "segments")
        check(json["text"] as? String == "Me: Hi all.\nSpeaker 1: Hello, let's start.", "plain text one turn per line")
        check(Set(json.keys) == ["schema", "id", "device", "device_label", "title", "calendar_event_id", "started_at", "ended_at", "duration_sec", "attendees", "language", "source", "channels", "segments", "text"], "exact transcript keys")

        var manual = info
        manual.calendarEventID = nil
        manual.source = .manual
        let manualJSON = (try? JSONSerialization.jsonObject(with: TranscriptBuilder.jsonData(TranscriptBuilder.payload(id: id, info: manual, endedAt: ended, settings: MeetingSettings(), segments: [], language: "en", timeZone: utc)))) as? [String: Any] ?? [:]
        check(manualJSON["calendar_event_id"] is NSNull && manualJSON["source"] as? String == "manual", "null calendar_event_id for manual")

        check(TranscriptBuilder.filename(id: id) == "meeting-6f9619ff-8b86-d011-b42d-00c04fc964ff.json", "filename")
        check(TranscriptBuilder.initialComment(title: "Weekly <sync>", startedAt: started, endedAt: ended, deviceLabel: "Personal Mac", timeZone: utc)
              == "🎙 Meeting recorded: *Weekly &lt;sync&gt;* · 07:46–08:28 · 42 min · Personal Mac", "initial_comment")
        check(MeetingFormat.duration(30) == "30 s" && MeetingFormat.duration(2530) == "42 min" && MeetingFormat.duration(3900) == "1 h 05 min", "duration text")
    }

    static func deepgramTests() {
        let utterances = """
        {"results":{"channels":[{"alternatives":[{"transcript":"x","languages":["hi"]}]},{"alternatives":[{"transcript":"y"}]}],
         "utterances":[
          {"start":3.0,"end":4.0,"transcript":"Sure.","channel":1,"speaker":0},
          {"start":0.2,"end":1.0,"transcript":"Hello team.","channel":0,"speaker":0},
          {"start":1.2,"end":2.0,"transcript":"Quick update.","channel":0,"speaker":0},
          {"start":5.0,"end":6.0,"transcript":"Agreed.","channel":1,"speaker":1},
          {"start":6.5,"end":6.6,"transcript":"  ","channel":1,"speaker":1}
         ]}}
        """
        let stereo = try? DeepgramMeetingParser.parse(Data(utterances.utf8), layout: .stereo)
        check(stereo?.segments.map(\.speaker) == ["Me", "Speaker 1", "Speaker 2"], "stereo: mic is Me, system audio diarized, turns merged; got \(stereo?.segments.map(\.speaker) ?? [])")
        check(stereo?.segments.first?.text == "Hello team. Quick update." && stereo?.segments.first?.end == 2.0, "merged turn text and end")
        check(stereo?.language == "hi", "language from Deepgram")

        let micOnly = try? DeepgramMeetingParser.parse(Data(utterances.utf8), layout: .micOnly)
        check(micOnly?.segments.first?.speaker == "Speaker 1", "mic-only layout never claims 'Me'")

        let words = """
        {"results":{"channels":[
          {"alternatives":[{"transcript":"hi there","words":[{"word":"hi","punctuated_word":"Hi","start":0.0,"end":0.3},{"word":"there","punctuated_word":"there.","start":0.4,"end":0.8}]}]},
          {"alternatives":[{"transcript":"yo","words":[{"word":"yo","start":1.0,"end":1.2,"speaker":2}]}]}
        ]}}
        """
        let fallback = try? DeepgramMeetingParser.parse(Data(words.utf8), layout: .stereo)
        check(fallback?.segments == [MeetingSegment(speaker: "Me", start: 0.0, end: 0.8, text: "Hi there."), MeetingSegment(speaker: "Speaker 3", start: 1.0, end: 1.2, text: "yo")], "word-level fallback; got \(String(describing: fallback?.segments))")
        check(fallback?.language == "en", "language defaults to en")
        check((try? DeepgramMeetingParser.parse(Data("{}".utf8), layout: .stereo)) == nil, "malformed response throws")
    }

    static func timingTests() {
        let standup = event("a", "Standup", startIn: 0.5) // starts in 30 s
        check(MeetingTiming.eventToPrompt([standup], now: now, alreadyPrompted: []) == standup, "prompt from 1 min before start")
        check(MeetingTiming.eventToPrompt([event("a", "Standup", startIn: 2)], now: now, alreadyPrompted: []) == nil, "no prompt 2 min early")
        check(MeetingTiming.eventToPrompt([event("a", "Standup", startIn: -11)], now: now, alreadyPrompted: []) == nil, "no prompt 11 min after start")
        check(MeetingTiming.eventToPrompt([standup], now: now, alreadyPrompted: [standup.occurrenceKey]) == nil, "never prompt twice")
        check(MeetingTiming.eventToPrompt([event("x", "Holiday", startIn: 0, allDay: true)], now: now, alreadyPrompted: []) == nil, "no prompt for all-day")
        let current = MeetingTiming.currentEvent([event("a", "Earlier", startIn: -50, length: 60), event("b", "Now", startIn: -2)], now: now)
        check(current?.id == "b", "current event = closest start among running ones")
        check(MeetingTiming.reminderDate(for: standup, leadMinutes: 5) == standup.start.addingTimeInterval(-300), "reminder lead")

        let idle = now.addingTimeInterval(-60)
        check(MeetingTiming.shouldOfferStop(eventEnd: now.addingTimeInterval(-1), now: now, callIdleSince: idle, alreadyOffered: false), "offer stop: event over + idle")
        check(!MeetingTiming.shouldOfferStop(eventEnd: now.addingTimeInterval(600), now: now, callIdleSince: idle, alreadyOffered: false), "no offer while the event runs")
        check(!MeetingTiming.shouldOfferStop(eventEnd: nil, now: now, callIdleSince: now.addingTimeInterval(-10), alreadyOffered: false), "no offer after a short pause")
        check(MeetingTiming.shouldOfferStop(eventEnd: nil, now: now, callIdleSince: idle, alreadyOffered: false), "no event: idle is enough")
        check(!MeetingTiming.shouldOfferStop(eventEnd: nil, now: now, callIdleSince: idle, alreadyOffered: true), "offer once")
    }

    static func detectionTests() {
        check(MeetingApps.name(forBundleID: "us.zoom.xos") == "Zoom", "Zoom")
        check(MeetingApps.name(forBundleID: "com.microsoft.teams2") == "Microsoft Teams", "Teams")
        check(MeetingApps.name(forBundleID: "com.tinyspeck.slackmacgap.helper") == "Slack huddle", "Slack helper")
        check(MeetingApps.name(forBundleID: "com.google.Chrome.helper") == "Browser call", "Chrome helper")
        check(MeetingApps.isBrowser(bundleID: "com.apple.WebKit.GPU"), "Safari capture process")
        check(MeetingApps.name(forBundleID: "com.apple.dictation") == nil, "unrelated mic user ignored")
        check(MeetingApps.browserCallName(windowTitles: ["Inbox", "Meet - abc-defg-hij"]) == "Google Meet", "Meet tab title")
        check(MeetingApps.browserCallName(windowTitles: ["YouTube"]) == nil, "non-call tab")
    }

    static func slackTests() async {
        let client = mockClient()

        MockSlack.seen = []
        MockSlack.handler = { request, _ in
            switch request.url?.lastPathComponent {
            case "auth.test": return (200, #"{"ok":true,"team":"Parv HQ","user":"helm"}"#)
            default: return (200, #"{"ok":false,"error":"unexpected"}"#)
            }
        }
        let auth = try? await client.authTest()
        check(auth == SlackClient.AuthInfo(team: "Parv HQ", user: "helm"), "auth.test parsed")
        check(MockSlack.seen.first?.auth == "Bearer xoxb-test", "bearer token header")

        // Agenda: edit in place when ts is known.
        MockSlack.seen = []
        MockSlack.handler = { _, _ in (200, #"{"ok":true,"ts":"111.222"}"#) }
        let kept = try? await AgendaSync.publish(client: client, channel: "CSYNC", text: "agenda", savedTS: "111.222")
        check(kept == "111.222" && MockSlack.seen.map { URL(string: $0.path)!.lastPathComponent } == ["chat.update"], "agenda edits in place")
        check(object(MockSlack.seen.first?.body ?? "")["ts"] as? String == "111.222", "chat.update carries ts")

        // Agenda: edit fails → post new.
        MockSlack.seen = []
        MockSlack.handler = { request, _ in
            request.url?.lastPathComponent == "chat.update" ? (200, #"{"ok":false,"error":"message_not_found"}"#) : (200, #"{"ok":true,"ts":"333.444"}"#)
        }
        let replaced = try? await AgendaSync.publish(client: client, channel: "CSYNC", text: "agenda", savedTS: "111.222")
        check(replaced == "333.444" && MockSlack.seen.map { URL(string: $0.path)!.lastPathComponent } == ["chat.update", "chat.postMessage"], "agenda reposts when the edit fails")
        let posted = object(MockSlack.seen.last?.body ?? "")
        check(posted["channel"] as? String == "CSYNC" && posted["text"] as? String == "agenda", "postMessage body")

        // Transcript upload: three-step external upload.
        MockSlack.seen = []
        MockSlack.handler = { request, _ in
            switch request.url?.lastPathComponent {
            case "files.getUploadURLExternal": return (200, #"{"ok":true,"upload_url":"https://files.slack.com/upload/v1/abc","file_id":"F123"}"#)
            case "abc": return (200, "OK - 12")
            case "files.completeUploadExternal": return (200, #"{"ok":true,"files":[{"id":"F123"}]}"#)
            default: return (404, "{}")
            }
        }
        let body = Data(#"{"schema":"localvoice.meeting/1"}"#.utf8)
        let fileID = try? await client.uploadFile(channelID: "CMEET", filename: "meeting-x.json", title: "Weekly sync", data: body, initialComment: "🎙 Meeting recorded: *Weekly sync*")
        check(fileID == "F123", "upload returns file id")
        check(MockSlack.seen.count == 3, "three upload requests; got \(MockSlack.seen.count)")
        if MockSlack.seen.count == 3 {
            check(MockSlack.seen[0].body == "filename=meeting-x.json&length=\(body.count)", "getUploadURLExternal form; got \(MockSlack.seen[0].body)")
            check(MockSlack.seen[1].body == String(decoding: body, as: UTF8.self) && MockSlack.seen[1].auth == nil, "bytes posted to upload_url without the token")
            let complete = MockSlack.seen[2].body
            check(complete.contains("channel_id=CMEET") && complete.contains("initial_comment=%F0%9F%8E%99%20Meeting%20recorded%3A%20%2AWeekly%20sync%2A"), "complete carries channel and comment; got \(complete)")
            let filesValue = complete.components(separatedBy: "&").first { $0.hasPrefix("files=") }?.dropFirst(6).removingPercentEncoding ?? ""
            let files = (try? JSONSerialization.jsonObject(with: Data(filesValue.utf8))) as? [[String: String]]
            check(files == [["id": "F123", "title": "Weekly sync"]], "files JSON; got \(filesValue)")
        }

        // Errors surface readable messages.
        MockSlack.handler = { _, _ in (200, #"{"ok":false,"error":"not_in_channel"}"#) }
        do {
            _ = try await client.postMessage(channel: "C1", text: "x")
            check(false, "not_in_channel must throw")
        } catch {
            check((error as? SlackError) == .api("not_in_channel") && error.localizedDescription.contains("Invite @Helm"), "not_in_channel message")
        }
    }
}
