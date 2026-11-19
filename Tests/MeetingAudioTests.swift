import AVFoundation
import Foundation

// Writes synthetic tones through TrackWriter (48 kHz stereo → 16 kHz mono AAC .caf, the converter
// path the mic uses) and mixes them into the stereo .m4a sent to Deepgram. No microphone needed.
//   swiftc -parse-as-library -swift-version 5 -framework AVFoundation -framework ScreenCaptureKit -framework CoreMedia \
//     Sources/MeetingModels.swift Sources/MeetingRecorder.swift Tests/MeetingAudioTests.swift -o /tmp/LocalVoice-audio-check && /tmp/LocalVoice-audio-check

private func tone(rate: Double, channels: AVAudioChannelCount, seconds: Double, frequency: Float) -> [AVAudioPCMBuffer] {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)!
    var buffers: [AVAudioPCMBuffer] = []
    var phase: Float = 0
    var remaining = Int(rate * seconds)
    while remaining > 0 {
        let count = min(4096, remaining)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        for frame in 0..<count {
            let sample = 0.4 * sin(phase)
            phase += 2 * .pi * frequency / Float(rate)
            for channel in 0..<Int(channels) { buffer.floatChannelData![channel][frame] = sample }
        }
        buffers.append(buffer)
        remaining -= count
    }
    return buffers
}

private func rms(_ file: AVAudioFile, channel: Int, from: AVAudioFramePosition, count: AVAudioFrameCount) -> Float {
    file.framePosition = from
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count)!
    try? file.read(into: buffer, frameCount: count)
    let data = buffer.floatChannelData![channel]
    var sum: Float = 0
    for index in 0..<Int(buffer.frameLength) { sum += data[index] * data[index] }
    return sqrt(sum / Float(max(1, buffer.frameLength)))
}

@main
enum MeetingAudioTests {
    static func main() throws {
        let tmp = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        let dir = tmp.appendingPathComponent("lv-audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let start = Date()
        let me = try TrackWriter(url: dir.appendingPathComponent("me.caf"), label: "me")
        let others = try TrackWriter(url: dir.appendingPathComponent("others.caf"), label: "others")
        for buffer in tone(rate: 48_000, channels: 2, seconds: 3, frequency: 440) { me.append(buffer, arrivedAt: start.addingTimeInterval(3)) }
        // Others start 1 s later and only speak for 2 s.
        for buffer in tone(rate: 16_000, channels: 1, seconds: 2, frequency: 660) { others.append(buffer, arrivedAt: start.addingTimeInterval(3)) }
        me.finish()
        others.finish()
        precondition(me.framesWritten > 47_000 && me.framesWritten < 49_000, "48 kHz stereo converted to ~48k frames at 16 kHz mono; got \(me.framesWritten)")
        precondition(others.framesWritten == 32_000, "others written as-is; got \(others.framesWritten)")

        let tracks = MeetingTracks(meURL: me.url, othersURL: others.url, meStartedAt: start, othersStartedAt: start.addingTimeInterval(1))
        let output = dir.appendingPathComponent("meeting.m4a")
        let stereo = try MeetingRecorder.mixdown(tracks, to: output)
        precondition(stereo, "two tracks give a stereo file")
        let mixed = try AVAudioFile(forReading: output)
        precondition(mixed.fileFormat.channelCount == 2, "stereo m4a")
        precondition(abs(Double(mixed.length) / 16_000 - 3) < 0.2, "≈3 s long; got \(Double(mixed.length) / 16_000)")
        precondition(rms(mixed, channel: 0, from: 8_000, count: 8_000) > 0.1, "left (me) has audio in the first second")
        precondition(rms(mixed, channel: 1, from: 2_000, count: 8_000) < 0.02, "right (others) is silent before they start")
        precondition(rms(mixed, channel: 1, from: 24_000, count: 8_000) > 0.1, "right (others) has audio after 1 s")

        let micOnly = MeetingTracks(meURL: me.url, othersURL: nil, meStartedAt: start, othersStartedAt: nil)
        let monoURL = dir.appendingPathComponent("mono.m4a")
        let monoIsStereo = try MeetingRecorder.mixdown(micOnly, to: monoURL)
        precondition(!monoIsStereo, "mic-only gives mono")
        let monoChannels = try AVAudioFile(forReading: monoURL).fileFormat.channelCount
        precondition(monoChannels == 1, "mono m4a")
        print("meeting audio: all checks passed")
    }
}
