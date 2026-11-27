import CoreBluetooth
import Foundation
import ObjectiveC.runtime
import UIKit

/// Entry point for the injected patch. Everything here is silent-integration:
/// no floating windows. ANT BMS data flows into the host app's own battery
/// pipeline; the vehicle projection wake hooks the host's streaming startup.
final class NBPatch: NSObject {
    static let shared = NBPatch()

    private(set) var vehicle: NinebotVehicleConnection?
    private(set) var bms: ANTBMSClient?
    private var started = false
    private var logLines: [String] = []

    func start() {
        guard !started else { return }
        started = true
        log("NBPatch 已加载")

        // 1. silent ANT BMS client — auto-connect previously bonded device
        let client = ANTBMSClient()
        bms = client
        client.onLog = { [weak self] in self?.log("ANT：" + $0) }
        client.onChange = { [weak self] in
            guard let self, let reading = client.freshReading else { return }
            NBSOCInjector.shared.updateANTPeripheral(client.currentPeripheral)
            NBSOCInjector.shared.inject(percent: reading.stateOfCharge)
        }
        // only start scanning when a device was previously bonded, or scan once for first-time setup
        client.start()

        // 2. vehicle connection manager (carwithin logic)
        let conn = NinebotVehicleConnection()
        vehicle = conn
        conn.onLog = { [weak self] in self?.log("车辆：" + $0) }

        // 3. hook discovery delegates so ANT readings ride the host pipeline
        NBSOCInjector.shared.install()

        // 4. auto-projection: keep navigation armed once a vehicle is paired
        NBAutoProjection.shared.install(vehicle: conn)

        // 5. install the pairing integration into the host UI (native, in-page)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            NBPairingIntegration.shared.install(vehicle: conn, bms: client)
        }
    }

    func log(_ message: String) {
        let line = String(format: "[%02d:%02d:%02d] %@",
                          Calendar.current.component(.hour, from: Date()),
                          Calendar.current.component(.minute, from: Date()),
                          Calendar.current.component(.second, from: Date()), message)
        logLines.append(line)
        if logLines.count > 200 { logLines.removeFirst(logLines.count - 200) }
        NSLog("NBPatch: %@", message)
    }

    var logs: [String] { logLines }
}

/// Constructor: runs when the dylib is loaded into the host process.
@objc class NBPatchLoader: NSObject {
    @objc static func load() {
        // `load` runs at dylib load time, before the host app's UI exists.
        // Defer real startup to main runloop.
        DispatchQueue.main.async {
            NBPatch.shared.start()
        }
    }
}
