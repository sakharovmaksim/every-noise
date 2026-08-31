import Foundation
import Observation
import ServiceManagement

enum PulseInterval: Int, CaseIterable, Identifiable, Sendable {
    case s15 = 15, s30 = 30, m1 = 60, m2 = 120, m3 = 180
    case m5 = 300, m10 = 600, m15 = 900, m30 = 1800, h1 = 3600

    var id: Int { rawValue }
    var seconds: TimeInterval { TimeInterval(rawValue) }

    var shortTitle: String {
        switch self {
        case .s15: L("15 с")
        case .s30: L("30 с")
        case .m1: L("1 мин")
        case .m2: L("2 мин")
        case .m3: L("3 мин")
        case .m5: L("5 мин")
        case .m10: L("10 мин")
        case .m15: L("15 мин")
        case .m30: L("30 мин")
        case .h1: L("1 час")
        }
    }

    var title: String {
        switch self {
        case .s15: L("Каждые 15 секунд")
        case .s30: L("Каждые 30 секунд")
        case .m1: L("Каждую минуту")
        case .m2: L("Каждые 2 минуты")
        case .m3: L("Каждые 3 минуты")
        case .m5: L("Каждые 5 минут")
        case .m10: L("Каждые 10 минут")
        case .m15: L("Каждые 15 минут")
        case .m30: L("Каждые 30 минут")
        case .h1: L("Каждый час")
        }
    }
}

/// Разбор частот — в README. Порядок кейсов задаёт порядок в пикерах.
enum TonePreset: String, CaseIterable, Identifiable, Sendable {
    case khz22, khz20, khz19, khz18, khz17, sub20, infra10

    var id: String { rawValue }

    var frequency: Double {
        switch self {
        case .infra10: 10
        case .sub20: 20
        case .khz17: 17_000
        case .khz18: 18_000
        case .khz19: 19_000
        case .khz20: 20_000
        case .khz22: 22_000
        }
    }

    var title: String {
        switch self {
        case .infra10: L("10 Гц · инфразвук, часто срезается")
        case .sub20: L("20 Гц · нижняя граница слуха")
        case .khz17: L("17 кГц · слышат подростки")
        case .khz18: L("18 кГц · для AirPlay и Bluetooth")
        case .khz19: L("19 кГц · запасной вариант")
        case .khz20: L("20 кГц · рекомендуется")
        case .khz22: L("22 кГц · нужен выход ≥ 48 кГц")
        }
    }

    var shortTitle: String {
        switch self {
        case .infra10: L("10 Гц")
        case .sub20: L("20 Гц")
        case .khz17: L("17 кГц")
        case .khz18: L("18 кГц")
        case .khz19: L("19 кГц")
        case .khz20: L("20 кГц")
        case .khz22: L("22 кГц")
        }
    }

    var summary: String {
        switch self {
        case .infra10:
            L("Ниже порога слышимости человека. Не все тракты его пропускают: разделительные конденсаторы и фильтры ВЧ-среза в усилителе часто режут всё ниже 20 Гц, и детектор сигнала тона не увидит.")
        case .sub20:
            L("Формально на границе слышимости: тон не различим как звук, но крупные напольные колонки могут отдавать лёгким гулом и заметным ходом диффузора.")
        case .khz17:
            L("Не слышат почти все люди старше 25 лет, но подростки, дети и домашние животные слышат хорошо. Берите, только если верхние пресеты не будят усилитель.")
        case .khz18:
            L("Неслышимо для подавляющего большинства взрослых. Компромисс, если 19–20 кГц теряются в тракте.")
        case .khz19:
            L("Неслышимо практически для всех. Основной запасной вариант, если на 20 кГц усилитель не просыпается.")
        case .khz20:
            L("Верхняя граница слышимости человека, реально не слышит никто. Проходит через тракт 44,1 кГц и выше — универсальный выбор по умолчанию.")
        case .khz22:
            L("Гарантированно неслышимо, но требует выхода 48 кГц и выше: на 44,1 кГц частота упирается в Найквиста и будет подавлена фильтром ЦАП.")
        }
    }

    var requiredSampleRate: Double { frequency / 0.45 }

    /// Ниже 17 кГц не опускаемся: там тон уже слышат подростки.
    static func bestFit(maxFrequency: Double) -> TonePreset? {
        allCases
            .filter { $0.frequency >= 17_000 && $0.frequency <= maxFrequency }
            .max { $0.frequency < $1.frequency }
    }
}

enum PulseDuration: Double, CaseIterable, Identifiable, Sendable {
    case ms250 = 0.25, ms500 = 0.5, s1 = 1, s2 = 2, s3 = 3

    var id: Double { rawValue }
    var seconds: TimeInterval { rawValue }

    var title: String {
        switch self {
        case .ms250: L("0,25 с")
        case .ms500: L("0,5 с")
        case .s1: L("1 с")
        case .s2: L("2 с")
        case .s3: L("3 с")
        }
    }
}

/// Непрерывная несущая, чтобы сессия не рвалась между импульсами.
enum RouteHoldMode: String, CaseIterable, Identifiable, Sendable {
    case auto, always, never

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: L("Автоматически")
        case .always: L("Всегда")
        case .never: L("Никогда")
        }
    }

    func isEnabled(for transport: OutputTransport?) -> Bool {
        switch self {
        case .always: true
        case .never: false
        case .auto: transport?.needsRouteHold ?? false
        }
    }
}

@Observable
final class AppSettings {
    private enum Key {
        static let interval = "pulseInterval"
        static let preset = "tonePreset"
        static let duration = "pulseDuration"
        static let level = "pulseLevel"
        static let routeHold = "routeHoldMode"
        static let adaptFrequency = "adaptFrequencyToRoute"
        static let pauseWhenIdle = "pauseWhenIdle"
        static let autoStart = "autoStart"
        static let launchAtLogin = "launchAtLogin"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var interval: PulseInterval { didSet { defaults.set(interval.rawValue, forKey: Key.interval) } }
    var preset: TonePreset { didSet { defaults.set(preset.rawValue, forKey: Key.preset) } }
    var duration: PulseDuration { didSet { defaults.set(duration.rawValue, forKey: Key.duration) } }

    /// Амплитуда 0…1.
    /// Присваивать свойству внутри его же didSet нельзя: макрос @Observable делает его
    /// вычисляемым поверх хранилища, и запись уходит в бесконечную рекурсию. Значение
    /// приводится к диапазону при чтении из настроек и ограничено самим слайдером.
    var level: Double {
        didSet { defaults.set(level, forKey: Key.level) }
    }

    static func clampedLevel(_ value: Double) -> Double {
        min(max(value, 0.01), 1)
    }

    var routeHold: RouteHoldMode { didSet { defaults.set(routeHold.rawValue, forKey: Key.routeHold) } }

    /// Не трогает выбор пользователя, влияет только на то, что играется.
    var adaptFrequencyToRoute: Bool { didSet { defaults.set(adaptFrequencyToRoute, forKey: Key.adaptFrequency) } }

    /// Пока движок играет, coreaudiod держит PreventUserIdleSystemSleep и мак не засыпает.
    var pauseWhenIdle: Bool { didSet { defaults.set(pauseWhenIdle, forKey: Key.pauseWhenIdle) } }

    var autoStart: Bool { didSet { defaults.set(autoStart, forKey: Key.autoStart) } }

    var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue, !isApplyingLoginItem else { return }
            defaults.set(launchAtLogin, forKey: Key.launchAtLogin)
            applyLaunchAtLogin()
        }
    }

    @ObservationIgnored private var isApplyingLoginItem = false

    @ObservationIgnored var onLoginItemError: ((String) -> Void)?

    var levelDecibels: Double { 20 * log10(max(level, 0.0001)) }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        interval = PulseInterval(rawValue: defaults.integer(forKey: Key.interval)) ?? .m1
        preset = TonePreset(rawValue: defaults.string(forKey: Key.preset) ?? "") ?? .khz20
        duration = PulseDuration(rawValue: defaults.double(forKey: Key.duration)) ?? .s1
        let storedLevel = defaults.double(forKey: Key.level)
        level = storedLevel > 0 ? AppSettings.clampedLevel(storedLevel) : 0.10
        routeHold = RouteHoldMode(rawValue: defaults.string(forKey: Key.routeHold) ?? "") ?? .auto
        adaptFrequencyToRoute = defaults.object(forKey: Key.adaptFrequency) as? Bool ?? true
        pauseWhenIdle = defaults.object(forKey: Key.pauseWhenIdle) as? Bool ?? true
        autoStart = defaults.object(forKey: Key.autoStart) as? Bool ?? true
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func applyLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            let description = error.localizedDescription
            // Откат в didSet того же свойства — снова через сеттер, поэтому защищаемся флагом.
            isApplyingLoginItem = true
            launchAtLogin = SMAppService.mainApp.status == .enabled
            isApplyingLoginItem = false
            onLoginItemError?(description)
        }
    }
}
