import Foundation
import Metal
import IOKit
import IOKit.ps
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Scans the Mac. Every call is fast (< 50 ms) but exposed as async to keep the UI free.
enum HardwareProfiler {

    static func scan() async -> HardwareProfile {
        let brand = sysctlString("machdep.cpu.brand_string") ?? "Unknown Mac"
        let architecture = detectArchitecture(brand: brand)
        let family = ChipFamily.parse(brand)
        let gpuCores = gpuCoreCount()
        let physical = ProcessInfo.processInfo.physicalMemory

        let device = MTLCreateSystemDefaultDevice()
        // No Metal limit (Intel / VM): assume 65% of RAM.
        let workingSet = device.map { UInt64($0.recommendedMaxWorkingSetSize) } ?? UInt64(Double(physical) * 0.65)

        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osString = "macOS \(os.majorVersion).\(os.minorVersion)" + (os.patchVersion > 0 ? ".\(os.patchVersion)" : "")

        return HardwareProfile(
            architecture: architecture,
            chipName: brand,
            chipFamily: family,
            performanceCores: sysctlInt("hw.perflevel0.physicalcpu") ?? sysctlInt("hw.physicalcpu") ?? 0,
            efficiencyCores: sysctlInt("hw.perflevel1.physicalcpu") ?? 0,
            gpuCores: gpuCores,
            physicalMemory: physical,
            gpuWorkingSetLimit: workingSet,
            memoryBandwidthGBs: family.estimatedBandwidth(gpuCores: gpuCores),
            freeDiskBytes: freeDiskSpace(),
            osVersion: osString,
            appleIntelligence: await appleIntelligenceStatus(),
            hasInternalBattery: hasInternalBattery(),
            isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            scannedAt: .now
        )
    }

    // MARK: - CPU / architecture

    private static func detectArchitecture(brand: String) -> HardwareProfile.Architecture {
        #if arch(arm64)
        return .appleSilicon
        #else
        if sysctlInt("sysctl.proc_translated") == 1 { return .rosetta }
        return brand.contains("Apple") ? .rosetta : .intel
        #endif
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    // MARK: - GPU

    /// Apple Silicon GPU core count lives on the AGXAccelerator node in the IORegistry.
    private static func gpuCoreCount() -> Int? {
        guard let matching = IOServiceMatching("AGXAccelerator") else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            let value = IORegistryEntryCreateCFProperty(service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue()
            IOObjectRelease(service)
            if let count = value as? Int, count > 0 { return count }
        }
        return nil
    }

    // MARK: - Disk

    static func freeDiskSpace() -> UInt64 {
        let url = URL.homeDirectory
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return UInt64(max(0, values?.volumeAvailableCapacityForImportantUsage ?? 0))
    }

    // MARK: - Power

    private static func hasInternalBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return false }

        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            if description["Type"] as? String == "InternalBattery" { return true }
        }
        return false
    }

    // MARK: - Apple Intelligence

    static func appleIntelligenceStatus() async -> HardwareProfile.AppleIntelligenceStatus {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible: return .deviceNotEligible
                case .appleIntelligenceNotEnabled: return .notEnabled
                case .modelNotReady: return .notReady
                @unknown default: return .unknown
                }
            @unknown default:
                return .unknown
            }
        }
        #endif
        return .unsupportedOS
    }
}
