import AppKit
import Combine

private func permissionText(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}

/// AppKit adaptation of PermissionFlow's compact, draggable permission card.
/// Kept outside SwiftUI to support the native bridge inside a Catalyst process.
@MainActor final class PermissionSetupView: NSViewController {
    private let model: PermissionSetupModel
    private let onClose: () -> Void
    private let onOpenSettings: () -> Void
    private let onDrag: (Bool) -> Void
    private let accent = NSColor(calibratedRed: 83/255, green: 103/255, blue: 90/255, alpha: 1)
    private let status = NSTextField(wrappingLabelWithString: "")
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let repair = NSTextField(wrappingLabelWithString: "")
    private let error = NSTextField(wrappingLabelWithString: "")
    private let openButton = NSButton()
    private let closeButton = NSButton()
    private let appCard: PermissionAppDragView
    private var contentStack: NSStackView?
    private var subscriptions = Set<AnyCancellable>()

    init(model: PermissionSetupModel, onOpenSettings: @escaping () -> Void,
         onDrag: @escaping (Bool) -> Void, onClose: @escaping () -> Void) {
        self.model = model; self.onClose = onClose; self.onOpenSettings = onOpenSettings; self.onDrag = onDrag
        appCard = PermissionAppDragView(applicationURL: model.applicationURL)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 350))
        view.appearance = NSAppearance(named: .aqua)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(calibratedRed: 247/255, green: 248/255, blue: 246/255, alpha: 1).cgColor
        let title = NSTextField(labelWithString: permissionText("permissionAccessibilityTitle"))
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor
        openButton.target = self; openButton.action = #selector(openSettings)
        openButton.bezelStyle = .rounded; openButton.bezelColor = accent; openButton.contentTintColor = .white
        appCard.onDragStateChange = onDrag
        hint.font = .systemFont(ofSize: 13)
        repair.stringValue = permissionText("permissionDragRepair"); repair.font = .systemFont(ofSize: 11); repair.textColor = .secondaryLabelColor
        error.stringValue = permissionText("permissionSettingsUnavailable"); error.font = .systemFont(ofSize: 12); error.textColor = .systemRed
        let locate = NSButton(title: permissionText("permissionLocateShort"), target: self, action: #selector(revealApplication))
        locate.toolTip = model.applicationURL.path
        let check = NSButton(title: permissionText("permissionCheckAgain"), target: self, action: #selector(checkAgain))
        closeButton.target = self; closeButton.action = #selector(closeSetup)
        for button in [locate, check, closeButton] { button.bezelStyle = .rounded; button.controlSize = .small }
        let footer = NSStackView(views: [locate, check, closeButton]); footer.orientation = .horizontal; footer.distribution = .equalSpacing
        let stack = NSStackView(views: [title, status, openButton, appCard, hint, repair, error, footer])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.detachesHiddenViews = true
        contentStack = stack
        for label in [status, hint, repair, error] { label.preferredMaxLayoutWidth = 324 }
        view.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            appCard.heightAnchor.constraint(equalToConstant: 88)
        ])
        for child in [status, openButton, appCard, hint, repair, error, footer] {
            child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        model.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.update() }.store(in: &subscriptions)
        update()
    }

    override func viewDidAppear() { super.viewDidAppear(); resizeToFitContent() }

    private func resizeToFitContent() {
        guard let stack = contentStack else { return }
        view.layoutSubtreeIfNeeded()
        let size = NSSize(width: 360, height: ceil(stack.fittingSize.height) + 32)
        guard let window = view.window else { view.setFrameSize(size); return }
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        if frame != window.frame { window.setFrame(frame, display: true) }
    }

    private func update() {
        let granted = model.status == .granted
        status.stringValue = permissionText(granted ? "permissionGranted" : model.needsRepair ? "permissionStillDenied" : "permissionRequired")
        status.textColor = granted ? accent : .secondaryLabelColor
        hint.stringValue = permissionText(granted ? "permissionReady" : "permissionDragHint")
        repair.isHidden = granted; error.isHidden = !model.settingsUnavailable
        repair.stringValue = permissionText(model.needsRepair ? "permissionRepairSteps" : "permissionDragRepair")
        openButton.title = permissionText(model.guidingInSettings ? "permissionReopenSettings" : "permissionOpenTitle")
        openButton.isEnabled = !granted
        appCard.allowsDragging = !granted
        closeButton.title = permissionText(granted ? "permissionDone" : "permissionLater")
        resizeToFitContent()
    }
    @objc private func openSettings() { onOpenSettings() }
    @objc private func revealApplication() { model.reveal() }
    @objc private func checkAgain() { model.checkAccess() }
    @objc private func closeSetup() { onClose() }
}
