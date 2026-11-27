import Foundation
import UIKit

/// Drives the full carwithin-style projection sequence after one-time pairing:
///
///   1. BLE authenticate + send 0x71 navigation-on — the instrument then starts
///      projection mode and brings up its Wi-Fi hotspot.
///   2. Wait until the iPhone itself joins the instrument Wi-Fi (en0 gets an
///      address in the instrument subnet); the user either joins it once manually
///      or iOS auto-rejoins a previously used network.
///   3. From then on the original app's UDP stream to the instrument simply works,
///      because projection is already armed — the official Ninebot app is never
///      needed again.
///
/// The state machine keeps running while the host app is in foreground and
/// re-arms whenever the vehicle powers up in range.
@MainActor
final class NBAutoProjection {
    static let shared = NBAutoProjection()

    enum Stage: Equatable {
        case idle           // nothing armed
        case waking         // BLE session active, waiting for navi ack
        case waitingWiFi    // navi acked — waiting for phone to join instrument Wi-Fi
        case ready          // instrument Wi-Fi up — original streamer can go
    }

    private(set) var stage: Stage = .idle
    private(set) var instrumentWiFiAddress: String?

    private var timer: Timer?
    private weak var vehicle: NinebotVehicleConnection?
    private var lastKickAt: TimeInterval = 0
    private var wifiWaitStartedAt: TimeInterval?
    private var foreground = true
    var onLog: ((String) -> Void)?

    func install(vehicle: NinebotVehicleConnection) {
        self.vehicle = vehicle
        NotificationCenter.default.addObserver(self, selector: #selector(appActive),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.tick() }
        }
    }

    @objc private func appActive() { foreground = true }
    @objc private func appBackground() { foreground = false }

    var autoProjectionEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "nbpatch.autoProjection") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "nbpatch.autoProjection") }
    }

    /// User-visible hint for the integration card.
    var statusHint: String {
        switch stage {
        case .idle: return "待机（配对后自动唤醒投屏）"
        case .waking: return "正在认证并唤醒仪表导航…"
        case .waitingWiFi: return "导航已开：请把 iPhone 连上仪表 Wi-Fi"
        case .ready: return "✅ 仪表投屏就绪，点原 App 启动即可"
        }
    }

    private func tick() {
        guard autoProjectionEnabled, foreground, let vehicle else { return }
        guard vehicle.garage.selected != nil else { stage = .idle; return }

        // Wi-Fi detection: instrument nets are 192.168.1.x / 192.168.169.x
        let wifi = wifiIPv4Address()
        let onInstrumentNet = wifi.map { $0.hasPrefix("192.168.1.") || $0.hasPrefix("192.168.169.") } ?? false
        instrumentWiFiAddress = onInstrumentNet ? wifi : nil

        switch vehicle.phase {
        case .active:
            // navigation acknowledged by instrument
            if onInstrumentNet {
                if stage != .ready {
                    stage = .ready
                    onLog?("仪表 Wi-Fi 已连接（\(wifi ?? "")），投屏就绪")
                }
            } else {
                if stage != .waitingWiFi {
                    stage = .waitingWiFi
                    wifiWaitStartedAt = ProcessInfo.processInfo.systemUptime
                    onLog?("仪表导航已开启，等待 iPhone 加入仪表 Wi-Fi")
                }
            }
            return

        case .starting, .authenticating, .preparing, .connecting, .discovering, .reconnecting, .pairing:
            stage = .waking
            return

        default:
            break
        }

        // not in an active session: decide whether to kick one
        if onInstrumentNet, stage == .ready {
            // instrument net is up but no session — instrument may already be
            // projecting from a previous wake; keep state, no need to re-kick yet
            return
        }
        stage = .idle
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastKickAt > 45 else { return }
        lastKickAt = now
        onLog?("自动发起 BLE 认证唤醒仪表导航（免九号出行）")
        vehicle.startProjection()
    }
}

// MARK: - Wi-Fi address detection (getifaddrs, same approach as carwithin)

#if os(iOS)
import Darwin
#endif

func wifiIPv4Address() -> String? {
    localIPv4Addresses(interface: "en0").first
}

func localIPv4Addresses(interface: String? = nil) -> [String] {
    var first: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&first) == 0 else { return [] }
    defer { freeifaddrs(first) }
    var result: [String] = []
    var current = first
    while let entry = current {
        defer { current = entry.pointee.ifa_next }
        let name = String(cString: entry.pointee.ifa_name)
        guard interface == nil || interface == name,
              let address = entry.pointee.ifa_addr,
              address.pointee.sa_family == UInt8(AF_INET),
              entry.pointee.ifa_flags & UInt32(IFF_UP) != 0,
              entry.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
            let value = String(cString: host)
            if interface != nil && (value.hasPrefix("169.254.") || value.hasPrefix("0.")) { continue }
            if name == "en0" { result.insert(value, at: 0) } else { result.append(value) }
        }
    }
    return result
}
