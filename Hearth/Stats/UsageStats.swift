import Foundation
import Observation

/// Everything the menu bar shows live: current speed, today's totals, who's calling, recent requests.
@MainActor
@Observable
final class UsageStats {
    struct Client: Identifiable, Hashable, Codable {
        let name: String
        var lastSeen: Date
        var tokensToday: Int
        var requestsToday: Int
        var id: String { name }
    }

    struct RequestRecord: Identifiable, Hashable, Codable {
        var id = UUID()
        let client: String
        let model: String
        let started: Date
        var promptTokens = 0
        var completionTokens = 0
        var duration: TimeInterval = 0
        /// When the first token arrived; speed is measured from here, so model warm-up doesn't drag it down.
        var firstTokenAt: Date?
        /// When the model started on this request (after waiting in the MLX queue).
        var generationStartedAt: Date?
        /// Prompt processing time reported by MLX. Nil for Apple Intelligence (not exposed).
        var promptSeconds: Double?
        var tokensPerSecond: Double = 0
        var status: Status = .running

        /// Time to first token: request in → first token out (includes queueing and prompt processing).
        var ttft: TimeInterval? { firstTokenAt.map { $0.timeIntervalSince(started) } }

        /// Time spent waiting for another request to finish.
        var queueSeconds: TimeInterval? { generationStartedAt.map { $0.timeIntervalSince(started) } }

        /// Prompt processing speed: measured by MLX, or estimated as prompt tokens ÷ TTFT.
        var promptSpeed: Double? {
            guard promptTokens > 0 else { return nil }
            if let promptSeconds, promptSeconds > 0.001 { return Double(promptTokens) / promptSeconds }
            guard let ttft, ttft > 0.05 else { return nil }
            return Double(promptTokens) / ttft
        }

        var promptSpeedIsMeasured: Bool { promptSeconds != nil }

        enum Status: Hashable, Codable {
            case running
            case done
            case failed(String)
            case cancelled
        }
    }

    /// Smoothed tokens/sec right now; 0 when idle.
    private(set) var currentRate: Double = 0
    private(set) var activeRequests = 0
    private(set) var requestsToday = 0
    private(set) var tokensToday = 0
    private(set) var clients: [Client] = []
    private(set) var recent: [RequestRecord] = []
    /// Best measured speed per model id, for "measured vs estimated".
    private(set) var measuredSpeed: [String: Double] = [:]
    /// Today's requests and output tokens per model id.
    private(set) var byModel: [String: ModelUsage] = [:]

    struct ModelUsage: Hashable, Codable {
        var requests = 0
        var tokens = 0
    }

    var isGenerating: Bool { activeRequests > 0 }

    /// Called when a request starts, so lower-priority on-device work (agent summaries) can step aside.
    @ObservationIgnored var onBegin: () -> Void = {}

    /// tok/s sampled once a second for the last two minutes (menu bar sparkline).
    private(set) var rateHistory: [Double] = Array(repeating: 0, count: UsageStats.historySeconds)
    static let historySeconds = 120

    private var tokenTimes: [Date] = []
    private var timer: Timer?
    private var historyTimer: Timer?
    private var day: Date

    /// Requests kept on disk (metadata only: app, model, time, token counts, speed; never prompts or replies).
    static let historyLimit = 500
    static let historyDays = 7

    init() {
        day = Calendar.current.startOfDay(for: .now)
        restore()
        historyTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleRate() }
        }
    }

    private func sampleRate() {
        // Nothing to scroll while idle and already flat; skip the redraw.
        if currentRate == 0, activeRequests == 0, rateHistory.allSatisfy({ $0 == 0 }) { return }
        rateHistory.append(currentRate)
        if rateHistory.count > Self.historySeconds { rateHistory.removeFirst(rateHistory.count - Self.historySeconds) }
    }

    /// What the same requests would have cost on a cloud model (finished requests since `date`).
    func cloudCost(since date: Date, at price: CloudPrice) -> (cost: Double, tokens: Int) {
        recent.filter { $0.started >= date && $0.status != .running }
            .reduce((cost: 0.0, tokens: 0)) { total, record in
                (cost: total.cost + price.cost(input: record.promptTokens, output: record.completionTokens),
                 tokens: total.tokens + record.promptTokens + record.completionTokens)
            }
    }

    // MARK: - Recording

    func begin(client: String, model: String) -> UUID {
        onBegin()
        rollDayIfNeeded()
        activeRequests += 1
        requestsToday += 1
        touch(client: client, tokens: 0, newRequest: true)
        byModel[model, default: ModelUsage()].requests += 1
        let record = RequestRecord(client: client, model: model, started: .now)
        recent.insert(record, at: 0)
        if recent.count > Self.historyLimit { recent.removeLast(recent.count - Self.historyLimit) }
        startTimer()
        save()
        return record.id
    }

    /// Call once per streamed token (or chunk).
    func token(for id: UUID, client: String, count: Int = 1) {
        let now = Date.now
        for _ in 0..<count { tokenTimes.append(now) }
        tokensToday += count
        touch(client: client, tokens: count, newRequest: false)
        update(id) { record in
            if record.firstTokenAt == nil { record.firstTokenAt = now }
            record.completionTokens += count
        }
    }

    /// The request left the queue and the model started on it.
    func markGenerating(_ id: UUID) {
        update(id) { $0.generationStartedAt = .now }
    }

    func finish(_ id: UUID, promptTokens: Int, completionTokens: Int, status: RequestRecord.Status,
                promptSeconds: Double? = nil) {
        activeRequests = max(0, activeRequests - 1)
        update(id) { record in
            // Trust the engine's final count over our chunk count.
            if completionTokens > 0 {
                tokensToday += completionTokens - record.completionTokens
                record.completionTokens = completionTokens
            }
            record.promptTokens = promptTokens
            if let promptSeconds { record.promptSeconds = promptSeconds }
            let end = Date.now
            record.duration = end.timeIntervalSince(record.started)
            let generating = end.timeIntervalSince(record.firstTokenAt ?? record.started)
            // Too short to measure meaningfully (a few tokens in a few ms): leave it blank.
            record.tokensPerSecond = generating > 0.2 && record.completionTokens > 2
                ? Double(record.completionTokens) / generating : 0
            record.status = status
            byModel[record.model, default: ModelUsage()].tokens += record.completionTokens
        }
        save()
    }

    func recordSpeed(_ tokensPerSecond: Double, model: String) {
        guard tokensPerSecond.isFinite, tokensPerSecond > 0 else { return }
        measuredSpeed[model] = max(measuredSpeed[model] ?? 0, tokensPerSecond)
    }

    // MARK: - Internals

    private func touch(client: String, tokens: Int, newRequest: Bool) {
        if let index = clients.firstIndex(where: { $0.name == client }) {
            clients[index].lastSeen = .now
            clients[index].tokensToday += tokens
            if newRequest { clients[index].requestsToday += 1 }
        } else {
            clients.append(Client(name: client, lastSeen: .now, tokensToday: tokens, requestsToday: newRequest ? 1 : 0))
        }
        clients.sort { $0.lastSeen > $1.lastSeen }
    }

    private func update(_ id: UUID, _ change: (inout RequestRecord) -> Void) {
        guard let index = recent.firstIndex(where: { $0.id == id }) else { return }
        change(&recent[index])
    }

    /// Rate = tokens in the last 2 s; ticks every 250 ms and stops once idle.
    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        let window: TimeInterval = 2
        let cutoff = Date.now.addingTimeInterval(-window)
        tokenTimes.removeAll { $0 < cutoff }
        let instant = Double(tokenTimes.count) / window
        // Light smoothing so the menu bar number doesn't flicker.
        currentRate = currentRate * 0.5 + instant * 0.5
        if currentRate < 0.5 { currentRate = 0 }
        if activeRequests == 0 && tokenTimes.isEmpty && currentRate == 0 {
            timer?.invalidate()
            timer = nil
        }
    }

    private func rollDayIfNeeded() {
        let today = Calendar.current.startOfDay(for: .now)
        guard today != day else { return }
        day = today
        requestsToday = 0
        tokensToday = 0
        clients = []
        byModel = [:]
    }

    // MARK: - Persistence

    /// Survives relaunches: recent requests, today's totals, per-app and per-model usage, measured speeds.
    /// Stored as JSON in Application Support. Only metadata; prompts and replies are never written.
    private struct Saved: Codable {
        var schema = 2
        let day: Date
        let requests: Int
        let tokens: Int
        let clients: [Client]
        let byModel: [String: ModelUsage]
        let recent: [RequestRecord]
        let measuredSpeed: [String: Double]
    }

    private static var fileURL: URL {
        URL.applicationSupportDirectory.appending(path: "Hearth").appending(path: "usage.json")
    }

    private func save() {
        let saved = Saved(day: day, requests: requestsToday, tokens: tokensToday, clients: clients,
                          byModel: byModel, recent: recent, measuredSpeed: measuredSpeed)
        guard let data = try? JSONEncoder().encode(saved) else { return }
        let url = Self.fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private func restore() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }

        let cutoff = Calendar.current.date(byAdding: .day, value: -Self.historyDays, to: .now) ?? .distantPast
        recent = saved.recent
            .filter { $0.started >= cutoff }
            .prefix(Self.historyLimit)
            .map { record in
                var record = record
                // The app quit while this was generating.
                if record.status == .running { record.status = .cancelled }
                return record
            }
        measuredSpeed = saved.measuredSpeed

        // Today's counters only carry over on the same day.
        guard saved.day == day else { return }
        requestsToday = saved.requests
        tokensToday = saved.tokens
        clients = saved.clients
        byModel = saved.byModel
    }

    /// Per-model medians over the stored history, for the performance summary.
    struct Performance: Identifiable, Hashable {
        let model: String
        let requests: Int
        let outputTokens: Int
        let medianTTFT: TimeInterval?
        let p90TTFT: TimeInterval?
        let medianSpeed: Double?
        let medianPromptSpeed: Double?
        var id: String { model }
    }

    var performance: [Performance] {
        let finished = recent.filter { $0.status == .done }
        let grouped = Dictionary(grouping: finished, by: \.model)
        return grouped.map { model, records in
            let ttfts = records.compactMap(\.ttft).sorted()
            return Performance(
                model: model,
                requests: records.count,
                outputTokens: records.reduce(0) { $0 + $1.completionTokens },
                medianTTFT: Self.percentile(ttfts, 0.5),
                p90TTFT: ttfts.count >= 5 ? Self.percentile(ttfts, 0.9) : nil,
                medianSpeed: Self.percentile(records.map(\.tokensPerSecond).filter { $0 > 0 }.sorted(), 0.5),
                medianPromptSpeed: Self.percentile(records.compactMap(\.promptSpeed).sorted(), 0.5)
            )
        }
        .sorted { $0.requests > $1.requests }
    }

    private static func percentile(_ sorted: [Double], _ p: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let index = Int((Double(sorted.count - 1) * p).rounded())
        return sorted[min(max(index, 0), sorted.count - 1)]
    }

    func clearHistory() {
        recent = []
        save()
    }
}
