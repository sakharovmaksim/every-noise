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

    /// Минимум из ограничения кодека и 0,45 × частоты дискретизации.
    var routeFrequencyCeiling: Double {
        var ceiling = Double.infinity
        if let device {
            ceiling = min(ceiling, device.transport.recommendedMaxFrequency)
            if device.sampleRate > 0 {
                ceiling = min(ceiling, device.sampleRate * 0.45)
            }
        }
        return ceiling
    }

    var effectivePreset: TonePreset {
        let ceiling = routeFrequencyCeiling
        guard settings.adaptFrequencyToRoute,
              settings.preset.frequency > ceiling,
              let fitted = TonePreset.bestFit(maxFrequency: ceiling)
        else { return settings.preset }
        return fitted
    }

    var isFrequencyAdapted: Bool { effectivePreset != settings.preset }

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let log: AuditLog
    @ObservationIgnored private let engine = ToneEngine()
    @ObservationIgnored private let routeMonitor = AudioRouteMonitor()
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var activity: NSObjectProtocol?

    /// Без громкости: иначе журнал засорится при каждом нажатии клавиши.
    private struct RouteSignature: Equatable {
        var deviceID: UInt32
        var name: String
        var transport: OutputTransport
        var sampleRate: Double
    }
    @ObservationIgnored private var routeSignature: RouteSignature?
    @ObservationIgnored private var appliedPreset: TonePreset?
    @ObservationIgnored private var lastClampNotice: String?

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
        syncFrequencyToRoute()
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

    /// Не сдвигает расписание.
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
                        // ContinuousClock учитывает сон Mac: после пробуждения импульс уйдёт сразу.
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
                frequency: effectivePreset.frequency,
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
                let notice = "Частота \(format(hz: report.requestedFrequency)) недоступна на \(Int(report.sampleRate)) Гц и снижена до \(format(hz: report.frequency)). Поднимите частоту дискретизации в «Настройке Audio-MIDI» или включите подстройку частоты."
                if lastClampNotice != notice {
                    log.warning(notice)
                    lastClampNotice = notice
                }
            } else {
                lastClampNotice = nil
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

    private func applyRouteHold() {
        let shouldHold = isRunning && settings.routeHold.isEnabled(for: device?.transport)
        guard shouldHold != isHoldingRoute else { return }
        if shouldHold {
            do {
                try engine.startRouteHold(frequency: effectivePreset.frequency)
                isHoldingRoute = true
                log.info("Удержание маршрута включено: непрерывная несущая \(effectivePreset.shortTitle) на −70 dBFS (\(device?.transport.title ?? "маршрут"))")
            } catch {
                log.error("Не удалось включить удержание маршрута: \(error.localizedDescription)")
            }
        } else {
            engine.stopRouteHold()
            isHoldingRoute = false
            log.info("Удержание маршрута выключено")
        }
    }

    private func syncFrequencyToRoute() {
        let preset = effectivePreset
        defer { appliedPreset = preset }
        guard appliedPreset != preset else { return }

        if isFrequencyAdapted {
            log.info("\(adaptationReason): частота снижена с \(settings.preset.shortTitle) до \(preset.shortTitle). Выбор в настройках не изменён.")
        } else if appliedPreset != nil {
            log.info("Возврат к выбранной частоте \(preset.shortTitle)")
        }

        // Несущая играет на той же частоте — пересобираем.
        if isHoldingRoute {
            engine.stopRouteHold()
            isHoldingRoute = false
        }
    }

    private var adaptationReason: String {
        guard let device else { return "Маршрут" }
        if device.transport.compressesAudio, settings.preset.frequency > device.transport.recommendedMaxFrequency {
            return "\(device.transport.title) сжимает звук кодеком AAC и режет всё выше ~18 кГц"
        }
        return "\(device.summary) работает на \(Int(device.sampleRate)) Гц"
    }

    private func warnAboutTransportIfNeeded() {
        guard let device else { return }
        if device.transport.compressesAudio,
           !settings.adaptFrequencyToRoute,
           settings.preset.frequency > device.transport.recommendedMaxFrequency {
            log.warning("\(device.transport.title) сжимает звук кодеком AAC и срезает всё выше ~18 кГц: тон \(settings.preset.shortTitle) до усилителя, скорее всего, не дойдёт. Выберите 17–18 кГц или включите подстройку частоты.")
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
        syncFrequencyToRoute()
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
            _ = settings.adaptFrequencyToRoute
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
        if isHoldingRoute {
            engine.stopRouteHold()
            isHoldingRoute = false
        }
        syncFrequencyToRoute()
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
            syncFrequencyToRoute()
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
