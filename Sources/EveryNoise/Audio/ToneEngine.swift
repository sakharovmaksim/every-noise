import AVFoundation
import Foundation

enum ToneEngineError: LocalizedError {
    case noOutputDevice
    case engineFailed(String)
    case bufferFailed

    var errorDescription: String? {
        switch self {
        case .noOutputDevice: L("Не найдено активное устройство вывода звука")
        case .engineFailed(let reason): L("Аудиодвижок не запустился: %@", reason)
        case .bufferFailed: L("Не удалось подготовить буфер тона")
        }
    }
}

struct PulseReport: Sendable, Equatable {
    var requestedFrequency: Double
    var frequency: Double
    var sampleRate: Double
    var duration: TimeInterval
    var level: Double

    var wasClamped: Bool { frequency < requestedFrequency - 0.5 }
}

/// Два узла: `pulsePlayer` — импульсы по расписанию, `holdPlayer` — непрерывная несущая
/// для маршрутов, которые рвутся на тишине.
final class ToneEngine {
    /// Поток не считается пустым, но на 40 дБ ниже порога слышимости.
    private static let holdLevel = 0.0003

    private let engine = AVAudioEngine()
    private let pulsePlayer = AVAudioPlayerNode()
    private let holdPlayer = AVAudioPlayerNode()

    private var format: AVAudioFormat?
    private var buffer: AVAudioPCMBuffer?
    private var bufferKey: BufferKey?
    private var holdFrequency: Double?

    var onConfigurationChange: (() -> Void)?

    private struct BufferKey: Equatable {
        var frequency: Double
        var duration: TimeInterval
        var level: Double
        var sampleRate: Double
        var channels: AVAudioChannelCount
    }

    init() {
        engine.attach(pulsePlayer)
        engine.attach(holdPlayer)
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleConfigurationChange() }
        }
    }

    var isRunning: Bool { engine.isRunning }
    var currentSampleRate: Double? { format?.sampleRate }
    var isHoldingRoute: Bool { holdFrequency != nil }

    func start() throws {
        if format == nil { try connect() }
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                throw ToneEngineError.engineFailed(error.localizedDescription)
            }
        }
        if !pulsePlayer.isPlaying { pulsePlayer.play() }
    }

    func stop() {
        stopRouteHold()
        pulsePlayer.stop()
        engine.stop()
        buffer = nil
        bufferKey = nil
    }

    @discardableResult
    func play(frequency: Double, duration: TimeInterval, level: Double) throws -> PulseReport {
        try start()
        guard let format else { throw ToneEngineError.noOutputDevice }

        // Всё выше 0,45 × Fs не переживёт восстанавливающий фильтр ЦАП, режем заранее.
        let effective = min(frequency, format.sampleRate * 0.45)
        let key = BufferKey(
            frequency: effective,
            duration: duration,
            level: min(max(level, 0), 1),
            sampleRate: format.sampleRate,
            channels: format.channelCount
        )
        if bufferKey != key || buffer == nil {
            guard let made = Self.makePulseBuffer(key: key, format: format) else { throw ToneEngineError.bufferFailed }
            buffer = made
            bufferKey = key
        }
        guard let buffer else { throw ToneEngineError.bufferFailed }

        pulsePlayer.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        if !pulsePlayer.isPlaying { pulsePlayer.play() }

        return PulseReport(
            requestedFrequency: frequency,
            frequency: effective,
            sampleRate: format.sampleRate,
            duration: duration,
            level: level
        )
    }

    // MARK: - Удержание маршрута

    func startRouteHold(frequency: Double) throws {
        try start()
        guard let format else { throw ToneEngineError.noOutputDevice }
        let effective = min(frequency, format.sampleRate * 0.45)
        if holdFrequency == effective, holdPlayer.isPlaying { return }

        holdPlayer.stop()
        guard let loop = Self.makeLoopBuffer(frequency: effective, level: Self.holdLevel, format: format) else {
            throw ToneEngineError.bufferFailed
        }
        holdPlayer.scheduleBuffer(loop, at: nil, options: [.loops], completionHandler: nil)
        holdPlayer.play()
        holdFrequency = effective
    }

    func stopRouteHold() {
        guard holdFrequency != nil else { return }
        holdPlayer.stop()
        holdFrequency = nil
    }

    // MARK: - Тракт

    private func connect() throws {
        let hardware = engine.outputNode.outputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0 else { throw ToneEngineError.noOutputDevice }
        let channels = min(hardware.channelCount, 2)
        guard let target = AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate, channels: channels) else {
            throw ToneEngineError.noOutputDevice
        }
        engine.connect(pulsePlayer, to: engine.mainMixerNode, format: target)
        engine.connect(holdPlayer, to: engine.mainMixerNode, format: target)
        engine.mainMixerNode.outputVolume = 1
        format = target
        buffer = nil
        bufferKey = nil
    }

    private func handleConfigurationChange() {
        let wasRunning = engine.isRunning
        let heldFrequency = holdFrequency
        pulsePlayer.stop()
        holdPlayer.stop()
        holdFrequency = nil
        format = nil
        buffer = nil
        bufferKey = nil
        try? connect()
        if wasRunning { try? start() }
        if let heldFrequency { try? startRouteHold(frequency: heldFrequency) }
        onConfigurationChange?()
    }

    // MARK: - Буферы

    /// Косинусные фронт и спад — иначе щелчок.
    private nonisolated static func makePulseBuffer(key: BufferKey, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(key.sampleRate * key.duration)
        guard frameCount > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount

        let fadeFrames = max(1, min(Int(key.sampleRate * 0.02), Int(frameCount) / 4))
        let step = 2 * Double.pi * key.frequency / key.sampleRate
        let total = Int(frameCount)

        guard let channels = buffer.floatChannelData else { return nil }
        for frame in 0..<total {
            var envelope = 1.0
            if frame < fadeFrames {
                envelope = 0.5 * (1 - cos(Double.pi * Double(frame) / Double(fadeFrames)))
            } else if frame >= total - fadeFrames {
                let tail = total - frame
                envelope = 0.5 * (1 - cos(Double.pi * Double(tail) / Double(fadeFrames)))
            }
            let value = Float(sin(step * Double(frame)) * key.level * envelope)
            for channel in 0..<Int(format.channelCount) {
                channels[channel][frame] = value
            }
        }
        return buffer
    }

    /// Длина под целое число периодов, иначе щелчок на стыке цикла.
    private nonisolated static func makeLoopBuffer(frequency: Double, level: Double, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard frequency > 0 else { return nil }
        let cycles = max(1, (format.sampleRate / frequency).rounded())
        let frameCount = AVAudioFrameCount((cycles * format.sampleRate / frequency).rounded())
        guard frameCount > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount

        let step = 2 * Double.pi * frequency / format.sampleRate
        guard let channels = buffer.floatChannelData else { return nil }
        for frame in 0..<Int(frameCount) {
            let value = Float(sin(step * Double(frame)) * level)
            for channel in 0..<Int(format.channelCount) {
                channels[channel][frame] = value
            }
        }
        return buffer
    }
}
