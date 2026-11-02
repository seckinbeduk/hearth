import Foundation
import Darwin
import Observation

/// Live system readings for the menu bar panel: our memory footprint, memory pressure, thermal state.
@MainActor
@Observable
final class SystemMonitor {
    enum Pressure: String { case normal, warning, critical }

    private(set) var footprintBytes: UInt64 = 0
    private(set) var pressure: Pressure = .normal
    private(set) var thermal: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState

    private var pressureSource: DispatchSourceMemoryPressure?
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }

        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.readPressure() }
        }
        source.resume()
        pressureSource = source
    }

    private func readPressure() {
        guard let event = pressureSource?.data else { return }
        if event.contains(.critical) { pressure = .critical }
        else if event.contains(.warning) { pressure = .warning }
        else { pressure = .normal }
    }

    private func refresh() {
        footprintBytes = Self.footprint()
        thermal = ProcessInfo.processInfo.thermalState
    }

    var thermalTitle: String {
        switch thermal {
        case .nominal: "Normal"
        case .fair: "Warm"
        case .serious: "Hot"
        case .critical: "Throttling"
        @unknown default: "Unknown"
        }
    }

    var pressureTitle: String {
        switch pressure {
        case .normal: "Normal"
        case .warning: "Elevated"
        case .critical: "Critical"
        }
    }

    /// Physical footprint of this process, including Metal buffers on Apple Silicon.
    nonisolated static func footprint() -> UInt64 {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? info.ri_phys_footprint : 0
    }
}
