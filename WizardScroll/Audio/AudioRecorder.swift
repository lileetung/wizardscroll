import AVFoundation
import Foundation

final class AudioRecorder {
    /// Qwen3-ASR consumes 16 kHz mono audio. Recording in that format lets the
    /// bridge read the file directly, so no ffmpeg decode step is needed.
    static let recordingFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    private let engine = AVAudioEngine()
    private var outputFile: AVAudioFile?
    private var outputURL: URL?
    private var levelHandler: ((Float) -> Void)?

    static func requestMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    func start(levelHandler: @escaping (Float) -> Void) throws {
        guard !engine.isRunning else { return }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WizardScroll", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw RecorderError.noInput
        }

        guard let converter = AVAudioConverter(from: format, to: Self.recordingFormat) else {
            throw RecorderError.unsupportedFormat
        }
        converter.downmix = true
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: Self.recordingFormat.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        outputFile = file
        outputURL = url
        self.levelHandler = levelHandler

        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            do {
                if let converted = Self.convert(buffer, with: converter) {
                    try self?.outputFile?.write(from: converted)
                }
            } catch {
                NSLog("Audio write failed: %@", error.localizedDescription)
            }
            self?.publishLevel(from: buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            outputFile = nil
            outputURL = nil
            self.levelHandler = nil
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    func stop() throws -> URL {
        guard engine.isRunning, let url = outputURL else { throw RecorderError.notRecording }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        outputFile = nil
        outputURL = nil
        levelHandler = nil

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let byteCount = attributes[.size] as? NSNumber
        guard byteCount?.intValue ?? 0 > 4_096 else {
            try? FileManager.default.removeItem(at: url)
            throw RecorderError.noAudioCaptured
        }
        return url
    }

    func cancel() {
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        outputFile = nil
        levelHandler = nil
        if let outputURL { try? FileManager.default.removeItem(at: outputURL) }
        outputURL = nil
    }

    static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) -> AVAudioPCMBuffer? {
        let ratio = converter.outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else {
            return nil
        }
        // Each tap buffer is converted on its own; the converter keeps its
        // resampler state between calls, so consecutive buffers stay seamless.
        var didProvideInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if didProvideInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            didProvideInput = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, conversionError == nil, output.frameLength > 0 else { return nil }
        return output
    }

    private func publishLevel(from buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else {
            levelHandler?(0)
            return
        }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else {
            levelHandler?(0)
            return
        }

        var sum: Float = 0
        for channel in 0..<channelCount {
            let samples = channels[channel]
            for frame in 0..<frameCount {
                let sample = samples[frame]
                sum += sample * sample
            }
        }

        let rms = sqrt(sum / Float(frameCount * channelCount))
        let decibels = 20 * log10(max(rms, 0.000_001))
        let normalized = max(0, min(1, (decibels + 55) / 45))
        levelHandler?(normalized)
    }
}

enum RecorderError: LocalizedError {
    case noInput
    case unsupportedFormat
    case notRecording
    case noAudioCaptured

    var errorDescription: String? {
        switch self {
        case .noInput: "No microphone input is available"
        case .unsupportedFormat: "The microphone format cannot be converted for speech recognition"
        case .notRecording: "No recording is in progress"
        case .noAudioCaptured: "The microphone produced no audio. Check the live level bars and input device."
        }
    }
}
