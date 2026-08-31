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
        case .s15: "15 с"
        case .s30: "30 с"
        case .m1: "1 мин"
        case .m2: "2 мин"
        case .m3: "3 мин"
        case .m5: "5 мин"
        case .m10: "10 мин"
        case .m15: "15 мин"
        case .m30: "30 мин"
        case .h1: "1 час"
        }
    }

    var title: String {
        switch self {
        case .s15: "Каждые 15 секунд"
        case .s30: "Каждые 30 секунд"
        case .m1: "Каждую минуту"
        case .m2: "Каждые 2 минуты"
        case .m3: "Каждые 3 минуты"
        case .m5: "Каждые 5 минут"
        case .m10: "Каждые 10 минут"
        case .m15: "Каждые 15 минут"
        case .m30: "Каждые 30 минут"
        case .h1: "Каждый час"
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
        case .infra10: "Ниже слуха · 10 Гц"
        case .sub20: "Ниже слуха · 20 Гц"
        case .khz17: "17 кГц · слышат подростки"
        case .khz18: "18 кГц · для AirPlay и Bluetooth"
        case .khz19: "19 кГц · запасной вариант"
        case .khz20: "20 кГц · рекомендуется"
        case .khz22: "22 кГц · нужен выход ≥ 48 кГц"
        }
    }

    var shortTitle: String {
        switch self {
        case .infra10: "10 Гц"
        case .sub20: "20 Гц"
        case .khz17: "17 кГц"
        case .khz18: "18 кГц"
        case .khz19: "19 кГц"
        case .khz20: "20 кГц"
        case .khz22: "22 кГц"
        }
    }

    var summary: String {
        switch self {
        case .infra10:
            "Ниже порога слышимости человека. Не все тракты его пропускают: разделительные конденсаторы и фильтры ВЧ-среза в усилителе часто режут всё ниже 20 Гц, и детектор сигнала тона не увидит."
        case .sub20:
            "Формально на границе слышимости: тон не различим как звук, но крупные напольные колонки могут отдавать лёгким гулом и заметным ходом диффузора."
        case .khz17:
            "Не слышат почти все люди старше 25 лет, но подростки, дети и домашние животные слышат хорошо. Берите, только если верхние пресеты не будят усилитель."
        case .khz18:
            "Неслышимо для подавляющего большинства взрослых. Компромисс, если 19–20 кГц теряются в тракте."
        case .khz19:
            "Неслышимо практически для всех. Основной запасной вариант, если на 20 кГц усилитель не просыпается."
        case .khz20:
            "Верхняя граница слышимости человека, реально не слышит никто. Проходит через тракт 44,1 кГц и выше — универсальный выбор по умолчанию."
        case .khz22:
            "Гарантированно неслышимо, но требует выхода 48 кГц и выше: на 44,1 кГц частота упирается в Найквиста и будет подавлена фильтром ЦАП."
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
        case .ms250: "0,25 с"
        case .ms500: "0,5 с"
        case .s1: "1 с"
        case .s2: "2 с"
        case .s3: "3 с"
        }
    }
}

/// Непрерывная несущая, чтобы сессия не рвалась между импульсами.
enum RouteHoldMode: String, CaseIterable, Identifiable, Sendable {
    case auto, always, never

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: "Автоматически"
        case .always: "Всегда"
        case .never: "Никогда"
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
        static let autoStart = "autoStart"
        static let launchAtLogin = "launchAtLogin"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var interval: PulseInterval { didSet { defaults.set(interval.rawValue, forKey: Key.interval) } }
    var preset: TonePreset { didSet { defaults.set(preset.rawValue, forKey: Key.preset) } }
    var duration: PulseDuration { didSet { defaults.set(duration.rawValue, forKey: Key.duration) } }

    /// Амплитуда 0…1.
    var level: Double {
        didSet {
            level = min(max(level, 0.01), 1)
            defaults.set(level, forKey: Key.level)
        }
    }

    var routeHold: RouteHoldMode { didSet { defaults.set(routeHold.rawValue, forKey: Key.routeHold) } }

    /// Не трогает выбор пользователя, влияет только на то, что играется.
    var adaptFrequencyToRoute: Bool { didSet { defaults.set(adaptFrequencyToRoute, forKey: Key.adaptFrequency) } }

    var autoStart: Bool { didSet { defaults.set(autoStart, forKey: Key.autoStart) } }

    var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue else { return }
            defaults.set(launchAtLogin, forKey: Key.launchAtLogin)
            applyLaunchAtLogin()
        }
    }

    @ObservationIgnored var onLoginItemError: ((String) -> Void)?

    var levelDecibels: Double { 20 * log10(max(level, 0.0001)) }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        interval = PulseInterval(rawValue: defaults.integer(forKey: Key.interval)) ?? .s30
        preset = TonePreset(rawValue: defaults.string(forKey: Key.preset) ?? "") ?? .khz20
        duration = PulseDuration(rawValue: defaults.double(forKey: Key.duration)) ?? .s1
        let storedLevel = defaults.double(forKey: Key.level)
        level = storedLevel > 0 ? min(storedLevel, 1) : 0.12
        routeHold = RouteHoldMode(rawValue: defaults.string(forKey: Key.routeHold) ?? "") ?? .auto
        adaptFrequencyToRoute = defaults.object(forKey: Key.adaptFrequency) as? Bool ?? true
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
            launchAtLogin = SMAppService.mainApp.status == .enabled
            onLoginItemError?(description)
        }
    }
}
