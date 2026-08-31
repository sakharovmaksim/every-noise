import CoreAudio
import Foundation

/// Как усилитель подключён к маку — от этого зависит, что доедет до его входа.
enum OutputTransport: Equatable, Sendable {
    case builtInSpeakers
    case headphoneJack
    case airPlay
    case bluetooth
    case usb
    case hdmi
    case aggregate
    case other(String)

    var title: String {
        switch self {
        case .builtInSpeakers: "Встроенные динамики"
        case .headphoneJack: "Разъём 3,5 мм"
        case .airPlay: "AirPlay"
        case .bluetooth: "Bluetooth"
        case .usb: "USB"
        case .hdmi: "HDMI"
        case .aggregate: "Составное устройство"
        case .other(let name): name
        }
    }

    /// Тракты со сжатием: AAC режет ультразвук, тон выше ~18 кГц до усилителя не доедет.
    var compressesAudio: Bool {
        self == .airPlay || self == .bluetooth
    }

    /// Маршруты, которые рвутся при тишине, поэтому их нужно удерживать несущей.
    var needsRouteHold: Bool {
        switch self {
        case .airPlay, .bluetooth, .aggregate: true
        default: false
        }
    }

    /// Верхняя разумная частота тона для этого подключения.
    var recommendedMaxFrequency: Double {
        compressesAudio ? 18_000 : .infinity
    }
}

struct OutputDeviceInfo: Equatable, Sendable {
    var deviceID: AudioDeviceID
    var name: String
    var transport: OutputTransport
    var sampleRate: Double
    /// nil, если устройство не отдаёт регулировку громкости (частый случай для внешних ЦАП).
    var volume: Float?
    var isMuted: Bool?

    /// Тон не дойдёт до усилителя, если система замьючена или громкость выкручена в ноль.
    var isSilenced: Bool {
        if isMuted == true { return true }
        if let volume, volume < 0.005 { return true }
        return false
    }

    /// Аналоговый выход мака регулируется системной громкостью: на 10 % сигнал уже слабый.
    var isAnalogAndQuiet: Bool {
        guard transport == .headphoneJack || transport == .builtInSpeakers else { return false }
        guard let volume else { return false }
        return volume > 0.005 && volume < 0.1
    }

    var summary: String {
        "\(name) · \(transport.title)"
    }
}

/// Тонкая обёртка над CoreAudio HAL: какое устройство сейчас играет, как подключено
/// и не замьючено ли оно.
enum AudioOutputInspector {
    nonisolated static func current() -> OutputDeviceInfo? {
        guard let deviceID = defaultOutputDevice() else { return nil }
        return OutputDeviceInfo(
            deviceID: deviceID,
            name: name(of: deviceID) ?? "Устройство вывода",
            transport: transport(of: deviceID),
            sampleRate: sampleRate(of: deviceID) ?? 0,
            volume: volume(of: deviceID),
            isMuted: muted(of: deviceID)
        )
    }

    nonisolated static func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private nonisolated static func name(of device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else { return nil }
        return value as String
    }

    /// Тип подключения; для встроенного звука дополнительно смотрим источник данных,
    /// потому что динамики и джек 3,5 мм — это одно устройство с разными data source.
    private nonisolated static func transport(of device: AudioDeviceID) -> OutputTransport {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
            return .other("Неизвестное подключение")
        }

        switch value {
        case kAudioDeviceTransportTypeBuiltIn:
            return dataSource(of: device) == fourCharCode("hdpn") ? .headphoneJack : .builtInSpeakers
        case kAudioDeviceTransportTypeAirPlay:
            return .airPlay
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return .bluetooth
        case kAudioDeviceTransportTypeUSB:
            return .usb
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return .hdmi
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeVirtual:
            return .aggregate
        case kAudioDeviceTransportTypeThunderbolt:
            return .other("Thunderbolt")
        default:
            return .other("Внешнее устройство")
        }
    }

    nonisolated static func dataSource(of device: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private nonisolated static func sampleRate(of device: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        guard status == noErr, value > 0 else { return nil }
        return value
    }

    private nonisolated static func volume(of device: AudioDeviceID) -> Float? {
        for element in [kAudioObjectPropertyElementMain, 1, 2] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: AudioObjectPropertyElement(element)
            )
            guard AudioObjectHasProperty(device, &address) else { continue }
            var value = Float32(0)
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr {
                return value
            }
        }
        return nil
    }

    private nonisolated static func muted(of device: AudioDeviceID) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    private nonisolated static func fourCharCode(_ text: String) -> UInt32 {
        text.utf8.reduce(UInt32(0)) { ($0 << 8) + UInt32($1) }
    }
}
