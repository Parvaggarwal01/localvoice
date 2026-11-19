import AppKit
import AVFoundation
import CoreGraphics
import Foundation
@preconcurrency import UserNotifications

/// Meetings mode: calendar agenda sync, meeting detection and prompts, two-track recording,
/// Deepgram transcription and the Slack transcript upload. Fn dictation is not touched.
@MainActor
final class MeetingController: ObservableObject {
    @Published var settings: MeetingSettings { didSet { settingsChanged(from: oldValue) } }
    @Published private(set) var slackTokenConfigured = SlackKeychain.load() != nil
    @Published private(set) var calendarAccess = false
    @Published private(set) var calendarDenied = false
    @Published private(set) var screenCaptureAccess = CGPreflightScreenCaptureAccess()
    @Published private(set) var upcoming: [CalendarEventInfo] = []
    @Published private(set) var isRecording = false
    @Published private(set) var isStarting = false
    @Published private(set) var processingCount = 0
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var currentTitle: String?
    @Published private(set) var capturingSystemAudio = false
    @Published private(set) var message: String?
    @Published private(set) var connectionMessage: String?
    @Published private(set) var isTestingConnection = false
    @Published private(set) var lastAgendaSync: Date?
    @Published private(set) var agendaSyncError: String?

    weak var appState: AppState?

    private let calendar = CalendarService()
    private let recorder = MeetingRecorder()
    private let bubble = MeetingBubbleController()
    private let prompt = MeetingPromptController()
    private let notificationDelegate = MeetingNotificationDelegate()
    private var detectTimer: Timer?
    private var refreshTimer: Timer?
    private var uiTimer: Timer?
    private var refreshDebounce: Task<Void, Never>?
    private var agendaSyncTask: Task<Void, Never>?

    private var promptedEvents = Set<String>()
    private var dismissedCallApps = Set<String>()
    private var dismissedEvents = Set<String>()
    private var active: ActiveMeeting?

    private struct ActiveMeeting {
        let id: UUID
        var info: MeetingHistoryInfo
        let eventEnd: Date?
        let eventKey: String?
        let callBundleID: String?
        /// The idle clock only runs once a call has actually held the mic, so an in-person
        /// meeting recorded manually is never asked to stop.
        var sawCall: Bool
        let meURL: URL
        let othersURL: URL
        var callIdleSince: Date?
        var stopOffered = false
    }

    init() {
        settings = MeetingSettings.load(from: .standard)
        calendar.onChange = { [weak self] in self?.scheduleRefresh() }
    }

    var isProcessing: Bool { processingCount > 0 }

    /// Called once by AppState after launch.
    func start() {
        if settings.enabled { activate() }
    }

    // MARK: Settings

    private func settingsChanged(from old: MeetingSettings) {
        settings.save(to: .standard)
        if settings.enabled != old.enabled {
            settings.enabled ? activate() : deactivate()
        } else if settings.enabled && (settings.deviceType != old.deviceType || settings.deviceLabel != old.deviceLabel || settings.syncChannelID != old.syncChannelID || settings.reminderLeadMinutes != old.reminderLeadMinutes) {
            scheduleRefresh()
        }
    }

    func setDeviceType(_ type: MeetingDeviceType) {
        let wasDefault = settings.deviceLabel == settings.deviceType.defaultLabel || settings.deviceLabel.isEmpty
        settings.deviceType = type
        if wasDefault { settings.deviceLabel = type.defaultLabel }
    }

    @discardableResult
    func saveSlackToken(_ raw: String) -> Bool {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.hasPrefix("xoxb-") else {
            connectionMessage = "That isn’t a bot token. Paste the Helm app’s Bot User OAuth Token (starts with xoxb-)."
            return false
        }
        do {
            try SlackKeychain.save(token)
            slackTokenConfigured = true
            connectionMessage = "Slack token saved in macOS Keychain."
            scheduleRefresh()
            return true
        } catch {
            connectionMessage = error.localizedDescription
            return false
        }
    }

    func removeSlackToken() {
        SlackKeychain.delete()
        slackTokenConfigured = false
        connectionMessage = "Slack token removed."
    }

    /// auth.test, then a real agenda sync to the sync channel (proves the bot can post there).
    func testConnection() {
        guard let token = SlackKeychain.load() else {
            connectionMessage = "Save the Slack bot token first."
            return
        }
        isTestingConnection = true
        connectionMessage = "Testing Slack…"
        Task {
            defer { isTestingConnection = false }
            do {
                let auth = try await SlackClient(token: token).authTest()
                var lines = ["Connected as \(auth.user) in \(auth.team)."]
                if settings.trimmedSyncChannel.isEmpty {
                    lines.append("Add the sync channel ID to post the agenda.")
                } else {
                    if calendarAccess { refreshEvents() }
                    do {
                        try await syncAgenda(token: token)
                        lines.append("Agenda posted to the sync channel.")
                    } catch {
                        lines.append("Sync channel: \(error.localizedDescription)")
                    }
                }
                if settings.trimmedMeetingsChannel.isEmpty { lines.append("Add the meetings channel ID for transcripts.") }
                connectionMessage = lines.joined(separator: " ")
            } catch {
                connectionMessage = error.localizedDescription
            }
        }
    }

    // MARK: Permissions

    func requestCalendarAccess() {
        Task {
            calendarAccess = await calendar.requestAccess()
            calendarDenied = calendar.accessDenied
            if calendarAccess { refreshAgenda() }
            else { openPrivacySettings("Privacy_Calendars") }
        }
    }

    func requestScreenCaptureAccess() {
        screenCaptureAccess = CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
        if !screenCaptureAccess {
            message = "Turn on LocalVoice in Privacy & Security → Screen & System Audio Recording, then quit and reopen LocalVoice. It is used only to capture the other participants’ audio."
            openPrivacySettings("Privacy_ScreenCapture")
        }
    }

    func openPrivacySettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Lifecycle

    private func activate() {
        calendarAccess = calendar.hasAccess
        calendarDenied = calendar.accessDenied
        screenCaptureAccess = CGPreflightScreenCaptureAccess()
        let center = UNUserNotificationCenter.current()
        center.delegate = notificationDelegate
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        Task {
            if !calendar.hasAccess && !calendar.accessDenied {
                calendarAccess = await calendar.requestAccess()
                calendarDenied = calendar.accessDenied
            }
            refreshAgenda()
        }
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAgenda() }
        }
        detectTimer?.invalidate()
        detectTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func deactivate() {
        refreshTimer?.invalidate()
        detectTimer?.invalidate()
        refreshTimer = nil
        detectTimer = nil
        if !isRecording { prompt.hide() }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: upcoming.map { "lv.meeting.\($0.occurrenceKey)" })
        upcoming = []
    }

    private func scheduleRefresh() {
        refreshDebounce?.cancel()
        refreshDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.refreshAgenda()
        }
    }

    // MARK: Agenda

    private func refreshEvents() {
        calendarAccess = calendar.hasAccess
        let now = Date()
        upcoming = AgendaBuilder.agendaEvents(calendar.events(from: now.addingTimeInterval(-6 * 3600), to: now.addingTimeInterval(AgendaBuilder.window)), now: now)
    }

    func refreshAgenda() {
        guard settings.enabled else { return }
        refreshEvents()
        scheduleReminders()
        guard calendarAccess, let token = SlackKeychain.load(), !settings.trimmedSyncChannel.isEmpty else { return }
        agendaSyncTask?.cancel()
        agendaSyncTask = Task {
            do {
                try await syncAgenda(token: token)
            } catch {
                agendaSyncError = error.localizedDescription
            }
        }
    }

    private func syncAgenda(token: String) async throws {
        let channel = settings.trimmedSyncChannel
        let payload = AgendaBuilder.payload(events: upcoming, settings: settings, now: Date())
        let tsKey = "meetings.agendaTS.\(channel).\(settings.deviceType.rawValue)"
        let ts = try await AgendaSync.publish(client: SlackClient(token: token), channel: channel, text: AgendaBuilder.messageText(payload), savedTS: UserDefaults.standard.string(forKey: tsKey))
        UserDefaults.standard.set(ts, forKey: tsKey)
        lastAgendaSync = Date()
        agendaSyncError = nil
    }

    private func scheduleReminders() {
        let center = UNUserNotificationCenter.current()
        let now = Date()
        var requests: [UNNotificationRequest] = []
        for event in upcoming {
            let fireAt = MeetingTiming.reminderDate(for: event, leadMinutes: settings.reminderLeadMinutes)
            guard fireAt > now else { continue }
            let content = UNMutableNotificationContent()
            content.title = event.title
            content.body = "Starts at \(event.start.formatted(date: .omitted, time: .shortened)). LocalVoice will offer to record it."
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: fireAt.timeIntervalSince(now), repeats: false)
            requests.append(UNNotificationRequest(identifier: "lv.meeting.\(event.occurrenceKey)", content: content, trigger: trigger))
        }
        // Same identifier replaces a pending reminder; only drop reminders for events that are gone.
        let keep = Set(requests.map(\.identifier))
        center.getPendingNotificationRequests { pending in
            let stale = pending.map(\.identifier).filter { $0.hasPrefix("lv.meeting.") && !keep.contains($0) }
            center.removePendingNotificationRequests(withIdentifiers: stale)
        }
        for request in requests { center.add(request) }
    }

    // MARK: Detection

    private func tick() {
        if let active {
            watchForEnd(active)
            return
        }
        guard settings.enabled, !isStarting, appState?.isRecording != true, !prompt.isShowing else { return }
        let now = Date()

        if let event = MeetingTiming.eventToPrompt(upcoming, now: now, alreadyPrompted: promptedEvents) {
            promptedEvents.insert(event.occurrenceKey)
            prompt.show(title: "Record \(event.title)?", subtitle: "Starts \(event.start.formatted(date: .omitted, time: .shortened)) · \(event.calendar)",
                        primary: "Start", secondary: "Not now",
                        onPrimary: { [weak self] in self?.startMeeting(title: event.title, source: .calendar, event: event, callBundleID: nil) },
                        onSecondary: { [weak self] in self?.dismissedEvents.insert(event.occurrenceKey) })
            return
        }

        let call = MeetingDetector.detect(selfCapturing: false)
        // Forget "Not now" once that app releases the mic, so the next call prompts again.
        dismissedCallApps = dismissedCallApps.filter { $0 == call?.bundleID }
        guard let call, !dismissedCallApps.contains(call.bundleID) else { return }
        let event = MeetingTiming.currentEvent(upcoming, now: now)
        if let event, dismissedEvents.contains(event.occurrenceKey) { return }
        let title = event?.title ?? "\(call.appName) call"
        prompt.show(title: "Record \(title)?", subtitle: "\(call.appName) is using the microphone",
                    primary: "Start", secondary: "Not now",
                    onPrimary: { [weak self] in self?.startMeeting(title: title, source: .detected, event: event, callBundleID: call.bundleID) },
                    onSecondary: { [weak self] in self?.dismissedCallApps.insert(call.bundleID) })
    }

    private func watchForEnd(_ meeting: ActiveMeeting) {
        guard !meeting.stopOffered, !prompt.isShowing else { return }
        let now = Date()
        let stillActive = MeetingDetector.callStillActive(bundleID: meeting.callBundleID)
        var updated = meeting
        if stillActive == true {
            updated.sawCall = true
            updated.callIdleSince = nil
        } else if stillActive == false, updated.sawCall {
            if updated.callIdleSince == nil { updated.callIdleSince = now }
        } else if let end = meeting.eventEnd, now >= end, updated.callIdleSince == nil {
            updated.callIdleSince = end // no call seen or mic state unknown: fall back to the calendar end
        }
        if MeetingTiming.shouldOfferStop(eventEnd: meeting.eventEnd, now: now, callIdleSince: updated.callIdleSince, alreadyOffered: false) {
            updated.stopOffered = true
            prompt.show(title: "Meeting over?", subtitle: "\(meeting.info.title) · \(formatElapsed(elapsed))",
                        primary: "Stop recording", secondary: "Keep recording", timeout: 120,
                        onPrimary: { [weak self] in self?.stopMeeting() },
                        onSecondary: {})
        }
        active = updated
    }

    // MARK: Recording

    /// Manual start from the menu: links the event that is on now, if any.
    func startManual() {
        let event = MeetingTiming.currentEvent(upcoming, now: Date())
        startMeeting(title: event?.title ?? "Meeting \(Date().formatted(date: .abbreviated, time: .shortened))", source: .manual, event: event, callBundleID: nil)
    }

    func toggleManual() {
        isRecording ? stopMeeting() : startManual()
    }

    func startMeeting(title: String, source: MeetingSource, event: CalendarEventInfo?, callBundleID: String?) {
        guard !isRecording, !isStarting else { return }
        prompt.hide()
        isStarting = true
        message = "Starting meeting recording…"
        Task {
            defer { isStarting = false }
            guard await microphoneAccess() else {
                message = "Allow microphone access for LocalVoice in System Settings → Privacy & Security → Microphone."
                return
            }
            screenCaptureAccess = CGPreflightScreenCaptureAccess()
            if !screenCaptureAccess {
                screenCaptureAccess = CGRequestScreenCaptureAccess()
            }
            let id = UUID()
            let base = "meeting-\(id.uuidString.lowercased())"
            let directory = AppState.recordingsDirectory
            let meURL = directory.appendingPathComponent("\(base)-me.caf")
            let othersURL = directory.appendingPathComponent("\(base)-others.caf")
            do {
                try await recorder.start(meURL: meURL, othersURL: othersURL, captureSystemAudio: screenCaptureAccess)
            } catch {
                message = "Couldn’t start the meeting recording: \(error.localizedDescription)"
                return
            }
            capturingSystemAudio = recorder.isCapturingSystemAudio
            let info = MeetingHistoryInfo(title: title, source: source, calendarEventID: event?.id, startedAt: Date(), endedAt: nil,
                                          attendees: event?.attendees ?? [], hasSystemAudio: capturingSystemAudio,
                                          jsonFilename: nil, slackPosted: nil, slackStatus: nil)
            active = ActiveMeeting(id: id, info: info, eventEnd: event?.end, eventKey: event?.occurrenceKey, callBundleID: callBundleID,
                                   sawCall: callBundleID != nil, meURL: meURL, othersURL: othersURL)
            appState?.addMeetingEntry(HistoryItem(id: id, createdAt: info.startedAt, audioFilename: "\(base).m4a", transcript: "",
                                                  state: "Recording", errorMessage: nil, duration: nil, meeting: info))
            isRecording = true
            currentTitle = title
            elapsed = 0
            if capturingSystemAudio {
                message = "Recording \(title): your mic and the other participants."
            } else {
                message = "Recording \(title) from your mic only. Other participants need Screen & System Audio Recording permission (Settings → Meetings)."
            }
            bubble.show(title: title) { [weak self] in self?.stopMeeting() }
            uiTimer?.invalidate()
            uiTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.updateBubble() }
            }
            if let sound = NSSound(named: NSSound.Name("Pop")) { sound.play() }
        }
    }

    private func updateBubble() {
        guard let active else { return }
        elapsed = Date().timeIntervalSince(active.info.startedAt)
        bubble.update(level: recorder.level, elapsed: elapsed)
    }

    func stopMeeting() {
        guard var meeting = active else { return }
        active = nil
        prompt.hide()
        // The call may continue after you stop: don't ask to record it again.
        if let key = meeting.eventKey { dismissedEvents.insert(key) }
        if let call = meeting.callBundleID ?? MeetingDetector.detect(selfCapturing: true)?.bundleID { dismissedCallApps.insert(call) }
        uiTimer?.invalidate()
        uiTimer = nil
        bubble.hide()
        isRecording = false
        currentTitle = nil
        let endedAt = Date()
        meeting.info.endedAt = endedAt
        let info = meeting.info
        appState?.updateMeetingEntry(meeting.id) {
            $0.meeting = info
            $0.duration = endedAt.timeIntervalSince(info.startedAt)
            $0.state = "Transcribing"
        }
        message = "Saving \(info.title)…"
        if let sound = NSSound(named: NSSound.Name("Glass")) { sound.play() }
        processingCount += 1
        Task {
            defer { processingCount -= 1 }
            let tracks = await recorder.stop()
            await process(id: meeting.id, tracks: tracks)
        }
    }

    func stopForQuit() {
        guard isRecording else { return }
        // Close the track files so they stay readable; History offers Retry after relaunch.
        uiTimer?.invalidate()
        bubble.hide()
        recorder.stopImmediately()
    }

    // MARK: Processing

    /// Mixdown → Deepgram → meeting-<id>.json → Slack. Each step can be retried from History.
    private func process(id: UUID, tracks: MeetingTracks?) async {
        guard let item = appState?.entries.first(where: { $0.id == id }), var info = item.meeting else { return }
        let output = item.audioURL
        do {
            let base = output.deletingPathExtension().lastPathComponent
            let meURL = tracks?.meURL ?? AppState.recordingsDirectory.appendingPathComponent("\(base)-me.caf")
            let othersCandidate = tracks?.othersURL ?? AppState.recordingsDirectory.appendingPathComponent("\(base)-others.caf")
            let othersURL = FileManager.default.fileExists(atPath: othersCandidate.path) ? othersCandidate : nil
            if FileManager.default.fileExists(atPath: meURL.path) {
                let mixTracks = MeetingTracks(meURL: meURL, othersURL: othersURL, meStartedAt: tracks?.meStartedAt, othersStartedAt: tracks?.othersStartedAt)
                let stereo = try await Task.detached { try MeetingRecorder.mixdown(mixTracks, to: output) }.value
                info.hasSystemAudio = stereo
                try? FileManager.default.removeItem(at: meURL)
                if let othersURL { try? FileManager.default.removeItem(at: othersURL) }
            }
            guard FileManager.default.fileExists(atPath: output.path) else { throw MeetingRecorderError.mixdownFailed }
        } catch {
            fail(id, "Couldn’t save the meeting audio: \(error.localizedDescription)")
            return
        }
        let savedInfo = info
        appState?.updateMeetingEntry(id) { $0.meeting = savedInfo }

        guard let apiKey = appState?.transcriptionAPIKey else {
            appState?.updateMeetingEntry(id) { $0.state = "Failed"; $0.errorMessage = "Meeting audio saved. Add your Deepgram API key, then retry from History." }
            message = "Meeting saved. Add your Deepgram key to transcribe it."
            return
        }

        message = "Transcribing \(info.title) with Deepgram…"
        let segments: [MeetingSegment]
        let language: String
        do {
            let data = try await DeepgramClient.transcribeMeeting(fileURL: output, apiKey: apiKey, multichannel: info.hasSystemAudio)
            (segments, language) = try DeepgramMeetingParser.parse(data, layout: info.hasSystemAudio ? .stereo : .micOnly)
        } catch {
            fail(id, error.localizedDescription)
            return
        }
        guard !segments.isEmpty else {
            fail(id, "Deepgram found no speech in this meeting. The audio is still saved.")
            return
        }

        let endedAt = info.endedAt ?? info.startedAt.addingTimeInterval(item.duration ?? 0)
        let payload = TranscriptBuilder.payload(id: id, info: info, endedAt: endedAt, settings: settings, segments: segments, language: language)
        let filename = TranscriptBuilder.filename(id: id)
        let jsonURL = AppState.recordingsDirectory.appendingPathComponent(filename)
        do {
            let data = try TranscriptBuilder.jsonData(payload)
            try data.write(to: jsonURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: jsonURL.path)
        } catch {
            fail(id, "Couldn’t save the transcript file: \(error.localizedDescription)")
            return
        }
        info.jsonFilename = filename
        let finalInfo = info
        appState?.updateMeetingEntry(id) {
            $0.meeting = finalInfo
            $0.transcript = payload.text
            $0.state = "Ready"
            $0.errorMessage = nil
        }
        message = "Transcribed \(info.title)."
        await upload(id: id)
    }

    private func fail(_ id: UUID, _ reason: String) {
        appState?.updateMeetingEntry(id) { $0.state = "Failed"; $0.errorMessage = reason }
        message = reason
    }

    /// Uploads meeting-<id>.json to the meetings channel (contract section 2).
    func upload(id: UUID) async {
        guard let item = appState?.entries.first(where: { $0.id == id }), let info = item.meeting, let filename = info.jsonFilename else { return }
        guard let token = SlackKeychain.load(), !settings.trimmedMeetingsChannel.isEmpty else {
            setSlack(id, posted: false, status: "Not posted: add the Slack token and meetings channel in Settings → Meetings.")
            return
        }
        do {
            let data = try Data(contentsOf: AppState.recordingsDirectory.appendingPathComponent(filename))
            let endedAt = info.endedAt ?? info.startedAt.addingTimeInterval(item.duration ?? 0)
            let comment = TranscriptBuilder.initialComment(title: info.title, startedAt: info.startedAt, endedAt: endedAt, deviceLabel: settings.effectiveLabel)
            _ = try await SlackClient(token: token).uploadFile(channelID: settings.trimmedMeetingsChannel, filename: filename, title: info.title, data: data, initialComment: comment)
            setSlack(id, posted: true, status: "Posted to Slack \(Date().formatted(date: .abbreviated, time: .shortened)).")
            message = "Posted \(info.title) to Slack."
        } catch {
            setSlack(id, posted: false, status: "Slack upload failed: \(error.localizedDescription)")
            message = "Transcript saved, but the Slack upload failed. Retry from History."
        }
    }

    private func setSlack(_ id: UUID, posted: Bool, status: String) {
        appState?.updateMeetingEntry(id) {
            $0.meeting?.slackPosted = posted
            $0.meeting?.slackStatus = status
        }
    }

    /// From History: re-run whatever failed (audio mixdown, transcription, upload).
    func retry(_ item: HistoryItem) {
        guard item.isMeeting, item.state != "Recording", item.state != "Transcribing" else { return }
        appState?.updateMeetingEntry(item.id) { $0.state = "Transcribing"; $0.errorMessage = nil }
        processingCount += 1
        Task {
            defer { processingCount -= 1 }
            await process(id: item.id, tracks: nil)
        }
    }

    func retryUpload(_ item: HistoryItem) {
        Task { await upload(id: item.id) }
    }

    private func microphoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
            }
        default: return false
        }
    }

    func formatElapsed(_ value: TimeInterval) -> String {
        let total = Int(value)
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60) : String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Shows meeting reminders even while LocalVoice is the frontmost app.
private final class MeetingNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
