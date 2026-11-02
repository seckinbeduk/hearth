import Foundation

/// A snapshot of what this Mac can do for local LLMs.
/// Pure value type; scanned once, shared everywhere.
struct HardwareProfile: Codable, Sendable, Equatable {
    enum Architecture: String, Codable, Sendable {
        case appleSilicon
        case intel
        case rosetta   // Apple Silicon, but the app runs as x86 (wrong build)
    }

    enum AppleIntelligenceStatus: String, Codable, Sendable {
        case available
        case notEnabled        // Eligible Mac, but turned off in System Settings
        case notReady          // Model still downloading
        case deviceNotEligible
        case unsupportedOS     // Before macOS 26
        case unknown

        var isUsable: Bool { self == .available }

        var title: String {
            switch self {
            case .available: "On and ready"
            case .notEnabled: "Turned off"
            case .notReady: "Downloading model"
            case .deviceNotEligible: "Not supported on this Mac"
            case .unsupportedOS: "Needs macOS 26"
            case .unknown: "Unknown"
            }
        }

        var hint: String? {
            switch self {
            case .available: "A free on-device model is already on your Mac. Hearth serves it as apple-intelligence."
            case .notEnabled: "Turn it on in System Settings → Apple Intelligence & Siri to get a free on-device model."
            case .notReady: "macOS is still downloading the model. Hearth will pick it up automatically."
            case .deviceNotEligible, .unsupportedOS, .unknown: nil
            }
        }
    }

    var architecture: Architecture
    /// e.g. "Apple M3 Pro"
    var chipName: String
    var chipFamily: ChipFamily
    var performanceCores: Int
    var efficiencyCores: Int
    var gpuCores: Int?
    /// Physical unified memory (bytes)
    var physicalMemory: UInt64
    /// Metal's recommended max working set for the GPU (bytes). Weights + KV cache must fit here.
    var gpuWorkingSetLimit: UInt64
    /// Estimated memory bandwidth (GB/s). The main driver of token speed.
    var memoryBandwidthGBs: Double
    var freeDiskBytes: UInt64
    var osVersion: String
    var appleIntelligence: AppleIntelligenceStatus
    var hasInternalBattery: Bool
    var isLowPowerMode: Bool
    var scannedAt: Date

    var physicalMemoryGB: Double { Double(physicalMemory) / 1_073_741_824 }
    var gpuWorkingSetGB: Double { Double(gpuWorkingSetLimit) / 1_073_741_824 }
    var freeDiskGB: Double { Double(freeDiskBytes) / 1_073_741_824 }
    var canRunMLX: Bool { architecture == .appleSilicon }
}

/// Chip family and tier, for bandwidth estimates and display.
struct ChipFamily: Codable, Sendable, Equatable {
    enum Tier: String, Codable, Sendable { case base, pro, max, ultra, unknown }

    /// 1 = M1, 2 = M2 ... (nil if unknown)
    var generation: Int?
    var tier: Tier

    static func parse(_ brand: String) -> ChipFamily {
        // "Apple M3 Pro", "Apple M4 Max", "Apple M2"
        let lower = brand.lowercased()
        var generation: Int?
        if let range = lower.range(of: #"m(\d+)"#, options: .regularExpression) {
            generation = Int(lower[range].dropFirst())
        }
        let tier: Tier
        if lower.contains("ultra") { tier = .ultra }
        else if lower.contains("max") { tier = .max }
        else if lower.contains("pro") { tier = .pro }
        else if generation != nil { tier = .base }
        else { tier = .unknown }
        return ChipFamily(generation: generation, tier: tier)
    }

    /// Apple's published memory bandwidth figures (GB/s).
    /// Binned Max chips (fewer GPU cores) have lower bandwidth.
    func estimatedBandwidth(gpuCores: Int?) -> Double {
        switch (generation ?? 0, tier) {
        case (1, .base): return 68
        case (1, .pro): return 200
        case (1, .max): return 400
        case (1, .ultra): return 800
        case (2, .base): return 100
        case (2, .pro): return 200
        case (2, .max): return 400
        case (2, .ultra): return 800
        case (3, .base): return 100
        case (3, .pro): return 150
        case (3, .max): return (gpuCores ?? 40) <= 30 ? 300 : 400
        case (3, .ultra): return 819
        case (4, .base): return 120
        case (4, .pro): return 273
        case (4, .max): return (gpuCores ?? 40) <= 32 ? 410 : 546
        case (5, .base): return 153
        default:
            // Conservative guess for chips not in the table yet.
            switch tier {
            case .ultra: return 800
            case .max: return 450
            case .pro: return 250
            case .base: return 150
            case .unknown: return 100
            }
        }
    }
}
