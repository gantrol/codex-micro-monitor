import UIKit
import Combine

final class ShellView: UIView {
    override init(frame: CGRect) { super.init(frame: frame); isOpaque = false; backgroundColor = .clear; isUserInteractionEnabled = false; contentMode = .redraw }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ rect: CGRect) {
        guard let c = UIGraphicsGetCurrentContext() else { return }
        let s = contentScaleFactor
        let outer = Paint.rect(23,23,544,564)
        Paint.effect(c,box:outer.offsetBy(dx:0,dy:7),radius:30,scale:s,opacity:0.29) { Paint.shape($0,outer.offsetBy(dx:0,dy:7),66,color:0x526E7B80) }
        Paint.shade(c,outer,66,[Stop(0xE4FFFFFF,0),Stop(0xD6F7FAF9,0.48),Stop(0xC8E8F0EF,0.78),Stop(0xB8C7D3D3,1)])
        Paint.stroke(c,outer,66,0xD9FFFFFF,2)
        c.saveGState(); c.clip(to:Paint.rect(25,25,540,560))
        c.saveGState(); c.setAlpha(0.94)
        Paint.shade(c,Paint.rect(29,29,532,551),61,[Stop(0xFFFFFFFF,0),Stop(0xB8DFF8F3,0.16),Stop(0x76FFFFFF,0.46),Stop(0x8BC6EEE5,0.78),Stop(0xD6FFFFFF,1)],diagonal:true,stroke:2); c.restoreGState()
        Paint.shape(c,Paint.rect(35,35,520,540),56,color:0x14748788)
        Paint.shade(c,Paint.rect(35,35,520,540),56,[Stop(0x78FFFFFF,0),Stop(0x5EACBDBB,0.58),Stop(0x75859498,1)],stroke:1)
        Paint.shade(c,Paint.rect(43,43,504,524),50,[Stop(0xF4FFFFFF,0),Stop(0xEEF8FAF8,0.5),Stop(0xE9F1F5F2,0.82),Stop(0xE3E1EAE8,1)])
        Paint.stroke(c,Paint.rect(43,43,504,524),50,0xA8FFFFFF,1)
        c.saveGState(); c.setAlpha(0.15)
        Paint.shade(c,Paint.rect(113,562,364,5),3,[Stop(0x0098E8D5,0),Stop(0xA598E8D5,0.48),Stop(0x0098E8D5,1)],horizontal:true); c.restoreGState()
        // The actual Segoe font is not redistributed. This fallback stays confined to silkscreen text.
        let font = UIFont(name:"SegoeUIVariableText",size:8) ?? UIFont.systemFont(ofSize:8,weight:.semibold)
        let attrs: [NSAttributedString.Key:Any] = [.font:font,.foregroundColor:UIColor(argb:0x6A5A6368)]
        func side(_ text: String, right: Bool) {
            let size = (text as NSString).size(withAttributes:attrs)
            c.saveGState(); c.translateBy(x:right ? 526 : 64,y:305); c.rotate(by:right ? .pi/2 : -.pi/2)
            (text as NSString).draw(at:CGPoint(x:-size.width/2,y:0),withAttributes:attrs); c.restoreGState()
        }
        side("CODEX  /  MICRO  /  CRYSTAL HID",right:false); side("OPTICAL INPUT  /  PROJECT 2077",right:true)
        let text = "OPENAI CODEX" as NSString, size = text.size(withAttributes:attrs), total = size.width+15
        Paint.glyph(c,"CODEX",in:Paint.rect(295-total/2,550,10,10),color:0x6A5A6368)
        text.draw(at:CGPoint(x:295-total/2+15,y:560-size.height),withAttributes:attrs)
        c.restoreGState()
    }
}

final class GlyphView: UIView {
    var name = "FAST" { didSet { if name != oldValue { resetAnimation() } } }
    private var position: CGFloat?
    private var hovering = false
    private var started: CFTimeInterval = 0
    private var displayLink: CADisplayLink?
    override init(frame: CGRect) { super.init(frame:frame); isOpaque=false; backgroundColor = .clear; isUserInteractionEnabled=false }
    required init?(coder: NSCoder) { fatalError() }
    deinit { displayLink?.invalidate() }
    override func didMoveToWindow() { super.didMoveToWindow(); if window == nil { resetAnimation() } }
    func installHover(on view: UIView) { view.addGestureRecognizer(UIHoverGestureRecognizer(target:self,action:#selector(hover(_:)))) }
    @objc private func hover(_ gesture: UIHoverGestureRecognizer) { setHovered(gesture.state == .began || gesture.state == .changed) }
    func setHovered(_ value: Bool) {
        guard value != hovering else { return }
        resetAnimation(); hovering = value
        guard value, window != nil, ReasoningGlyph.names.contains(name), !UIAccessibility.isReduceMotionEnabled else { return }
        started = CACurrentMediaTime()
        let link = CADisplayLink(target:self,selector:#selector(advance(_:)))
        displayLink = link; link.add(to:.main,forMode:.common)
    }
    private func resetAnimation() {
        displayLink?.invalidate(); displayLink=nil; position=nil; hovering=false; setNeedsDisplay()
    }
    @objc private func advance(_ link: CADisplayLink) {
        guard !UIAccessibility.isReduceMotionEnabled else { resetAnimation(); return }
        let progress = min(1, max(0, (link.timestamp - started) / 0.18))
        let eased = CGFloat(1 - pow(1 - progress, 3))
        let rest = ReasoningGlyph.rest(name), end: CGFloat = name == "MIND+" ? 1 : 0
        position = rest + (end - rest) * eased; setNeedsDisplay()
        if progress >= 1 { displayLink?.invalidate(); displayLink=nil }
    }
    override func draw(_ rect: CGRect) { if let c=UIGraphicsGetCurrentContext() { Paint.glyph(c,name,in:bounds,reasoningPosition:position) } }
}

final class SurfaceKey: UIControl {
    let task: Bool
    let far = UIImageView(), seam = UIImageView(), cap = UIImageView(), glyph = GlyphView()
    private let seat = UIView()
    var light = LightState(signal:.unknown,selected:false)
    var designScale: CGFloat = 0.75
    var edit: (() -> Void)?
    var secondaryTitle: String { task ? tr("markUnread") : tr("editKey") }
    var requiredTapCount = 1
    var selectOnly: (() -> Void)?
    var prepare: (() -> (() -> Void)?)?
    var interaction: ((String, Bool) -> Void)?
    private var pending: (() -> Void)?
    private var hovering = false
    var artScale: CGFloat { max(1,traitCollection.displayScale * designScale) }
    init(task: Bool) {
        self.task=task; super.init(frame:.zero)
        isOpaque=false; backgroundColor = .clear; clipsToBounds=false
        seat.backgroundColor=UIColor(argb:0xB8ADB4B0); seat.layer.cornerRadius=14; seat.isUserInteractionEnabled=false
        for v in [far,seam,cap] { v.isUserInteractionEnabled=false }
        addSubview(far); addSubview(seam)
        if !task { addSubview(seat) }
        addSubview(cap)
        cap.addSubview(glyph)
        isAccessibilityElement=true; accessibilityTraits = .button
        addInteraction(UIPointerInteraction(delegate:nil))
        addInteraction(UIContextMenuInteraction(delegate:self))
        addGestureRecognizer(UIHoverGestureRecognizer(target:self,action:#selector(hover(_:))))
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() {
        super.layoutSubviews()
        for v in [far,seam,cap] {
            // Keep layout independent of the live press translation.
            v.bounds=Paint.rect(0,0,bounds.width+KeyArt.pad*2,96+KeyArt.pad*2)
            v.center=CGPoint(x:bounds.midX,y:48)
        }
        seat.frame=Paint.rect(0.5,2,bounds.width-1,93.5)
        let side=KeycapGlyph.side(at:designScale,name:glyph.name)
        glyph.frame=Paint.rect(KeyArt.pad+bounds.width/2-side/2,KeyArt.pad+47.25-side/2,side,side)
        glyph.isHidden=task
        updateArt()
    }
    func updateArt() {
        guard bounds.width > 0 else { return }
        far.image=KeyArt.far(task:task,white:light.neutral,width:bounds.width,scale:artScale)
        seam.image=task ? KeyArt.seam(light,scale:artScale) : nil
        cap.image=KeyArt.cap(task:task,width:bounds.width,light:light,hover:hovering,scale:artScale)
    }
    @objc private func hover(_ recognizer:UIHoverGestureRecognizer) {
        let value = recognizer.state == .began || recognizer.state == .changed
        if value != hovering { hovering=value; glyph.setHovered(value); interaction?("hover",value); updateArt() }
    }
    override func beginTracking(_ touch:UITouch,with event:UIEvent?) -> Bool {
        guard !SecondaryClickGesture.matches(event) else { return false }
        pending=prepare?(); interaction?("press",true); isHighlighted=true; animatePress(true); return true
    }
    override func continueTracking(_ touch:UITouch,with event:UIEvent?) -> Bool {
        let inside=bounds.contains(touch.location(in:self))
        if inside != isHighlighted { isHighlighted=inside; animatePress(inside) }; return true
    }
    override func endTracking(_ touch:UITouch?,with event:UIEvent?) {
        let activate = isHighlighted && (touch?.tapCount ?? 1) >= requiredTapCount
        let action = activate ? pending : nil
        if isHighlighted && !activate { selectOnly?() }
        pending=nil; isHighlighted=false; animatePress(false)
        action?(); interaction?("press",false)
    }
    override func cancelTracking(with event:UIEvent?) {
        pending=nil; isHighlighted=false; animatePress(false); interaction?("press",false)
    }
    override func contextMenuInteraction(_ interaction:UIContextMenuInteraction, configurationForMenuAtLocation location:CGPoint) -> UIContextMenuConfiguration? {
        cancelTracking(with:nil)
        guard let edit else { return nil }
        return UIContextMenuConfiguration(identifier:nil,previewProvider:nil) { _ in
            UIMenu(children:[UIAction(title:self.secondaryTitle,image:UIImage(systemName:self.task ? "circle.badge" : "slider.horizontal.3")) { _ in edit() }])
        }
    }
    override func accessibilityActivate() -> Bool { guard let action=prepare?() else { return false }; action(); return true }
    private func animatePress(_ down:Bool) {
        UIView.animate(withDuration:down ? 0.08 : 0.11,delay:0,options:[.beginFromCurrentState, .allowUserInteraction, down ? .curveLinear : .curveEaseOut]) {
            self.cap.transform=CGAffineTransform(translationX:0,y:down ? (self.task ? 1.5 : 1) : 0)
            self.far.alpha=down ? 0.45 : 1; self.seat.alpha=down ? 0.35 : 1
        }
    }
}

final class HardwareControl: UIControl {
    enum Kind { case dial, joystick, quota }
    let kind: Kind
    var usage: [UsageWindow] = [] { didSet { setNeedsDisplay() } }
    var modelID = "" { didSet { setNeedsDisplay() } }
    var effort = "" { didSet { setNeedsDisplay() } }
    var efforts:[String] = [] { didSet { if oldValue != efforts { setNeedsDisplay() } } }
    private var modelPreview = false
    var feedbackPreview = false { didSet { setNeedsDisplay() } }
    var dialAngle: CGFloat = 42 { didSet { setNeedsDisplay() } }
    var accessibilityIncreaseStep = -1
    lazy var input = DialInput(view: self)
    private let loading = CAShapeLayer()
    var available=false
    var connected=false { didSet { setNeedsDisplay() } }
    var desktopConnected=false { didSet { setNeedsDisplay() } }
    var refreshing=false { didSet { setNeedsDisplay(); updateLoading() } }
    var controlAttention=false { didSet { setNeedsDisplay() } }
    var action: (() -> Void)?
    var prepareJoystick: (() -> ((String) -> Bool)?)?
    var joystickInteraction: ((Bool) -> Void)?
    var joystickDirections: Set<String> = ["up","down","left","right"] { didSet { if oldValue != joystickDirections { setNeedsDisplay() } } }
    private var joystickAction: ((String) -> Bool)?
    private var joystickOrigin = CGPoint.zero
    private var joystickOffset = CGPoint.zero
    private var joystickArrow: String?
    private var joystickDirection: String?
    init(_ kind:Kind) {
        self.kind=kind; super.init(frame:.zero); isOpaque=false; backgroundColor = .clear; isAccessibilityElement=true; accessibilityTraits = .button
        if kind == .joystick { addTarget(self,action:#selector(tap),for:.touchUpInside) }
        else { _ = input }
        if kind == .quota {
            addGestureRecognizer(UIHoverGestureRecognizer(target:self,action:#selector(hover(_:))))
            loading.frame=Paint.rect(33,19,58,58); loading.fillColor=nil; loading.strokeColor=UIColor(argb:0xFF9EBDFF).cgColor
            loading.lineWidth=1.25*58/52; loading.lineCap = .round
            let p=CGMutablePath(); p.addArc(center:CGPoint(x:29,y:29),radius:51/2*58/52,startAngle:-.pi/2,endAngle:-.pi/2+2 * .pi * 0.24,clockwise:false)
            loading.path=p; loading.isHidden=true; layer.addSublayer(loading)
        }
    }
    required init?(coder:NSCoder) { fatalError() }
    @objc private func tap() { action?() }
    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard !SecondaryClickGesture.matches(event) else { return false }
        if kind == .joystick {
            guard let captured = prepareJoystick?() else { return false }
            joystickAction = captured; joystickOrigin = touch.location(in: self); joystickDirection = nil
            let dx=joystickOrigin.x-48, dy=joystickOrigin.y-48
            joystickArrow = hypot(dx,dy)>37 ? direction(dx,dy) : nil
            if let arrow=joystickArrow {
                guard joystickDirections.contains(arrow) else {resetJoystick();return false}
                joystickOffset=CGPoint(x:arrow == "left" ? -6 : arrow == "right" ? 6 : 0,y:arrow == "up" ? -6 : arrow == "down" ? 6 : 0)
            }
            isHighlighted=true;setNeedsDisplay()
            joystickInteraction?(true); return true
        }
        input.begin(touch.location(in: self)); isHighlighted = true; return true
    }
    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        if kind == .joystick {
            guard joystickArrow == nil else { return true }
            let point=touch.location(in:self), dx=point.x-joystickOrigin.x, dy=point.y-joystickOrigin.y
            let radius=hypot(dx,dy), distance=min(1,radius/24)
            joystickOffset=radius>0 ? CGPoint(x:dx/radius*distance*13,y:dy/radius*distance*13) : .zero
            setNeedsDisplay()
            if distance<0.5 { joystickDirection=nil }
            else {
                let next=direction(dx,dy)
                if next != joystickDirection,joystickDirections.contains(next),joystickAction?(next) == true { joystickDirection=next }
            }
            return true
        }
        input.move(touch.location(in: self)); return true
    }
    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        if kind == .joystick {
            if let arrow=joystickArrow, let touch, bounds.contains(touch.location(in:self)) { _ = joystickAction?(arrow) }
            resetJoystick(); return
        }
        input.end(inside: touch.map { bounds.contains($0.location(in: self)) } ?? false)
        isHighlighted = false
    }
    override func cancelTracking(with event: UIEvent?) { if kind == .joystick { resetJoystick() } else { input.cancel() }; isHighlighted = false }
    private func direction(_ dx:CGFloat,_ dy:CGFloat) -> String { abs(dx)>abs(dy) ? (dx>0 ? "right" : "left") : (dy<0 ? "up" : "down") }
    func resetJoystick() { joystickAction=nil; joystickArrow=nil; joystickDirection=nil; joystickOffset = .zero; isHighlighted=false; joystickInteraction?(false); setNeedsDisplay() }
    override func accessibilityActivate() -> Bool { kind == .joystick ? false : input.activate() }
    override func accessibilityIncrement() { input.adjust(accessibilityIncreaseStep) }
    override func accessibilityDecrement() { input.adjust(-accessibilityIncreaseStep) }
    @objc private func hover(_ recognizer:UIHoverGestureRecognizer) { modelPreview=recognizer.state == .began || recognizer.state == .changed; setNeedsDisplay() }
    private func updateLoading() {
        guard kind == .quota else { return }
        loading.isHidden = !refreshing
        if refreshing && loading.animation(forKey:"spin")==nil {
            let spin=CABasicAnimation(keyPath:"transform.rotation.z"); spin.fromValue=0; spin.toValue=2 * Double.pi; spin.duration=0.82; spin.repeatCount = .infinity
            loading.add(spin,forKey:"spin")
        } else if !refreshing { loading.removeAnimation(forKey:"spin") }
    }
    override func draw(_ rect:CGRect) {
        guard let c=UIGraphicsGetCurrentContext() else { return }
        let s=contentScaleFactor
        switch kind {
        case .dial:
            Paint.ellipse(c,Paint.rect(7,13,82,79),0x8B8E9DA3)
            Paint.ellipse(c,Paint.rect(9,8,78,80),0x55DDE9EC); Paint.stroke(c,Paint.rect(9,8,78,80),39,0x8AFFFFFF,1)
            let face=Paint.rect(7,4,82,81)
            Paint.effect(c,box:face.offsetBy(dx:0.776,dy:2.898),radius:8,scale:s,opacity:0.3) { Paint.ellipse($0,face.offsetBy(dx:0.776,dy:2.898),0xFF000000) }
            c.saveGState(); c.addEllipse(in:face); c.clip()
            Paint.shade(c,face,0,[Stop(0xFFFFFFFF,0),Stop(0xFFF4F9F9,0.38),Stop(0xFFE3EDF0,0.7),Stop(0xFFB4C2C8,1)],diagonal:true); c.restoreGState()
            c.saveGState(); c.translateBy(x:48,y:43); c.rotate(by:dialAngle * .pi/180)
            Paint.shape(c,Paint.rect(-3,-30,6,30),3,color:0xFF6A7379); c.restoreGState()
        case .joystick:
            for i in 0..<4 {
                c.saveGState(); c.translateBy(x:48,y:48); c.rotate(by:CGFloat(i) * .pi/2); c.translateBy(x:-7,y:-47)
                c.setAlpha(joystickDirections.contains(["up","right","down","left"][i]) ? 1 : 0.25)
                for (color,y,w):(UInt32,CGFloat,CGFloat) in [(0xD8FFFFFF,1,1.8),(0xB347403B,0,1.65)] {
                    c.setStrokeColor(UIColor(argb:color).cgColor); c.setLineWidth(w); c.setLineCap(.round); c.setLineJoin(.round)
                    c.move(to:CGPoint(x:1,y:7+y)); c.addLine(to:CGPoint(x:6,y:2+y)); c.addLine(to:CGPoint(x:11,y:7+y)); c.strokePath()
                }; c.restoreGState()
            }
            let face=Paint.rect(14.5+joystickOffset.x,14.5+joystickOffset.y,67,67)
            Paint.effect(c,box:face.offsetBy(dx:0,dy:3),radius:5,scale:s,opacity:0.42) { Paint.ellipse($0,face.offsetBy(dx:0,dy:3),0xFF232624) }
            Paint.radial(c,face,center:CGPoint(x:0.34,y:0.27),radii:CGSize(width:0.76,height:0.76),stops:[Stop(0xFF50524F,0),Stop(0xFF363936,0.44),Stop(0xFF222422,1)])
            Paint.stroke(c,face,33.5,0xCC000000,1); Paint.stroke(c,face.insetBy(dx:1,dy:1),32.5,0x1AFFFFFF,1)
        case .quota:
            Paint.ellipse(c,Paint.rect(31,18,64,64),0x4AFFFFFF); Paint.stroke(c,Paint.rect(31,18,64,64),32,0x72C9D8DC,1)
            let face=Paint.rect(33,19,58,58)
            Paint.effect(c,box:face.offsetBy(dx:0,dy:1),radius:4,scale:s,opacity:0.24) { Paint.ellipse($0,face.offsetBy(dx:0,dy:1),0xFF4F483F) }
            Paint.ellipse(c,face,0xFF2D2925)
            for (i,on) in [connected,desktopConnected,refreshing || controlAttention].enumerated() {
                let r=Paint.rect(10,33.5+CGFloat(i)*11,7,7), color:UInt32=i==2 && controlAttention ? 0xFFFFB24A : on ? (i==2 ? 0xFF304FFE : 0xFF78A6FF) : 0xFFB8B98B
                if on { Paint.effect(c,box:r,radius:8,scale:s,opacity:0.78) { Paint.ellipse($0,r,color) } }
                Paint.ellipse(c,r,color)
            }
            c.saveGState(); c.translateBy(x:33,y:19); c.scaleBy(x:58/52,y:58/52)
            QuotaDrawing.draw(c,windows:usage,modelID:modelID,effort:effort,efforts:efforts,showModel:modelPreview || feedbackPreview,updating:refreshing); c.restoreGState()
        }
    }
}

@MainActor final class MicroViewController: UIViewController, UIPopoverPresentationControllerDelegate {
    let settings: Settings
    let model: MicroViewModel
    private var settingsPage: SettingsViewController?
    init() {
        let settings = Settings(); self.settings = settings; model = MicroViewModel(settings:settings)
        super.init(nibName:nil,bundle:nil)
    }
    required init?(coder:NSCoder) { fatalError() }
    private let canvas=UIView(), shell=ShellView()
    private var tasks: [SurfaceKey]=[], halos: [UIImageView]=[], wideHalos: [UIImageView]=[], commands: [String:SurfaceKey]=[:]
    private let dial=HardwareControl(.dial), joystick=HardwareControl(.joystick), quota=HardwareControl(.quota)
    private let pages=[UIButton(type:.custom),UIButton(type:.custom)]
    private var subscriptions:Set<AnyCancellable>=[]
    private var configuring=false, ready=false
    private var designScale:CGFloat=0.75
    private weak var nativeScrollControl:HardwareControl?
    private var nativeScrollOwned=false
    private let sceneTitle="Codex Micro Monitor"
    override func loadView() {
        view=UIView(); view.backgroundColor = .clear; view.isOpaque=false
        canvas.backgroundColor = .clear; canvas.isOpaque=false; canvas.bounds=Paint.rect(0,0,590,610); view.addSubview(canvas)
        shell.frame=canvas.bounds; canvas.addSubview(shell)
        for i in 0..<14 {
            let halo=UIImageView(), wide=UIImageView()
            halo.isUserInteractionEnabled=false; wide.isUserInteractionEnabled=false
            halos.append(halo); wideHalos.append(wide)
            let key=SurfaceKey(task:true); tasks.append(key)
            key.interaction={ [weak self] kind, active in self?.model.setInteraction("task-\(i)-\(kind)",active:active) }
        }
        // WPF uses Z=-10 for every wide halo, then Z=-9 for every near halo.
        for halo in wideHalos { canvas.addSubview(halo) }
        for halo in halos { canvas.addSubview(halo) }
        for key in tasks { canvas.addSubview(key) }
        for (name,label) in [("FAST","fast"),("APPR","approve"),("REJ","decline"),("SPLIT","fork"),("MIC","voice"),("MIC1","voice"),("MIC2","emptySlot"),("CODEX","submit")] {
            let key=SurfaceKey(task:false); key.glyph.name=name; key.accessibilityLabel=tr(label)
            key.interaction={ [weak self] kind,active in self?.model.setInteraction("command-\(name)-\(kind)",active:active) }
            key.edit={ [weak self] in self?.showSettings(key:name) }
            commands[name]=key; canvas.addSubview(key)
        }
        for control in [dial,joystick,quota] { canvas.addSubview(control) }
        dial.accessibilityLabel=tr("dial"); joystick.accessibilityLabel=tr("joystick"); quota.accessibilityLabel=tr("usage")
        joystick.prepareJoystick={ [weak self] in
            guard let self else { return nil }
            return self.model.prepareJoystick()
        }
        joystick.joystickInteraction={ [weak self] active in self?.model.setInteraction("joystick",active:active) }
        dial.input.prepare={ [weak self] in
            guard let self else { return nil }
            let mode=self.settings.dial.encoderMode ?? self.model.encoderMode ?? "composer-navigation"
            guard let actions=mode == "reasoning" ? self.model.prepareDial(self.settings.dial) : self.model.prepareNavigationDial(mode,profile:self.settings.dial) else { self.model.unavailableInput();return nil }
            return DialActions(step: { [weak self] steps in self?.dial.dialAngle += CGFloat(steps)*18; actions.step(steps) }, end:actions.end,tap:actions.tap)
        }
        quota.input.prepare={ [weak self] in
            guard let self else { return nil }
            let actions=self.model.prepareDial(self.settings.dial)
            if actions == nil {self.model.unavailableInput()}
            return actions
        }
        dial.input.inspect={ [weak self] in self?.showSettings(section:"interaction") }
        quota.input.inspect={ [weak self] in self?.showSettings(section:"currentContext") }
        quota.input.longPress={ [weak self] in self?.model.openOfficialMicroSettings() }
        for (name,control) in [("encoder",dial),("quota",quota)] {
            control.input.interaction={ [weak self] active in self?.model.setInteraction(name+"-input",active:active) }
        }
        for (i,p) in pages.enumerated() {
            p.frame=Paint.rect(259+CGFloat(i)*36,53,36,28); p.tag=i; p.accessibilityLabel=tr(i==0 ? "controls" : "monitor")
            p.addTarget(self,action:#selector(changePage(_:)),for:.touchUpInside); canvas.addSubview(p)
        }
        let drag=UIPanGestureRecognizer(target:self,action:#selector(drag(_:))); drag.delegate=self; canvas.addGestureRecognizer(drag)
        let menu=UILongPressGestureRecognizer(target:self,action:#selector(menu(_:))); menu.minimumPressDuration=0.65; menu.delegate=self; canvas.addGestureRecognizer(menu)
        SecondaryClickGesture.install(on:canvas,target:self,action:#selector(secondaryMenu(_:)),delegate:self)
        Desktop.services?.installScrollInput { [weak self] x,y,dx,dy,precise,phase in
            self?.routeScroll(x:x,y:y,dx:dx,dy:dy,precise:precise,phase:phase) ?? false
        }
        model.objectWillChange.receive(on:DispatchQueue.main).sink { [weak self] _ in self?.update() }.store(in:&subscriptions)
        settings.objectWillChange.receive(on:DispatchQueue.main).sink { [weak self] _ in self?.cancelDialGestures(); self?.model.preferencesChanged(); self?.configure(); self?.update() }.store(in:&subscriptions)
        Desktop.services?.install { [weak self] event in
            guard let self else { return }
            switch event {
            case "hide","sleep": self.closeSettings(); self.cancelDialGestures(); self.dismiss(animated:false); self.model.stop(); Task { await self.model.closeTransport() }
            case "show": self.model.start()
            case "observationChanged": self.model.recoverObservation()
            case "refresh": Task { await self.model.refresh(); self.model.refreshControls() }
            case "floating": self.settings.toggleFloating()
            case "settings": self.showSettings()
            default: if event.hasPrefix("scale:"), let value=Double(event.dropFirst(6)) { self.settings.setScale(value) }
            }
        }
        update()
    }
    override func viewDidAppear(_ animated:Bool) { super.viewDidAppear(animated); configure(); model.start(); becomeFirstResponder() }
    override var canBecomeFirstResponder: Bool { true }
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input:"w",modifierFlags:.command,action:#selector(hideWindow)),
         UIKeyCommand(input:",",modifierFlags:.command,action:#selector(openSettings))]
    }
    @objc private func hideWindow() { Desktop.services?.hideWindow() }
    @objc private func openSettings() { showSettings() }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        settingsPage?.view.frame=view.bounds
        guard settingsPage == nil else { return }
        let scale=min(view.bounds.width/590,view.bounds.height/610)
        canvas.transform=CGAffineTransform(scaleX:scale,y:scale); canvas.center=CGPoint(x:view.bounds.midX,y:view.bounds.midY)
        if abs(scale-designScale)>0.001 { designScale=scale; layoutKeys(); update() }
    }
    private func configure() {
        guard !configuring else { return }; configuring=true
        view.window?.windowScene?.title=sceneTitle
        let restrictions=view.window?.windowScene?.sizeRestrictions
        restrictions?.minimumSize=CGSize(width:354,height:366); restrictions?.maximumSize=CGSize(width:1000,height:1100)
        ready=Desktop.services?.configureWindow(sceneTitle,scale:settings.scale,floating:settings.floating) ?? false
        configuring=false
        // Window creation is asynchronous relative to the UIKit scene callback.
        if !ready { DispatchQueue.main.asyncAfter(deadline:.now()+0.15) { [weak self] in self?.retryConfigure(remaining:10) } }
    }
    private func retryConfigure(remaining:Int) {
        guard !ready, remaining>0 else { return }
        ready=Desktop.services?.configureWindow(sceneTitle,scale:settings.scale,floating:settings.floating) ?? false
        if !ready { DispatchQueue.main.asyncAfter(deadline:.now()+0.15) { [weak self] in self?.retryConfigure(remaining:remaining-1) } }
    }
    @objc private func changePage(_ sender:UIButton) { cancelDialGestures(); model.monitor=sender.tag==1; layoutKeys(); update() }
    private func cancelDialGestures() { dial.input.cancel(); quota.input.cancel();nativeScrollControl=nil;joystick.resetJoystick(); model.cancelDialInput() }
    private func routeScroll(x:Double,y:Double,dx:Double,dy:Double,precise:Bool,phase:String) -> Bool {
        // Inertial scrolling must not turn a model/control selector after the
        // fingers leave the trackpad, including after a page/settings change.
        if phase == "momentum" { return nativeScrollOwned }
        if phase == "begin" || phase == "wheel" { nativeScrollOwned=false }
        guard settingsPage == nil,presentedViewController == nil,!canvas.isHidden,view.window != nil else { return false }
        if phase == "begin" || phase == "wheel" || (phase == "change" && nativeScrollControl == nil) {
            let point=CGPoint(x:view.bounds.minX+x*view.bounds.width,y:view.bounds.minY+y*view.bounds.height)
            let hit=view.hitTest(point,with:nil)
            let controls:[HardwareControl]=[dial,quota]
            let control=controls.first { !$0.isHidden && (hit === $0 || hit?.isDescendant(of:$0) == true) }
            if nativeScrollControl !== control { nativeScrollControl?.input.cancel() }
            nativeScrollControl=control;nativeScrollOwned=control != nil
        }
        guard let control=nativeScrollControl,!control.isHidden else { return false }
        control.input.nativeScroll(dx:dx,dy:dy,precise:precise,phase:phase)
        return true
    }
    @objc private func drag(_ recognizer:UIPanGestureRecognizer) { if recognizer.state == .began { Desktop.services?.dragWindow() } }
    @objc private func menu(_ recognizer:UILongPressGestureRecognizer) { if recognizer.state == .began { Desktop.services?.showMenu() } }
    @objc private func secondaryMenu(_ recognizer:UITapGestureRecognizer) { if recognizer.state == .ended { Desktop.services?.showMenu() } }
    private func layoutKeys() {
        let cells=model.monitor ? Array(0..<16).filter { ![12,15].contains($0) } : [1,2,4,5,6,7]
        for i in tasks.indices {
            let show=i<cells.count; tasks[i].isHidden = !show; halos[i].isHidden = !show; wideHalos[i].isHidden = !show
            if show {
                let cell=cells[i], x=88+CGFloat(cell%4)*106, y=98+CGFloat(cell/4)*106
                tasks[i].frame=Paint.rect(x,y,96,96); tasks[i].designScale=designScale
                halos[i].frame=Paint.rect(x-KeyArt.pad,y-KeyArt.pad,96+KeyArt.pad*2,96+KeyArt.pad*2)
                wideHalos[i].frame=halos[i].frame
                tasks[i].setNeedsLayout()
            }
        }
        commands.values.forEach { $0.isHidden=true }
        for (id,frame) in KeySlots.frames(separate:model.separateMicrophoneKeys) {
            commands[id]?.frame=frame; commands[id]?.designScale=designScale
            commands[id]?.isHidden=model.monitor && id != "CODEX"; commands[id]?.setNeedsLayout()
        }
        dial.frame=Paint.rect(88,98,96,96); joystick.frame=Paint.rect(406,98,96,96); quota.frame=Paint.rect(88,416,96,96)
        dial.isHidden=model.monitor; joystick.isHidden=model.monitor
    }
    private func update() {
        guard isViewLoaded else { return }
        layoutKeys()
        for i in tasks.indices {
            let key=tasks[i], row=model.taskRow(at:i)
            let fresh=row.map { row in model.connected && model.knownThreads.contains { $0.id == row.id } } ?? false
            let light=LightState(signal:row.map { model.displaySignal(for:$0) } ?? .unknown,selected:fresh && row?.id == model.displayedThreadID)
            key.light=light; key.updateArt()
            wideHalos[i].image=KeyArt.halo(light,near:false,scale:key.artScale)
            halos[i].image=KeyArt.halo(light,near:true,scale:key.artScale)
            key.alpha=model.monitor ? (row==nil && model.taskCommand(at:i)==nil ? 0.42 : model.connected ? 1 : 0.58) : 1
            key.isEnabled=model.canUseTask(i)
            key.accessibilityLabel=model.taskLabel(at:i); key.accessibilityValue=tr(light.signal.rawValue)
            key.requiredTapCount=settings.layout.singleTapAgentKeys ? 1 : 2
            key.selectOnly={ [weak self] in self?.model.prepareTask(i,open:false)?() }
            key.prepare={ [weak self] in self?.model.prepareTask(i) }
            key.edit = row.flatMap { row in model.canUseTask(i) && model.canMarkUnread(row) ? { [weak self] in
                guard let self,self.model.canUseTask(i),self.model.taskRow(at:i)?.id == row.id else {return}
                self.model.markUnread(row)
            } : nil }
        }
        for (id,key) in commands {
            let cap=model.keycap(for:id)
            let decision=model.approvalDecision(for:id)
            let approval=decision != nil
            let enabled=approval ? model.controlTarget != nil && !model.usesNativeSettings && !model.approvals.isEmpty : model.prepareKey(id) != nil
            // Keep unassigned keys editable; prepare still gates every action.
            let binding=model.binding(for:id)
            let unsupported=binding?["type"] as? String == "command" && !KeySlots.supportedCommands.contains(binding?["commandId"] as? String ?? "")
            key.isEnabled=true; key.accessibilityHint=enabled ? model.selectedTitle : tr(binding == nil ? "emptySlot" : unsupported ? "unsupportedAction" : "controlNotReady")
            key.glyph.alpha=enabled ? 1 : 0.4
            key.glyph.name=cap=="FAST" && model.fast ? "FAST_ON" : cap
            key.setNeedsLayout()
            key.accessibilityLabel=KeySlots.actionLabel(model.binding(for:id))
            key.accessibilityValue=cap
            key.prepare={ [weak self,weak key] in
                guard let self else { return nil }
                if !approval { return self.model.prepareKey(id) }
                guard let target=self.model.controlTarget, !target.usesNativeSettings, !self.model.approvals.isEmpty else { return nil }
                // Capture the exact observed target on pointer down.
                return { [weak self,weak key] in
                    guard let self else { return }
                    if let key, let decision { self.showApprovals(target:target,source:key,decision:decision) }
                }
            }
        }
        quota.usage=model.usageWindows; quota.connected=model.connected; quota.desktopConnected=model.desktopConnected; quota.refreshing=model.refreshing || model.controlling
        quota.controlAttention=model.controlError != nil || model.needsControlRefresh
        quota.modelID=model.currentModel; quota.effort=model.reasoningFeedback ?? model.currentEffort
        quota.efforts=model.currentDefinition?.efforts ?? []
        quota.feedbackPreview=model.reasoningFeedback != nil
        quota.accessibilityValue=[model.quota,model.currentModelTitle,model.currentEffort,model.displayedThreadID ?? "",quota.controlAttention ? tr("actionFailed") : ""].filter { !$0.isEmpty }.joined(separator:" · ")
        let reasoning=(settings.dial.encoderMode ?? model.encoderMode)=="reasoning"
        dial.accessibilityTraits=reasoning ? [.button,.adjustable] : [.button]
        quota.accessibilityTraits=[.button,.adjustable]
        dial.accessibilityHint=tr(reasoning ? "dialReasoningHint" : "dialNavigationHint")
        quota.accessibilityHint=tr("quotaDialHint")
        dial.accessibilityValue=model.currentEffort
        for control in [dial,quota] { control.accessibilityIncreaseStep=settings.dial.invertDirection ? 1 : -1 }
        let directions=["up","down","left","right"].filter { model.prepareBinding(model.analogBindings[$0]) != nil }
        if !joystick.isTracking {
            joystick.joystickDirections=Set(directions)
            joystick.isEnabled = !directions.isEmpty
        }
        joystick.accessibilityValue=model.collaborationMode
        joystick.accessibilityHint=tr(joystick.isEnabled ? "joystickNavigationHint" : "controlNotReady")
        joystick.accessibilityCustomActions=directions.map { direction in
            UIAccessibilityCustomAction(name:tr(direction)) { [weak self] _ in
                guard let self, let action=self.model.prepareBinding(self.model.analogBindings[direction]) else { return false }
                action(); return true
            }
        }
        for (i,p) in pages.enumerated() {
            let selected=(i==1)==model.monitor
            let dot=p.viewWithTag(10) ?? UIView(); dot.tag=10; dot.isUserInteractionEnabled=false
            if dot.superview==nil { p.addSubview(dot) }
            dot.frame=Paint.rect(selected ? 8 : 14.5,10.5,selected ? 20 : 7,7); dot.layer.cornerRadius=4
            dot.backgroundColor=UIColor(argb:selected ? 0xFF7185EA : 0x55718592)
            p.accessibilityTraits=selected ? [.button,.selected] : .button
        }
    }
    func open(_ url:URL) {
        guard let parts=URLComponents(url:url,resolvingAgainstBaseURL:false),parts.scheme=="codex-micro-monitor",parts.host=="show" else { return }
        let ids=parts.queryItems?.filter { $0.name=="thread" }.compactMap(\.value) ?? []
        guard ids.count<=1, ids.first.map({UUID(uuidString:$0) != nil}) ?? true else { return }
        Desktop.services?.showWindow(); if let id=ids.first { model.select(id) }
    }
    private func showSettings(key:String? = nil, section:String? = nil) {
        guard settingsPage == nil else { return }
        guard presentedViewController == nil else {
            dismiss(animated:false) { [weak self] in self?.showSettings(key:key,section:section) }; return
        }
        cancelDialGestures()
        model.setInteraction("settings",active:true)
        let page=SettingsViewController(settings:settings,model:model)
        page.onClose={ [weak self] in self?.closeSettings() }
        settingsPage=page
        addChild(page); page.view.frame=view.bounds; page.view.autoresizingMask=[.flexibleWidth,.flexibleHeight]
        view.addSubview(page.view); page.didMove(toParent:self)
        canvas.isHidden=true
        Desktop.services?.setSettingsVisible(true)
        view.setNeedsLayout(); view.layoutIfNeeded()
        page.open(key:key,section:section)
    }
    private func closeSettings() {
        guard let page=settingsPage else { return }
        page.willMove(toParent:nil); page.view.removeFromSuperview(); page.removeFromParent()
        settingsPage=nil; canvas.isHidden=false
        Desktop.services?.setSettingsVisible(false)
        model.setInteraction("settings",active:false)
        view.setNeedsLayout(); update(); becomeFirstResponder()
    }
    private func showApprovals(target:ControlTarget,source:UIView,decision:String) {
        guard model.isCurrent(target),presentedViewController==nil else { model.refreshControls(); return }
        guard !model.approvals.isEmpty else { return }
        let sheet=ApprovalSheet(title:target.title)
        for approval in model.approvals {
            sheet.addSection(approval.method); sheet.addText(approval.text,monospace:true)
            sheet.addAction(tr(decision=="accept" ? "approve" : "decline")) { [weak self] in self?.dismiss(animated:true); self?.model.reply(approval,decision:decision,target:target) }
        }
        showApprovalSheet(sheet,source:source)
    }
    private func showApprovalSheet(_ sheet:ApprovalSheet,source:UIView) {
        model.setInteraction("popover",active:true)
        sheet.onClose={ [weak self] in self?.model.setInteraction("popover",active:false) }
        sheet.modalPresentationStyle = .popover; sheet.preferredContentSize=CGSize(width:360,height:430)
        sheet.popoverPresentationController?.backgroundColor = .white
        sheet.popoverPresentationController?.sourceView=source; sheet.popoverPresentationController?.sourceRect=source.bounds; sheet.popoverPresentationController?.delegate=self
        present(sheet,animated:true)
    }
    func adaptivePresentationStyle(for controller:UIPresentationController) -> UIModalPresentationStyle { .none }
}

extension MicroViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer:UIGestureRecognizer,shouldReceive event:UIEvent) -> Bool {
        gestureRecognizer is SecondaryClickGesture || !SecondaryClickGesture.matches(event)
    }
    func gestureRecognizerShouldBegin(_ gestureRecognizer:UIGestureRecognizer) -> Bool {
        var v=canvas.hitTest(gestureRecognizer.location(in:canvas),with:nil)
        while let current=v,current !== canvas { if current is UIControl {return false};v=current.superview }
        return v === canvas
    }
    func gestureRecognizer(_ gestureRecognizer:UIGestureRecognizer,shouldReceive touch:UITouch) -> Bool {
        var v=touch.view
        while let current=v, current !== canvas { if current is UIControl { return false }; v=current.superview }
        return true
    }
}

// Request details belong to the approval flow, never to a settings menu.
final class ApprovalSheet: UIViewController {
    private let stack=SettingsStyle.stack(.vertical,spacing:12)
    var onClose:(()->Void)?
    init(title:String) { super.init(nibName:nil,bundle:nil); self.title=title }
    required init?(coder:NSCoder) { fatalError() }
    override func loadView() {
        view=UIView(); view.backgroundColor = .white; view.tintColor=SettingsStyle.accent
        let header=SettingsStyle.stack(.horizontal,spacing:12); header.alignment = .center
        let title=SettingsStyle.label(title ?? "",size:16,weight:.semibold)
        title.numberOfLines=2; title.lineBreakMode = .byTruncatingTail
        let close=SettingsStyle.button("",symbol:"xmark") { [weak self] in self?.dismiss(animated:true) }
        close.accessibilityLabel=tr("close")
        header.addArrangedSubview(title); header.addArrangedSubview(close)
        let line=SettingsStyle.lineView(), scroll=UIScrollView()
        for item in [header,line,scroll] { item.translatesAutoresizingMaskIntoConstraints=false; view.addSubview(item) }
        stack.translatesAutoresizingMaskIntoConstraints=false; scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:18), header.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-12),
            header.topAnchor.constraint(equalTo:view.topAnchor,constant:12), header.heightAnchor.constraint(greaterThanOrEqualToConstant:40),
            line.leadingAnchor.constraint(equalTo:view.leadingAnchor), line.trailingAnchor.constraint(equalTo:view.trailingAnchor), line.topAnchor.constraint(equalTo:header.bottomAnchor,constant:12),
            scroll.leadingAnchor.constraint(equalTo:view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo:view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo:line.bottomAnchor), scroll.bottomAnchor.constraint(equalTo:view.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo:scroll.contentLayoutGuide.leadingAnchor,constant:18), stack.trailingAnchor.constraint(equalTo:scroll.contentLayoutGuide.trailingAnchor,constant:-18),
            stack.topAnchor.constraint(equalTo:scroll.contentLayoutGuide.topAnchor,constant:18), stack.bottomAnchor.constraint(equalTo:scroll.contentLayoutGuide.bottomAnchor,constant:-18),
            stack.widthAnchor.constraint(equalTo:scroll.frameLayoutGuide.widthAnchor,constant:-36)
        ])
    }
    func addSection(_ text:String) {
        if !stack.arrangedSubviews.isEmpty { stack.addArrangedSubview(SettingsStyle.lineView()) }
        let label=SettingsStyle.label(text,weight:.semibold); label.textColor=SettingsStyle.muted
        stack.addArrangedSubview(label)
    }
    func addText(_ text:String,monospace:Bool=false) {
        let label=SettingsStyle.label(text)
        if monospace { label.font = .monospacedSystemFont(ofSize:11,weight:.regular) }
        stack.addArrangedSubview(label)
    }
    func addAction(_ text:String,action:@escaping()->Void) {
        let button=SettingsStyle.button(text,primary:true,action:action)
        button.contentHorizontalAlignment = .center; stack.addArrangedSubview(button)
    }
    override var canBecomeFirstResponder:Bool { true }
    override func viewDidAppear(_ animated:Bool) { super.viewDidAppear(animated); becomeFirstResponder() }
    override var keyCommands:[UIKeyCommand]? { [UIKeyCommand(input:UIKeyCommand.inputEscape,modifierFlags:[],action:#selector(closeSheet))] }
    @objc private func closeSheet() { dismiss(animated:true) }
    override func viewDidDisappear(_ animated:Bool) { super.viewDidDisappear(animated); onClose?(); onClose=nil }
}
