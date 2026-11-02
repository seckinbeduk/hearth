import SwiftUI
import Charts

/// The panel under the menu bar item: what's running, the endpoint, live numbers, who's calling.
struct MenuPanel: View {
    @Environment(AppModel.self) private var model
    @AppStorage(CloudPrice.storageKey) private var referenceID = CloudPrice.defaultID

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if model.server.isRunning {
                EndpointField(url: model.server.baseURL)
            }
            if case .downloading(let progress) = model.models.state {
                ProgressView(value: progress) {
                    Text("Downloading \(model.models.activeModel?.displayName ?? "model")")
                        .font(.caption)
                }
            }
            metrics
            ActivityGraph(history: model.stats.rateHistory)
            savingsLine
            servedModels
            clients
            environment
            actions
        }
        .padding(14)
        .frame(width: 340)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Badge(text: statusText, color: statusColor)
        }
    }

    /// The panel is about the server, which can answer with more than one model; each model's
    /// details are in "Models on this endpoint".
    private var title: String { "Hearth" }

    private var subtitle: String {
        if model.needsSetup { return "Finish setup to start serving" }
        var serving: [String] = []
        if let local = model.models.activeModel, model.models.state == .ready { serving.append(local.displayName) }
        if model.hardware?.appleIntelligence.isUsable == true { serving.append("Apple Intelligence") }
        guard !serving.isEmpty else { return "No model loaded" }
        return "Serving " + ListFormatter.localizedString(byJoining: serving)
    }

    private var statusText: String {
        if model.stats.isGenerating { return "Generating" }
        switch model.models.state {
        case .downloading(let p): return "Downloading \(Int(p * 100))%"
        case .loading: return "Loading"
        case .failed: return "Error"
        default: break
        }
        if case .failed = model.server.status { return "Server error" }
        return model.server.isRunning ? "Ready" : "Paused"
    }

    private var statusColor: Color {
        if model.stats.isGenerating { return Theme.flame }
        switch model.models.state {
        case .downloading, .loading: return Theme.apple
        case .failed: return .red
        default: break
        }
        return model.server.isRunning ? Theme.ready : .secondary
    }

    // MARK: - Numbers

    private var metrics: some View {
        HStack(spacing: 8) {
            Metric(label: "Now", value: "\(Int(model.stats.currentRate.rounded()))", unit: "tok/s")
            Metric(label: "Today", value: "\(model.stats.requestsToday)", unit: "requests")
            Metric(label: "Today", value: Format.compact(model.stats.tokensToday), unit: "tokens")
        }
    }

    @ViewBuilder
    private var savingsLine: some View {
        let price = CloudPrice.with(id: referenceID)
        let today = model.stats.cloudCost(since: Calendar.current.startOfDay(for: .now), at: price)
        if today.tokens > 0 {
            Label("≈ \(Format.usd(today.cost)) saved today vs \(price.name)", systemImage: "leaf")
                .font(.caption)
                .foregroundStyle(Theme.ready)
                .help("Today's \(today.tokens.formatted()) tokens at \(price.name) list prices, checked \(CloudPrice.checkedOn).")
        }
    }

    /// Every model this endpoint answers with, and how each is being used today.
    @ViewBuilder
    private var servedModels: some View {
        let local = model.models.activeModel
        let apple = model.hardware?.appleIntelligence.isUsable == true
        if local != nil || apple {
            VStack(alignment: .leading, spacing: 6) {
                Text("Models on this endpoint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                VStack(spacing: 0) {
                    if let local {
                        ServedModelRow(name: local.displayName, modelID: "hearth", symbol: "flame",
                                       color: Theme.flame, usage: model.stats.byModel[local.id],
                                       speed: model.stats.measuredSpeed[local.id], status: localStatus)
                    }
                    if local != nil && apple { Divider() }
                    if apple {
                        ServedModelRow(name: "Apple Intelligence", modelID: AppleIntelligenceBackend.modelID,
                                       symbol: "sparkles", color: Theme.apple,
                                       usage: model.stats.byModel[AppleIntelligenceBackend.modelID],
                                       speed: model.stats.measuredSpeed[AppleIntelligenceBackend.modelID],
                                       status: "On-device · free")
                    }
                }
            }
        }
    }

    private var localStatus: String {
        switch model.models.state {
        case .downloading(let p): "Downloading \(Int(p * 100))%"
        case .loading: "Loading"
        case .failed: "Error"
        case .ready: "MLX · 4-bit · \(Format.bytes(model.monitor.footprintBytes))"
        case .idle: "Not loaded"
        }
    }

    @ViewBuilder
    private var clients: some View {
        if !model.stats.clients.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Who's using it")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TimelineView(.periodic(from: .now, by: 5)) { _ in
                    VStack(spacing: 0) {
                        ForEach(model.stats.clients.prefix(4)) { client in
                            HStack {
                                Label(client.name, systemImage: ClientIdentifier.symbol(for: client.name))
                                Spacer()
                                Text("\(Format.ago(client.lastSeen)) · \(Format.compact(client.tokensToday)) tokens")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            .font(.callout)
                            .padding(.vertical, 5)
                            if client.id != model.stats.clients.prefix(4).last?.id { Divider() }
                        }
                    }
                }
            }
        } else if model.server.isRunning {
            Text("Point any OpenAI-compatible app at the address above. Requests will show up here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Environment

    private var environment: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let ai = model.hardware?.appleIntelligence, !ai.isUsable, ai != .unsupportedOS {
                Label("Apple Intelligence: \(ai.title.lowercased())", systemImage: "sparkles")
            }
            ForEach(model.discovery.servers) { server in
                Label("\(server.name) is also running (\(String(server.port)))", systemImage: "server.rack")
            }
            Label("Memory pressure: \(model.monitor.pressureTitle.lowercased()) · Heat: \(model.monitor.thermalTitle.lowercased())",
                  systemImage: "thermometer.medium")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: 8) {
            Button("Details") { showMainWindow() }
            Button("Change model") {
                Task { await model.changeModel() }
                showMainWindow()
            }
            Spacer()
            Button {
                Task { await model.toggleServer() }
            } label: {
                Image(systemName: model.server.isRunning ? "pause.fill" : "play.fill")
            }
            .help(model.server.isRunning ? "Pause the server" : "Resume the server")
            .disabled(model.needsSetup)

            SettingsMenu()
        }
        .controlSize(.regular)
    }

    private func showMainWindow() {
        model.showMainWindow()
    }
}

/// tok/s over the last two minutes.
private struct ActivityGraph: View {
    let history: [Double]

    var body: some View {
        let peak = history.max() ?? 0
        VStack(alignment: .leading, spacing: 3) {
            Chart(Array(history.enumerated()), id: \.offset) { point in
                AreaMark(x: .value("Second", point.offset), y: .value("tok/s", point.element))
                    .foregroundStyle(Theme.flame.opacity(0.18))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Second", point.offset), y: .value("tok/s", point.element))
                    .foregroundStyle(Theme.flame)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.monotone)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartXScale(domain: 0...max(1, history.count - 1))
            .chartYScale(domain: 0...max(5, peak * 1.15))
            .frame(height: 38)
            HStack {
                Text("Last 2 min")
                Spacer()
                if peak > 0 { Text("peak \(Format.speed(peak))").monospacedDigit() }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }
}

private struct ServedModelRow: View {
    let name: String
    let modelID: String
    let symbol: String
    let color: Color
    let usage: UsageStats.ModelUsage?
    let speed: Double?
    let status: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.callout.weight(.medium))
                HStack(spacing: 4) {
                    Text("model: \(modelID)")
                        .font(.system(.caption2, design: .monospaced))
                    CopyButton(text: modelID)
                        .buttonStyle(.borderless)
                        .controlSize(.mini)
                }
                .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(usageText).font(.caption).monospacedDigit()
                Text(status).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
    }

    private var usageText: String {
        var parts: [String] = []
        if let usage, usage.requests > 0 { parts.append("\(usage.requests) req") }
        if let speed { parts.append(Format.speed(speed)) }
        return parts.isEmpty ? "Ready" : parts.joined(separator: " · ")
    }
}

private struct Metric: View {
    let label: String
    let value: String
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            Text(unit).font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 8))
    }
}

private struct SettingsMenu: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = false

    var body: some View {
        Menu {
            Toggle("Open at login", isOn: $launchAtLogin)
            Button("Rescan this Mac") { Task { await model.refreshEnvironment() } }
            Divider()
            Button("Quit Hearth") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: "gearshape")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .onAppear { launchAtLogin = model.launchAtLogin }
        .onChange(of: launchAtLogin) { _, value in
            if value != model.launchAtLogin { model.launchAtLogin = value }
        }
    }
}
