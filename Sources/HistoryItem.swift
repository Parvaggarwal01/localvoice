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
}
