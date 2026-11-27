import CoreBluetooth
import Foundation
import ObjectiveC.runtime

/// Injects synthetic "xiaoha-style" BLE discovery callbacks into the host app's
/// own CBCentralManager delegates, so the ANT BMS state of charge flows through
/// the original battery pipeline (HBB...SOC0XX advertisement-name parsing).
///
/// Mechanism: every `centralManager:didDiscover:advertisementData:rssi:` delegate
/// method implemented inside the host process is wrapped once. Wrapping lets us
/// (a) learn the live CBCentralManager instances and (b) capture the original IMP
/// to invoke later with synthetic advertisement data.
final class NBSOCInjector {
    static let shared = NBSOCInjector()

    private struct Hook {
        let central: CBCentralManager
        let delegate: AnyObject
        let original: IMP
    }

    private var hooks: [Hook] = []
    private weak var lastCentral: CBCentralManager?
    private weak var lastDelegate: AnyObject?
    private var lastOriginal: IMP?

    private var hookedClasses = Set<UnsafeRawPointer>()
    private var lastInjectionAt: TimeInterval = 0
    private var antDeviceDigits = "0000000000"
    weak var antPeripheral: CBPeripheral?
    private(set) var hookedDelegateCount = 0

    private static let selector = NSSelectorFromString("centralManager:didDiscover:advertisementData:rssi:")

    func install() {
        swizzleHostDelegates()
    }

    func updateANTPeripheral(_ peripheral: CBPeripheral?) {
        antPeripheral = peripheral
        if let peripheral {
            let base = peripheral.name ?? peripheral.identifier.uuidString
            let digits = base.filter(\.isNumber)
            antDeviceDigits = digits.count >= 6
                ? String(digits.suffix(10)).padding(toLength: 10, withPad: "0", startingAt: 0)
                : String(peripheral.identifier.uuidString.hashValue.magnitude % 1_000_000_000).padding(toLength: 10, withPad: "9", startingAt: 0)
        }
    }

    /// Called whenever a fresh validated ANT reading arrives; rate-limited to 4s.
    func inject(percent: Int) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastInjectionAt >= 4 else { return }
        lastInjectionAt = now
        guard let central = lastCentral, let delegate = lastDelegate, let imp = lastOriginal,
              let peripheral = antPeripheral else { return }
        let soc = String(format: "SOC%03d", min(100, max(0, percent)))
        let fakeName = "HBB\(antDeviceDigits)\(soc)"
        let payload: NSDictionary = [
            CBAdvertisementDataLocalNameKey: fakeName,
            CBAdvertisementDataIsConnectable: NSNumber(value: false)
        ]
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject, AnyObject, NSDictionary, NSNumber) -> Void
        let fn = unsafeBitCast(imp, to: Fn.self)
        // two shots: one per registered hook in case the app scans with several centrals
        for hook in hooks {
            guard let cls: AnyClass = object_getClass(hook.delegate) else { continue }
            _ = cls
            let f = unsafeBitCast(hook.original, to: Fn.self)
            f(hook.delegate, Self.selector, hook.central, peripheral, payload, NSNumber(value: -52))
        }
        if hooks.isEmpty {
            fn(delegate, Self.selector, central, peripheral, payload, NSNumber(value: -52))
        }
    }

    // MARK: host delegate wrapping

    private func swizzleHostDelegates() {
        var count: UInt32 = 0
        guard let classList = objc_copyClassList(&count) else { return }
        defer { free(UnsafeMutableRawPointer(mutating: classList)) }
        let classes = UnsafeBufferPointer(start: classList, count: Int(count))
        for cls in classes {
            let name = NSStringFromClass(cls)
            // limit to host app classes — Swift classes of the host app carry the module name
            guard name.hasPrefix("NinebotDash.") else { continue }
            guard class_getInstanceMethod(cls, Self.selector) != nil else { continue }
            wrap(cls: cls)
        }
    }

    private func wrap(cls: AnyClass) {
        let key = unsafeBitCast(cls, to: UnsafeRawPointer.self)
        guard !hookedClasses.contains(key) else { return }
        hookedClasses.insert(key)
        guard let method = class_getInstanceMethod(cls, Self.selector) else { return }
        let originalIMP = method_getImplementation(method)
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject, AnyObject, NSDictionary, NSNumber) -> Void
        let original = unsafeBitCast(originalIMP, to: Fn.self)
        hookStorage.append((cls, originalIMP))

        let block: @convention(block) (AnyObject, AnyObject, AnyObject, NSDictionary, NSNumber) -> Void = { obj, central, peripheral, adv, rssi in
            original(obj, Self.selector, central, peripheral, adv, rssi)
            if let mgr = central as? CBCentralManager {
                NBSOCInjector.shared.noteHook(central: mgr, delegate: obj, original: originalIMP)
            }
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
        hookedDelegateCount += 1
    }

    private var hookStorage: [(AnyClass, IMP)] = []

    private func noteHook(central: CBCentralManager, delegate: AnyObject, original: IMP) {
        lastCentral = central
        lastDelegate = delegate
        lastOriginal = original
        if !hooks.contains(where: { $0.delegate === delegate && $0.central === central }) {
            hooks.append(Hook(central: central, delegate: delegate, original: original))
        }
    }
}
