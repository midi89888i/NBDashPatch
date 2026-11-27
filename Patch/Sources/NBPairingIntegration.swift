import CoreBluetooth
import Foundation
import ObjectiveC.runtime
import UIKit

/// Integrates vehicle pairing + ANT bonding into the host app's own UI.
/// The card is added as a plain subview of the host's BLE-settings page
/// controller view (inside the view hierarchy, scrolling with the page),
/// not as a separate floating window.
@MainActor
final class NBPairingIntegration: NSObject {
    static let shared = NBPairingIntegration()

    private weak var vehicle: NinebotVehicleConnection?
    private weak var bms: ANTBMSClient?
    private var installedCard = false
    private var pollTimer: Timer?
    private var card: UIView?
    private var statusLabel: UILabel?
    private var deviceButtons: UIStackView?
    private var bmsLabel: UILabel?
    private var refreshTimer: Timer?

    func install(vehicle: NinebotVehicleConnection, bms: ANTBMSClient) {
        self.vehicle = vehicle
        self.bms = bms
        // watch the host view hierarchy: when a settings/host controller appears,
        // append our card to its scroll content
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.tryAttachCard()
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

    /// Walks the controller tree looking for the visible controller that is NOT
    /// our own card host. Any visible content controller qualifies as a mounting
    /// point; the card pins to the bottom of its view.
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
        if let card, card.superview != nil {
            // already attached somewhere visible — keep it
            return
        }
        buildCard(in: container)
    }

    // MARK: card construction — looks native: grouped-inset style like the host forms

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
        stack.spacing = 8
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

        statusLabel = smallLabel("车辆：未配对")
        bmsLabel = smallLabel("ANT：未连接")
        stack.addArrangedSubview(statusLabel!)
        stack.addArrangedSubview(bmsLabel!)

        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 8
        row.distribution = .fillEqually
        row.addArrangedSubview(actionButton("扫描配对车辆", #selector(scanVehicle)))
        row.addArrangedSubview(actionButton("绑定ANT", #selector(scanBMS)))
        stack.addArrangedSubview(row)

        deviceButtons = UIStackView()
        deviceButtons?.axis = .vertical
        deviceButtons?.spacing = 6
        stack.addArrangedSubview(deviceButtons!)

        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
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

    private func actionButton(_ title: String, _ action: Selector) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.baseBackgroundColor = .systemBlue.withAlphaComponent(0.85)
        config.baseForegroundColor = .white
        config.cornerStyle = .medium
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
        let b = UIButton(configuration: config)
        b.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
        b.addTarget(self, action: action, for: .touchUpInside)
        return b
    }

    // MARK: actions

    @objc private func scanVehicle() {
        guard let vehicle else { return }
        vehicle.startScan()
        // populate after scan has had time
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            self?.populateVehicles()
        }
    }

    @objc private func scanBMS() {
        bms?.scan()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.populateBMS()
        }
    }

    private func populateVehicles() {
        guard let vehicle, !vehicle.devices.isEmpty else { return }
        deviceButtons?.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for device in vehicle.devices.prefix(3) {
            addRowButton("🛵 \(device.name) — 点选后等震动再按P键") { [weak self] in
                guard let self, let vehicle = self.vehicle else { return }
                vehicle.connectForPairing(device)
                // auto continue to pairing when ready
                self.waitForPairingReady(attempts: 0)
            }
        }
    }

    private func waitForPairingReady(attempts: Int) {
        guard let vehicle, attempts < 20 else { return }
        if vehicle.canBeginPairing {
            vehicle.beginPairing()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.waitForPairingReady(attempts: attempts + 1)
        }
    }

    private func populateBMS() {
        guard let bms, !bms.devices.isEmpty else { return }
        for device in bms.devices.prefix(2) {
            addRowButton("🔋 \(device.name) — 点击绑定") { [weak self] in
                self?.bms?.select(device.id)
            }
        }
    }

    private func addRowButton(_ title: String, handler: @escaping () -> Void) {
        var config = UIButton.Configuration.gray()
        config.title = title
        config.baseForegroundColor = .label
        config.cornerStyle = .small
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
        let b = UIButton(configuration: config)
        b.titleLabel?.font = .systemFont(ofSize: 11)
        b.titleLabel?.numberOfLines = 0
        b.contentHorizontalAlignment = .leading
        b.addAction(UIAction { _ in handler() }, for: .touchUpInside)
        deviceButtons?.addArrangedSubview(b)
    }

    // MARK: live status

    private func refresh() {
        guard let vehicle else { return }
        var text: String
        if vehicle.readyForButtonPress {
            text = "✅ 车机已就绪！现在短按车上 P 键"
        } else if vehicle.phase == .active {
            text = "🟢 仪表导航已开启，可投屏"
        } else {
            text = "车辆：" + vehicle.status
        }
        if let selected = vehicle.garage.selected {
            text += "（已选：\(selected.name)）"
        }
        statusLabel?.text = text

        if let bms {
            if let r = bms.freshReading {
                bmsLabel?.text = String(format: "🔋 ANT %d%% %.1fV %+.1fA %dW（已并入仪表电量）",
                                        r.stateOfCharge, r.voltage, r.current, r.power)
            } else {
                bmsLabel?.text = "ANT：" + bms.status + (bms.selectedID != nil ? "（已绑定 \(bms.selectedName)）" : "")
            }
        }
    }
}
