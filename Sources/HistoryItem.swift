import Foundation

struct HistoryItem: Codable, Identifiable {
    var id: UUID
    var createdAt: Date
    var audioFilename: String
    var transcript: String
    var state: String
    var errorMessage: String?
    var duration: TimeInterval?
    /// Set for meeting recordings; nil for Fn dictation. Optional so older history still decodes.
    var meeting: MeetingHistoryInfo?

    var isMeeting: Bool { meeting != nil }

    var audioURL: URL { AppState.recordingsDirectory.appendingPathComponent(audioFilename) }

    /// Input for MeetingAudioRetention; nil for Fn dictation, whose audio is never auto-deleted.
    var audioRetentionCandidate: MeetingAudioCandidate? {
        guard let meeting else { return nil }
        return MeetingAudioCandidate(id: id, startedAt: meeting.startedAt, endedAt: meeting.endedAt, state: state,
                                     transcribed: meeting.jsonFilename != nil, slackPosted: meeting.slackPosted == true,
                                     audioDeleted: meeting.audioDeletedAt != nil)
    }

    /// One line for History about the meeting audio: deleted, or kept because a step is pending.
    func meetingAudioNote(now: Date = Date(), autoDelete: Bool) -> String? {
        guard let meeting else { return nil }
        if meeting.audioDeletedAt != nil { return "Audio deleted, transcript kept" }
        guard autoDelete, let candidate = audioRetentionCandidate else { return nil }
        switch MeetingAudioRetention.decide(candidate, now: now) {
        case .pendingTranscription: return "Audio kept: transcription pending"
        case .pendingUpload: return "Audio kept: Slack upload pending"
        case .keep, .delete: return nil
        }
    }
}
