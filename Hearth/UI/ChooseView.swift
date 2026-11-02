import SwiftUI

/// Setup screen: this Mac, what's already here, and one clear pick.
struct ChooseView: View {
    @Environment(AppModel.self) private var model
    @State private var showAll = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.canCancelChoosing ? "Choose a local model" : "Here's what your Mac can run")
                            .font(.largeTitle.weight(.semibold))
                        Text(model.canCancelChoosing
                             ? "Apple Intelligence is always served alongside it. Everything runs on this Mac."
                             : "Everything runs on this Mac. Nothing you send leaves it.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.canCancelChoosing {
                        Button("Cancel") { model.cancelChoosing() }
                            .keyboardShortcut(.cancelAction)
                            .help("Keep the current model")
                    }
                }

                if let hw = model.hardware {
                    HStack(alignment: .top, spacing: 14) {
                        HardwareCard(hw: hw)
                        AppleIntelligenceCard(status: hw.appleIntelligence)
                    }
                }

                if !model.discovery.isEmpty {
                    AlreadyHereCard()
                }

                if let advice = model.advice {
                    ForEach(advice.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Theme.warning)
                            .font(.callout)
                    }

                    if let fit = selectedFit(advice) {
                        PickCard(fit: fit, reason: fit.isRecommended ? advice.reason : nil)
                    }

                    DisclosureGroup(isExpanded: $showAll) {
                        VStack(spacing: 0) {
                            ForEach(advice.fits) { fit in
                                ModelRow(fit: fit, isSelected: fit.id == model.selectedID) {
                                    model.selectedID = fit.id
                                }
                                Divider()
                            }
                        }
                        .padding(.top, 6)
                    } label: {
                        Text("All models (\(advice.fits.count))")
                            .font(.headline)
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
        .task {
            // Pick up Apple Intelligence being switched on while this screen is open.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                await model.refreshAppleIntelligence()
            }
        }
    }

    private func selectedFit(_ advice: ModelAdvice) -> ModelFit? {
        if let id = model.selectedID {
            if let fit = advice.fit(for: id) { return fit }
            // An MLX model found on disk but not in the catalog
            if let review = advice.existing.first(where: { $0.model?.id == id }), let m = review.model {
                return ModelFit(model: m, verdict: review.verdict, context: 8_192,
                                memoryGB: m.memoryGB(context: 8_192), tokensPerSecond: review.tokensPerSecond,
                                isDownloaded: true)
            }
        }
        return advice.recommended
    }
}

// MARK: - Hardware

private struct HardwareCard: View {
    let hw: HardwareProfile

    var body: some View {
        Card {
            Label("This Mac", systemImage: "laptopcomputer")
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                row("Chip", hw.chipName)
                row("Memory", "\(Int(hw.physicalMemoryGB.rounded())) GB unified · \(Format.gb(hw.gpuWorkingSetGB)) for GPU")
                if let gpu = hw.gpuCores { row("GPU", "\(gpu) cores · ~\(Int(hw.memoryBandwidthGBs)) GB/s") }
                row("CPU", "\(hw.performanceCores) performance + \(hw.efficiencyCores) efficiency cores")
                row("Free disk", Format.gb(hw.freeDiskGB))
                row("System", hw.osVersion)
            }
            .font(.callout)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
    }
}

private struct AppleIntelligenceCard: View {
    @Environment(AppModel.self) private var model
    let status: HardwareProfile.AppleIntelligenceStatus

    var body: some View {
        Card {
            HStack {
                Label("Apple Intelligence", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                Badge(text: status.title, color: status.isUsable ? Theme.ready : .secondary)
            }
            if let hint = status.hint {
                Text(hint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Not available here. Hearth will use a downloaded model instead.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if status.isUsable {
                Button("Skip the local model") {
                    Task { await model.runAppleIntelligenceOnly() }
                }
                .help("Serve only Apple Intelligence: nothing to download, and the memory a local model would use stays free.")
            } else if status == .notEnabled {
                Button("Open System Settings") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
                }
            }
        }
    }
}

// MARK: - Already on this Mac

private struct AlreadyHereCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card {
            HStack {
                Label("Already on this Mac", systemImage: "externaldrive")
                    .font(.headline)
                Spacer()
                if model.discovery.totalDiskGB > 0 {
                    Text("\(Format.gb(model.discovery.totalDiskGB)) of models on disk")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(model.discovery.servers) { server in
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(Theme.ready)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(server.name) is running")
                            .font(.callout.weight(.medium))
                        Text(server.models.isEmpty ? "No models loaded" : server.models.prefix(4).joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(server.baseURL)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    CopyButton(text: server.baseURL).buttonStyle(.borderless)
                }
            }

            if let existing = model.advice?.existing, !existing.isEmpty {
                if !model.discovery.servers.isEmpty { Divider() }
                VStack(spacing: 0) {
                    ForEach(existing.prefix(8)) { review in
                        ExistingRow(review: review)
                        if review.id != existing.prefix(8).last?.id { Divider() }
                    }
                }
            }
        }
    }
}

private struct ExistingRow: View {
    @Environment(AppModel.self) private var model
    let review: ExistingModelReview

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(review.disk.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text("\(review.disk.source.rawValue) · \(Format.gb(review.disk.sizeGB)) · ~\(Format.speed(review.tokensPerSecond)) here")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Badge(text: review.verdict.title, color: review.verdict.color)
                if review.runnableInHearth, let m = review.model, review.verdict.isRunnable {
                    if model.selectedID == m.id {
                        Label("Selected", systemImage: "checkmark")
                            .font(.caption)
                            .foregroundStyle(Theme.flame)
                    } else {
                        Button("Select") { model.selectedID = m.id }
                            .controlSize(.small)
                    }
                }
            }
            if let alt = review.fasterAlternative {
                Label("\(alt.model.displayName) would run ~\(Format.speed(alt.tokensPerSecond)) here, about \(String(format: "%.1f", alt.tokensPerSecond / max(1, review.tokensPerSecond)))× faster.",
                      systemImage: "hare")
                    .font(.caption)
                    .foregroundStyle(Theme.flame)
                    .onTapGesture { model.selectedID = alt.id }
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - The pick

private struct PickCard: View {
    @Environment(AppModel.self) private var model
    let fit: ModelFit
    let reason: String?

    /// This is the model Hearth is serving right now.
    private var isRunning: Bool {
        model.models.activeModel?.id == fit.model.id && model.models.state == .ready
    }

    var body: some View {
        Card {
            HStack(alignment: .firstTextBaseline) {
                Text(fit.model.displayName)
                    .font(.title2.weight(.semibold))
                if fit.isRecommended { Badge(text: "Recommended", color: Theme.flame) }
                if isRunning {
                    Badge(text: "Running", color: Theme.ready)
                } else if fit.isDownloaded {
                    Badge(text: "Already downloaded", color: Theme.ready)
                }
                Spacer()
                Badge(text: fit.verdict.title, color: fit.verdict.color)
            }
            if let reason, !reason.isEmpty {
                Text(reason)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Stat(label: "Download", value: fit.isDownloaded ? "None" : Format.gb(fit.model.diskGB))
                Stat(label: "Memory (est.)", value: Format.gb(fit.memoryGB))
                    .help("What it needs with the whole context in use. It usually takes less until long prompts fill it.")
                Stat(label: "Speed", value: "~" + Format.speed(fit.tokensPerSecond))
                Stat(label: "Context", value: "\(fit.context / 1024)K")
            }
            HStack {
                Text(fit.model.id)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    Task { await model.run(fit.model) }
                } label: {
                    Text(isRunning ? "Running" : fit.isDownloaded ? "Start" : "Download and start")
                        .frame(minWidth: 160)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.flame)
                .controlSize(.large)
                .disabled(isRunning || !fit.verdict.isRunnable)
            }
        }
    }
}

private struct Stat: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.medium)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 8))
    }
}

private struct ModelRow: View {
    let fit: ModelFit
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Theme.flame : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(fit.model.displayName).font(.callout.weight(.medium))
                        if fit.model.isCoder { Badge(text: "Code", color: Theme.apple) }
                        if fit.isDownloaded { Badge(text: "Downloaded", color: Theme.ready) }
                    }
                    Text("\(Format.gb(fit.model.diskGB)) · \(Format.gb(fit.memoryGB)) memory · ~\(Format.speed(fit.tokensPerSecond))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Badge(text: fit.verdict.title, color: fit.verdict.color)
            }
            .padding(.vertical, 7)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!fit.verdict.isRunnable)
        .opacity(fit.verdict.isRunnable ? 1 : 0.55)
    }
}
