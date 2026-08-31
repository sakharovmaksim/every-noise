import AppKit
import CoreGraphics
import Foundation
import Observation

/// Почему импульсы стоят на паузе, хотя приложение запущено.
enum SuspendReason: Equatable, Sendable {
    case idle
    case systemSleep

    var statusText: String {
        switch self {
        case .idle: L("За маком никого — пауза, чтобы он мог уснуть. Вернётесь — импульсы продолжатся")
        case .systemSleep: L("Mac спит — импульсы остановлены, продолжатся после пробуждения")
        }
    }

    var shortText: String {
        switch self {
        case .idle: L("Пауза: Mac простаивает")
        case .systemSleep: L("Пауза: Mac спит")
        }
    }

    var nextPulseText: String {
        switch self {
        case .idle: L("после возвращения к Mac")
        case .systemSleep: L("после пробуждения Mac")
        }
    }
}

enum KeeperStatus: Equatable, Sendable {
    case stopped
    case running
    case failed(String)

    var title: String {
        switch self {
        case .stopped: L("Остановлено")
        case .running: L("Работает")
        case .failed: L("Ошибка")
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
    private(set) var suspendedBy: SuspendReason?

    var isRunning: Bool { status == .running }
    var isSuspended: Bool { suspendedBy != nil }

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
    @ObservationIgnored private var idleWatcher: Task<Void, Never>?
    @ObservationIgnored private var manualPulseCleanup: Task<Void, Never>?

    /// Через столько бездействия пользователя отпускаем аудиотракт, чтобы мак мог уснуть.
    private static let idleThreshold: TimeInterval = 300
    private static let idleCheckInterval: TimeInterval = 20
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
            self?.handleRouteChange(source: L("аудиотракт пересобран"))
        }
        routeMonitor.start { [weak self] property in
            Task { @MainActor in self?.handleRouteChange(source: property) }
        }
        observeSystemPower()
        observeSettings()
        refreshDevice()
        routeSignature = makeSignature()
        if let device {
            log.info(L("Текущий вывод: %@, %d Гц", device.summary, Int(device.sampleRate)))
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
            log.error(L("Не удалось запустить аудиодвижок: %@", text))
            return
        }
        status = .running
        beginActivity()
        refreshDevice()
        log.info(L("Запуск: %@, импульс %@, %@, уровень %@", settings.preset.shortTitle, settings.duration.title, settings.interval.title.lowercased(), levelText))
        syncFrequencyToRoute()
        applyRouteHold()
        warnAboutTransportIfNeeded()
        nextPulseDate = Date()
        runLoop()
        watchIdle()
    }

    func stop(reason: String = L("по команде пользователя")) {
        guard isRunning else { return }
        loop?.cancel()
        loop = nil
        idleWatcher?.cancel()
        idleWatcher = nil
        suspendedBy = nil
        engine.stop()
        isHoldingRoute = false
        endActivity()
        nextPulseDate = nil
        status = .stopped
        log.info(L("Остановлено %@", reason))
    }

    func toggle() {
        isRunning ? stop() : start()
    }

    /// Не сдвигает расписание.
    /// Работает и на паузе: тогда аудиотракт освобождается сразу после импульса,
    /// чтобы не мешать маку засыпать.
    func pulseNow() {
        let releaseAfterwards = !isRunning || isSuspended
        emit(scheduled: false)
        guard releaseAfterwards else { return }
        manualPulseCleanup?.cancel()
        manualPulseCleanup = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(settings.duration.seconds + 0.5))
            guard !Task.isCancelled, !isRunning || isSuspended else { return }
            engine.stop()
        }
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

            let kind = scheduled ? L("Импульс") : L("Импульс вручную")
            var line = L("%@ №%d: %@, %@, уровень %@", kind, pulseCount, format(hz: report.frequency), settings.duration.title, levelText)
            line += L(", вывод %@ @ %d Гц", device?.summary ?? L("неизвестно"), Int(report.sampleRate))
            if isHoldingRoute { line += L(", удержание маршрута включено") }
            log.info(line)

            if report.wasClamped {
                let notice = L("Частота %@ недоступна на %d Гц и снижена до %@. Поднимите частоту дискретизации в «Настройке Audio-MIDI» или включите подстройку частоты.", format(hz: report.requestedFrequency), Int(report.sampleRate), format(hz: report.frequency))
                if lastClampNotice != notice {
                    log.warning(notice)
                    lastClampNotice = notice
                }
            } else {
                lastClampNotice = nil
            }
            if let device, device.isSilenced {
                log.warning(L("Вывод %@ замьючен или громкость на нуле — усилитель сигнал не увидит.", device.name))
            }
            if let device, device.isAnalogAndQuiet {
                log.warning(L("Системная громкость %d %%: на аналоговом выходе сигнал может не дотянуть до порога детектора усилителя.", Int((device.volume ?? 0) * 100)))
            }
            if status != .running && scheduled { status = .running }
        } catch {
            let text = error.localizedDescription
            status = .failed(text)
            log.error(L("Импульс не воспроизведён: %@", text))
        }
    }

    // MARK: - Простой пользователя

    /// Работающий аудиодвижок держит PreventUserIdleSystemSleep, поэтому на время простоя
    /// тракт отпускаем: пока мака нет рядом, будить усилитель всё равно не для чего.
    private func watchIdle() {
        idleWatcher?.cancel()
        idleWatcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.idleCheckInterval))
                guard let self, !Task.isCancelled else { return }
                checkIdle()
            }
        }
    }

    private var userIdleSeconds: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
    }

    private func checkIdle() {
        guard isRunning, settings.pauseWhenIdle else {
            if suspendedBy == .idle { resume(logging: L("Пауза по простою выключена — импульсы возобновлены")) }
            return
        }
        guard suspendedBy != .systemSleep else { return }
        if suspendedBy == nil, userIdleSeconds >= Self.idleThreshold {
            suspend(.idle, logging: L("Пауза: за маком %d минут никого — аудиотракт отпущен, чтобы Mac мог уснуть", Int(Self.idleThreshold / 60)))
        } else if suspendedBy == .idle, userIdleSeconds < Self.idleThreshold {
            resume(logging: L("Пользователь вернулся — импульсы возобновлены"))
        }
    }

    private func suspend(_ reason: SuspendReason, logging message: String) {
        suspendedBy = reason
        loop?.cancel()
        loop = nil
        nextPulseDate = nil
        engine.stop()
        isHoldingRoute = false
        endActivity()
        log.info(message)
    }

    private func resume(logging message: String) {
        guard isSuspended else { return }
        suspendedBy = nil
        do {
            try engine.start()
        } catch {
            status = .failed(error.localizedDescription)
            log.error(L("Аудиодвижок не стартовал: %@", error.localizedDescription))
            return
        }
        beginActivity()
        refreshDevice()
        syncFrequencyToRoute()
        applyRouteHold()
        log.info(message)
        nextPulseDate = Date()
        runLoop()
    }

    // MARK: - Маршрут вывода

    private func applyRouteHold() {
        let shouldHold = isRunning && settings.routeHold.isEnabled(for: device?.transport)
        guard shouldHold != isHoldingRoute else { return }
        if shouldHold {
            do {
                try engine.startRouteHold(frequency: effectivePreset.frequency)
                isHoldingRoute = true
                log.info(L("Удержание маршрута включено: непрерывная несущая %@ на −70 dBFS (%@)", effectivePreset.shortTitle, device?.transport.title ?? L("маршрут")))
            } catch {
                log.error(L("Не удалось включить удержание маршрута: %@", error.localizedDescription))
            }
        } else {
            engine.stopRouteHold()
            isHoldingRoute = false
            log.info(L("Удержание маршрута выключено"))
        }
    }

    private func syncFrequencyToRoute() {
        let preset = effectivePreset
        defer { appliedPreset = preset }
        guard appliedPreset != preset else { return }

        if isFrequencyAdapted {
            log.info(L("%@: частота снижена с %@ до %@. Выбор в настройках не изменён.", adaptationReason, settings.preset.shortTitle, preset.shortTitle))
        } else if appliedPreset != nil {
            log.info(L("Возврат к выбранной частоте %@", preset.shortTitle))
        }

        // Несущая играет на той же частоте — пересобираем.
        if isHoldingRoute {
            engine.stopRouteHold()
            isHoldingRoute = false
        }
    }

    private var adaptationReason: String {
        guard let device else { return L("Маршрут") }
        if device.transport.compressesAudio, settings.preset.frequency > device.transport.recommendedMaxFrequency {
            return L("%@ сжимает звук кодеком AAC и режет всё выше ~18 кГц", device.transport.title)
        }
        return L("%@ работает на %d Гц", device.summary, Int(device.sampleRate))
    }

    private func warnAboutTransportIfNeeded() {
        guard let device else { return }
        if device.transport.compressesAudio,
           !settings.adaptFrequencyToRoute,
           settings.preset.frequency > device.transport.recommendedMaxFrequency {
            log.warning(L("%@ сжимает звук кодеком AAC и срезает всё выше ~18 кГц: тон %@ до усилителя, скорее всего, не дойдёт. Выберите 17–18 кГц или включите подстройку частоты.", device.transport.title, settings.preset.shortTitle))
        }
        if device.transport == .airPlay {
            log.info(L("AirPlay работает на 44,1 кГц и добавляет задержку около 2 секунд — импульс короче 1 секунды может не дойти целиком."))
        }
    }

    private func handleRouteChange(source: String) {
        refreshDevice()
        let signature = makeSignature()
        guard signature != routeSignature else { return }
        routeSignature = signature
        if let device {
            log.info(L("Маршрут изменился (%@): %@, %d Гц", source, device.summary, Int(device.sampleRate)))
        } else {
            log.warning(L("Маршрут изменился (%@): активного устройства вывода нет", source))
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
            _ = settings.pauseWhenIdle
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.settingsDidChange()
                self?.observeSettings()
            }
        }
    }

    private func settingsDidChange() {
        if !settings.pauseWhenIdle, suspendedBy == .idle {
            resume(logging: L("Пауза по простою выключена — импульсы возобновлены"))
        }
        log.info(L("Настройки изменены: %@, %@, импульс %@, уровень %@", settings.preset.shortTitle, settings.interval.title.lowercased(), settings.duration.title, levelText))
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
            Task { @MainActor in self?.handleWillSleep() }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleWake() }
        }
    }

    /// Отпускаем аудиоустройство до засыпания: иначе движок уходит в сон вместе с системой
    /// и после пробуждения может остаться в нерабочем состоянии.
    private func handleWillSleep() {
        guard isRunning else { return }
        if suspendedBy == .idle {
            suspendedBy = .systemSleep
            log.info(L("Mac уходит в сон"))
            return
        }
        suspend(.systemSleep, logging: L("Mac уходит в сон — импульсы остановлены, аудиотракт отпущен"))
    }

    private func handleWake() {
        guard isRunning else {
            log.info(L("Mac проснулся"))
            return
        }
        // Тёмное пробуждение: система встала сама, пользователя за маком нет.
        if settings.pauseWhenIdle, userIdleSeconds >= Self.idleThreshold {
            suspendedBy = .idle
            log.info(L("Mac проснулся, но за ним никого — импульсы остаются на паузе"))
            return
        }
        if isSuspended {
            resume(logging: L("Mac проснулся — импульсы возобновлены"))
        } else {
            resume(logging: L("Mac проснулся"))
        }
    }

    // MARK: - App Nap

    private func beginActivity() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: L("Периодическое воспроизведение неслышимого тона")
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
        hz >= 1000 ? String(format: L("%.1f кГц"), hz / 1000) : String(format: L("%.0f Гц"), hz)
    }
}
