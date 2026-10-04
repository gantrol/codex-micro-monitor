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
    var name = "FAST" { didSet { setNeedsDisplay() } }
    override init(frame: CGRect) { super.init(frame:frame); isOpaque=false; backgroundColor = .clear; isUserInteractionEnabled=false }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ rect: CGRect) { if let c=UIGraphicsGetCurrentContext() { Paint.glyph(c,name,in:bounds) } }
}

final class SurfaceKey: UIControl {
    let task: Bool
    let far = UIImageView(), seam = UIImageView(), cap = UIImageView(), glyph = GlyphView()
    private let seat = UIView()
    var light = LightState(signal:.unknown,selected:false)
    var designScale: CGFloat = 0.75
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
        let side=max(28,24/designScale)
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
        if value != hovering { hovering=value; interaction?("hover",value); updateArt() }
    }
    override func beginTracking(_ touch:UITouch,with event:UIEvent?) -> Bool {
        pending=prepare?(); interaction?("press",true); isHighlighted=true; animatePress(true); return true
    }
    override func continueTracking(_ touch:UITouch,with event:UIEvent?) -> Bool {
        let inside=bounds.contains(touch.location(in:self))
        if inside != isHighlighted { isHighlighted=inside; animatePress(inside) }; return true
    }
    override func endTracking(_ touch:UITouch?,with event:UIEvent?) {
        let action = isHighlighted ? pending : nil
        pending=nil; isHighlighted=false; animatePress(false)
        action?(); interaction?("press",false)
    }
    override func cancelTracking(with event:UIEvent?) {
        pending=nil; isHighlighted=false; animatePress(false); interaction?("press",false)
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
    var action: (() -> Void)?
    var prepareJoystick: (() -> ((String) -> Bool)?)?
    var joystickInteraction: ((Bool) -> Void)?
    private var joystickAction: ((String) -> Bool)?
    private var joystickOrigin = CGPoint.zero
    private var joystickOffset = CGPoint.zero
    private var joystickArrow: String?
    private var joystickFired = false
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
        if kind == .joystick {
            guard let captured = prepareJoystick?() else { return false }
            joystickAction = captured; joystickOrigin = touch.location(in: self); joystickFired = false
            let dx=joystickOrigin.x-48, dy=joystickOrigin.y-48
            joystickArrow = hypot(dx,dy)>37 ? direction(dx,dy) : nil
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
            if distance>=0.5 && !joystickFired { joystickFired=joystickAction?(direction(dx,dy)) ?? false }
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
    func resetJoystick() { joystickAction=nil; joystickArrow=nil; joystickOffset = .zero; joystickInteraction?(false); setNeedsDisplay() }
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
            for (i,on) in [connected,desktopConnected,refreshing].enumerated() {
                let r=Paint.rect(10,33.5+CGFloat(i)*11,7,7), color:UInt32=on ? (i==2 ? 0xFF304FFE : 0xFF78A6FF) : 0xFFB8B98B
                if on { Paint.effect(c,box:r,radius:8,scale:s,opacity:0.78) { Paint.ellipse($0,r,color) } }
                Paint.ellipse(c,r,color)
            }
            c.saveGState(); c.translateBy(x:33,y:19); c.scaleBy(x:58/52,y:58/52)
            QuotaDrawing.draw(c,windows:usage,modelID:modelID,effort:effort,showModel:modelPreview || feedbackPreview,updating:refreshing); c.restoreGState()
        }
    }
}

@MainActor final class MicroViewController: UIViewController, UIPopoverPresentationControllerDelegate {
    let model=MicroModel(), settings=Settings()
    private let canvas=UIView(), shell=ShellView()
    private var tasks: [SurfaceKey]=[], halos: [UIImageView]=[], wideHalos: [UIImageView]=[], commands: [String:SurfaceKey]=[:]
    private let dial=HardwareControl(.dial), joystick=HardwareControl(.joystick), quota=HardwareControl(.quota)
    private let pages=[UIButton(type:.custom),UIButton(type:.custom)]
    private var subscriptions:Set<AnyCancellable>=[]
    private var configuring=false, ready=false
    private var designScale:CGFloat=0.75
    private var lastError:String?
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
        for (name,label) in [("FAST","fast"),("APPR","approve"),("REJ","decline"),("SPLIT","fork"),("MIC","voice"),("CODEX","submit")] {
            let key=SurfaceKey(task:false); key.glyph.name=name; key.accessibilityLabel=tr(label)
            key.interaction={ [weak self] kind,active in self?.model.setInteraction("command-\(name)-\(kind)",active:active) }
            commands[name]=key; canvas.addSubview(key)
        }
        for control in [dial,joystick,quota] { canvas.addSubview(control) }
        dial.accessibilityLabel=tr("dial"); joystick.accessibilityLabel=tr("joystick"); quota.accessibilityLabel=tr("usage")
        joystick.prepareJoystick={ [weak self] in
            guard let self, self.model.canTogglePlan, let target=self.model.controlTarget else { return nil }
            let bindings=self.model.analogActions
            return { [weak self] direction in
                guard let self, bindings[direction]=="composer.togglePlanMode", self.model.isCurrent(target) else { return false }
                self.model.togglePlan(target:target); return true
            }
        }
        joystick.joystickInteraction={ [weak self] active in self?.model.setInteraction("joystick",active:active) }
        dial.input.prepare={ [weak self] in
            guard let self, (self.settings.dial.encoderMode ?? self.model.encoderMode) == "reasoning",
                  let actions=self.model.prepareDial(self.settings.dial) else { return nil }
            return DialActions(step: { [weak self] steps in self?.dial.dialAngle += CGFloat(steps)*18; actions.step(steps) }, end:actions.end,tap:actions.tap)
        }
        quota.input.prepare={ [weak self] in guard let self else { return nil }; return self.model.prepareDial(self.settings.dial) }
        dial.input.inspect={ [weak self] in self?.showDialControls() }
        quota.input.inspect={ [weak self] in self?.showControls() }
        for (i,p) in pages.enumerated() {
            p.frame=Paint.rect(259+CGFloat(i)*36,53,36,28); p.tag=i; p.accessibilityLabel=tr(i==0 ? "controls" : "monitor")
            p.addTarget(self,action:#selector(changePage(_:)),for:.touchUpInside); canvas.addSubview(p)
        }
        let drag=UIPanGestureRecognizer(target:self,action:#selector(drag(_:))); drag.delegate=self; canvas.addGestureRecognizer(drag)
        let menu=UILongPressGestureRecognizer(target:self,action:#selector(menu(_:))); menu.minimumPressDuration=0.65; menu.delegate=self; canvas.addGestureRecognizer(menu)
        model.objectWillChange.receive(on:DispatchQueue.main).sink { [weak self] _ in self?.update() }.store(in:&subscriptions)
        settings.objectWillChange.receive(on:DispatchQueue.main).sink { [weak self] _ in self?.configure(); self?.update() }.store(in:&subscriptions)
        Desktop.services?.install { [weak self] event in
            guard let self else { return }
            switch event {
            case "hide","sleep": self.cancelDialGestures(); self.dismiss(animated:false); self.model.stop(); Task { await self.model.closeTransport() }
            case "show": self.model.start()
            case "refresh": Task { await self.model.refresh(); self.model.refreshControls() }
            case "floating": self.settings.toggleFloating()
            default: if event.hasPrefix("scale:"), let value=Double(event.dropFirst(6)) { self.settings.setScale(value) }
            }
        }
        update()
    }
    override func viewDidAppear(_ animated:Bool) { super.viewDidAppear(animated); configure(); model.start(); becomeFirstResponder() }
    override var canBecomeFirstResponder: Bool { true }
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input:"w",modifierFlags:.command,action:#selector(hideWindow)),
         UIKeyCommand(input:",",modifierFlags:.command,action:#selector(windowMenu))]
    }
    @objc private func hideWindow() { Desktop.services?.hideWindow() }
    @objc private func windowMenu() { Desktop.services?.showMenu() }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
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
    private func cancelDialGestures() { dial.input.cancel(); quota.input.cancel(); joystick.resetJoystick(); model.cancelDialInput() }
    @objc private func drag(_ recognizer:UIPanGestureRecognizer) { if recognizer.state == .began { Desktop.services?.dragWindow() } }
    @objc private func menu(_ recognizer:UILongPressGestureRecognizer) { if recognizer.state == .began { Desktop.services?.showMenu() } }
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
        for (id,x,y,w) in [("FAST",88.0,310.0,96.0),("APPR",194,310,96),("REJ",300,310,96),("SPLIT",406,310,96),("MIC",194,416,202),("CODEX",406,416,96)] {
            commands[id]?.frame=Paint.rect(x,y,w,96); commands[id]?.designScale=designScale
            commands[id]?.isHidden=model.monitor && id != "CODEX"; commands[id]?.setNeedsLayout()
        }
        dial.frame=Paint.rect(88,98,96,96); joystick.frame=Paint.rect(406,98,96,96); quota.frame=Paint.rect(88,416,96,96)
        dial.isHidden=model.monitor; joystick.isHidden=model.monitor
    }
    private func update() {
        guard isViewLoaded else { return }
        layoutKeys()
        for i in tasks.indices {
            let key=tasks[i], row=model.displayedThreads.indices.contains(i) ? model.displayedThreads[i] : nil
            let fresh=row.map { row in model.connected && model.threads.contains { $0.id == row.id } } ?? false
            let light=LightState(signal:row.map { model.signal(for:$0) } ?? .unknown,selected:fresh && row?.id == model.selectedID)
            key.light=light; key.updateArt()
            wideHalos[i].image=KeyArt.halo(light,near:false,scale:key.artScale)
            halos[i].image=KeyArt.halo(light,near:true,scale:key.artScale)
            key.alpha=model.monitor ? (row==nil ? 0.42 : model.connected ? 1 : 0.58) : 1
            key.isEnabled=row.map { model.canOpen($0) } ?? false
            key.accessibilityLabel=row?.label ?? tr("emptySlot"); key.accessibilityValue=tr(light.signal.rawValue)
            key.prepare={ [weak self] in
                guard let self, let row, self.model.canOpen(row) else { return nil }
                return { [weak self] in self?.model.select(row.id,open:true) }
            }
        }
        for (id,key) in commands {
            let enabled=id=="FAST" ? model.canSetFast : ["APPR","REJ"].contains(id) && model.controlTarget != nil && !model.approvals.isEmpty
            key.isEnabled=enabled; key.accessibilityHint=enabled ? model.selectedTitle : tr("controlNotReady")
            key.glyph.name=id=="FAST" && model.fast ? "FAST_ON" : id
            key.prepare={ [weak self,weak key] in
                guard let self, let target=self.model.controlTarget else { return nil }
                // Capture the exact observed target on pointer down.
                return { [weak self,weak key] in
                    guard let self else { return }
                    if id=="FAST" { self.model.toggleFast(target:target) }
                    else if let key { self.showApprovals(target:target,source:key,decision:id=="APPR" ? "accept" : "decline") }
                }
            }
        }
        quota.usage=model.usageWindows; quota.connected=model.connected; quota.desktopConnected=model.desktopConnected; quota.refreshing=model.refreshing || model.controlling
        quota.modelID=model.currentModel; quota.effort=model.reasoningFeedback ?? model.currentEffort
        quota.feedbackPreview=model.reasoningFeedback != nil
        quota.accessibilityValue=model.quota
        let reasoning=(settings.dial.encoderMode ?? model.encoderMode)=="reasoning"
        dial.accessibilityTraits=reasoning ? [.button,.adjustable] : [.button]
        quota.accessibilityTraits=[.button,.adjustable]
        dial.accessibilityHint=tr(reasoning ? "dialReasoningHint" : "dialUnavailableHint")
        quota.accessibilityHint=tr("dialReasoningHint")
        dial.accessibilityValue=model.currentEffort
        for control in [dial,quota] { control.accessibilityIncreaseStep=settings.dial.invertDirection ? 1 : -1 }
        let planDirections=["up","down","left","right"].filter { model.analogActions[$0]=="composer.togglePlanMode" }
        joystick.isEnabled=model.canTogglePlan && !planDirections.isEmpty
        joystick.accessibilityValue=model.collaborationMode
        joystick.accessibilityHint=tr(joystick.isEnabled ? "joystickPlanHint" : "controlNotReady")
        joystick.accessibilityCustomActions=planDirections.map { direction in
            UIAccessibilityCustomAction(name:tr(direction)+" · "+tr("plan")) { [weak self] _ in
                guard let self, self.model.canTogglePlan, let target=self.model.controlTarget else { return false }
                self.model.togglePlan(target:target); return true
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
        if let error=model.controlError, error != lastError, presentedViewController==nil {
            lastError=error
            let alert=UIAlertController(title:tr("actionFailed"),message:error,preferredStyle:.alert)
            alert.addAction(UIAlertAction(title:tr("ok"),style:.default) { [weak self] _ in self?.model.dismissControlError(); self?.lastError=nil })
            present(alert,animated:true)
        }
    }
    func open(_ url:URL) {
        guard let parts=URLComponents(url:url,resolvingAgainstBaseURL:false),parts.scheme=="codex-micro-monitor",parts.host=="show" else { return }
        let ids=parts.queryItems?.filter { $0.name=="thread" }.compactMap(\.value) ?? []
        guard ids.count<=1, ids.first.map({UUID(uuidString:$0) != nil}) ?? true else { return }
        Desktop.services?.showWindow(); if let id=ids.first { model.select(id) }
    }
    private func showControls() {
        guard presentedViewController==nil else { return }
        let target=model.controlTarget
        let sheet=ControlSheet(title:model.selectedTitle)
        sheet.addSection(tr("usage"))
        for window in model.usageWindows where window.available { sheet.addText("\(window.label)  ·  \(window.text)") }
        if let error=model.error { sheet.addText(error) }
        sheet.addSection(tr("quickModels"))
        for slot in ["A","B"] {
            let preset=slot=="A" ? settings.dial.a : settings.dial.b
            let selected=model.models.first { $0.id==preset.model }
            let label="\(slot)  ·  \(selected?.title ?? preset.model)  ·  \(preset.effort ?? tr("modelDefault"))"
            let menus=model.models.map { choice in
                let choices: [String?]=[nil]+choice.efforts.map(Optional.some)
                return UIMenu(title:choice.title,children:choices.map { effort in
                    UIAction(title:effort ?? tr("modelDefault"),state:preset.model==choice.id && preset.effort==effort ? .on : .off) { [weak self] _ in
                        guard let self else { return }
                        var profile=self.settings.dial
                        if slot=="A" { profile.a=QuickModelPreset(model:choice.id,effort:effort) }
                        else { profile.b=QuickModelPreset(model:choice.id,effort:effort) }
                        self.cancelDialGestures(); self.settings.setDial(profile); self.dismiss(animated:true)
                    }
                })
            }
            sheet.addMenu(label,menu:UIMenu(children:menus))
        }
        if let target {
            sheet.addSection(tr("model"))
            for choice in model.models { sheet.addAction(choice.title,selected:choice.id==model.currentModel) { [weak self] in self?.dismiss(animated:true); self?.model.setModel(choice,target:target) } }
            sheet.addSection(tr("reasoning"))
            for effort in model.currentDefinition?.efforts ?? [] { sheet.addAction(effort,selected:effort==model.currentEffort) { [weak self] in self?.dismiss(animated:true); self?.model.setReasoning(effort,target:target) } }
            if model.canSetFast { sheet.addAction(tr("fast"),selected:target.fast) { [weak self] in self?.dismiss(animated:true); self?.model.toggleFast(target:target) } }
            if model.canTogglePlan { sheet.addAction(tr("plan"),selected:model.collaborationMode=="plan") { [weak self] in self?.dismiss(animated:true); self?.model.togglePlan(target:target) } }
            if target.turnID != nil { sheet.addAction(tr("stop")) { [weak self] in self?.dismiss(animated:true); self?.model.stopTurn(target:target) } }
        }
        sheet.addAction(tr("refreshControls")) { [weak self] in self?.dismiss(animated:true); self?.model.refreshControls() }
        show(sheet,source:quota)
    }
    private func showDialControls() {
        guard presentedViewController==nil else { return }
        let sheet=ControlSheet(title:tr("dial"))
        sheet.addAction(tr("followCodex"),selected:settings.dial.encoderMode==nil) { [weak self] in
            guard let self else { return }; var profile=self.settings.dial; profile.encoderMode=nil
            self.cancelDialGestures(); self.settings.setDial(profile); self.dismiss(animated:true)
        }
        sheet.addAction(tr("reasoning"),selected:settings.dial.encoderMode=="reasoning") { [weak self] in
            guard let self else { return }; var profile=self.settings.dial; profile.encoderMode="reasoning"
            self.cancelDialGestures(); self.settings.setDial(profile); self.dismiss(animated:true)
        }
        sheet.addAction(tr("invertDial"),selected:settings.dial.invertDirection) { [weak self] in
            guard let self else { return }; var profile=self.settings.dial; profile.invertDirection.toggle()
            self.cancelDialGestures(); self.settings.setDial(profile); self.dismiss(animated:true)
        }
        show(sheet,source:dial)
    }
    private func showApprovals(target:ControlTarget,source:UIView,decision:String) {
        guard model.isCurrent(target),presentedViewController==nil else { model.refreshControls(); return }
        let sheet=ControlSheet(title:target.title)
        for approval in model.approvals {
            sheet.addSection(approval.method); sheet.addText(approval.text,monospace:true)
            sheet.addAction(tr(decision=="accept" ? "approve" : "decline")) { [weak self] in self?.dismiss(animated:true); self?.model.reply(approval,decision:decision,target:target) }
        }
        show(sheet,source:source)
    }
    private func show(_ sheet:ControlSheet,source:UIView) {
        model.setInteraction("popover",active:true)
        sheet.onClose={ [weak self] in self?.model.setInteraction("popover",active:false) }
        sheet.modalPresentationStyle = .popover; sheet.preferredContentSize=CGSize(width:360,height:430)
        sheet.popoverPresentationController?.sourceView=source; sheet.popoverPresentationController?.sourceRect=source.bounds; sheet.popoverPresentationController?.delegate=self
        present(sheet,animated:true)
    }
    func adaptivePresentationStyle(for controller:UIPresentationController) -> UIModalPresentationStyle { .none }
}

extension MicroViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer:UIGestureRecognizer,shouldReceive touch:UITouch) -> Bool {
        var v=touch.view
        while let current=v, current !== canvas { if current is UIControl { return false }; v=current.superview }
        return true
    }
}

final class ControlSheet: UIViewController {
    private let stack=UIStackView(); var onClose:(()->Void)?
    init(title:String) { super.init(nibName:nil,bundle:nil); self.title=title; stack.axis = .vertical; stack.spacing=10; addSection(title) }
    required init?(coder:NSCoder) { fatalError() }
    override func loadView() {
        view=UIView(); view.backgroundColor = .systemBackground
        let scroll=UIScrollView(); scroll.translatesAutoresizingMaskIntoConstraints=false; view.addSubview(scroll)
        stack.translatesAutoresizingMaskIntoConstraints=false; scroll.addSubview(stack)
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo:view.leadingAnchor),scroll.trailingAnchor.constraint(equalTo:view.trailingAnchor),scroll.topAnchor.constraint(equalTo:view.topAnchor),scroll.bottomAnchor.constraint(equalTo:view.bottomAnchor),stack.leadingAnchor.constraint(equalTo:scroll.contentLayoutGuide.leadingAnchor,constant:18),stack.trailingAnchor.constraint(equalTo:scroll.contentLayoutGuide.trailingAnchor,constant:-18),stack.topAnchor.constraint(equalTo:scroll.contentLayoutGuide.topAnchor,constant:18),stack.bottomAnchor.constraint(equalTo:scroll.contentLayoutGuide.bottomAnchor,constant:-18),stack.widthAnchor.constraint(equalTo:scroll.frameLayoutGuide.widthAnchor,constant:-36)])
    }
    func addSection(_ text:String) { let label=UILabel(); label.text=text; label.numberOfLines=0; label.font = .preferredFont(forTextStyle:.headline); stack.addArrangedSubview(label) }
    func addText(_ text:String,monospace:Bool=false) { let label=UILabel(); label.text=text; label.numberOfLines=0; label.font=monospace ? .monospacedSystemFont(ofSize:11,weight:.regular) : .preferredFont(forTextStyle:.body); stack.addArrangedSubview(label) }
    func addAction(_ text:String,selected:Bool=false,action:@escaping()->Void) {
        let b=UIButton(type:.system); b.setTitle((selected ? "✓  " : "")+text,for:.normal); b.contentHorizontalAlignment = .leading
        b.addAction(UIAction { _ in action() },for:.touchUpInside); stack.addArrangedSubview(b)
    }
    func addMenu(_ text:String,menu:UIMenu) {
        let button=UIButton(type:.system); button.setTitle(text,for:.normal); button.contentHorizontalAlignment = .leading
        button.titleLabel?.numberOfLines=0; button.menu=menu; button.showsMenuAsPrimaryAction=true
        button.isEnabled = !menu.children.isEmpty; stack.addArrangedSubview(button)
    }
    override func viewDidDisappear(_ animated:Bool) { super.viewDidDisappear(animated); onClose?(); onClose=nil }
}
