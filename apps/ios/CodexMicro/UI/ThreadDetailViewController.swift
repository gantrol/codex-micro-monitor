import UIKit

final class ThreadDetailViewController: UITableViewController {
    private let store: MicroStore
    private let threadID: String
    private let messageField = UITextField()
    private var detail: MicroThreadDetail?

    init(store: MicroStore, threadID: String) {
        self.store = store
        self.threadID = threadID
        self.detail = store.threadDetails[threadID]
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    private var thread: MicroThread? {
        store.snapshot?.threads.first { $0.id == threadID }
    }

    private var approvals: [MicroApprovalItem] {
        if let detail, !detail.approvals.isEmpty {
            return detail.approvals
        }
        if let single = thread?.approval {
            return [single]
        }
        return []
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = thread?.title ?? "任务详情"
        view.backgroundColor = MicroTheme.backdrop
        tableView.keyboardDismissMode = .interactive

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "arrow.clockwise"),
            primaryAction: UIAction { [weak self] _ in
                self?.refreshDetail()
            }
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done,
            primaryAction: UIAction { [weak self] _ in
                self?.dismiss(animated: true)
            }
        )

        messageField.font = .preferredFont(forTextStyle: .body)
        messageField.placeholder = "向当前空闲会话发送新消息…"
        messageField.clearButtonMode = .whileEditing
        messageField.returnKeyType = .send

        store.onThreadDetail = { [weak self] updated in
            guard let self, updated.threadID == self.threadID else { return }
            self.detail = updated
            self.tableView.reloadData()
        }

        refreshDetail()
    }

    private func refreshDetail() {
        store.fetchThreadDetail(threadID)
        store.queryPending()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 5 }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0:
            return (store.isReadOnlyLease || store.hasUncertainCommand(forThread: threadID)) ? "状态恢复与控制权" : nil
        case 1:
            return "运行与参数控制"
        case 2:
            return approvals.isEmpty ? nil : "待审批请求 (\(approvals.count))"
        case 3:
            return "最近助手回复"
        case 4:
            return "发送文字消息"
        default:
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0:
            var count = 0
            if store.isReadOnlyLease { count += 1 }
            if store.hasUncertainCommand(forThread: threadID) { count += 1 }
            return count
        case 1:
            return (thread?.turnID != nil || detail?.activeTurnID != nil) ? 5 : 4
        case 2:
            return approvals.count
        case 3:
            let qCount = detail?.pendingQuestions.count ?? 0
            return 1 + qCount
        case 4:
            return 2
        default:
            return 0
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        cell.backgroundColor = MicroTheme.paper

        switch indexPath.section {
        case 0:
            var config = cell.defaultContentConfiguration()
            if store.isReadOnlyLease && indexPath.row == 0 {
                let writer = store.lease?.activeWriterName ?? "其他设备"
                config.text = "接管控制权（当前由 \(writer) 控制）"
                config.textProperties.color = MicroTheme.accent
                config.image = UIImage(systemName: "hand.raised.fill")
            } else {
                config.text = "重新查询结果并解除待确认锁定"
                config.textProperties.color = .systemOrange
                config.image = UIImage(systemName: "exclamationmark.arrow.triangle.2.circlepath")
            }
            cell.contentConfiguration = config
            return cell

        case 1:
            let currentThread = thread
            switch indexPath.row {
            case 0:
                var config = cell.defaultContentConfiguration()
                config.text = "模型"
                let modelID = currentThread?.modelID
                let modelName = store.models.first(where: { $0.id == modelID })?.name ?? modelID ?? "未知"
                config.secondaryText = modelName
                cell.contentConfiguration = config
                cell.accessoryType = .disclosureIndicator
                return cell

            case 1:
                let segCell = UITableViewCell(style: .default, reuseIdentifier: nil)
                segCell.backgroundColor = MicroTheme.paper
                segCell.selectionStyle = .none
                let label = UILabel()
                label.text = "推理强度"
                label.font = .preferredFont(forTextStyle: .body)
                label.textColor = MicroTheme.ink

                let modelID = currentThread?.modelID
                let efforts = store.models.first(where: { $0.id == modelID })?.efforts ?? ["low", "medium", "high", "xhigh"]
                let segmented = UISegmentedControl(items: efforts)
                if let currentEffort = currentThread?.effort,
                   let idx = efforts.firstIndex(of: currentEffort) {
                    segmented.selectedSegmentIndex = idx
                } else {
                    segmented.selectedSegmentIndex = UISegmentedControl.noSegment
                }
                segmented.isEnabled = store.canControl
                segmented.addAction(UIAction { [weak self, weak segmented] _ in
                    guard let self, let segmented,
                          segmented.selectedSegmentIndex >= 0,
                          segmented.selectedSegmentIndex < efforts.count else { return }
                    let chosen = efforts[segmented.selectedSegmentIndex]
                    self.store.execute(.effort, value: chosen, threadID: self.threadID)
                }, for: .valueChanged)

                let stack = UIStackView(arrangedSubviews: [label, segmented])
                stack.axis = .horizontal
                stack.spacing = 12
                stack.alignment = .center
                stack.translatesAutoresizingMaskIntoConstraints = false
                segCell.contentView.addSubview(stack)
                NSLayoutConstraint.activate([
                    stack.leadingAnchor.constraint(equalTo: segCell.contentView.leadingAnchor, constant: 16),
                    stack.trailingAnchor.constraint(equalTo: segCell.contentView.trailingAnchor, constant: -16),
                    stack.topAnchor.constraint(equalTo: segCell.contentView.topAnchor, constant: 10),
                    stack.bottomAnchor.constraint(equalTo: segCell.contentView.bottomAnchor, constant: -10),
                ])
                return segCell

            case 2:
                var config = cell.defaultContentConfiguration()
                config.text = "Fast 模式"
                if let fast = currentThread?.fast {
                    config.secondaryText = fast ? "已开启" : "已关闭"
                } else {
                    config.secondaryText = "未知"
                }
                cell.contentConfiguration = config
                return cell

            case 3:
                var config = cell.defaultContentConfiguration()
                config.text = "Plan 模式"
                if let plan = currentThread?.plan {
                    config.secondaryText = plan ? "已开启" : "已关闭"
                } else {
                    config.secondaryText = "未知"
                }
                cell.contentConfiguration = config
                return cell

            default:
                var config = cell.defaultContentConfiguration()
                config.text = "停止当前运行中的 Turn"
                config.textProperties.color = .systemRed
                config.image = UIImage(systemName: "stop.circle.fill")
                config.imageProperties.tintColor = .systemRed
                cell.contentConfiguration = config
                return cell
            }

        case 2:
            let item = approvals[indexPath.row]
            let appCell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
            appCell.backgroundColor = MicroTheme.paper
            var config = appCell.defaultContentConfiguration()
            let kindTitle: String = switch item.kind {
            case .command: "命令执行审批"
            case .fileChange: "文件改动审批"
            case .other: "操作审批"
            }
            config.text = "\(kindTitle)：\(item.summary)"
            config.textProperties.font = .preferredFont(forTextStyle: .headline)
            config.secondaryText = item.detailText
            config.secondaryTextProperties.numberOfLines = 4
            config.secondaryTextProperties.color = MicroTheme.muted
            config.image = UIImage(systemName: "exclamationmark.shield.fill")
            config.imageProperties.tintColor = .systemOrange
            appCell.contentConfiguration = config
            appCell.accessoryType = .disclosureIndicator
            return appCell

        case 3:
            let replyCell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
            replyCell.backgroundColor = MicroTheme.paper
            var config = replyCell.defaultContentConfiguration()
            if indexPath.row == 0 {
                if let reply = detail?.latestReply, !reply.text.isEmpty {
                    config.text = reply.isStreaming ? "正在生成回复…" : "最新助手回复"
                    config.textProperties.font = .preferredFont(forTextStyle: .caption1)
                    config.textProperties.color = MicroTheme.muted
                    config.secondaryText = reply.text
                    config.secondaryTextProperties.font = .preferredFont(forTextStyle: .body)
                    config.secondaryTextProperties.color = MicroTheme.ink
                    config.secondaryTextProperties.numberOfLines = 0
                } else {
                    config.text = "暂无可显示的助手回复"
                    config.textProperties.color = MicroTheme.muted
                }
            } else if let q = detail?.pendingQuestions[indexPath.row - 1] {
                config.text = "待回答提问：\(q.prompt)"
                config.textProperties.color = MicroTheme.ink
                if !q.options.isEmpty {
                    config.secondaryText = "候选项：" + q.options.joined(separator: " / ")
                }
            }
            replyCell.contentConfiguration = config
            return replyCell

        case 4:
            if indexPath.row == 0 {
                let inputCell = UITableViewCell(style: .default, reuseIdentifier: nil)
                inputCell.backgroundColor = MicroTheme.paper
                inputCell.selectionStyle = .none
                messageField.translatesAutoresizingMaskIntoConstraints = false
                inputCell.contentView.addSubview(messageField)
                NSLayoutConstraint.activate([
                    messageField.leadingAnchor.constraint(equalTo: inputCell.contentView.leadingAnchor, constant: 16),
                    messageField.trailingAnchor.constraint(equalTo: inputCell.contentView.trailingAnchor, constant: -16),
                    messageField.topAnchor.constraint(equalTo: inputCell.contentView.topAnchor, constant: 12),
                    messageField.bottomAnchor.constraint(equalTo: inputCell.contentView.bottomAnchor, constant: -12),
                    messageField.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
                ])
                return inputCell
            } else {
                var config = cell.defaultContentConfiguration()
                let canSend = (detail?.canSubmitText ?? (thread?.status == .idle)) && store.canControl
                config.text = canSend ? "发送消息到当前会话" : "当前会话非空闲或待审批，暂不可发送"
                config.textProperties.color = canSend ? MicroTheme.accent : MicroTheme.muted
                config.image = UIImage(systemName: "paperplane.fill")
                config.imageProperties.tintColor = canSend ? MicroTheme.accent : MicroTheme.muted
                cell.contentConfiguration = config
                return cell
            }

        default:
            return cell
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        switch indexPath.section {
        case 0:
            if store.isReadOnlyLease && indexPath.row == 0 {
                store.requestTakeover()
            } else {
                store.queryPending()
                store.clearUncertainCommands(forThread: threadID)
                refreshDetail()
            }
            tableView.reloadData()

        case 1:
            guard let currentThread = thread else { return }
            switch indexPath.row {
            case 0:
                presentModelPicker(currentThread)
            case 2:
                guard let fast = currentThread.fast else { return }
                store.execute(.fast, value: String(!fast), threadID: threadID)
                tableView.reloadData()
            case 3:
                guard let plan = currentThread.plan else { return }
                store.execute(.plan, value: String(!plan), threadID: threadID)
                tableView.reloadData()
            case 4:
                confirmStopTurn(currentThread)
            default:
                break
            }

        case 2:
            guard indexPath.row < approvals.count else { return }
            presentApprovalConfirmation(approvals[indexPath.row])

        case 3:
            if indexPath.row == 0, let text = detail?.latestReply?.text, !text.isEmpty {
                UIPasteboard.general.string = text
            }

        case 4:
            if indexPath.row == 1 {
                submitTextMessage()
            }

        default:
            break
        }
    }

    private func presentModelPicker(_ currentThread: MicroThread) {
        let alert = UIAlertController(title: "选择模型", message: nil, preferredStyle: .actionSheet)
        for model in store.models {
            let prefix = (model.id == currentThread.modelID) ? "✓ " : ""
            let action = UIAlertAction(title: prefix + model.name, style: .default) { [weak self] _ in
                guard let self else { return }
                self.store.execute(.model, value: model.id, threadID: self.threadID)
                self.tableView.reloadData()
            }
            action.isEnabled = store.canControl
            alert.addAction(action)
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.popoverPresentationController?.sourceView = view
        present(alert, animated: true)
    }

    func presentApprovalConfirmation(_ item: MicroApprovalItem) {
        let alert = UIAlertController(
            title: "审批确认",
            message: item.detailText,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "拒绝", style: .destructive) { [weak self] _ in
            guard let self else { return }
            self.store.execute(.decline, threadID: self.threadID, approvalItem: item)
            self.refreshDetail()
        })
        alert.addAction(UIAlertAction(title: "批准", style: .default) { [weak self] _ in
            guard let self else { return }
            self.store.execute(.approve, threadID: self.threadID, approvalItem: item)
            self.refreshDetail()
        })
        present(alert, animated: true)
    }

    private func confirmStopTurn(_ currentThread: MicroThread) {
        let alert = UIAlertController(
            title: "停止任务",
            message: currentThread.title,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "停止任务", style: .destructive) { [weak self] _ in
            guard let self else { return }
            self.store.execute(.stop, threadID: self.threadID)
            self.refreshDetail()
        })
        present(alert, animated: true)
    }

    private func submitTextMessage() {
        let canSend = (detail?.canSubmitText ?? (thread?.status == .idle)) && store.canControl
        guard canSend else { return }
        let text = (messageField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        messageField.text = nil
        messageField.resignFirstResponder()
        store.execute(.sendText, value: text, threadID: threadID)
        refreshDetail()
    }
}
