import CoreAudio
import Foundation

/// Слушатель маршрута вывода: втыкание джека 3,5 мм, переключение на AirPlay,
/// смена частоты дискретизации и громкости приходят сюда без опроса.
///
/// Отдельный монитор нужен потому, что `AVAudioEngineConfigurationChange` срабатывает
/// не на всё: у встроенного звука динамики и джек — одно устройство с разными
/// data source, и смена источника движок не трогает.
///
/// Класс живёт вне главного актора: HAL зовёт блоки на своей очереди, вся мутация
/// состояния сериализована через `queue`, наружу события уходят уже на `MainActor`.
nonisolated final class AudioRouteMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.sakharovmaksim.every-noise.route", qos: .utility)
    private var deviceSubscriptions: [(device: AudioDeviceID, address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []
    private var systemSubscription: (address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)?
    private var handler: (@Sendable (String) -> Void)?

    private static let deviceProperties: [(AudioObjectPropertySelector, String)] = [
        (kAudioDevicePropertyDataSource, "источник вывода"),
        (kAudioDevicePropertyNominalSampleRate, "частота дискретизации"),
        (kAudioDevicePropertyMute, "мьют"),
        (kAudioDevicePropertyVolumeScalar, "громкость"),
    ]

    func start(onChange: @escaping @Sendable (String) -> Void) {
        queue.async { [self] in
            handler = onChange
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self else { return }
                queue.async {
                    self.subscribeToDevice()
                    self.handler?("устройство вывода")
                }
            }
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block) == noErr {
                systemSubscription = (address, block)
            }
            subscribeToDevice()
        }
    }

    func stop() {
        queue.sync { [self] in
            handler = nil
            unsubscribeAll()
        }
    }

    /// Вызывать только на `queue`.
    private func subscribeToDevice() {
        unsubscribeFromDevice()
        guard let device = AudioOutputInspector.defaultOutputDevice() else { return }

        for (selector, label) in Self.deviceProperties {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectHasProperty(device, &address) else { continue }
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self else { return }
                queue.async { self.handler?(label) }
            }
            if AudioObjectAddPropertyListenerBlock(device, &address, queue, block) == noErr {
                deviceSubscriptions.append((device, address, block))
            }
        }
    }

    private func unsubscribeFromDevice() {
        for var subscription in deviceSubscriptions {
            AudioObjectRemovePropertyListenerBlock(
                subscription.device,
                &subscription.address,
                queue,
                subscription.block
            )
        }
        deviceSubscriptions.removeAll()
    }

    private func unsubscribeAll() {
        unsubscribeFromDevice()
        if var subscription = systemSubscription {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &subscription.address,
                queue,
                subscription.block
            )
            systemSubscription = nil
        }
    }
}
