import UIKit

final class MicroViewController: UIViewController {
    private let store: MicroStore
    private let device = MicroDeviceView(frame: CGRect(origin: .zero, size: MicroTheme.designSize))
    private let scroll = UIScrollView()
    private let connectionButton = UIButton(type: .system)
    private let tasksButton = UIButton(type: .system)
    private let detailButton = UIButton(type: .system)
    private let settingsButton = UIButton(type: .system)
    private let topTrailingStack = UIStackView()
    private let selectionLabel = UILabel()
    private var lastFeedback: UUID?

    init(store: MicroStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var preferredStatusBarStyle: UIStatusBarStyle { .darkContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = MicroTheme.backdrop
        scroll.showsVerticalScrollIndicator = false
        scroll.alwaysBounceVertical = false
        scroll.contentInsetAdjustmentBehavior = .never
        for case let gesture as UIPanGestureRecognizer in device.encoder.gestureRecognizers ?? [] {
            scroll.panGestureRecognizer.require(toFail: gesture)
        }
        scroll.addSubview(device)

        topTrailingStack.axis = .horizontal
        topTrailingStack.spacing = 12
        topTrailingStack.alignment = .center
        for button in [tasksButton, detailButton, settingsButton] {
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 44),
                button.heightAnchor.constraint(equalToConstant: 44),
            ])
            topTrailingStack.addArrangedSubview(button)
        }

        for child in [connectionButton, topTrailingStack, scroll, selectionLabel] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }

        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            connectionButton.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 22),
            connectionButton.topAnchor.constraint(equalTo: safe.topAnchor, constant: 8),
            connectionButton.heightAnchor.constraint(equalToConstant: 44),
            connectionButton.trailingAnchor.constraint(lessThanOrEqualTo: topTrailingStack.leadingAnchor, constant: -12),
            topTrailingStack.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -18),
            topTrailingStack.topAnchor.constraint(equalTo: connectionButton.topAnchor),
            topTrailingStack.heightAnchor.constraint(equalToConstant: 44),
            scroll.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: connectionButton.bottomAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: selectionLabel.topAnchor, constant: -8),
            selectionLabel.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 24),
            selectionLabel.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -24),
            selectionLabel.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -16),
            selectionLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
        ])

        connectionButton.addTarget(self, action: #selector(showConnection), for: .touchUpInside)

        tasksButton.setImage(UIImage(systemName: "list.bullet.rectangle"), for: .normal)
        tasksButton.tintColor = MicroTheme.muted
        tasksButton.accessibilityLabel = "全部任务列表"
        tasksButton.addTarget(self, action: #selector(showTaskList), for: .touchUpInside)

        detailButton.setImage(UIImage(systemName: "bubble.left.and.text.bubble.right"), for: .normal)
        detailButton.tintColor = MicroTheme.muted
        detailButton.accessibilityLabel = "会话详情与消息"
        detailButton.addTarget(self, action: #selector(showSelectedThreadDetail), for: .touchUpInside)

        settingsButton.setImage(UIImage(systemName: "slider.horizontal.3"), for: .normal)
        settingsButton.tintColor = MicroTheme.muted
        settingsButton.accessibilityLabel = "电脑与连接设置"
        settingsButton.addTarget(self, action: #selector(showConnection), for: .touchUpInside)

        selectionLabel.font = .preferredFont(forTextStyle: .caption1)
        selectionLabel.adjustsFontForContentSizeCategory = true
        selectionLabel.textColor = MicroTheme.muted
        selectionLabel.textAlignment = .center
        selectionLabel.numberOfLines = 2
        selectionLabel.isUserInteractionEnabled = true
        selectionLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(showSelectedThreadDetail)))

        device.onPage = { [weak store] in store?.page = $0 }
        device.onThread = { [weak store] in store?.select($0) }
        device.onCommand = { [weak self] in self?.perform($0) }
        device.encoder.onStep = { [weak store] in store?.stepEffort($0) }
        device.encoder.onTap = { [weak store] in store?.toggleModel() }
        device.encoder.onLongPress = { [weak self] in self?.showModels() }
        device.quota.onTap = { [weak store] in store?.toggleModel() }
        device.quota.onLongPress = { [weak self] in self?.showModels() }
        device.joystick.onUp = { [weak self] in self?.perform(.plan) }
        device.menuForThread = { [weak self] in self?.threadMenu($0) }
        store.onChange = { [weak self] in self?.render() }
        store.onError = { [weak self] in self?.showError($0) }
        render()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = scroll.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let scale = min((size.width - 16) / 590, min(1.20, max(0.62, size.height / 610)))
        let height = max(size.height, 610 * scale)
        device.bounds = CGRect(origin: .zero, size: MicroTheme.designSize)
        device.transform = CGAffineTransform(scaleX: scale, y: scale)
        device.center = CGPoint(x: size.width / 2, y: height / 2)
        scroll.contentSize = CGSize(width: size.width, height: height)
    }

    private func render() {
        guard isViewLoaded else { return }
        device.render(store)

        var configuration = UIButton.Configuration.tinted()
        let hostPrefix: String = {
            if store.isDemo { return "DEMO" }
            let name = store.snapshot?.hostName ?? store.activeHost?.name ?? "Host"
            if store.isReadOnlyLease {
                return "\(name) · 只读"
            }
            return "\(name) · \(store.connection.label)"
        }()
        configuration.title = hostPrefix
        configuration.image = UIImage(systemName: store.isDemo ? "circle.dotted" : "network")
        configuration.imagePadding = 7
        configuration.cornerStyle = .capsule
        configuration.baseForegroundColor = store.connection.allowsCommands ? MicroTheme.ink : MicroTheme.muted
        configuration.baseBackgroundColor = .white
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 12)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var result = attributes
            result.font = .systemFont(ofSize: 12, weight: .semibold)
            return result
        }
        connectionButton.configuration = configuration
        connectionButton.menu = buildHostQuickSwitchMenu()
        if case .failed(let reason) = store.connection {
            connectionButton.accessibilityValue = reason
        } else {
            connectionButton.accessibilityValue = nil
        }

        detailButton.isEnabled = store.selected != nil
        tasksButton.isEnabled = store.connection.allowsCommands

        if let thread = store.selected {
            let model = store.models.first { $0.id == thread.modelID }?.name ?? thread.modelID ?? "未知模型"
            let effort = thread.effort ?? "未知强度"
            let suffix: String
            if store.hasUncertainCommand(forThread: thread.id) {
                suffix = "操作待确认 · 点按查看详情或解锁"
            } else if store.isReadOnlyLease {
                suffix = "只读模式 · 点按可接管控制"
            } else {
                suffix = "\(model) · \(effort) · \(MicroTheme.statusName(thread.status))"
            }
            selectionLabel.text = "\(thread.title)\n\(suffix)"
        } else {
            selectionLabel.text = nil
        }

        if let receipt = store.lastReceipt, receipt.status == .applied, receipt.requestID != lastFeedback {
            lastFeedback = receipt.requestID
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    private func buildHostQuickSwitchMenu() -> UIMenu {
        var actions: [UIAction] = [
            UIAction(
                title: "演示模式 (DEMO)",
                image: UIImage(systemName: "circle.dotted"),
                state: store.isDemo ? .on : .off
            ) { [weak self] _ in
                self?.store.useDemo()
            },
        ]
        for host in store.savedHosts {
            let isCurrent = !store.isDemo && store.activeHost?.id == host.id
            let icon = (host.platform == .windows) ? "pc" : "laptopcomputer"
            actions.append(UIAction(
                title: host.name,
                image: UIImage(systemName: icon),
                state: isCurrent ? .on : .off
            ) { [weak self] _ in
                self?.store.useHost(host)
            })
        }
        if store.isReadOnlyLease {
            actions.append(UIAction(
                title: "接管控制权",
                image: UIImage(systemName: "hand.raised.fill")
            ) { [weak self] _ in
                self?.store.requestTakeover()
            })
        }
        return UIMenu(title: "切换电脑", children: actions)
    }

    private func perform(_ kind: MicroCommandKind) {
        guard let thread = store.selected, store.supports(kind) else { return }
        switch kind {
        case .fast:
            guard let fast = thread.fast else { return }
            store.execute(kind, value: String(!fast))

        case .plan:
            guard let plan = thread.plan else { return }
            store.execute(kind, value: String(!plan))

        case .approve, .decline:
            if thread.pendingApprovalCount > 1 {
                presentThreadDetail(threadID: thread.id)
                return
            }
            guard let approvalItem = thread.approval else {
                presentThreadDetail(threadID: thread.id)
                return
            }
            let title = (kind == .approve) ? "批准请求" : "拒绝请求"
            let detail = "\(thread.title)\n\n\(approvalItem.detailText)"
            let alert = UIAlertController(title: title, message: detail, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "取消", style: .cancel))
            alert.addAction(UIAlertAction(
                title: title,
                style: kind == .decline ? .destructive : .default
            ) { [weak self] _ in
                guard let self,
                      let current = self.store.selected,
                      current.id == thread.id,
                      current.approval?.id == approvalItem.id,
                      current.approval?.approvalContentHash == approvalItem.approvalContentHash else {
                    return
                }
                self.store.execute(kind, threadID: thread.id, approvalItem: approvalItem)
            })
            present(alert, animated: true)

        case .fork, .stop:
            let labels: [MicroCommandKind: String] = [.fork: "分叉会话", .stop: "停止任务"]
            let title = labels[kind] ?? "确认"
            let alert = UIAlertController(title: title, message: thread.title, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "取消", style: .cancel))
            alert.addAction(UIAlertAction(
                title: title,
                style: kind == .stop ? .destructive : .default
            ) { [weak self] _ in
                guard let self,
                      let current = self.store.selected,
                      current.id == thread.id,
                      current.turnID == thread.turnID else {
                    return
                }
                self.store.execute(kind)
            })
            present(alert, animated: true)

        default:
            store.execute(kind)
        }
    }

    private func threadMenu(_ id: String) -> UIMenu? {
        guard let thread = store.snapshot?.threads.first(where: { $0.id == id }) else { return nil }
        let inspect = UIAction(
            title: "查看回复与发送消息",
            image: UIImage(systemName: "bubble.left.and.text.bubble.right")
        ) { [weak self] _ in
            self?.store.select(id)
            self?.presentThreadDetail(threadID: id)
        }
        let open = UIAction(
            title: "在桌面打开",
            image: UIImage(systemName: "desktopcomputer"),
            attributes: store.canControl && thread.capabilities.contains(.open) ? [] : .disabled
        ) { [weak self] _ in
            self?.store.select(id)
            self?.perform(.open)
        }
        let stop = UIAction(
            title: "停止任务",
            image: UIImage(systemName: "stop.circle"),
            attributes: store.canControl && thread.turnID != nil && thread.capabilities.contains(.stop)
                ? .destructive : [.disabled, .destructive]
        ) { [weak self] _ in
            self?.store.select(id)
            self?.perform(.stop)
        }
        return UIMenu(title: thread.title, children: [inspect, open, stop])
    }

    private func showModels() {
        guard let selected = store.selected else { return }
        let alert = UIAlertController(title: "模型", message: nil, preferredStyle: .actionSheet)
        for model in store.models {
            let action = UIAlertAction(
                title: (model.id == selected.modelID ? "✓ " : "") + model.name,
                style: .default
            ) { [weak self] _ in
                guard let self, self.store.selectedID == selected.id else { return }
                self.store.execute(.model, value: model.id)
            }
            action.isEnabled = store.supports(.model)
            alert.addAction(action)
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.popoverPresentationController?.sourceView = device.quota
        alert.popoverPresentationController?.sourceRect = device.quota.bounds
        present(alert, animated: true)
    }

    @objc private func showTaskList() {
        let controller = TaskListViewController(store: store)
        let navigation = UINavigationController(rootViewController: controller)
        navigation.sheetPresentationController?.detents = [.medium(), .large()]
        navigation.sheetPresentationController?.prefersGrabberVisible = true
        present(navigation, animated: true)
    }

    @objc private func showSelectedThreadDetail() {
        guard let threadID = store.selectedID else { return }
        presentThreadDetail(threadID: threadID)
    }

    private func presentThreadDetail(threadID: String) {
        let controller = ThreadDetailViewController(store: store, threadID: threadID)
        let navigation = UINavigationController(rootViewController: controller)
        navigation.sheetPresentationController?.detents = [.medium(), .large()]
        navigation.sheetPresentationController?.prefersGrabberVisible = true
        present(navigation, animated: true)
    }

    @objc private func showConnection() {
        let controller = ConnectionViewController(store: store)
        let navigation = UINavigationController(rootViewController: controller)
        navigation.sheetPresentationController?.detents = [.medium(), .large()]
        navigation.sheetPresentationController?.prefersGrabberVisible = true
        present(navigation, animated: true)
    }

    private func showError(_ message: String) {
        guard presentedViewController == nil, view.window != nil else { return }
        let alert = UIAlertController(title: "操作未完成", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }
}
