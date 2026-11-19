import AVFoundation
import Foundation

// Optional LIVE check (one short Deepgram call, ~15 s of audio): two synthesized voices →
// TrackWriter → stereo mixdown → Deepgram multichannel + diarize → localvoice.meeting/1 JSON.
// Expect "Me" for the first voice and "Speaker 1" for the second.
//   mkdir -p /tmp/lv-live && say -v Samantha -o /tmp/lv-live/me.aiff "Hi everyone, I will share the numbers first." \
//     && say -v Daniel -o /tmp/lv-live/others.aiff "Thanks. Then let's decide the launch date."
//   swiftc -parse-as-library -swift-version 5 Sources/MeetingModels.swift Sources/MeetingRecorder.swift Sources/DeepgramClient.swift \
//     Tests/MeetingLiveCheck.swift -o /tmp/lv-live/check && DEEPGRAM_API_KEY=... /tmp/lv-live/check /tmp/lv-live
@main
enum MeetingLiveCheck {
    static func main() async throws {
        let dir = URL(fileURLWithPath: CommandLine.arguments[1])
        guard let key = ProcessInfo.processInfo.environment["DEEPGRAM_API_KEY"], !key.isEmpty else {
            print("Set DEEPGRAM_API_KEY to run the live check.")
            exit(2)
        }
        func feed(_ name: String, into writer: TrackWriter, at: Date) throws {
            let file = try AVAudioFile(forReading: dir.appendingPathComponent(name))
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buffer)
            writer.append(buffer, arrivedAt: at)
        }
        let start = Date()
        let me = try TrackWriter(url: dir.appendingPathComponent("me.caf"), label: "me")
        let others = try TrackWriter(url: dir.appendingPathComponent("others.caf"), label: "others")
        try feed("me.aiff", into: me, at: start.addingTimeInterval(5))
        try feed("others.aiff", into: others, at: start.addingTimeInterval(11)) // others speak ~6 s later
        me.finish(); others.finish()
        let out = dir.appendingPathComponent("meeting.m4a")
        let stereo = try MeetingRecorder.mixdown(MeetingTracks(meURL: me.url, othersURL: others.url, meStartedAt: me.firstSampleAt, othersStartedAt: others.firstSampleAt), to: out)
        let data = try await DeepgramClient.transcribeMeeting(fileURL: out, apiKey: key, multichannel: stereo)
        let (segments, language) = try DeepgramMeetingParser.parse(data, layout: stereo ? .stereo : .micOnly)
        let info = MeetingHistoryInfo(title: "Live test", source: .manual, calendarEventID: nil, startedAt: start, endedAt: start.addingTimeInterval(15), attendees: [], hasSystemAudio: stereo, jsonFilename: nil, slackPosted: nil, slackStatus: nil)
        let payload = TranscriptBuilder.payload(id: UUID(), info: info, endedAt: start.addingTimeInterval(15), settings: MeetingSettings(), segments: segments, language: language)
        print(String(decoding: try TranscriptBuilder.jsonData(payload), as: UTF8.self))
    }
}
