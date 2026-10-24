import Network
import Observation
import UIKit

/// Observes charging, Low Power Mode, thermal state and Wi-Fi so the UI and
/// background scheduling can respond to real device conditions.
@MainActor
@Observable
final class DeviceConditionMonitor {
    private(set) var batteryState: UIDevice.BatteryState = .unknown
    private(set) var isLowPowerMode = false
    private(set) var thermalState: ProcessInfo.ThermalState = .nominal
    private(set) var isOnWiFi = false
    private(set) var isNetworkAvailable = false

    private let pathMonitor = NWPathMonitor()
    private var observers: [NSObjectProtocol] = []

    var isConnectedToPower: Bool { batteryState == .charging || batteryState == .full }
    /// Battery state is unknown in Simulator and before monitoring starts.
    var isBatteryStateKnown: Bool { batteryState != .unknown }

    var chargingDescription: String {
        switch batteryState {
        case .charging: "Charging"
        case .full: "Connected to Power"
        case .unplugged: "On Battery"
        case .unknown: "Unavailable"
        @unknown default: "Unavailable"
        }
    }

    var thermalDescription: String { Self.describe(thermalState) }

    func start() {
        guard observers.isEmpty else { return }
        UIDevice.current.isBatteryMonitoringEnabled = true
        refresh()

        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            UIDevice.batteryStateDidChangeNotification,
            .NSProcessInfoPowerStateDidChange,
            ProcessInfo.thermalStateDidChangeNotification,
        ]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }

        pathMonitor.pathUpdateHandler = { [weak self] path in
            let wifi = path.status == .satisfied && path.usesInterfaceType(.wifi)
            let available = path.status == .satisfied
            Task { @MainActor in
                self?.isOnWiFi = wifi
                self?.isNetworkAvailable = available
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.rackful.network"))
    }

    func refresh() {
        batteryState = UIDevice.current.batteryState
        isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        thermalState = ProcessInfo.processInfo.thermalState
    }

    func snapshot() -> DeviceConditions {
        refresh()
        return DeviceConditions(
            isCharging: isBatteryStateKnown ? isConnectedToPower : nil,
            isLowPowerMode: isLowPowerMode,
            thermalState: thermalDescription
        )
    }

    nonisolated static func describe(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "Normal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }
}
