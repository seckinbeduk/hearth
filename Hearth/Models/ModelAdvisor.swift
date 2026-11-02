import Foundation

/// How a catalog model fits on this particular Mac.
struct ModelFit: Sendable, Hashable, Identifiable {
    enum Verdict: Int, Sendable, Comparable {
        case comfortable = 0   // Fits with room left for your other apps
        case tight             // Fits, but the Mac will feel it
        case slow              // Fits, but generates below a usable speed
        case tooBig            // Doesn't fit in GPU memory
        case noDisk            // Not enough free disk to download
        case unsupported       // Intel / Rosetta

        static func < (a: Verdict, b: Verdict) -> Bool { a.rawValue < b.rawValue }

        var title: String {
            switch self {
            case .comfortable: "Runs well"
            case .tight: "Tight fit"
            case .slow: "Slow here"
            case .tooBig: "Too big"
            case .noDisk: "Not enough disk"
            case .unsupported: "Needs Apple Silicon"
            }
        }

        var isRunnable: Bool { self == .comfortable || self == .tight || self == .slow }
    }

    let model: CatalogModel
    let verdict: Verdict
    let context: Int
    let memoryGB: Double
    let tokensPerSecond: Double
    var isRecommended = false
    /// Weights are already in the Hugging Face cache; nothing to download.
    var isDownloaded = false

    var id: String { model.id }
}

/// A model found on disk, judged for this Mac.
struct ExistingModelReview: Sendable, Hashable, Identifiable {
    let disk: DiskModel
    /// Hearth can load it directly (MLX weights in the Hugging Face cache).
    let runnableInHearth: Bool
    let verdict: ModelFit.Verdict
    let tokensPerSecond: Double
    /// A catalog MLX model at least as big that runs clearly faster here.
    let fasterAlternative: ModelFit?
    /// Ready-to-load entry (the catalog model itself, or one built from the files).
    let model: CatalogModel?

    var id: String { disk.id }
}

struct ModelAdvice: Sendable {
    var fits: [ModelFit]
    var recommended: ModelFit?
    var reason: String
    var warnings: [String]
    /// Models already on this Mac and how they'd do here.
    var existing: [ExistingModelReview] = []

    func fit(for id: String) -> ModelFit? { fits.first { $0.id == id } }
}

/// Hardware + catalog (+ what's already on disk) → one clear recommendation,
/// plus how every other model would do. Pure function; covered by tests with synthetic Macs.
struct ModelAdvisor: Sendable {
    let catalog: [CatalogModel]

    /// Below this, chatting feels broken (tokens/sec).
    var minimumUsableSpeed: Double = 12
    /// Share of theoretical bandwidth MLX actually achieves (~0.7 measured).
    var bandwidthEfficiency: Double = 0.7
    /// Free disk that must remain after the download (GB).
    var diskReserveGB: Double = 10
    /// Share of the GPU working set a "comfortable" model may use.
    var comfortableShare: Double = 0.65
    /// Share of the GPU working set any model may use.
    var maximumShare: Double = 0.85
    var context: Int = 8_192
    /// How many quality points we give up to skip a download (as long as it's not much slower).
    var downloadedQualitySlack = 8

    func advise(for hw: HardwareProfile, onDisk: [DiskModel] = []) -> ModelAdvice {
        var warnings: [String] = []
        guard hw.canRunMLX else {
            let fits = catalog.map {
                ModelFit(model: $0, verdict: .unsupported, context: 0, memoryGB: 0, tokensPerSecond: 0)
            }
            warnings.append(hw.architecture == .rosetta
                ? "Hearth is running under Rosetta. Install the Apple Silicon build to run local models."
                : "Local models need an Apple Silicon Mac. Hearth can still show what's already running here.")
            return ModelAdvice(fits: fits, recommended: nil, reason: "", warnings: warnings)
        }

        let speedFactor = hw.isLowPowerMode ? 0.6 : 1.0
        let comfortable = hw.gpuWorkingSetGB * comfortableShare
        let maximum = hw.gpuWorkingSetGB * maximumShare
        let diskAvailable = hw.freeDiskGB - diskReserveGB
        let downloaded = Set(onDisk.filter { $0.source == .huggingFace }.compactMap(\.repoID))

        var fits = catalog.map { model -> ModelFit in
            let ctx = min(context, model.maxContext)
            let memory = model.memoryGB(context: ctx)
            let speed = hw.memoryBandwidthGBs * bandwidthEfficiency * speedFactor / model.activeGB
            let isDownloaded = downloaded.contains(model.id)
            let verdict: ModelFit.Verdict
            if memory > maximum { verdict = .tooBig }
            else if !isDownloaded && model.diskGB > diskAvailable { verdict = .noDisk }
            else if speed < minimumUsableSpeed { verdict = .slow }
            else if memory > comfortable { verdict = .tight }
            else { verdict = .comfortable }
            return ModelFit(model: model, verdict: verdict, context: ctx, memoryGB: memory,
                            tokensPerSecond: speed, isDownloaded: isDownloaded)
        }

        // The pick: best general model that runs comfortably. Quality first, speed as a tie-breaker.
        let candidates = fits.filter { $0.verdict == .comfortable && !$0.model.isCoder }
        var recommended = candidates.max { score($0) < score($1) }
        // Something nearly as good that's already on disk beats a multi-GB download.
        if let best = recommended,
           let local = candidates
               .filter({ $0.isDownloaded
                   && $0.model.quality >= best.model.quality - downloadedQualitySlack
                   && $0.tokensPerSecond >= best.tokensPerSecond * 0.6 })
               .max(by: { score($0) < score($1) }) {
            recommended = local
        }

        if let recommended, let index = fits.firstIndex(where: { $0.id == recommended.id }) {
            fits[index].isRecommended = true
        }

        fits.sort { a, b in
            if a.isRecommended != b.isRecommended { return a.isRecommended }
            if a.verdict != b.verdict { return a.verdict < b.verdict }
            return a.model.quality > b.model.quality
        }

        if hw.isLowPowerMode {
            warnings.append("Low Power Mode is on, so speed estimates are lower.")
        }
        if recommended == nil {
            if diskAvailable < 3 {
                warnings.append("There isn't enough free disk (\(Int(hw.freeDiskGB)) GB) to download a model. Free up a few GB and rescan.")
            } else {
                warnings.append("Memory is tight on this Mac. A small model may still run, but expect it to compete with your other apps.")
            }
        }

        let existing = onDisk
            .map { review($0, hw: hw, fits: fits, speedFactor: speedFactor, comfortable: comfortable, maximum: maximum) }
            .sorted { a, b in
                if a.runnableInHearth != b.runnableInHearth { return a.runnableInHearth }
                return a.tokensPerSecond > b.tokensPerSecond
            }

        var pick = recommended
        pick?.isRecommended = true
        return ModelAdvice(
            fits: fits,
            recommended: pick,
            reason: pick.map { reason(for: $0, hw: hw) } ?? "",
            warnings: warnings,
            existing: existing
        )
    }

    // MARK: - Models already on disk

    private func review(_ disk: DiskModel, hw: HardwareProfile, fits: [ModelFit], speedFactor: Double,
                        comfortable: Double, maximum: Double) -> ExistingModelReview {
        let catalogMatch = catalog.first { $0.id == disk.repoID }
        let size = catalogMatch?.diskGB ?? disk.sizeGB
        let params = Self.parameterCounts(disk.name)
        var active = size
        if let match = catalogMatch {
            active = match.activeGB
        } else if let total = params.total, let act = params.active, total > 0 {
            active = size * act / total
        }
        let speed = hw.memoryBandwidthGBs * bandwidthEfficiency * speedFactor / max(0.1, active)
        let memory = size * 1.05 + 144 * Double(context) / 1_048_576 + 0.4

        let verdict: ModelFit.Verdict
        if memory > maximum { verdict = .tooBig }
        else if speed < minimumUsableSpeed { verdict = .slow }
        else if memory > comfortable { verdict = .tight }
        else { verdict = .comfortable }

        let runnable = disk.isMLX && disk.source == .huggingFace && disk.repoID != nil
        var model: CatalogModel?
        if runnable, let repoID = disk.repoID {
            model = catalogMatch ?? CatalogModel(
                id: repoID, displayName: disk.name, roles: [.general],
                paramsB: params.total ?? 0, diskGB: size, activeGB: active,
                kvKBPerToken: 144, quality: 0, maxContext: 32_768)
        }

        // Only suggest a switch when it's clearly faster and at least about as big.
        var alternative: ModelFit?
        if let total = params.total ?? catalogMatch?.paramsB, total > 0 {
            alternative = fits
                .filter { ($0.verdict == .comfortable || $0.verdict == .tight) && !$0.model.isCoder }
                .filter { $0.model.id != disk.repoID }
                .filter { $0.model.paramsB >= total * 0.8 && $0.tokensPerSecond >= speed * 1.25 }
                .max { score($0) < score($1) }
        }

        return ExistingModelReview(disk: disk, runnableInHearth: runnable, verdict: verdict,
                                   tokensPerSecond: speed, fasterAlternative: alternative, model: model)
    }

    /// "Qwen3-30B-A3B-4bit" → (30, 3) · "llama3.1:8b" → (8, nil) · "gemma-3-270m" → (0.27, nil)
    static func parameterCounts(_ name: String) -> (total: Double?, active: Double?) {
        let lower = name.lowercased()
        let activePattern = #"(?<![a-z0-9])a\d+(\.\d+)?b(?![a-z])"#
        var active: Double?
        if let range = lower.range(of: activePattern, options: .regularExpression) {
            active = Double(lower[range].dropFirst().dropLast())
        }
        let rest = lower.replacingOccurrences(of: activePattern, with: " ", options: .regularExpression)
        var total: Double?
        if let range = rest.range(of: #"(?<![a-z0-9.])\d+(\.\d+)?b(?![a-z])"#, options: .regularExpression) {
            total = Double(rest[range].dropLast())
        } else if let range = rest.range(of: #"(?<![a-z0-9.])\d+m(?![a-z])"#, options: .regularExpression) {
            total = Double(rest[range].dropLast()).map { $0 / 1000 }
        }
        return (total, active)
    }

    // MARK: - Helpers

    /// Quality leads; speed adds a log bonus over the usable minimum (max +10).
    private func score(_ fit: ModelFit) -> Double {
        let speedBonus = min(10, max(0, log2(fit.tokensPerSecond / minimumUsableSpeed) * 3))
        return Double(fit.model.quality) + speedBonus
    }

    private func reason(for fit: ModelFit, hw: HardwareProfile) -> String {
        let share = Int((fit.memoryGB / hw.physicalMemoryGB * 100).rounded())
        let speed = Int(fit.tokensPerSecond.rounded())
        var text = "The strongest model that fits your \(Int(hw.physicalMemoryGB.rounded())) GB comfortably: "
            + "about \(share)% of memory and ~\(speed) tokens/sec"
        if fit.model.isMoE { text += ", fast because only a few experts run per token" }
        if fit.isDownloaded { text += ". It's already on your Mac, so there's nothing to download" }
        return text + "."
    }
}
