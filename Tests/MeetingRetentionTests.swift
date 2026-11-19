import Foundation

// Deterministic checks for "Delete meeting audio after the day" (dates, pending steps, in-progress).
//   swiftc -parse-as-library -swift-version 5 Sources/MeetingRetention.swift Tests/MeetingRetentionTests.swift -o /tmp/LocalVoice-retention-check && /tmp/LocalVoice-retention-check

private var failures = 0
private var checks = 0

private func check(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    checks += 1
    if !condition() {
        failures += 1
        print("FAIL (line \(line)): \(message)")
    }
}

private let tz = TimeZone(identifier: "Asia/Kolkata")!
private var cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = tz
    return c
}()

private func local(_ text: String) -> Date {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = tz
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.date(from: text)!
}

private func meeting(start: String, end: String?, state: String = "Ready", transcribed: Bool = true, posted: Bool = true, deleted: Bool = false, id: UUID = UUID()) -> MeetingAudioCandidate {
    MeetingAudioCandidate(id: id, startedAt: local(start), endedAt: end.map(local), state: state, transcribed: transcribed, slackPosted: posted, audioDeleted: deleted)
}

@main
struct MeetingRetentionTests {
    static func main() {
        let now = local("2026-11-19 09:00")
        func decide(_ m: MeetingAudioCandidate, inProgress: Set<UUID> = [], at: Date? = nil) -> MeetingAudioDecision {
            MeetingAudioRetention.decide(m, now: at ?? now, inProgressIDs: inProgress, calendar: cal)
        }

        // Dates: only meetings from a previous local day are deleted.
        check(decide(meeting(start: "2026-11-18 15:00", end: "2026-11-18 16:00")) == .delete, "yesterday, transcribed and posted → delete")
        check(decide(meeting(start: "2026-11-01 10:00", end: "2026-11-01 11:00")) == .delete, "weeks old → delete")
        check(decide(meeting(start: "2026-11-19 00:05", end: "2026-11-19 00:45")) == .keep, "today, just after midnight → keep")
        check(decide(meeting(start: "2026-11-18 23:59", end: "2026-11-18 23:59"), at: local("2026-11-19 00:00")) == .delete, "first minute of the new day → delete yesterday")
        check(decide(meeting(start: "2026-11-18 23:30", end: "2026-11-19 00:30")) == .keep, "crossed midnight: counts by end day → keep")
        check(decide(meeting(start: "2026-11-18 23:30", end: "2026-11-19 00:30"), at: local("2026-11-20 00:01")) == .delete, "crossed midnight, next day → delete")
        check(decide(meeting(start: "2026-11-18 10:00", end: nil, state: "Failed", transcribed: false, posted: false)) == .pendingTranscription, "no end (crash) uses start day; untranscribed → pending")

        // Pending steps keep the audio.
        check(decide(meeting(start: "2026-11-18 10:00", end: "2026-11-18 11:00", state: "Failed", transcribed: false, posted: false)) == .pendingTranscription, "transcription failed → pending transcription")
        check(decide(meeting(start: "2026-11-18 10:00", end: "2026-11-18 11:00", transcribed: true, posted: false)) == .pendingUpload, "Slack upload not done → pending upload")
        check(decide(meeting(start: "2026-11-18 10:00", end: "2026-11-18 11:00", state: "Failed", transcribed: true, posted: true)) == .pendingTranscription, "state not Ready → never delete")
        check(decide(meeting(start: "2026-11-19 08:00", end: "2026-11-19 08:30", transcribed: true, posted: false)) == .keep, "today and pending → keep (no pending flag yet)")

        // In progress is never touched.
        let id = UUID()
        check(decide(meeting(start: "2026-11-18 10:00", end: "2026-11-18 11:00", id: id), inProgress: [id]) == .keep, "in-progress id → keep even if old and done")
        check(decide(meeting(start: "2026-11-18 23:00", end: nil, state: "Recording", transcribed: false, posted: false)) == .keep, "Recording state → keep")
        check(decide(meeting(start: "2026-11-18 10:00", end: "2026-11-18 11:00", state: "Transcribing", transcribed: false, posted: false)) == .keep, "Transcribing state → keep")

        // Already deleted stays a no-op.
        check(decide(meeting(start: "2026-11-10 10:00", end: "2026-11-10 11:00", deleted: true)) == .keep, "already deleted → keep (no work)")

        // Midnight scheduling and file set.
        check(MeetingAudioRetention.nextMidnight(after: local("2026-11-19 09:00"), calendar: cal) == local("2026-11-20 00:00"), "next midnight")
        check(MeetingAudioRetention.nextMidnight(after: local("2026-11-19 00:00"), calendar: cal) == local("2026-11-20 00:00"), "at midnight → the following one")
        check(MeetingAudioRetention.audioFilenames(forAudioFilename: "meeting-abc.m4a") == ["meeting-abc.m4a", "meeting-abc-me.caf", "meeting-abc-others.caf"], "audio files for a meeting")

        print("\(checks - failures)/\(checks) retention checks passed")
        exit(failures == 0 ? 0 : 1)
    }
}
