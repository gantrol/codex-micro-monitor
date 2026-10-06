import UIKit
import Combine

// Windows MicroSettingsResources palette; the keyboard keeps its own materials.
@MainActor enum SettingsStyle {
    static let ink = UIColor(argb:0xFF1A1C1D)
    static let muted = UIColor(argb:0xFF5F6866)
    static let line = UIColor(argb:0xFFE0E3E3)
    static let accent = UIColor(argb:0xFF53675A)
    static let selected = UIColor(argb:0xFFE6EBE6)
    static let danger = UIColor(argb:0xFFBE4238)
    static func label(_ text:String, size:CGFloat=14, weight:UIFont.Weight = .regular) -> UILabel {
        let label=UILabel(); label.text=text; label.font = .systemFont(ofSize:size,weight:weight)
        label.textColor=ink; label.numberOfLines=0; return label
    }
    static func button(_ title:String, symbol:String?=nil, primary:Bool=false, action:(()->Void)?=nil) -> UIButton {
        var config=UIButton.Configuration.plain()
        config.title=title; config.baseForegroundColor=primary ? .white : ink
        config.background.backgroundColor=primary ? accent : .clear
        config.background.cornerRadius=4
        config.contentInsets=NSDirectionalEdgeInsets(top:8,leading:12,bottom:8,trailing:12)
        config.titleTextAttributesTransformer=UIConfigurationTextAttributesTransformer { incoming in
            var result=incoming; result.font=UIFont.systemFont(ofSize:14); return result
        }
        if let symbol { config.image=UIImage(systemName:symbol); config.imagePadding=8 }
        let button=UIButton(configuration:config); button.preferredBehavioralStyle = .pad
        button.heightAnchor.constraint(greaterThanOrEqualToConstant:36).isActive=true
        button.setContentHuggingPriority(.required,for:.horizontal)
        button.setContentCompressionResistancePriority(.required,for:.horizontal)
        if let action { button.addAction(UIAction { _ in action() },for:.touchUpInside) }
        return button
    }
    static func menuButton(_ name:String, width:CGFloat=224) -> UIButton {
        let button=button("")
        button.accessibilityLabel=name; button.showsMenuAsPrimaryAction=true
        button.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        button.contentHorizontalAlignment = .leading
        button.configuration?.titleAlignment = .leading
        button.configuration?.contentInsets.trailing=32
        button.configuration?.titleLineBreakMode = .byTruncatingTail
        let arrow=UIImageView(image:UIImage(systemName:"chevron.down",withConfiguration:UIImage.SymbolConfiguration(pointSize:10,weight:.medium)))
        arrow.contentMode = .scaleAspectFit; arrow.tintColor=ink; arrow.isUserInteractionEnabled=false; arrow.translatesAutoresizingMaskIntoConstraints=false
        button.addSubview(arrow)
        NSLayoutConstraint.activate([arrow.trailingAnchor.constraint(equalTo:button.trailingAnchor,constant:-12),arrow.centerYAnchor.constraint(equalTo:button.centerYAnchor),arrow.widthAnchor.constraint(equalToConstant:12),arrow.heightAnchor.constraint(equalToConstant:12)])
        button.configuration?.background.strokeColor=line; button.configuration?.background.strokeWidth=1
        button.widthAnchor.constraint(equalToConstant:width).isActive=true
        return button
    }
    static func lineView() -> UIView {
        let view=UIView(); view.backgroundColor=line
        view.heightAnchor.constraint(equalToConstant:1).isActive=true; return view
    }
    static func stack(_ axis:NSLayoutConstraint.Axis, spacing:CGFloat=0) -> UIStackView {
        let stack=UIStackView(); stack.axis=axis; stack.spacing=spacing; return stack
    }
    static func row(_ title:String, control:UIView) -> UIView {
        let label=label(title); label.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        let row=stack(.horizontal,spacing:20); row.alignment = .center
        row.addArrangedSubview(label); row.addArrangedSubview(control)
        row.heightAnchor.constraint(greaterThanOrEqualToConstant:56).isActive=true
        control.setContentHuggingPriority(.required,for:.horizontal)
        return row
    }
}

// A compact Windows-style switch; UIButton supplies keyboard and pointer
// activation while the same painter also works in windowless design exports.
@MainActor final class SettingsToggle: UIButton {
    var isOn=false {
        didSet { accessibilityValue=tr(isOn ? "enabled" : "disabled"); setNeedsDisplay() }
    }
    override init(frame:CGRect) {
        super.init(frame:frame)
        preferredBehavioralStyle = .pad; isOpaque=false; backgroundColor = .clear
        isAccessibilityElement=true; accessibilityTraits = .button
        accessibilityValue=tr("disabled"); contentMode = .redraw
        widthAnchor.constraint(equalToConstant:44).isActive=true
        heightAnchor.constraint(equalToConstant:24).isActive=true
        addAction(UIAction { [weak self] _ in
            guard let self else { return }; self.isOn.toggle(); self.sendActions(for:.valueChanged)
        },for:.touchUpInside)
    }
    required init?(coder:NSCoder) { fatalError() }
    override func draw(_ rect:CGRect) {
        guard let context=UIGraphicsGetCurrentContext() else { return }
        let track=bounds.insetBy(dx:0.5,dy:0.5)
        context.setFillColor((isOn ? SettingsStyle.accent : UIColor(argb:0xFFE4E7E6)).cgColor)
        context.addPath(UIBezierPath(roundedRect:track,cornerRadius:12).cgPath); context.fillPath()
        context.setStrokeColor((isOn ? SettingsStyle.accent : SettingsStyle.muted).cgColor)
        context.setLineWidth(1); context.addPath(UIBezierPath(roundedRect:track,cornerRadius:12).cgPath); context.strokePath()
        context.setFillColor(UIColor.white.cgColor)
        context.fillEllipse(in:Paint.rect(isOn ? bounds.width-21 : 3,3,18,18))
    }
}

@MainActor final class KeypadPreview: UIView {
    private let canvas=UIView()
    private let shell=ShellView()
    private var commands:[String:SurfaceKey]=[:]
    private var tasks:[SurfaceKey]=[]
    private let dial=HardwareControl(.dial), stick=HardwareControl(.joystick), quota=HardwareControl(.quota)
    var onKey:((String)->Void)?
    override init(frame:CGRect) {
        super.init(frame:frame)
        canvas.bounds=Paint.rect(0,0,590,610); addSubview(canvas)
        shell.frame=canvas.bounds; canvas.addSubview(shell)
        for cell in [1,2,4,5,6,7] {
            let key=SurfaceKey(task:true); key.isUserInteractionEnabled=false; key.isAccessibilityElement=false
            key.frame=Paint.rect(88+CGFloat(cell%4)*106,98+CGFloat(cell/4)*106,96,96)
            tasks.append(key); canvas.addSubview(key)
        }
        for key in KeySlots.aliases.keys {
            let button=SurfaceKey(task:false)
            button.layer.borderColor=SettingsStyle.accent.withAlphaComponent(0.6).cgColor
            button.layer.borderWidth=3; button.layer.cornerRadius=14
            button.accessibilityLabel=tr("editKey")+" "+KeySlots.id(key)
            button.prepare={ [weak self] in { [weak self] in self?.onKey?(key) } }
            commands[key]=button; canvas.addSubview(button)
        }
        for (control,frame) in [(dial,Paint.rect(88,98,96,96)),(stick,Paint.rect(406,98,96,96)),(quota,Paint.rect(88,416,96,96))] {
            control.frame=frame; control.isUserInteractionEnabled=false; control.isAccessibilityElement=false
            canvas.addSubview(control)
        }
    }
    required init?(coder:NSCoder) { fatalError() }
    override func layoutSubviews() {
        super.layoutSubviews()
        let scale=min(bounds.width/590,bounds.height/610)
        canvas.transform=CGAffineTransform(scaleX:scale,y:scale); canvas.center=CGPoint(x:bounds.midX,y:bounds.midY)
    }
    func refresh(_ model:MicroViewModel) {
        commands.values.forEach { $0.isHidden=true }
        for (key,frame) in KeySlots.frames(separate:model.separateMicrophoneKeys) {
            guard let button=commands[key] else { continue }
            button.isHidden=false; button.frame=frame; button.glyph.name=model.keycap(for:key)
            button.isEnabled=model.layoutAvailable || model.preferences.layout.keys[KeySlots.id(key)] != nil
            button.setNeedsLayout()
        }
        for (index,key) in tasks.enumerated() {
            let row=model.taskRow(at:index)
            key.light=LightState(signal:row.map { model.displaySignal(for:$0) } ?? .unknown,selected:row != nil && row?.id == model.displayedThreadID)
            key.updateArt()
        }
        quota.usage=model.usageWindows; quota.connected=model.connected; quota.desktopConnected=model.desktopConnected
    }
}

@MainActor final class CurrentContextView: UIView {
    private let heading=SettingsStyle.label("",weight:.semibold)
    private let title=SettingsStyle.label(""), model=SettingsStyle.label(""), effort=SettingsStyle.label("")
    private let identity=UIButton(type:.custom)
    private let identityLabel=SettingsStyle.label("—",size:12)
    private let identityIcon=UIImageView(image:UIImage(systemName:"doc.on.doc",withConfiguration:UIImage.SymbolConfiguration(pointSize:16)))
    private var threadID:String?
    override init(frame:CGRect) {
        super.init(frame:frame)
        let stack=SettingsStyle.stack(.vertical); stack.translatesAutoresizingMaskIntoConstraints=false; addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:leadingAnchor),stack.trailingAnchor.constraint(equalTo:trailingAnchor),stack.topAnchor.constraint(equalTo:topAnchor),stack.bottomAnchor.constraint(equalTo:bottomAnchor)])
        heading.textColor=SettingsStyle.muted; stack.addArrangedSubview(heading); stack.setCustomSpacing(8,after:heading)
        identity.preferredBehavioralStyle = .pad
        identityLabel.font = .monospacedSystemFont(ofSize:12,weight:.regular)
        identityLabel.numberOfLines=1; identityLabel.textAlignment = .right
        identityIcon.contentMode = .scaleAspectFit; identityIcon.tintColor=SettingsStyle.ink
        for child in [identityLabel,identityIcon] { child.translatesAutoresizingMaskIntoConstraints=false; child.isUserInteractionEnabled=false; identity.addSubview(child) }
        NSLayoutConstraint.activate([
            identityLabel.leadingAnchor.constraint(equalTo:identity.leadingAnchor),identityLabel.trailingAnchor.constraint(equalTo:identityIcon.leadingAnchor,constant:-8),identityLabel.centerYAnchor.constraint(equalTo:identity.centerYAnchor),
            identityIcon.trailingAnchor.constraint(equalTo:identity.trailingAnchor),identityIcon.centerYAnchor.constraint(equalTo:identity.centerYAnchor),identityIcon.widthAnchor.constraint(equalToConstant:18),identityIcon.heightAnchor.constraint(equalToConstant:20),
            identity.heightAnchor.constraint(greaterThanOrEqualToConstant:36)
        ])
        identity.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        // Leave room for the complete UUID and keep its copy icon on the same
        // trailing edge as the other values, independent of Catalyst button padding.
        identity.widthAnchor.constraint(equalToConstant:360).isActive=true
        identity.addAction(UIAction { [weak self] _ in if let id=self?.threadID { UIPasteboard.general.string=id } },for:.touchUpInside)
        identity.accessibilityLabel=tr("copyThreadID")
        for label in [title,model,effort] { label.textAlignment = .right; label.setContentCompressionResistancePriority(.defaultLow,for:.horizontal) }
        for (name,value):(String,UIView) in [("chatTitle",title),("threadID",identity),("model",model),("reasoning",effort)] {
            stack.addArrangedSubview(SettingsStyle.row(tr(name),control:value)); stack.addArrangedSubview(SettingsStyle.lineView())
        }
    }
    required init?(coder:NSCoder) { fatalError() }
    func update(source:String,title:String,id:String?,model:String,effort:String) {
        heading.text=source; self.title.text=title; threadID=id
        identityLabel.text=id ?? "—"; identity.isEnabled=id != nil; identity.accessibilityValue=id
        identity.alpha=id == nil ? 0.35 : 1
        self.model.text=model.isEmpty ? "—" : model; self.effort.text=effort.isEmpty ? "—" : effort
    }
}

@MainActor final class SettingsViewController: UIViewController, UIGestureRecognizerDelegate {
    let settings:Settings
    let model:MicroViewModel
    var onClose:(()->Void)?
    private let chrome=UIView(), header=UIView(), scroll=UIScrollView()
    private let content=SettingsStyle.stack(.vertical)
    private let preview=KeypadPreview()
    private let size=UISlider(), sizeValue=SettingsStyle.label("",weight:.medium)
    private let source=SettingsStyle.menuButton(tr("agentKeys"))
    private let mode=SettingsStyle.menuButton(tr("dial"))
    private let reverse=SettingsToggle(), split=SettingsToggle(), singleTap=SettingsToggle(), floating=SettingsToggle()
    private var modelButtons:[UIButton]=[], effortButtons:[UIButton]=[]
    private let connection=SettingsStyle.label("")
    private let desktopConnection=SettingsStyle.label("")
    private let currentContext=CurrentContextView()
    private let taskMappingPanel=SettingsStyle.stack(.vertical)
    private var taskButtons:[UIButton]=[]
    private var captureTasks:UIButton?
    private var lastTaskSignature=""
    private var subscriptions:Set<AnyCancellable>=[]
    private var sections:[String:UIView]=[:]
    private var editor:KeyEditorViewController?
    private var lastSignature=""

    init(settings:Settings,model:MicroViewModel) {
        self.settings=settings; self.model=model
        super.init(nibName:nil,bundle:nil)
    }
    required init?(coder:NSCoder) { fatalError() }
    override func loadView() {
        view=UIView(); view.backgroundColor = .clear
        chrome.backgroundColor = .white; chrome.layer.cornerRadius=8; chrome.layer.borderWidth=1
        chrome.layer.borderColor=SettingsStyle.line.cgColor; chrome.clipsToBounds=true
        chrome.translatesAutoresizingMaskIntoConstraints=false; view.addSubview(chrome)
        header.translatesAutoresizingMaskIntoConstraints=false; chrome.addSubview(header)
        scroll.translatesAutoresizingMaskIntoConstraints=false; chrome.addSubview(scroll)
        content.translatesAutoresizingMaskIntoConstraints=false; scroll.addSubview(content)
        let title=SettingsStyle.label(tr("settings"),size:18,weight:.semibold)
        let close=SettingsStyle.button("",symbol:"xmark") { [weak self] in self?.onClose?() }
        close.accessibilityLabel=tr("closeSettings")
        let titleRow=SettingsStyle.stack(.horizontal); titleRow.alignment = .center
        titleRow.addArrangedSubview(title); titleRow.addArrangedSubview(close)
        titleRow.translatesAutoresizingMaskIntoConstraints=false; header.addSubview(titleRow)
        let line=SettingsStyle.lineView(); line.translatesAutoresizingMaskIntoConstraints=false; header.addSubview(line)
        NSLayoutConstraint.activate([
            chrome.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:12), chrome.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-12),
            chrome.topAnchor.constraint(equalTo:view.topAnchor,constant:12), chrome.bottomAnchor.constraint(equalTo:view.bottomAnchor,constant:-12),
            header.leadingAnchor.constraint(equalTo:chrome.leadingAnchor), header.trailingAnchor.constraint(equalTo:chrome.trailingAnchor),
            header.topAnchor.constraint(equalTo:chrome.topAnchor), header.heightAnchor.constraint(equalToConstant:64),
            titleRow.leadingAnchor.constraint(equalTo:header.leadingAnchor,constant:24), titleRow.trailingAnchor.constraint(equalTo:header.trailingAnchor,constant:-12),
            titleRow.centerYAnchor.constraint(equalTo:header.centerYAnchor),
            line.leadingAnchor.constraint(equalTo:header.leadingAnchor), line.trailingAnchor.constraint(equalTo:header.trailingAnchor), line.bottomAnchor.constraint(equalTo:header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo:chrome.leadingAnchor), scroll.trailingAnchor.constraint(equalTo:chrome.trailingAnchor),
            scroll.topAnchor.constraint(equalTo:header.bottomAnchor), scroll.bottomAnchor.constraint(equalTo:chrome.bottomAnchor),
            content.leadingAnchor.constraint(equalTo:scroll.contentLayoutGuide.leadingAnchor,constant:24), content.trailingAnchor.constraint(equalTo:scroll.contentLayoutGuide.trailingAnchor,constant:-24),
            content.topAnchor.constraint(equalTo:scroll.contentLayoutGuide.topAnchor,constant:12), content.bottomAnchor.constraint(equalTo:scroll.contentLayoutGuide.bottomAnchor,constant:-24),
            content.widthAnchor.constraint(equalTo:scroll.frameLayoutGuide.widthAnchor,constant:-48)
        ])
        let drag=UIPanGestureRecognizer(target:self,action:#selector(dragWindow(_:))); drag.delegate=self; header.addGestureRecognizer(drag)
        buildLayout(); buildInteraction(); buildTaskMappings(); buildCurrentContext(); buildModels(); buildConnection()
        settings.objectWillChange.receive(on:DispatchQueue.main).sink { [weak self] _ in self?.refresh() }.store(in:&subscriptions)
        model.objectWillChange.receive(on:DispatchQueue.main).throttle(for:.milliseconds(300),scheduler:DispatchQueue.main,latest:true)
            .sink { [weak self] _ in self?.refresh() }.store(in:&subscriptions)
        refresh()
    }
    override func viewDidAppear(_ animated:Bool) { super.viewDidAppear(animated); becomeFirstResponder() }
    override var canBecomeFirstResponder:Bool { true }
    override var keyCommands:[UIKeyCommand]? {
        [UIKeyCommand(input:UIKeyCommand.inputEscape,modifierFlags:[],action:#selector(escape)),
         UIKeyCommand(input:"w",modifierFlags:.command,action:#selector(escape)),
         UIKeyCommand(input:",",modifierFlags:.command,action:#selector(keepSettings))]
    }
    @objc private func escape() { if editor != nil { closeEditor() } else { onClose?() } }
    @objc private func keepSettings() {}
    @objc private func dragWindow(_ gesture:UIPanGestureRecognizer) { if gesture.state == .began { Desktop.services?.dragWindow() } }
    func gestureRecognizer(_ recognizer:UIGestureRecognizer,shouldReceive touch:UITouch) -> Bool {
        var target=touch.view
        while let current=target, current !== header { if current is UIControl { return false }; target=current.superview }
        return true
    }
    private func heading(_ title:String, id:String, trailing:UIView?=nil) {
        let label=SettingsStyle.label(title,weight:.semibold); label.textColor=SettingsStyle.muted
        let row=SettingsStyle.stack(.horizontal); row.alignment = .center
        row.addArrangedSubview(label); if let trailing { row.addArrangedSubview(trailing) }
        row.heightAnchor.constraint(greaterThanOrEqualToConstant:40).isActive=true
        if !content.arrangedSubviews.isEmpty { content.setCustomSpacing(16,after:content.arrangedSubviews.last!) }
        content.addArrangedSubview(row); sections[id]=row
    }
    private func buildLayout() {
        heading(tr("layout"),id:"layout",trailing:SettingsStyle.button(tr("resetLayout")) { [weak self] in self?.settings.resetLayout() })
        let row=SettingsStyle.stack(.horizontal,spacing:28); row.alignment = .center
        preview.widthAnchor.constraint(equalToConstant:160).isActive=true; preview.heightAnchor.constraint(equalToConstant:166).isActive=true
        preview.onKey={ [weak self] key in self?.editKey(key) }
        row.addArrangedSubview(preview)
        let controls=SettingsStyle.stack(.vertical,spacing:8)
        let labels=SettingsStyle.stack(.horizontal); labels.addArrangedSubview(SettingsStyle.label(tr("size"))); labels.addArrangedSubview(sizeValue)
        sizeValue.textAlignment = .right; sizeValue.font = .monospacedDigitSystemFont(ofSize:14,weight:.regular)
        controls.addArrangedSubview(labels)
        size.preferredBehavioralStyle = .pad
        size.minimumValue=60; size.maximumValue=105; size.minimumTrackTintColor=SettingsStyle.accent; size.accessibilityLabel=tr("size")
        size.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            let snapped=(self.size.value/5).rounded()*5; self.size.value=snapped
            self.settings.setScale(Double(snapped)/100)
        },for:.valueChanged)
        let sliderRow=SettingsStyle.stack(.horizontal,spacing:8); sliderRow.alignment = .center; sliderRow.addArrangedSubview(size)
        let reset=SettingsStyle.button("",symbol:"arrow.counterclockwise") { [weak self] in self?.settings.setScale(Settings.defaultScale) }
        reset.accessibilityLabel=tr("resetSize"); sliderRow.addArrangedSubview(reset); controls.addArrangedSubview(sliderRow)
        row.addArrangedSubview(controls); content.addArrangedSubview(row)
        content.setCustomSpacing(20,after:row); content.addArrangedSubview(SettingsStyle.lineView())
    }
    private func addSwitch(_ title:String, control:SettingsToggle, change:@escaping (Bool)->Void) {
        control.accessibilityLabel=title
        control.addAction(UIAction { [weak control] _ in if let control { change(control.isOn) } },for:.valueChanged)
        content.addArrangedSubview(SettingsStyle.row(title,control:control)); content.addArrangedSubview(SettingsStyle.lineView())
    }
    private func buildInteraction() {
        heading(tr("interaction"),id:"interaction")
        content.addArrangedSubview(SettingsStyle.row(tr("agentKeys"),control:source)); content.addArrangedSubview(SettingsStyle.lineView())
        content.addArrangedSubview(SettingsStyle.row(tr("dial"),control:mode)); content.addArrangedSubview(SettingsStyle.lineView())
        addSwitch(tr("invertDial"),control:reverse) { [weak self] value in
            guard let self else { return }; var profile=self.settings.dial; profile.invertDirection=value; self.settings.setDial(profile)
        }
        addSwitch(tr("splitMicrophone"),control:split) { [weak self] value in
            guard let self else { return }; var profile=self.settings.layout; profile.separateMicrophoneKeys=value; self.settings.setLayout(profile)
        }
        addSwitch(tr("singleTap"),control:singleTap) { [weak self] value in
            guard let self else { return }; var profile=self.settings.layout; profile.singleTapAgentKeys=value; self.settings.setLayout(profile)
        }
        addSwitch(tr("floating"),control:floating) { [weak self] value in
            if let self, self.settings.floating != value { self.settings.toggleFloating() }
        }
    }
    private func buildModels() {
        heading(tr("quickModels"),id:"models")
        for index in 0..<2 {
            let title=tr(index==0 ? "quickModelA" : "quickModelB")
            let model=SettingsStyle.menuButton(title,width:170), effort=SettingsStyle.menuButton(title+" · "+tr("reasoning"),width:128)
            modelButtons.append(model); effortButtons.append(effort)
            let group=SettingsStyle.stack(.horizontal,spacing:8); group.addArrangedSubview(model); group.addArrangedSubview(effort)
            content.addArrangedSubview(SettingsStyle.row(title,control:group)); content.addArrangedSubview(SettingsStyle.lineView())
        }
    }
    private func buildTaskMappings() {
        let capture=SettingsStyle.button(tr("useRecentTasks")) { [weak self] in self?.model.captureRecentTaskLayout() }
        captureTasks=capture
        taskMappingPanel.addArrangedSubview(SettingsStyle.row(tr("taskMappings"),control:capture))
        for index in 0..<TaskSlots.count {
            let title=String(format:tr("taskKeyNumber"),index+1)
            let button=SettingsStyle.menuButton(title,width:330)
            taskButtons.append(button)
            taskMappingPanel.addArrangedSubview(SettingsStyle.row(title,control:button))
            taskMappingPanel.addArrangedSubview(SettingsStyle.lineView())
        }
        content.addArrangedSubview(taskMappingPanel);sections["taskMappings"]=taskMappingPanel
    }
    private func refreshTaskMappings() {
        taskMappingPanel.isHidden=settings.layout.agentSource != "custom"
        let scope=model.rosterScope,map=settings.layout.taskMap(scope:scope),commands=settings.layout.taskCommandMap(scope:scope),choices=model.taskChoices
        let enabled=model.connected && scope != nil
        captureTasks?.isEnabled=enabled && !model.threads.isEmpty
        let signature="\(scope ?? "")|\(map)|\(commands)|\(enabled)|"+choices.map {"\($0.id):\($0.label)"}.joined(separator:"|")
        guard signature != lastTaskSignature else {return};lastTaskSignature=signature
        for (index,button) in taskButtons.enumerated() {
            let selected=map[TaskSlots.ids[index]]
            let command=commands[TaskSlots.ids[index]]
            let title=command.map {KeySlots.actionLabel(["type":"command","commandId":$0])} ?? selected.map {id in choices.first {$0.id == id}?.label ?? tr("unavailableTask")+" · "+id.prefix(8)} ?? tr("emptySlot")
            button.configuration?.title=title;button.accessibilityValue=(selected ?? command).map {title+" · "+$0} ?? title
            button.isEnabled=enabled
            var actions:[UIMenuElement]=[UIAction(title:tr("emptySlot"),state:selected == nil && command == nil ? .on:.off) { [weak self] _ in
                guard let self,self.model.rosterScope == scope else {return};self.model.assignTask(index,thread:nil)
            }]
            let commandChoices=KeySlots.recentCommands+KeySlots.supportedCommands.subtracting(KeySlots.recentCommands).sorted()
            actions.append(UIMenu(title:tr("customAction"),children:commandChoices.map {id in
                UIAction(title:KeySlots.actionLabel(["type":"command","commandId":id]),state:command == id ? .on:.off) { [weak self] _ in
                    guard let self,self.model.rosterScope == scope else {return};self.model.assignTaskCommand(index,command:id)
                }
            }))
            actions += choices.map {row in
                UIAction(title:row.label,subtitle:row.id,state:selected == row.id ? .on:.off) { [weak self] _ in
                    guard let self,self.model.rosterScope == scope else {return};self.model.assignTask(index,thread:row.id)
                }
            }
            button.menu=UIMenu(children:actions)
        }
    }
    private func buildCurrentContext() {
        if let last=content.arrangedSubviews.last { content.setCustomSpacing(24,after:last) }
        content.addArrangedSubview(currentContext); sections["currentContext"]=currentContext
    }
    private func buildConnection() {
        heading(tr("connection"),id:"connection")
        let refresh=SettingsStyle.button(tr("refresh"),symbol:"arrow.clockwise") { [weak self] in
            guard let self else { return }; Task { await self.model.refresh(); self.model.refreshControls() }
        }
        content.addArrangedSubview(SettingsStyle.row("Codex",control:connection))
        content.addArrangedSubview(SettingsStyle.row(tr("chatState"),control:desktopConnection))
        content.addArrangedSubview(refresh)
    }
    private func selectMenu(_ button:UIButton, title:String, choices:[(String,String)], selected:String, choose:@escaping (String)->Void) {
        button.configuration?.title=title
        button.menu=UIMenu(children:choices.map { id,label in UIAction(title:label,state:id==selected ? .on : .off) { _ in choose(id) } })
    }
    private func refresh() {
        guard isViewLoaded else { return }
        size.value=Float(settings.scale*100); sizeValue.text="\(Int((settings.scale*100).rounded()))%"
        reverse.isOn=settings.dial.invertDirection; split.isOn=model.separateMicrophoneKeys
        singleTap.isOn=settings.layout.singleTapAgentKeys; floating.isOn=settings.floating
        let contextHeading=model.contextSource == .selected ? "selectedConversation" : "currentConversation"
        let title=model.isDraft ? tr("newDraft") : model.isNativeComposer || model.displayedThreadID != nil ? model.selectedTitle : "—"
        let modelText=model.currentModelTitle == model.currentModel ? model.currentModel : model.currentModelTitle+"\n"+model.currentModel
        currentContext.update(source:tr(contextHeading),title:title,id:model.displayedThreadID,model:modelText,effort:model.currentEffort)
        connection.text=tr(model.connected ? "connected" : "disconnected")
        connection.textColor=model.connected ? SettingsStyle.accent : SettingsStyle.muted
        let needsRefresh=model.needsControlRefresh || model.controlError != nil
        desktopConnection.text=tr(model.needsControlRefresh ? "refreshRequired" : model.controlError != nil ? "actionFailed" : model.desktopConnected ? "connected" : "disconnected")
        desktopConnection.textColor=needsRefresh ? SettingsStyle.danger : model.desktopConnected ? SettingsStyle.accent : SettingsStyle.muted
        // Replacing a menu on every activity tick interferes with open menus.
        let signature="\(settings.layout)\(settings.dial)\(model.separateMicrophoneKeys)\(model.layoutAvailable)" + model.models.map { "\($0.id)\($0.efforts)" }.joined() + model.slots.description
        if signature != lastSignature {
            lastSignature=signature
            selectMenu(source,title:tr(settings.layout.agentSource),choices:[("recent",tr("recent")),("pinned",tr("pinned")),("priority",tr("priority")),("custom",tr("custom"))],selected:settings.layout.agentSource) { [weak self] id in
                guard let self else { return }; var profile=self.settings.layout; profile.agentSource=id; self.settings.setLayout(profile);self.model.preferencesChanged()
            }
            let modes=["followCodex","composer-navigation","reasoning","conversation-scroll"]
            let selected=settings.dial.encoderMode ?? "followCodex"
            selectMenu(mode,title:tr(selected),choices:modes.map { ($0,tr($0)) },selected:selected) { [weak self] id in
                guard let self else { return }; var profile=self.settings.dial; profile.encoderMode=id=="followCodex" ? nil : id; self.settings.setDial(profile)
            }
            for index in 0..<2 { refreshPreset(index) }
        }
        refreshTaskMappings()
        preview.refresh(model)
    }
    private func refreshPreset(_ index:Int) {
        let preset=index==0 ? settings.dial.a : settings.dial.b
        let definition=model.models.first { $0.id==preset.model }
        let button=modelButtons[index]
        selectMenu(button,title:definition?.title ?? preset.model,choices:model.models.map { ($0.id,$0.title) },selected:preset.model) { [weak self] id in
            guard let self, self.model.models.contains(where: { $0.id==id }) else { return }
            self.savePreset(index,QuickModelPreset(model:id,effort:nil))
        }
        button.isEnabled = !model.models.isEmpty
        let efforts=[("",tr("modelDefault"))]+(definition?.efforts ?? []).map { ($0,$0) }
        selectMenu(effortButtons[index],title:preset.effort ?? tr("modelDefault"),choices:efforts,selected:preset.effort ?? "") { [weak self] effort in
            guard let self, let current=self.model.models.first(where: { $0.id==preset.model }),
                  effort.isEmpty || current.efforts.contains(effort) else { return }
            self.savePreset(index,QuickModelPreset(model:preset.model,effort:effort.isEmpty ? nil : effort))
        }
        effortButtons[index].isEnabled=definition != nil
    }
    private func savePreset(_ index:Int,_ preset:QuickModelPreset) {
        var profile=settings.dial
        if index==0 { profile.a=preset } else { profile.b=preset }
        settings.setDial(profile)
    }
    func open(key:String?,section:String?) {
        loadViewIfNeeded(); view.layoutIfNeeded()
        if let key { editKey(key) }
        else if let section, let target=sections[section] {
            let top=target.convert(target.bounds,to:content).minY+12
            let limit=max(0,scroll.contentSize.height-scroll.bounds.height)
            scroll.setContentOffset(CGPoint(x:0,y:min(limit,max(0,top))),animated:false)
            scroll.layoutIfNeeded()
        }
        becomeFirstResponder()
    }
    private func editKey(_ key:String) {
        guard editor == nil, model.layoutAvailable || settings.layout.keys[KeySlots.id(key)] != nil else { return }
        let editor=KeyEditorViewController(key:key,model:model,settings:settings)
        editor.onClose={ [weak self] in self?.closeEditor() }
        self.editor=editor
        addChild(editor); editor.view.frame=chrome.bounds; editor.view.autoresizingMask=[.flexibleWidth,.flexibleHeight]
        chrome.addSubview(editor.view); editor.didMove(toParent:self)
        header.isHidden=true; scroll.isHidden=true; editor.becomeFirstResponder()
    }
    private func closeEditor() {
        guard let editor else { return }
        editor.willMove(toParent:nil); editor.view.removeFromSuperview(); editor.removeFromParent(); self.editor=nil
        header.isHidden=false; scroll.isHidden=false; refresh(); becomeFirstResponder()
    }
}

@MainActor final class KeyEditorViewController: UIViewController, UISearchBarDelegate, UIGestureRecognizerDelegate {
    let key:String
    let model:MicroViewModel
    let settings:Settings
    var onClose:(()->Void)?
    private var draft:KeyOverride
    private let header=UIView(), grid=SettingsStyle.stack(.vertical,spacing:10), search=UISearchBar()
    private let actionButton=SettingsStyle.menuButton(tr("action"),width:310)
    private let glyph=GlyphView(), iconName=SettingsStyle.label("",weight:.medium)
    private var glyphWidth:NSLayoutConstraint?, glyphHeight:NSLayoutConstraint?
    private var iconButtons:[String:UIButton]=[:]
    private let icons:[String]
    private static let commands:[(String,String)] = [
        ("composer.submit","submit"),("composer.toggleFastMode","fast"),("composer.togglePlanMode","plan"),
        ("approval.approve","approve"),("approval.decline","decline"),("forkThread","fork"),("newTask","newDraft"),
        ("toggleReviewTab","review"),("turn.cancel","stop"),("dictation.pushToTalk","voice"),("composer.sketch","sketch"),
        ("composer.increaseReasoningEffort","moreReasoning"),("composer.decreaseReasoningEffort","lessReasoning"),
        ("toggleSidebar","sidebar"),("navigateBack","back"),("navigateForward","forward"),
        ("developers.openai.com","developers"),("openFolder","openFolder")
    ]
    init(key:String,model:MicroViewModel,settings:Settings) {
        self.key=key; self.model=model; self.settings=settings
        draft=KeyOverride(icon:model.keycap(for:key),action:model.binding(for:key))
        icons=KeySlots.iconIDs
        super.init(nibName:nil,bundle:nil)
    }
    required init?(coder:NSCoder) { fatalError() }
    override func loadView() {
        view=UIView(); view.backgroundColor = .white
        let stack=SettingsStyle.stack(.vertical,spacing:12); stack.translatesAutoresizingMaskIntoConstraints=false; view.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:24),stack.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-24),stack.topAnchor.constraint(equalTo:view.topAnchor,constant:20),stack.bottomAnchor.constraint(equalTo:view.bottomAnchor,constant:-20)])
        let title=SettingsStyle.label(tr("editKey")+" · "+KeySlots.id(key),size:18,weight:.semibold)
        let close=SettingsStyle.button("",symbol:"xmark") { [weak self] in self?.onClose?() }; close.accessibilityLabel=tr("cancel")
        let titleRow=SettingsStyle.stack(.horizontal); titleRow.alignment = .center; titleRow.addArrangedSubview(title); titleRow.addArrangedSubview(close)
        titleRow.translatesAutoresizingMaskIntoConstraints=false; header.addSubview(titleRow); stack.addArrangedSubview(header)
        NSLayoutConstraint.activate([titleRow.leadingAnchor.constraint(equalTo:header.leadingAnchor),titleRow.trailingAnchor.constraint(equalTo:header.trailingAnchor),titleRow.topAnchor.constraint(equalTo:header.topAnchor),titleRow.bottomAnchor.constraint(equalTo:header.bottomAnchor)])
        let drag=UIPanGestureRecognizer(target:self,action:#selector(dragWindow(_:))); drag.delegate=self; header.addGestureRecognizer(drag)
        let selected=SettingsStyle.stack(.horizontal,spacing:12); selected.alignment = .center
        glyphWidth=glyph.widthAnchor.constraint(equalToConstant:28); glyphWidth?.isActive=true
        glyphHeight=glyph.heightAnchor.constraint(equalToConstant:28); glyphHeight?.isActive=true
        selected.addArrangedSubview(glyph); selected.addArrangedSubview(iconName)
        selected.addArrangedSubview(SettingsStyle.button(tr("resetKey")) { [weak self] in
            guard let self, let icon=KeySlots.defaults[KeySlots.id(self.key)] else { return }
            self.draft=KeyOverride(icon:icon,action:KeySlots.defaultAction(icon)); self.refreshDraft()
        }); stack.addArrangedSubview(selected)
        search.placeholder=tr("searchIcons"); search.searchBarStyle = .minimal; search.delegate=self
        search.searchTextField.accessibilityLabel=tr("searchIcons"); stack.addArrangedSubview(search)
        let scroll=UIScrollView(); stack.addArrangedSubview(scroll)
        grid.translatesAutoresizingMaskIntoConstraints=false; scroll.addSubview(grid)
        NSLayoutConstraint.activate([grid.leadingAnchor.constraint(equalTo:scroll.contentLayoutGuide.leadingAnchor),grid.trailingAnchor.constraint(equalTo:scroll.contentLayoutGuide.trailingAnchor),grid.topAnchor.constraint(equalTo:scroll.contentLayoutGuide.topAnchor),grid.bottomAnchor.constraint(equalTo:scroll.contentLayoutGuide.bottomAnchor),grid.widthAnchor.constraint(equalTo:scroll.frameLayoutGuide.widthAnchor),scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:100)])
        stack.addArrangedSubview(SettingsStyle.lineView()); stack.addArrangedSubview(SettingsStyle.row(tr("action"),control:actionButton))
        let footer=SettingsStyle.stack(.horizontal,spacing:10); footer.addArrangedSubview(UIView())
        footer.addArrangedSubview(SettingsStyle.button(tr("cancel")) { [weak self] in self?.onClose?() })
        footer.addArrangedSubview(SettingsStyle.button(tr("save"),primary:true) { [weak self] in
            guard let self else { return }; self.settings.saveKey(self.key,value:self.draft); self.onClose?()
        }); stack.addArrangedSubview(footer)
        rebuildIcons(); refreshDraft()
    }
    override var canBecomeFirstResponder:Bool { true }
    override var keyCommands:[UIKeyCommand]? { [UIKeyCommand(input:UIKeyCommand.inputEscape,modifierFlags:[],action:#selector(cancel)),UIKeyCommand(input:"w",modifierFlags:.command,action:#selector(cancel))] }
    @objc private func cancel() { onClose?() }
    @objc private func dragWindow(_ gesture:UIPanGestureRecognizer) { if gesture.state == .began { Desktop.services?.dragWindow() } }
    func gestureRecognizer(_ recognizer:UIGestureRecognizer,shouldReceive touch:UITouch) -> Bool {
        var target=touch.view
        while let current=target, current !== header { if current is UIControl { return false }; target=current.superview }
        return true
    }
    func searchBar(_ searchBar:UISearchBar,textDidChange searchText:String) { rebuildIcons() }
    private func rebuildIcons() {
        for view in grid.arrangedSubviews { grid.removeArrangedSubview(view); view.removeFromSuperview() }
        iconButtons=[:]
        let query=(search.text ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
        let filtered=icons.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) || iconTitle($0).localizedCaseInsensitiveContains(query) }
        let columns=6
        for offset in stride(from:0,to:filtered.count,by:columns) {
            let row=SettingsStyle.stack(.horizontal,spacing:10); row.distribution = .fillEqually
            for column in 0..<columns {
                guard offset+column < filtered.count else { row.addArrangedSubview(UIView()); continue }
                let name=filtered[offset+column]
                let button=UIButton(type:.custom); button.backgroundColor=UIColor(argb:0xFFF7F8F6); button.layer.cornerRadius=8; button.layer.borderWidth=1
                button.accessibilityLabel=iconTitle(name); button.heightAnchor.constraint(equalToConstant:82).isActive=true
                let image=GlyphView(); image.name=name; image.translatesAutoresizingMaskIntoConstraints=false; button.addSubview(image)
                image.installHover(on:button)
                let label=SettingsStyle.label(name,size:10); label.textAlignment = .center; label.isUserInteractionEnabled=false
                label.translatesAutoresizingMaskIntoConstraints=false; button.addSubview(label)
                let side=KeycapGlyph.side(at:1,name:name)
                NSLayoutConstraint.activate([image.widthAnchor.constraint(equalToConstant:side),image.heightAnchor.constraint(equalToConstant:side),image.centerXAnchor.constraint(equalTo:button.centerXAnchor),image.centerYAnchor.constraint(equalTo:button.topAnchor,constant:28),label.leadingAnchor.constraint(equalTo:button.leadingAnchor,constant:2),label.trailingAnchor.constraint(equalTo:button.trailingAnchor,constant:-2),label.topAnchor.constraint(equalTo:button.topAnchor,constant:50)])
                button.addAction(UIAction { [weak self] _ in self?.draft.selectIcon(name); self?.refreshDraft() },for:.touchUpInside)
                row.addArrangedSubview(button); iconButtons[name]=button
            }
            grid.addArrangedSubview(row)
        }
        updateIcons()
    }
    private func iconTitle(_ icon:String) -> String {
        if KeySlots.emptyIcons.contains(icon) {return tr("emptySlot")+" · "+icon}
        if let preset=ComposerTextPreset(rawValue:icon) {return tr("writeToComposer")+" "+preset.text}
        let labels=["MIC":"voice","MIC1":"voice","FAST":"fast","APPR":"approve","REJ":"decline","SPLIT":"fork","CODEX":"submit","SKETCH":"sketch","EMPT1":"emptySlot","MIND+":"moreReasoning","MIND-":"lessReasoning","NEW":"newDraft","DIFF":"review"]
        return labels[icon].map(tr) ?? icon
    }
    private func updateIcons() {
        for (name,button) in iconButtons {
            let selected=name==draft.icon
            button.backgroundColor=selected ? SettingsStyle.selected : UIColor(argb:0xFFF7F8F6)
            button.layer.borderColor=(selected ? SettingsStyle.accent : SettingsStyle.line).cgColor
            button.accessibilityTraits=selected ? [.button,.selected] : [.button]
        }
    }
    private func refreshDraft() {
        glyphWidth?.constant=KeycapGlyph.side(at:1,name:draft.icon); glyphHeight?.constant=glyphWidth?.constant ?? 28
        glyph.name=draft.icon; iconName.text=draft.icon; updateIcons()
        func data(_ action:[String:Any]?) -> Data? { KeyOverride(icon:"",action:action).actionData }
        func choice(_ title:String,_ action:[String:Any]?) -> UIAction {
            UIAction(title:title,state:data(action)==draft.actionData ? .on : .off) { [weak self] _ in
                self?.draft.actionData=data(action); self?.refreshDraft()
            }
        }
        let action=draft.action
        let command=action?["commandId"] as? String
        let known=Self.commands.first { $0.0==command }
        let title:String
        if action?["type"] as? String == "skill" { title="$"+(action?["skillName"] as? String ?? "") }
        else if let known { title=tr(known.1) }
        else { title=KeySlots.actionLabel(action) }
        actionButton.configuration?.title=title
        actionButton.accessibilityValue=title
        var actions:[UIMenuElement]=[choice(tr("emptySlot"),nil)]
        // An imported action remains selectable even if it is outside this build's catalog.
        let isPreset=action?["type"] as? String == "composer-text" && ComposerTextPreset.matching(action?["text"] as? String) != nil
        if action != nil && known == nil && !isPreset { actions.append(choice(title,action)) }
        actions += ComposerTextPreset.allCases.map { preset in
            let binding=KeySlots.defaultAction(preset.rawValue)
            return choice(KeySlots.actionLabel(binding),binding)
        }
        actions += Self.commands.map { command,label in choice(tr(label),["type":"command","commandId":command]) }
        var seen:Set<String>=[]
        let bindings=Array(model.analogBindings.values)+Array(model.encoderBindings.values)+model.slots.values.compactMap { $0["action"] as? [String:Any] }
            + settings.layout.keys.values.compactMap(\.action)
        let skills=bindings.compactMap { binding -> UIAction? in
            guard binding["type"] as? String == "skill",let name=binding["skillName"] as? String,let path=binding["skillPath"] as? String,seen.insert(path).inserted else { return nil }
            return choice("$"+name,binding)
        }
        if !skills.isEmpty { actions.append(UIMenu(title:tr("skills"),children:skills)) }
        actionButton.menu=UIMenu(children:actions)
    }
}
