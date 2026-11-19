import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Converts incoming audio to 16 kHz mono and appends it to an AAC .caf file as it arrives, so a
/// multi-hour meeting never sits in memory and a crash still leaves a readable file.
final class TrackWriter: @unchecked Sendable {
    static let sampleRate = 16_000.0
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!

    let url: URL
    private let queue: DispatchQueue
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?
    private let lock = NSLock()
    private var _firstSampleAt: Date?
    private var _level: Float = 0
    private(set) var framesWritten: AVAudioFramePosition = 0

    init(url: URL, label: String) throws {
        self.url = url
        queue = DispatchQueue(label: "LocalVoice.track.\(label)")
        file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    var firstSampleAt: Date? { lock.lock(); defer { lock.unlock() }; return _firstSampleAt }
    /// 0…1 peak-ish level of the latest buffer, for the bubble animation.
    var level: Float { lock.lock(); defer { lock.unlock() }; return _level }

    /// Call from any thread; the buffer is copied before the hop to the writer queue.
    func append(_ buffer: AVAudioPCMBuffer, arrivedAt: Date = Date()) {
        guard buffer.frameLength > 0, let copy = Self.copy(buffer) else { return }
        queue.async { [self] in write(copy, arrivedAt: arrivedAt) }
    }

    /// Flushes pending buffers and closes the file.
    func finish() {
        queue.sync {
            file = nil
            converter = nil
        }
    }

    private func write(_ buffer: AVAudioPCMBuffer, arrivedAt: Date) {
        guard let file else { return }
        let output: AVAudioPCMBuffer
        if buffer.format == Self.format {
            output = buffer
        } else {
            if converter == nil || converterInput != buffer.format {
                converter = AVAudioConverter(from: buffer.format, to: Self.format)
                converterInput = buffer.format
            }
            guard let converter else { return }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * Self.sampleRate / buffer.format.sampleRate) + 32
            guard let converted = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: capacity) else { return }
            var fed = false
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, converted.frameLength > 0 else { return }
            output = converted
        }
        do {
            try file.write(from: output)
            lock.lock()
            if _firstSampleAt == nil {
                _firstSampleAt = arrivedAt.addingTimeInterval(-Double(buffer.frameLength) / buffer.format.sampleRate)
            }
            _level = Self.peak(output)
            lock.unlock()
            framesWritten += AVAudioFramePosition(output.frameLength)
        } catch {
            // Disk full or file closed: drop the buffer, keep the meeting going.
        }
    }

    private static func peak(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        var sum: Float = 0
        let count = Int(buffer.frameLength)
        for index in 0..<count { sum += data[index] * data[index] }
        let rms = sqrt(sum / Float(max(count, 1)))
        let decibels = 20 * log10(max(rms, 0.000_01))
        return min(1, max(0, (decibels + 55) / 55))
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(source, target) {
            guard let src = from.mData, let dst = to.mData else { continue }
            memcpy(dst, src, Int(min(from.mDataByteSize, to.mDataByteSize)))
        }
        return copy
    }
}

struct MeetingTracks {
    let meURL: URL
    let othersURL: URL?
    let meStartedAt: Date?
    let othersStartedAt: Date?
}

enum MeetingRecorderError: LocalizedError {
    case microphoneUnavailable
    case mixdownFailed
    var errorDescription: String? {
        switch self {
        case .microphoneUnavailable: "The microphone could not be started."
        case .mixdownFailed: "The meeting tracks could not be combined into one audio file."
        }
    }
}

/// Records the microphone ("Me") with AVAudioEngine and the system audio ("others") with
/// ScreenCaptureKit, each to its own file.
@MainActor
final class MeetingRecorder: NSObject {
    private var engine: AVAudioEngine?
    private var stream: SCStream?
    private var streamOutput: SystemAudioOutput?
    private var meWriter: TrackWriter?
    private var othersWriter: TrackWriter?
    private(set) var systemAudioError: String?

    var level: Double { Double(max(meWriter?.level ?? 0, othersWriter?.level ?? 0)) }
    var isCapturingSystemAudio: Bool { stream != nil }

    /// Starts both tracks. System audio is best effort: without Screen Recording permission the
    /// meeting is recorded from the microphone only and `systemAudioError` says why.
    func start(meURL: URL, othersURL: URL, captureSystemAudio: Bool) async throws {
        systemAudioError = nil
        let me = try TrackWriter(url: meURL, label: "me")
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw MeetingRecorderError.microphoneUnavailable }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            me.append(buffer)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
        meWriter = me

        guard captureSystemAudio else { return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { throw NSError(domain: "LocalVoice", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display to attach system audio capture to."]) }
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = Int(TrackWriter.sampleRate)
            configuration.channelCount = 1
            // Video is required by the API but unused: keep it tiny and slow.
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            configuration.queueDepth = 3

            let others = try TrackWriter(url: othersURL, label: "others")
            let output = SystemAudioOutput(writer: others)
            let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
            let queue = DispatchQueue(label: "LocalVoice.systemAudio")
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: queue)
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
            self.stream = stream
            streamOutput = output
            othersWriter = others
        } catch {
            systemAudioError = error.localizedDescription
            try? FileManager.default.removeItem(at: othersURL)
        }
    }

    func stop() async -> MeetingTracks? {
        guard let meWriter else { return nil }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        if let stream { try? await stream.stopCapture() }
        stream = nil
        streamOutput = nil
        let others = othersWriter
        await Task.detached {
            meWriter.finish()
            others?.finish()
        }.value
        self.meWriter = nil
        othersWriter = nil
        let othersHasAudio = (others?.framesWritten ?? 0) > 0
        if let others, !othersHasAudio { try? FileManager.default.removeItem(at: others.url) }
        return MeetingTracks(meURL: meWriter.url, othersURL: othersHasAudio ? others?.url : nil,
                             meStartedAt: meWriter.firstSampleAt, othersStartedAt: othersHasAudio ? others?.firstSampleAt : nil)
    }

    /// Synchronous stop for app quit: closes both files without waiting for ScreenCaptureKit.
    func stopImmediately() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        if let stream { stream.stopCapture { _ in } }
        stream = nil
        meWriter?.finish()
        othersWriter?.finish()
        meWriter = nil
        othersWriter = nil
    }

    /// Mixes the tracks into one AAC .m4a: left = me, right = others, aligned by first-sample time.
    /// Mic-only meetings produce a mono file. Streams in 10 s chunks, so length does not matter.
    nonisolated static func mixdown(_ tracks: MeetingTracks, to output: URL) throws -> Bool {
        let me = try AVAudioFile(forReading: tracks.meURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        let others = try tracks.othersURL.map { try AVAudioFile(forReading: $0, commonFormat: .pcmFormatFloat32, interleaved: false) }
        let channels: AVAudioChannelCount = others == nil ? 1 : 2
        let rate = TrackWriter.sampleRate
        try? FileManager.default.removeItem(at: output)
        let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)!
        var writer: AVAudioFile? = try AVAudioFile(forWriting: output, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: channels == 1 ? 32_000 : 64_000
        ], commonFormat: .pcmFormatFloat32, interleaved: false)

        // Leading silence so both tracks share one timeline.
        var mePad: AVAudioFramePosition = 0
        var othersPad: AVAudioFramePosition = 0
        if let a = tracks.meStartedAt, let b = tracks.othersStartedAt {
            let delta = AVAudioFramePosition((b.timeIntervalSince(a) * rate).rounded())
            if delta > 0 { othersPad = delta } else { mePad = -delta }
        }
        let meTotal = me.length + mePad
        let othersTotal = (others?.length ?? 0) + othersPad
        let total = max(meTotal, others == nil ? 0 : othersTotal)
        let chunk: AVAudioFrameCount = 160_000
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: chunk),
              let scratch = AVAudioPCMBuffer(pcmFormat: me.processingFormat, frameCapacity: chunk) else { throw MeetingRecorderError.mixdownFailed }

        func fill(_ channel: UnsafeMutablePointer<Float>, from file: AVAudioFile, pad: AVAudioFramePosition, at position: AVAudioFramePosition, count: Int, scratch: AVAudioPCMBuffer) throws {
            channel.update(repeating: 0, count: count)
            var offset = 0
            if position < pad { offset = Int(min(AVAudioFramePosition(count), pad - position)) }
            let wanted = count - offset
            guard wanted > 0, file.framePosition < file.length else { return }
            scratch.frameLength = 0
            try file.read(into: scratch, frameCount: AVAudioFrameCount(wanted))
            guard let source = scratch.floatChannelData?[0] else { return }
            (channel + offset).update(from: source, count: Int(scratch.frameLength))
        }

        var position: AVAudioFramePosition = 0
        while position < total {
            let count = Int(min(AVAudioFramePosition(chunk), total - position))
            out.frameLength = AVAudioFrameCount(count)
            guard let data = out.floatChannelData else { throw MeetingRecorderError.mixdownFailed }
            try fill(data[0], from: me, pad: mePad, at: position, count: count, scratch: scratch)
            if let others, channels == 2 {
                try fill(data[1], from: others, pad: othersPad, at: position, count: count, scratch: scratch)
            }
            try writer?.write(from: out)
            position += AVAudioFramePosition(count)
        }
        writer = nil // closes and finalizes the .m4a
        return channels == 2
    }
}

private final class SystemAudioOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    let writer: TrackWriter
    init(writer: TrackWriter) { self.writer = writer }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let description = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: asbd) else { return }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList) == noErr else { return }
        writer.append(buffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Capture ended underneath us (permission revoked, display change); the mic track continues.
    }
}
