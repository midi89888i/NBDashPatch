import CoreBluetooth
import Foundation
import ObjectiveC.runtime
import UIKit

/// Integrates vehicle pairing + ANT bonding into the host app's own UI as a
/// native in-page card. The card walks the user through the pairing sequence
/// step by step instead of exposing raw scan/connect primitives.
@MainActor
final class NBPairingIntegration: NSObject {
    static let shared = NBPairingIntegration()

    private weak var vehicle: NinebotVehicleConnection?
    private weak var bms: ANTBMSClient?
    private var pollTimer: Timer?
    private var card: UIView?
    private var statusLabel: UILabel?
    private var hintLabel: UILabel?
    private var bmsLabel: UILabel?
    private var deviceList: UIStackView?
    private var actionsRow: UIStackView?
    private var refreshTimer: Timer?
    private var pendingVehicle: NinebotVehicleConnection.Device?

    func install(vehicle: NinebotVehicleConnection, bms: ANTBMSClient) {
        self.vehicle = vehicle
        self.bms = bms
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.tryAttachCard() }
        }
    }

    // MARK: attachment

    private func tryAttachCard() {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }
        for window in scene.windows {
            guard let root = window.rootViewController else { continue }
            if let host = findHostController(in: root) {
                attachIfNeeded(to: host)
                return
            }
        }
    }

    private func findHostController(in vc: UIViewController) -> UIViewController? {
        if let nav = vc as? UINavigationController, let top = nav.visibleViewController {
            return top
        }
        if let presented = vc.presentedViewController {
            return findHostController(in: presented)
        }
        if let tab = vc as? UITabBarController, let selected = tab.selectedViewController {
            return findHostController(in: selected)
        }
        if vc.children.isEmpty, vc.viewIfLoaded != nil, vc.view.window != nil {
            return vc
        }
        for child in vc.children {
            if child.viewIfLoaded?.window != nil { return child }
        }
        return vc.viewIfLoaded?.window != nil ? vc : nil
    }

    private func attachIfNeeded(to vc: UIViewController) {
        guard let container = vc.viewIfLoaded else { return }
        if let card, card.superview != nil { return }
        buildCard(in: container)
    }

    // MARK: card construction

    private func buildCard(in container: UIView) {
        let card = UIView()
        card.backgroundColor = UIColor.secondarySystemGroupedBackground
        card.layer.cornerRadius = 12
        card.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: container.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            card.trailingAnchor.constraint(equalTo: container.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            card.bottomAnchor.constraint(equalTo: container.safeAreaLayoutGuide.bottomAnchor, constant: -8)
        ])
        container.bringSubviewToFront(card)
        self.card = card

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 7
        stack.layoutMargins = UIEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.isLayoutMarginsRelativeArrangement = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor)
        ])

        let title = UILabel()
        title.text = "免九号投屏 · ANT BMS"
        title.font = .boldSystemFont(ofSize: 13)
        title.textColor = .label
        stack.addArrangedSubview(title)

        statusLabel = smallLabel("…")
        hintLabel = smallLabel("")
        hintLabel?.textColor = .systemOrange
        bmsLabel = smallLabel("ANT：未连接")
        stack.addArrangedSubview(statusLabel!)
        stack.addArrangedSubview(hintLabel!)
        stack.addArrangedSubview(bmsLabel!)

        actionsRow = UIStackView()
        actionsRow?.axis = .horizontal
        actionsRow?.spacing = 8
        actionsRow?.distribution = .fillEqually
        stack.addArrangedSubview(actionsRow!)
        rebuildActions()

        deviceList = UIStackView()
        deviceList?.axis = .vertical
        deviceList?.spacing = 6
        stack.addArrangedSubview(deviceList!)

        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.refresh() }
        }
        refresh()
    }

    private func smallLabel(_ text: String) -> UILabel {
        let l = UILabel()
        l.text = text
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabel
        l.numberOfLines = 0
        return l
    }

    private func rebuildActions() {
        guard let actionsRow, let vehicle else { return }
        actionsRow.arrangedSubviews.forEach { $0.removeFromSuperview() }

        if vehicle.canClearStaleKey {
            actionsRow.addArrangedSubview(actionButton("清除残留密钥", .systemOrange, #selector(clearStale)))
        }
        if vehicle.garage.selected != nil {
            actionsRow.addArrangedSubview(actionButton("一键重配(P键)", .systemBlue, #selector(repair)))
        }
        actionsRow.addArrangedSubview(actionButton("扫描配对车辆", .systemBlue, #selector(scanVehicle)))
        actionsRow.addArrangedSubview(actionButton("绑定ANT", .systemTeal, #selector(scanBMS)))
    }

    private func actionButton(_ title: String, _ color: UIColor, _ action: Selector) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.baseBackgroundColor = color
        config.baseForegroundColor = .white
        config.cornerStyle = .medium
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6)
        let b = UIButton(configuration: config)
        b.titleLabel?.font = .systemFont(ofSize: 11, weight: .semibold)
        b.titleLabel?.numberOfLines = 2
        b.titleLabel?.textAlignment = .center
        b.addTarget(self, action: action, for: .touchUpInside)
        return b
    }

    // MARK: actions

    @objc private func clearStale() {
        vehicle?.clearStaleKey()
        rebuildActions()
    }

    @objc private func repair() {
        vehicle?.rePairSelectedVehicle()
    }

    @objc private func scanVehicle() {
        guard let vehicle else { return }
        deviceList?.arrangedSubviews.forEach { $0.removeFromSuperview() }
        vehicle.startScan()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated { self.populateVehicles() }
        }
    }

    @objc private func scanBMS() {
        bms?.scan()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated { self.populateBMS() }
        }
    }

    private func populateVehicles() {
        guard let vehicle else { return }
        deviceList?.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard !vehicle.devices.isEmpty else {
            addRowLabel("未发现车辆：确认车辆已通电、九号出行已彻底划掉")
            return
        }
        for device in vehicle.devices.filter(\.isConnectable).prefix(3) {
            addRowButton("🛵 \(device.name) — 点这里开始配对", .systemGreen) { [weak self] in
                self?.beginGuidedPairing(device)
            }
        }
    }

    private func populateBMS() {
        guard let bms else { return }
        guard !bms.devices.isEmpty else {
            addRowLabel("未发现 ANT 设备：确认保护板蓝牙模块已开")
            return
        }
        for device in bms.devices.prefix(2) {
            addRowButton("🔋 \(device.name) — 点击绑定", .systemTeal) { [weak self] in
                self?.bms?.select(device.id)
            }
        }
    }

    // MARK: guided pairing — explicit step machine, no hidden auto-advance

    private func beginGuidedPairing(_ device: NinebotVehicleConnection.Device) {
        guard let vehicle else { return }
        pendingVehicle = device
        hintLabel?.text = "⏳ 正在连接 \(device.name)，请稍候…"
        vehicle.connectForPairing(device)
        waitForPairingReady(attempts: 0)
    }

    private func waitForPairingReady(attempts: Int) {
        guard let vehicle, attempts < 25 else {
            if attempts >= 25 { hintLabel?.text = "⚠️ 连接超时，请把九号出行彻底划掉后重试" }
            return
        }
        if vehicle.canBeginPairing {
            hintLabel?.text = "📡 已连接，正在下发配对请求…先不要按 P 键！"
            vehicle.beginPairing()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated { self.waitForPairingReady(attempts: attempts + 1) }
        }
    }

    private func addRowLabel(_ text: String) {
        let l = smallLabel(text)
        l.textColor = .systemRed
        deviceList?.addArrangedSubview(l)
    }

    private func addRowButton(_ title: String, _ color: UIColor, handler: @escaping () -> Void) {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.baseBackgroundColor = color.withAlphaComponent(0.2)
        config.baseForegroundColor = .label
        config.cornerStyle = .small
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
        let b = UIButton(configuration: config)
        b.titleLabel?.font = .systemFont(ofSize: 11)
        b.titleLabel?.numberOfLines = 0
        b.contentHorizontalAlignment = .leading
        b.addAction(UIAction { _ in MainActor.assumeIsolated { handler() } }, for: .touchUpInside)
        deviceList?.addArrangedSubview(b)
    }

    // MARK: live status

    private var lastActionState = ""

    private func refresh() {
        guard let vehicle else { return }

        // P-button prompt takes over the hint with maximum visibility
        if vehicle.readyForButtonPress {
            hintLabel?.text = "✅ 车机已就绪！\n现在立刻短按一下车上的 P 键！"
            hintLabel?.textColor = .systemGreen
            hintLabel?.font = .boldSystemFont(ofSize: 14)
        } else if vehicle.phase == .needsPairing {
            hintLabel?.textColor = .systemOrange
            hintLabel?.font = .systemFont(ofSize: 11)
        } else if vehicle.phase == .active {
            hintLabel?.textColor = .systemGreen
        }

        var text: String
        if vehicle.phase == .active {
            text = "🟢 仪表导航已开启"
        } else {
            text = vehicle.status
        }
        if let selected = vehicle.garage.selected {
            text += "（已选：\(selected.name)）"
        }
        statusLabel?.text = text

        // dynamic action buttons as state changes
        let stateKey = "\(vehicle.canClearStaleKey)-\(vehicle.garage.selected != nil)"
        if stateKey != lastActionState {
            lastActionState = stateKey
            rebuildActions()
        }

        if let bms {
            if let r = bms.freshReading {
                bmsLabel?.text = String(format: "🔋 ANT %d%% %.1fV %+.1fA %dW（已并入仪表电量）",
                                        r.stateOfCharge, r.voltage, r.current, r.power)
            } else {
                bmsLabel?.text = "ANT：" + bms.status + (bms.selectedID != nil ? "（已绑定 \(bms.selectedName)）" : "（未绑定设备）")
            }
        }
    }
}
