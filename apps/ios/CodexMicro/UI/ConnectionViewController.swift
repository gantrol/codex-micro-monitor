import AVFoundation
import UIKit

final class ConnectionViewController: UITableViewController {
    private let store: MicroStore
    private let modeControl = UISegmentedControl(items: ["方案 A：Tailscale 直连", "方案 B：自建中继"])
    private let nameField = UITextField()
    private let endpointField = UITextField()
    private let tokenField = UITextField()
    private let pinOrPubKeyField = UITextField()

    init(store: MicroStore) {
        self.store = store
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "电脑与连接"
        view.backgroundColor = MicroTheme.backdrop
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done,
            primaryAction: UIAction { [weak self] _ in
                self?.dismiss(animated: true)
            }
        )
        tableView.keyboardDismissMode = .interactive

        modeControl.selectedSegmentIndex = 0
        modeControl.addAction(UIAction { [weak self] _ in
            self?.updatePlaceholdersForMode()
        }, for: .valueChanged)

        for field in [nameField, endpointField, tokenField, pinOrPubKeyField] {
            field.font = .preferredFont(forTextStyle: .body)
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.clearButtonMode = .whileEditing
            field.adjustsFontForContentSizeCategory = true
        }

        nameField.placeholder = "电脑名称（如 Mac Studio / Win PC）"
        endpointField.keyboardType = .URL
        endpointField.textContentType = .URL
        tokenField.placeholder = "一次性配对码或设备令牌"
        tokenField.isSecureTextEntry = true

        if let active = store.activeHost {
            populateFields(from: active)
        } else {
            updatePlaceholdersForMode()
        }
    }

    private func populateFields(from host: SavedHost) {
        modeControl.selectedSegmentIndex = (host.mode == .relayE2EE) ? 1 : 0
        nameField.text = host.name
        endpointField.text = host.primaryEndpoint
        tokenField.text = host.token
        pinOrPubKeyField.text = (host.mode == .relayE2EE) ? (host.hostPublicKey ?? "") : host.certificateSHA256
        updatePlaceholdersForMode()
    }

    private func updatePlaceholdersForMode() {
        let isRelay = modeControl.selectedSegmentIndex == 1
        endpointField.placeholder = isRelay
            ? "wss://relay.example.com/ws/relay"
            : "wss://100.x.y.z:48720/ws/micro"
        pinOrPubKeyField.placeholder = isRelay
            ? "Host Curve25519 公钥（Base64）"
            : "证书 SHA-256 指纹（64 位 Hex，可选）"
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 5 }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0: return "已保存的电脑"
        case 1: return "快速配对"
        case 2: return "手动配置连接"
        case 3: return "会话控制与恢复"
        default: return nil
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0: return store.savedHosts.count + 1
        case 1: return 2
        case 2: return 5
        case 3: return 3
        case 4: return store.activeHost != nil ? 1 : 0
        default: return 0
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.backgroundColor = MicroTheme.paper

        switch indexPath.section {
        case 0:
            var config = cell.defaultContentConfiguration()
            if indexPath.row == 0 {
                config.text = "演示模式 (DEMO)"
                config.secondaryText = "本地内置模拟数据"
                config.image = UIImage(systemName: "circle.dotted")
                cell.accessoryType = store.isDemo ? .checkmark : .none
            } else {
                let host = store.savedHosts[indexPath.row - 1]
                config.text = host.name
                let modeLabel = (host.mode == .relayE2EE) ? "方案 B 中继" : "方案 A 直连"
                let platformLabel: String = switch host.platform {
                case .macos: "macOS"
                case .windows: "Windows"
                default: "Host"
                }
                config.secondaryText = "\(platformLabel) · \(modeLabel) · \(host.primaryEndpoint)"
                config.secondaryTextProperties.color = MicroTheme.muted
                let iconName = (host.platform == .windows) ? "pc" : "laptopcomputer"
                config.image = UIImage(systemName: iconName)
                let isSelected = !store.isDemo && store.activeHost?.id == host.id
                cell.accessoryType = isSelected ? .checkmark : .none
            }
            cell.contentConfiguration = config
            return cell

        case 1:
            var config = cell.defaultContentConfiguration()
            if indexPath.row == 0 {
                config.text = "扫描电脑端配对二维码"
                config.image = UIImage(systemName: "qrcode.viewfinder")
                config.textProperties.color = MicroTheme.accent
            } else {
                config.text = "从剪贴板导入配对链接 (codexmicro://pair)"
                config.image = UIImage(systemName: "doc.on.clipboard")
                config.textProperties.color = MicroTheme.accent
            }
            cell.contentConfiguration = config
            return cell

        case 2:
            if indexPath.row == 0 {
                let segCell = UITableViewCell(style: .default, reuseIdentifier: nil)
                segCell.backgroundColor = MicroTheme.paper
                segCell.selectionStyle = .none
                modeControl.translatesAutoresizingMaskIntoConstraints = false
                segCell.contentView.addSubview(modeControl)
                NSLayoutConstraint.activate([
                    modeControl.leadingAnchor.constraint(equalTo: segCell.contentView.leadingAnchor, constant: 16),
                    modeControl.trailingAnchor.constraint(equalTo: segCell.contentView.trailingAnchor, constant: -16),
                    modeControl.topAnchor.constraint(equalTo: segCell.contentView.topAnchor, constant: 10),
                    modeControl.bottomAnchor.constraint(equalTo: segCell.contentView.bottomAnchor, constant: -10),
                ])
                return segCell
            }
            let fields = [nameField, endpointField, tokenField, pinOrPubKeyField]
            let field = fields[indexPath.row - 1]
            let fieldCell = UITableViewCell(style: .default, reuseIdentifier: nil)
            fieldCell.backgroundColor = MicroTheme.paper
            fieldCell.selectionStyle = .none
            field.translatesAutoresizingMaskIntoConstraints = false
            fieldCell.contentView.addSubview(field)
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: fieldCell.contentView.leadingAnchor, constant: 16),
                field.trailingAnchor.constraint(equalTo: fieldCell.contentView.trailingAnchor, constant: -16),
                field.topAnchor.constraint(equalTo: fieldCell.contentView.topAnchor, constant: 12),
                field.bottomAnchor.constraint(equalTo: fieldCell.contentView.bottomAnchor, constant: -12),
                field.heightAnchor.constraint(greaterThanOrEqualToConstant: 24),
            ])
            return fieldCell

        case 3:
            var config = cell.defaultContentConfiguration()
            if indexPath.row == 0 {
                config.text = "保存并连接此电脑"
                config.textProperties.color = MicroTheme.accent
                config.image = UIImage(systemName: "bolt.horizontal.circle.fill")
            } else if indexPath.row == 1 {
                config.text = "接管当前电脑控制权 (Takeover)"
                config.textProperties.color = MicroTheme.accent
                config.image = UIImage(systemName: "hand.raised")
            } else {
                config.text = "查询待确认操作并解除未知状态锁定"
                config.textProperties.color = .systemOrange
                config.image = UIImage(systemName: "arrow.triangle.2.circlepath")
            }
            cell.contentConfiguration = config
            return cell

        default:
            var config = cell.defaultContentConfiguration()
            config.text = "移除当前选中的电脑"
            config.textProperties.color = .systemRed
            cell.contentConfiguration = config
            return cell
        }
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        indexPath.section == 0 && indexPath.row > 0
    }

    override func tableView(
        _ tableView: UITableView,
        commit editingStyle: UITableViewCell.EditingStyle,
        forRowAt indexPath: IndexPath
    ) {
        guard editingStyle == .delete, indexPath.section == 0, indexPath.row > 0 else { return }
        let host = store.savedHosts[indexPath.row - 1]
        store.removeHost(id: host.id)
        tableView.reloadData()
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        switch indexPath.section {
        case 0:
            if indexPath.row == 0 {
                store.useDemo()
                dismiss(animated: true)
            } else {
                let host = store.savedHosts[indexPath.row - 1]
                populateFields(from: host)
                store.useHost(host)
                dismiss(animated: true)
            }

        case 1:
            if indexPath.row == 0 {
                presentQRScanner()
            } else {
                importPairingFromClipboard()
            }

        case 3:
            if indexPath.row == 0 {
                saveAndConnectManualHost()
            } else if indexPath.row == 1 {
                store.requestTakeover()
                dismiss(animated: true)
            } else {
                store.queryPending()
                store.clearUncertainCommands()
                dismiss(animated: true)
            }

        case 4:
            if let activeID = store.activeHost?.id {
                store.removeHost(id: activeID)
                tableView.reloadData()
            }

        default:
            break
        }
    }

    private func importPairingFromClipboard() {
        let raw = (UIPasteboard.general.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let payload = MicroRemotePairPayload.parse(raw) else {
            showError("剪贴板中未识别到有效的 codexmicro://pair 配对链接或 JSON")
            return
        }
        applyPairedPayload(payload)
    }

    private func presentQRScanner() {
        let scanner = QRScannerViewController()
        scanner.onScannedCode = { [weak self] code in
            guard let self else { return }
            guard let payload = MicroRemotePairPayload.parse(code) else {
                self.showError("二维码内容不是有效的 Micro 配对码")
                return
            }
            self.applyPairedPayload(payload)
        }
        let nav = UINavigationController(rootViewController: scanner)
        present(nav, animated: true)
    }

    private func applyPairedPayload(_ payload: MicroRemotePairPayload) {
        let host = SavedHost.fromPairPayload(payload)
        do {
            _ = try host.validatedCandidateURLs()
            try HostKeychain.upsertHost(host)
            store.useHost(host)
            dismiss(animated: true)
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func saveAndConnectManualHost() {
        let isRelay = modeControl.selectedSegmentIndex == 1
        let ep = (endpointField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let rawToken = (tokenField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let extra = (pinOrPubKeyField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let customName = (nameField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackName = URL(string: ep)?.host ?? "Host"

        let hostID = store.activeHost?.id ?? ("host-" + MicroRemoteCrypto.sha256Hex(ep).prefix(10))
        let isOneTimeToken = !rawToken.hasPrefix("dt_")
        let saved = SavedHost(
            id: String(hostID),
            name: customName.isEmpty ? fallbackName : customName,
            platform: store.activeHost?.platform ?? .unknown,
            mode: isRelay ? .relayE2EE : .directTailscale,
            endpoints: isRelay ? [] : [ep],
            relayURL: isRelay ? ep : nil,
            token: rawToken,
            isPairingToken: isOneTimeToken,
            certificateSHA256: isRelay ? "" : extra,
            hostPublicKey: isRelay ? extra : nil,
            lastConnectedAtMs: Int64(Date().timeIntervalSince1970 * 1000)
        )

        do {
            _ = try saved.validatedCandidateURLs()
            try HostKeychain.upsertHost(saved)
            store.useHost(saved)
            dismiss(animated: true)
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func showError(_ message: String) {
        let alert = UIAlertController(title: "连接未完成", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }
}

private final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScannedCode: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var hasHandledResult = false

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "扫描配对二维码"
        view.backgroundColor = .black
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .cancel,
            primaryAction: UIAction { [weak self] _ in
                self?.dismiss(animated: true)
            }
        )

        guard let videoDevice = AVCaptureDevice.default(for: .video),
              let videoInput = try? AVCaptureDeviceInput(device: videoDevice),
              session.canAddInput(videoInput) else {
            return
        }
        session.addInput(videoInput)

        let metadataOutput = AVCaptureMetadataOutput()
        guard session.canAddOutput(metadataOutput) else { return }
        session.addOutput(metadataOutput)
        metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
        if metadataOutput.availableMetadataObjectTypes.contains(.qr) {
            metadataOutput.metadataObjectTypes = [.qr]
        }

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.layer.bounds
        view.layer.addSublayer(preview)
        self.previewLayer = preview

        DispatchQueue.global(qos: .userInitiated).async { [session] in
            session.startRunning()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.layer.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning {
            session.stopRunning()
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !hasHandledResult,
              let readable = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let stringValue = readable.stringValue,
              !stringValue.isEmpty else {
            return
        }
        hasHandledResult = true
        session.stopRunning()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        dismiss(animated: true) { [onScannedCode] in
            onScannedCode?(stringValue)
        }
    }
}
