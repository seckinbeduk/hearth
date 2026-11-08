import SwiftUI

/// The details window once Hearth is serving: endpoint, how to use it, a quick test, recent requests.
struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @State private var snippet: Snippet = .curl
    @State private var chosenTarget: String?
    @State private var tab: Tab = .server

    private enum Tab: String, CaseIterable, Identifiable {
        case server = "Server", agents = "Agents"
        var id: String { rawValue }
    }

    /// The models this endpoint answers with.
    private struct Target: Identifiable, Hashable {
        let id: String      // value for the `model` field
        let title: String
    }

    private var targets: [Target] {
        var list: [Target] = []
        if let local = model.models.activeModel { list.append(Target(id: local.slug, title: local.displayName)) }
        if model.hardware?.appleIntelligence.isUsable == true {
            list.append(Target(id: AppleIntelligenceBackend.modelID, title: "Apple Intelligence"))
        }
        return list
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Picker("Show", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                switch tab {
                case .server:
                    header
                    endpointCard
                    SavingsCard()
                    TryBox(baseURL: model.server.baseURL, model: modelName)
                    RequestsCard()
                    if let hw = model.hardware { footer(hw) }
                case .agents:
                    AgentsTab()
                }
            }
            .padding(32)
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
        }
    }

    /// The model the examples and the test box use.
    private var modelName: String {
        if let chosenTarget, targets.contains(where: { $0.id == chosenTarget }) { return chosenTarget }
        return targets.first?.id ?? AppleIntelligenceBackend.modelID
    }

    private var isApple: Bool { modelName == AppleIntelligenceBackend.modelID }

    // MARK: - Header

    /// Hearth first, then the models it answers with, side by side: neither is an add-on to the other.
    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Hearth")
                    .font(.largeTitle.weight(.semibold))
                Badge(text: statusText, color: model.server.isRunning ? Theme.ready : .secondary)
            }
            HStack(alignment: .top, spacing: 12) {
                ModelTile(
                    symbol: "flame.fill", color: Theme.flame,
                    name: model.models.activeModel?.displayName ?? "No local model",
                    status: localStatus,
                    modelID: model.models.activeModel == nil ? nil : "hearth",
                    detail: localDetail,
                    speed: speedLine
                ) {
                    Button(model.models.activeModel == nil ? "Choose a model" : "Change model") {
                        Task { await model.changeModel() }
                    }
                    .controlSize(.small)
                }
                if model.hardware?.appleIntelligence.isUsable == true {
                    ModelTile(
                        symbol: "sparkles", color: Theme.apple,
                        name: "Apple Intelligence",
                        status: model.server.isRunning ? ("Running", Theme.ready) : ("Paused", .secondary),
                        modelID: AppleIntelligenceBackend.modelID,
                        detail: "On-device · free · no download",
                        speed: model.stats.measuredSpeed[AppleIntelligenceBackend.modelID].map { "Measured \(Format.speed($0))" }
                    ) { EmptyView() }
                }
            }
            .fixedSize(horizontal: false, vertical: true)   // both tiles as tall as the taller one
        }
    }

    private var localStatus: (String, Color) {
        switch model.models.state {
        case .ready: return model.server.isRunning ? ("Running", Theme.ready) : ("Paused", .secondary)
        case .downloading(let p): return ("Downloading \(Int(p * 100))%", Theme.apple)
        case .loading: return ("Loading", Theme.apple)
        case .failed: return ("Error", .red)
        case .idle: return ("Off", .secondary)
        }
    }

    private var localDetail: String {
        switch model.models.state {
        case .downloading(let p): return "Downloading \(Int(p * 100))%"
        case .loading: return "Loading into memory"
        case .failed: return "Couldn't load"
        case .idle: return model.models.activeModel == nil ? "Runs on your GPU with MLX" : "Not loaded"
        case .ready: return "MLX · 4-bit · \(Format.bytes(model.monitor.footprintBytes)) in memory"
        }
    }

    private var statusText: String {
        switch model.models.state {
        case .downloading(let p): return "Downloading \(Int(p * 100))%"
        case .loading: return "Loading"
        case .failed: return "Model error"
        default: break
        }
        switch model.server.status {
        case .running: return "Serving"
        case .stopped: return "Paused"
        case .failed(let message): return message
        }
    }

    /// Measured speed next to the estimate, once we have a real number.
    private var speedLine: String? {
        guard let active = model.models.activeModel else { return nil }
        let estimate = model.advice?.fit(for: active.id)?.tokensPerSecond
            ?? model.advice?.existing.first { $0.model?.id == active.id }?.tokensPerSecond
        if let measured = model.stats.measuredSpeed[active.id] {
            var text = "Measured \(Format.speed(measured))"
            if let estimate { text += " (estimated \(Format.speed(estimate)))" }
            return text
        }
        return estimate.map { "Estimated \(Format.speed($0)), measured after the first request" }
    }

    // MARK: - Endpoint

    private var endpointCard: some View {
        Card {
            HStack {
                Text("Your local endpoint")
                    .font(.headline)
                Spacer()
                Text("OpenAI-compatible · this Mac only")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            EndpointField(url: model.server.baseURL)

            if targets.count > 1 {
                HStack(spacing: 10) {
                    Text("Model").foregroundStyle(.secondary)
                    Picker("Model", selection: Binding(get: { modelName }, set: { chosenTarget = $0 })) {
                        ForEach(targets) { Text($0.title).tag($0.id) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                }
                Text(isApple
                     ? "Apple's on-device model: free, no download, ~4K context. Great for summaries, rewriting and quick answers."
                     : "Your local MLX model on the GPU: longer context, better for code and longer reasoning.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                LabeledValue(label: "Model", value: modelName)
                LabeledValue(label: "API key", value: "any (not checked)")
            }

            Picker("Example", selection: $snippet) {
                ForEach(Snippet.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            let code = snippet.code(baseURL: model.server.baseURL, model: modelName)
            ZStack(alignment: .topTrailing) {
                ScrollView(.horizontal) {
                    Text(code)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 8))
                CopyButton(text: code, label: "Copy")
                    .controlSize(.small)
                    .padding(8)
            }
        }
    }

    private func footer(_ hw: HardwareProfile) -> some View {
        HStack(spacing: 6) {
            Text("\(hw.chipName) · \(Int(hw.physicalMemoryGB.rounded())) GB")
            Text("·")
            Text("Hearth using \(Format.bytes(model.monitor.footprintBytes))")
            Text("·")
            Text("Memory pressure \(model.monitor.pressureTitle.lowercased())")
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
}

private struct LabeledValue: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
        }
    }
}

// MARK: - Recent requests

private struct RequestsCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card {
            HStack(alignment: .firstTextBaseline) {
                Text("Recent requests")
                    .font(.headline)
                Spacer()
                if !model.stats.recent.isEmpty {
                    Button("Clear") { model.stats.clearHistory() }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
            }
            Text("Kept on this Mac for \(UsageStats.historyDays) days. Only counts and timings are saved, never prompts or replies.")
                .font(.caption)
                .foregroundStyle(.secondary)
            let performance = model.stats.performance
            if !performance.isEmpty {
                PerformanceSummary(rows: performance)
                Divider()
            }
            if model.stats.recent.isEmpty {
                Text("Nothing yet. Try the box above or run one of the examples.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow {
                        Text("App"); Text("Model"); Text("When")
                        Text("In").gridColumnAlignment(.trailing)
                        Text("Out").gridColumnAlignment(.trailing)
                        Text("TTFT").gridColumnAlignment(.trailing)
                        Text("Time").gridColumnAlignment(.trailing)
                        Text("Speed").gridColumnAlignment(.trailing)
                        Text("Status")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Divider()
                    ForEach(model.stats.recent.prefix(25)) { record in
                        GridRow {
                            Label(record.client, systemImage: ClientIdentifier.symbol(for: record.client))
                            Text(record.model.split(separator: "/").last.map(String.init) ?? record.model)
                                .lineLimit(1)
                            Text(Calendar.current.isDateInToday(record.started)
                                 ? record.started.formatted(date: .omitted, time: .shortened)
                                 : record.started.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
                            Text("\(record.promptTokens)").monospacedDigit()
                            Text("\(record.completionTokens)").monospacedDigit()
                            Text(record.ttft.map(Format.duration) ?? "–")
                                .monospacedDigit()
                                .help(promptHelp(record))
                            Text(record.status == .running ? "…" : Format.duration(record.duration))
                                .monospacedDigit()
                            Text(record.tokensPerSecond > 0 ? Format.speed(record.tokensPerSecond) : "–").monospacedDigit()
                            status(record.status)
                        }
                        .font(.callout)
                    }
                }
            }
        }
    }

    private func promptHelp(_ record: UsageStats.RequestRecord) -> String {
        var parts: [String] = []
        if let queue = record.queueSeconds, queue >= 0.05 { parts.append("Queue \(Format.duration(queue))") }
        if let seconds = record.promptSeconds {
            parts.append("Prompt \(Format.duration(seconds))")
        }
        if let speed = record.promptSpeed {
            parts.append((record.promptSpeedIsMeasured ? "" : "~") + "\(Format.speed(speed)) prompt"
                         + (record.promptSpeedIsMeasured ? "" : " (estimated)"))
        }
        return parts.isEmpty ? "Time to first token" : "Time to first token · " + parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func status(_ status: UsageStats.RequestRecord.Status) -> some View {
        switch status {
        case .running: ProgressView().controlSize(.mini)
        case .done: Image(systemName: "checkmark.circle").foregroundStyle(Theme.ready)
        case .cancelled: Image(systemName: "stop.circle").foregroundStyle(.secondary)
        case .failed(let message): Image(systemName: "exclamationmark.triangle").foregroundStyle(.red).help(message)
        }
    }
}

/// What the same tokens would have cost in the cloud.
private struct SavingsCard: View {
    @Environment(AppModel.self) private var model
    @AppStorage(CloudPrice.storageKey) private var referenceID = CloudPrice.defaultID

    var body: some View {
        let price = CloudPrice.with(id: referenceID)
        let today = model.stats.cloudCost(since: Calendar.current.startOfDay(for: .now), at: price)
        let week = model.stats.cloudCost(
            since: Calendar.current.date(byAdding: .day, value: -UsageStats.historyDays, to: .now) ?? .distantPast,
            at: price)
        Card {
            HStack {
                Label("Saved by running locally", systemImage: "leaf")
                    .font(.headline)
                Spacer()
                Picker("Compared with", selection: $referenceID) {
                    ForEach(CloudPrice.all) { Text($0.name).tag($0.id) }
                }
                .fixedSize()
            }
            HStack(spacing: 10) {
                SavingsStat(label: "Today", cost: today.cost, tokens: today.tokens)
                SavingsStat(label: "Last \(UsageStats.historyDays) days", cost: week.cost, tokens: week.tokens)
                SavingsStat(label: "On this Mac", cost: 0, tokens: nil)
            }
            Text("Same input and output tokens at \(price.name) list prices (\(Format.usd(price.inputPerMTok)) in / \(Format.usd(price.outputPerMTok)) out per 1M tokens, checked \(CloudPrice.checkedOn)). Electricity not included.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SavingsStat: View {
    let label: String
    let cost: Double
    let tokens: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(Format.usd(cost)).font(.title3.weight(.medium)).monospacedDigit()
                .foregroundStyle(tokens == nil ? Theme.ready : .primary)
            Text(tokens.map { "\(Format.compact($0)) tokens" } ?? "what you paid")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 8))
    }
}

/// Medians per model over the stored history.
private struct PerformanceSummary: View {
    let rows: [UsageStats.Performance]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
            GridRow {
                Text("Model")
                Text("Requests").gridColumnAlignment(.trailing)
                Text("Output").gridColumnAlignment(.trailing)
                Text("TTFT p50").gridColumnAlignment(.trailing)
                Text("TTFT p90").gridColumnAlignment(.trailing)
                Text("Speed p50").gridColumnAlignment(.trailing)
                Text("Prompt p50").gridColumnAlignment(.trailing)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            ForEach(rows) { row in
                GridRow {
                    Text(row.model.split(separator: "/").last.map(String.init) ?? row.model)
                        .font(.callout.weight(.medium))
                    Text("\(row.requests)")
                    Text(Format.compact(row.outputTokens) + " tok")
                    Text(row.medianTTFT.map(Format.duration) ?? "–")
                    Text(row.p90TTFT.map(Format.duration) ?? "–")
                        .help("Shown after 5 requests")
                    Text(row.medianSpeed.map(Format.speed) ?? "–")
                    Text(row.medianPromptSpeed.map(Format.speed) ?? "–")
                        .help("Prompt processing speed (prefill). Measured by MLX; estimated from TTFT for Apple Intelligence.")
                }
                .font(.callout)
                .monospacedDigit()
            }
        }
    }
}

// MARK: - Try it

/// Sends a prompt through the real endpoint, so it also proves the server works.
private struct TryBox: View {
    let baseURL: String
    let model: String

    @State private var prompt = ""
    @State private var reply = ""
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var started: Date?
    @State private var firstToken: Date?
    @State private var finished: Date?
    @State private var chunks = 0

    var body: some View {
        Card {
            HStack {
                Text("Try it")
                    .font(.headline)
                Spacer()
                Text("model: \(model)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            HStack {
                TextField("Ask something", text: $prompt)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                if task != nil {
                    Button("Stop") { task?.cancel(); task = nil; finished = .now }
                } else {
                    Button("Send", action: send)
                        .keyboardShortcut(.defaultAction)
                        .disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if !reply.isEmpty {
                // Long answers scroll inside the box instead of stretching the whole window.
                ScrollView {
                    MarkdownView(text: reply)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 360)
                .defaultScrollAnchor(.bottom)
            }
            if started != nil {
                HStack {
                    TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                        Text(statsLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Spacer()
                    if task == nil {
                        CopyButton(text: reply, label: "Copy")
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            .disabled(reply.isEmpty)
                        Button {
                            clear()
                        } label: {
                            Label("Clear", systemImage: "trash")
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    }
                }
            }
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
        }
    }

    /// "1,707 tokens · 2m 21s · 12 tok/s · first token 0.4s"
    private var statsLine: String {
        guard let started else { return "" }
        let end = finished ?? .now
        var parts = ["\(chunks.formatted()) tokens", Format.duration(end.timeIntervalSince(started))]
        if let firstToken {
            let generating = end.timeIntervalSince(firstToken)
            if generating > 0.2, chunks > 2 { parts.append(Format.speed(Double(chunks) / generating)) }
            parts.append("TTFT \(Format.duration(firstToken.timeIntervalSince(started)))")
        } else if task != nil {
            parts.append("waiting for the model…")
        }
        return parts.joined(separator: " · ")
    }

    private func clear() {
        task?.cancel()
        task = nil
        prompt = ""
        reply = ""
        error = nil
        started = nil
        firstToken = nil
        finished = nil
        chunks = 0
    }

    private func send() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, task == nil else { return }
        reply = ""
        error = nil
        chunks = 0
        started = .now
        firstToken = nil
        finished = nil
        task = Task {
            do {
                for try await delta in Self.stream(baseURL: baseURL, model: model, prompt: text) {
                    if firstToken == nil { firstToken = .now }
                    chunks += 1
                    reply += delta
                }
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
            if finished == nil { finished = .now }
            task = nil
        }
    }

    private static func stream(baseURL: String, model: String, prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: URL(string: baseURL + "/chat/completions")!)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("Hearth", forHTTPHeaderField: "User-Agent")
                    let body: [String: Any] = [
                        "model": model,
                        "stream": true,
                        "messages": [["role": "user", "content": prompt]],
                    ]
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        var data = Data()
                        for try await byte in bytes { data.append(byte) }
                        let message = (try? JSONDecoder().decode(OpenAIError.self, from: data))?.error.message
                        throw TryError(message: message ?? "The server answered \(http.statusCode).")
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = line.dropFirst(6)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        if let err = json["error"] as? [String: Any], let message = err["message"] as? String {
                            throw TryError(message: message)
                        }
                        let choices = json["choices"] as? [[String: Any]]
                        if let delta = choices?.first?["delta"] as? [String: Any], let content = delta["content"] as? String {
                            continuation.yield(content)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private struct TryError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}

/// One model Hearth answers with: what it is, how fast it's been, and the name clients send.
private struct ModelTile<Accessory: View>: View {
    let symbol: String
    let color: Color
    let name: String
    let status: (String, Color)
    let modelID: String?
    let detail: String
    let speed: String?
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(color)
                Text(name).font(.title3.weight(.semibold))
                Badge(text: status.0, color: status.1)
                Spacer(minLength: 8)
                accessory()
            }
            Text(detail).font(.callout).foregroundStyle(.secondary)
            if let speed { Text(speed).font(.callout).foregroundStyle(.secondary) }
            if let modelID {
                Text("model: \(modelID)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(color.opacity(0.07), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(color.opacity(0.18)))
    }
}
