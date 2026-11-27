import Foundation
import UIKit

/// Keeps the vehicle navigation projection armed after one-time pairing.
/// Whenever the paired vehicle is in range the BLE session authenticates and
/// sends the 0x71 navigation-on command, so the instrument cluster is already
/// projecting when the user starts streaming in the host UI — no need to ever
/// open the official Ninebot app.
@MainActor
final class NBAutoProjection {
    static let shared = NBAutoProjection()

    private var timer: Timer?
    private weak var vehicle: NinebotVehicleConnection?
    private var lastKickAt: TimeInterval = 0
    private var foreground = true

    func install(vehicle: NinebotVehicleConnection) {
        self.vehicle = vehicle
        NotificationCenter.default.addObserver(self, selector: #selector(appActive),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    @objc private func appActive() { foreground = true }
    @objc private func appBackground() { foreground = false }

    var autoProjectionEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "nbpatch.autoProjection") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "nbpatch.autoProjection") }
    }

    private func tick() {
        guard autoProjectionEnabled, foreground, let vehicle else { return }
        guard vehicle.garage.selected != nil else { return }
        switch vehicle.phase {
        case .active, .starting, .authenticating, .preparing, .connecting, .discovering, .reconnecting:
            return
        default: break
        }
        let now = ProcessInfo.processInfo.systemUptime
        // at most one kick per 40s so a powered-off vehicle doesn't cause churn
        guard now - lastKickAt > 40 else { return }
        lastKickAt = now
        vehicle.startProjection()
    }
}
