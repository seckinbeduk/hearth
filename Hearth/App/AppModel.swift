import Foundation
import Observation
import ServiceManagement

/// Top-level state: scan → choose → prepare → running.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case scanning
        case choose       // Hardware, what's already here, and the recommendation
        case preparing    // Downloading / loading the chosen model
        case running      // Serving
        case failed(String)
    }

    /// What the user chose to serve.
    enum Choice: Codable, Equatable {
        case model(CatalogModel)
        case appleIntelligenceOnly
    }

    private(set) var phase: Phase = .scanning
    private(set) var hardware: HardwareProfile?
    private(set) var discovery = DiscoveryReport()
    private(set) var advice: ModelAdvice?
    private(set) var choice: Choice?
    var selectedID: String?

    let models = LocalModelManager()
    let stats = UsageStats()
    let monitor = SystemMonitor()
    let agents = AgentsModel()
    let server: InferenceService

    private let choiceKey = "hearth.choice.v1"

    /// Set by AppDelegate; views call these instead of SwiftUI's openWindow.
    @ObservationIgnored var showMainWindow: () -> Void = {}
    @ObservationIgnored var closePanel: () -> Void = {}

    var needsSetup: Bool { choice == nil }

    init() {
        server = InferenceService(models: models, stats: stats, agents: agents.endpoint)
        agents.isServing = { [stats] in stats.isGenerating }
        // The on-device model answers one request at a time: a summary in flight would delay Hearth's own.
        stats.onBegin = { [weak agents] in agents?.yieldToInference() }
        if let data = UserDefaults.standard.data(forKey: choiceKey),
           let saved = try? JSONDecoder().decode(Choice.self, from: data) {
            choice = saved
            phase = .running
        }
    }

    /// Called once at launch from the menu bar label.
    func launch() async {
        monitor.start()
        agents.startSweeping()
        guard let choice else {
            await scan()
            return
        }
        await server.start()
        Task { await refreshEnvironment() }
        if case .model(let model) = choice { await models.prepare(model) }
    }

    // MARK: - Scanning

    func scan() async {
        phase = .scanning
        let started = Date()
        let ownPort = server.port
        async let hw = HardwareProfiler.scan()
        async let found = LocalDiscovery.scan(excludingPort: ownPort)
        let (profile, report) = await (hw, found)
        hardware = profile
        discovery = report
        computeAdvice()
        selectedID = advice?.recommended?.id

        // The scan is quick; hold the animation briefly so people see what happened.
        let elapsed = Date().timeIntervalSince(started)
        if elapsed < 1.6 { try? await Task.sleep(for: .seconds(1.6 - elapsed)) }
        phase = .choose
    }

    /// Re-reads hardware and what's on this Mac without leaving the current screen.
    func refreshEnvironment() async {
        let ownPort = server.port
        async let hw = HardwareProfiler.scan()
        async let found = LocalDiscovery.scan(excludingPort: ownPort)
        let (profile, report) = await (hw, found)
        hardware = profile
        discovery = report
        computeAdvice()
    }

    /// Apple Intelligence can be switched on while the setup window is open.
    func refreshAppleIntelligence() async {
        guard var hw = hardware, hw.appleIntelligence != .available else { return }
        let status = await HardwareProfiler.appleIntelligenceStatus()
        guard status != hw.appleIntelligence else { return }
        hw.appleIntelligence = status
        hardware = hw
    }

    private func computeAdvice() {
        guard let hardware else { return }
        let catalog = (try? ModelCatalog.bundled().models) ?? []
        advice = ModelAdvisor(catalog: catalog).advise(for: hardware, onDisk: discovery.diskModels)
    }

    // MARK: - Choosing

    /// All runnable choices: catalog models plus MLX models found on disk.
    func model(for id: String) -> CatalogModel? {
        advice?.fit(for: id)?.model ?? advice?.existing.first { $0.model?.id == id }?.model
    }

    func run(_ model: CatalogModel) async {
        save(.model(model))
        phase = .preparing
        await server.start()
        await models.prepare(model)
        if models.state == .ready { phase = .running }
    }

    func runAppleIntelligenceOnly() async {
        models.unload()
        save(.appleIntelligenceOnly)
        await server.start()
        phase = .running
    }

    func retryPreparing() async {
        await models.retry()
        if models.state == .ready { phase = .running }
    }

    /// Back to the chooser, keeping the server up with whatever is loaded.
    func changeModel() async {
        await refreshEnvironment()
        selectedID = currentModel?.id ?? advice?.recommended?.id
        phase = .choose
    }

    /// "Change model" can be abandoned when something is already being served.
    var canCancelChoosing: Bool { choice != nil }

    func cancelChoosing() {
        guard canCancelChoosing else { return }
        selectedID = currentModel?.id
        phase = .running
    }

    var currentModel: CatalogModel? {
        if case .model(let model) = choice { return model }
        return nil
    }

    private func save(_ choice: Choice) {
        self.choice = choice
        if let data = try? JSONEncoder().encode(choice) {
            UserDefaults.standard.set(data, forKey: choiceKey)
        }
    }

    // MARK: - Serving controls

    func toggleServer() async {
        if server.isRunning { server.stop() } else { await server.start() }
    }

    // MARK: - Launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Hearth: launch at login change failed: \(error.localizedDescription)")
            }
        }
    }
}
