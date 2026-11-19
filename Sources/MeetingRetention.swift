import Foundation

/// Pure rule for "Delete meeting audio after the day". Foundation only, so Tests/MeetingRetentionTests.swift
/// can check it without the app. Transcripts (History text + meeting-<id>.json) are never touched; Fn
/// dictation items are never passed in.
struct MeetingAudioCandidate: Equatable {
    var id: UUID
    /// When the meeting started and ended (nil while recording or after a crash).
    var startedAt: Date
    var endedAt: Date?
    /// History state: "Recording", "Transcribing", "Ready" or "Failed".
    var state: String
    /// True once meeting-<id>.json was written (transcription succeeded).
    var transcribed: Bool
    /// True once the transcript was uploaded to Slack.
    var slackPosted: Bool
    /// True when the audio was already deleted by an earlier pass.
    var audioDeleted: Bool
}

enum MeetingAudioDecision: Equatable {
    /// Recorded today, already deleted, or in progress: leave it alone.
    case keep
    /// From a previous day, transcribed and posted: delete the audio files.
    case delete
    /// From a previous day, but a step has not succeeded yet: keep the audio and retry that step.
    case pendingTranscription
    case pendingUpload
}

enum MeetingAudioRetention {
    /// Decides one meeting. `inProgressID` is the meeting being recorded or processed right now.
    static func decide(_ meeting: MeetingAudioCandidate, now: Date, inProgressIDs: Set<UUID> = [], calendar: Calendar = .current) -> MeetingAudioDecision {
        if meeting.audioDeleted { return .keep }
        if inProgressIDs.contains(meeting.id) || meeting.state == "Recording" || meeting.state == "Transcribing" { return .keep }
        // The day that counts is the day the meeting ended, so a meeting across midnight keeps its audio
        // until the end of the day it finished.
        let day = meeting.endedAt ?? meeting.startedAt
        if calendar.startOfDay(for: day) >= calendar.startOfDay(for: now) { return .keep }
        if !meeting.transcribed || meeting.state != "Ready" { return .pendingTranscription }
        if !meeting.slackPosted { return .pendingUpload }
        return .delete
    }

    /// Next local midnight after `date`; the app runs a pass then.
    static func nextMidnight(after date: Date, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: 1, to: start) ?? date.addingTimeInterval(86_400)
    }

    /// Audio files that belong to a meeting item: the stereo mixdown and the two raw tracks.
    static func audioFilenames(forAudioFilename audioFilename: String) -> [String] {
        let base = (audioFilename as NSString).deletingPathExtension
        return [audioFilename, "\(base)-me.caf", "\(base)-others.caf"]
    }
}
