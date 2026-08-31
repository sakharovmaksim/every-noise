import AppKit
import Foundation
import Observation

enum KeeperStatus: Equatable, Sendable {
    case stopped
    case running
    case failed(String)

    var title: String {
        switch self {
        case .stopped: "Остановлено"
        case .running: "Работает"
        case .failed: "Ошибка"
        }
    }
}

/// Планировщик импульсов: держит цикл ожидания, дергает `ToneEngine`,
/// следит за маршрутом вывода и пишет всё происходящее в журнал аудита.
@Observable
final class KeepAwakeController {
    private(set) var status: KeeperStatus = .stopped
    private(set) var lastPulseDate: Date?
    private(set) var nextPulseDate: Date?
    private(set) var pulseCount = 0
    private(set) var lastReport: PulseReport?
    private(set) var device: OutputDeviceInfo?
    private(set) var isHoldingRoute = false

    var isRunning: Bool { status == .running }

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let log: AuditLog
    @ObservationIgnored private let engine = ToneEngine()
    @ObservationIgnored private let routeMonitor = AudioRouteMonitor()
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var activity: NSObjectProtocol?

    /// Всё, что описывает маршрут; громкость сюда не входит, иначе журнал засорится
    /// при каждом нажатии клавиши громкости.
    private struct RouteSignature: Equatable {
        var deviceID: UInt32
        var name: String
        var transport: OutputTransport
        var sampleRate: Double
    }
    @ObservationIgnored private var routeSignature: RouteSignature?

    init(settings: AppSettings, log: AuditLog) {
        self.settings = settings
        self.log = log
        engine.onConfigurationChange = { [weak self] in
            self?.handleRouteChange(source: "аудиотракт пересобран")
        }
        routeMonitor.start { [weak self] property in
            Task { @MainActor in self?.handleRouteChange(source: property) }
        }
        observeSystemPower()
        observeSettings()
        refreshDevice()
        routeSignature = makeSignature()
        if let device {
            log.info("Текущий вывод: \(device.summary), \(Int(device.sampleRate)) Гц")
        }
    }

    // MARK: - Управление

    func start() {
        guard !isRunning else { return }
        do {
            try engine.start()
        } catch {
            let text = error.localizedDescription
            status = .failed(text)
            log.error("Не удалось запустить аудиодвижок: \(text)")
            return
        }
        status = .running
        beginActivity()
        refreshDevice()
        log.info("Запуск: \(settings.preset.shortTitle), импульс \(settings.duration.title), \(settings.interval.title.lowercased()), уровень \(levelText)")
        applyRouteHold()
        warnAboutTransportIfNeeded()
        nextPulseDate = Date()
        runLoop()
    }

    func stop(reason: String = "по команде пользователя") {
        guard isRunning else { return }
        loop?.cancel()
        loop = nil
        engine.stop()
        isHoldingRoute = false
        endActivity()
        nextPulseDate = nil
        status = .stopped
        log.info("Остановлено \(reason)")
    }

    func toggle() {
        isRunning ? stop() : start()
    }

    /// Ручной импульс из меню — не сдвигает расписание.
    func pulseNow() {
        emit(scheduled: false)
    }

    // MARK: - Цикл

    private func runLoop() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let next = nextPulseDate {
                    let delay = next.timeIntervalSinceNow
                    if delay > 0 {
                        // ContinuousClock учитывает время сна Mac: после пробуждения импульс уйдёт сразу.
                        try? await Task.sleep(for: .seconds(delay))
                    }
                }
                if Task.isCancelled { return }
                emit(scheduled: true)
                nextPulseDate = Date().addingTimeInterval(settings.interval.seconds)
            }
        }
    }

    private func emit(scheduled: Bool) {
        do {
            let report = try engine.play(
                frequency: settings.preset.frequency,
                duration: settings.duration.seconds,
                level: settings.level
            )
            lastReport = report
            lastPulseDate = Date()
            pulseCount += 1
            refreshDevice()

            let kind = scheduled ? "Импульс" : "Импульс вручную"
            var line = "\(kind) №\(pulseCount): \(format(hz: report.frequency)), \(settings.duration.title), уровень \(levelText)"
            line += ", вывод \(device?.summary ?? "неизвестно") @ \(Int(report.sampleRate)) Гц"
            if isHoldingRoute { line += ", удержание маршрута включено" }
            log.info(line)

            if report.wasClamped {
                log.warning("Частота \(format(hz: report.requestedFrequency)) недоступна на \(Int(report.sampleRate)) Гц и снижена до \(format(hz: report.frequency)). Поднимите частоту дискретизации в «Настройке Audio-MIDI».")
            }
            if let device, device.isSilenced {
                log.warning("Вывод \(device.name) замьючен или громкость на нуле — усилитель сигнал не увидит.")
            }
            if let device, device.isAnalogAndQuiet {
                log.warning("Системная громкость \(Int((device.volume ?? 0) * 100)) %: на аналоговом выходе сигнал может не дотянуть до порога детектора усилителя.")
            }
            if status != .running && scheduled { status = .running }
        } catch {
            let text = error.localizedDescription
            status = .failed(text)
            log.error("Импульс не воспроизведён: \(text)")
        }
    }

    // MARK: - Маршрут вывода

    /// Несущая удержания нужна там, где сессия рвётся на тишине: AirPlay, Bluetooth,
    /// составные устройства. Для джека и USB она бессмысленна.
    private func applyRouteHold() {
        let shouldHold = isRunning && settings.routeHold.isEnabled(for: device?.transport)
        guard shouldHold != isHoldingRoute else { return }
        if shouldHold {
            do {
                try engine.startRouteHold(frequency: settings.preset.frequency)
                isHoldingRoute = true
                log.info("Удержание маршрута включено: непрерывная несущая \(settings.preset.shortTitle) на −70 dBFS (\(device?.transport.title ?? "маршрут"))")
            } catch {
                log.error("Не удалось включить удержание маршрута: \(error.localizedDescription)")
            }
        } else {
            engine.stopRouteHold()
            isHoldingRoute = false
            log.info("Удержание маршрута выключено")
        }
    }

    private func warnAboutTransportIfNeeded() {
        guard let device else { return }
        if device.transport.compressesAudio, settings.preset.frequency > device.transport.recommendedMaxFrequency {
            log.warning("\(device.transport.title) сжимает звук кодеком AAC и срезает всё выше ~18 кГц: тон \(settings.preset.shortTitle) до усилителя, скорее всего, не дойдёт. Выберите 17–18 кГц.")
        }
        if device.transport == .airPlay {
            log.info("AirPlay работает на 44,1 кГц и добавляет задержку около 2 секунд — импульс короче 1 секунды может не дойти целиком.")
        }
    }

    private func handleRouteChange(source: String) {
        refreshDevice()
        let signature = makeSignature()
        guard signature != routeSignature else { return }
        routeSignature = signature
        if let device {
            log.info("Маршрут изменился (\(source)): \(device.summary), \(Int(device.sampleRate)) Гц")
        } else {
            log.warning("Маршрут изменился (\(source)): активного устройства вывода нет")
        }
        applyRouteHold()
        warnAboutTransportIfNeeded()
    }

    private func makeSignature() -> RouteSignature? {
        guard let device else { return nil }
        return RouteSignature(
            deviceID: device.deviceID,
            name: device.name,
            transport: device.transport,
            sampleRate: device.sampleRate
        )
    }

    func refreshDevice() {
        let info = AudioOutputInspector.current()
        if info != device { device = info }
    }

    // MARK: - Реакция на настройки и систему

    private func observeSettings() {
        withObservationTracking {
            _ = settings.interval
            _ = settings.preset
            _ = settings.duration
            _ = settings.level
            _ = settings.routeHold
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.settingsDidChange()
                self?.observeSettings()
            }
        }
    }

    private func settingsDidChange() {
        log.info("Настройки изменены: \(settings.preset.shortTitle), \(settings.interval.title.lowercased()), импульс \(settings.duration.title), уровень \(levelText)")
        guard isRunning else { return }
        // Частота могла смениться — несущую удержания надо пересобрать.
        if isHoldingRoute {
            engine.stopRouteHold()
            isHoldingRoute = false
        }
        applyRouteHold()
        warnAboutTransportIfNeeded()
        let base = lastPulseDate ?? Date()
        let next = base.addingTimeInterval(settings.interval.seconds)
        nextPulseDate = max(next, Date())
        runLoop()
    }

    private func observeSystemPower() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.log.info("Mac уходит в сон — импульсы приостановлены") }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleWake() }
        }
    }

    private func handleWake() {
        log.info("Mac проснулся")
        guard isRunning else { return }
        do {
            try engine.start()
            refreshDevice()
            isHoldingRoute = false
            applyRouteHold()
            nextPulseDate = Date()
            runLoop()
        } catch {
            status = .failed(error.localizedDescription)
            log.error("После пробуждения аудиодвижок не стартовал: \(error.localizedDescription)")
        }
    }

    // MARK: - App Nap

    private func beginActivity() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Периодическое воспроизведение неслышимого тона"
        )
    }

    private func endActivity() {
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
        activity = nil
    }

    // MARK: - Формат

    var levelText: String {
        String(format: "%.0f %% (%.0f dBFS)", settings.level * 100, settings.levelDecibels)
    }

    private func format(hz: Double) -> String {
        hz >= 1000 ? String(format: "%.1f кГц", hz / 1000) : String(format: "%.0f Гц", hz)
    }
}
