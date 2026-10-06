import UIKit

/// Offline design artifact export. Uses the shipping painter without creating
/// UIApplication, windows, a desktop bridge, polling, or any Codex connection.
@MainActor enum DesignExport {
    static func write(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let primaryGlyphs = ["FAST", "FAST_ON", "APPR", "REJ", "SPLIT", "MIC", "MIC1", "CODEX", "SKETCH"]
        let glyphNames = primaryGlyphs + KeycapGlyph.names.filter { !primaryGlyphs.contains($0) }.sorted()
        var glyphMetrics: [[String: Any]] = []
        for designScale: CGFloat in [0.6, 0.75, 1, 1.05] {
            let columns = 8, rows = (glyphNames.count + columns - 1) / columns
            let width = CGFloat(columns * 100), themeHeight = CGFloat(rows * 100)
            let sheet = Paint.image(CGSize(width: width, height: themeHeight * 2), scale: 2) { c in
                Paint.shape(c, Paint.rect(0, 0, width, themeHeight), 0, color: 0xFFF7F8F6)
                Paint.shape(c, Paint.rect(0, themeHeight, width, themeHeight), 0, color: 0xFF182326)
                for (index, name) in glyphNames.enumerated() {
                    let size = KeycapGlyph.side(at:designScale,name:name) * designScale
                    let x = CGFloat(index % columns) * 100
                    let row = CGFloat(index / columns) * 100
                    for theme in 0..<2 {
                        let y = CGFloat(theme) * themeHeight + row
                        let rect = Paint.rect(x + 50 - size / 2, y + 42 - size / 2, size, size)
                        Paint.glyph(c, name, in: rect, color: theme == 0 ? 0xFF171717 : 0xFFF7F8F6)
                        (name as NSString).draw(at: CGPoint(x: x + 20, y: y + 72),
                            withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                                .foregroundColor: theme == 0 ? UIColor.darkGray : UIColor.lightGray])
                    }
                    if let bounds = KeycapGlyph.bounds[name], let transform = KeycapGlyph.transform(name, in: Paint.rect(0, 0, size, size)) {
                        let ink = bounds.applying(transform)
                        glyphMetrics.append(["name": name, "designScale": designScale,
                            "targetVisibleSide": KeycapGlyph.visibleSide * KeycapGlyph.opticalScale(name) * designScale,
                            "visibleWidth": ink.width, "visibleHeight": ink.height, "centerX": ink.midX, "centerY": ink.midY])
                    }
                }
            }
            try save(sheet, to: directory.appendingPathComponent("glyphs-\(Int((designScale * 100).rounded())).png"))
        }
        try JSONSerialization.data(withJSONObject: glyphMetrics, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("glyph-metrics.json"), options: .atomic)
        let reasoning = Paint.image(CGSize(width: 360, height: 200), scale: 2) { c in
            Paint.shape(c, Paint.rect(0,0,360,200), 0, color: 0xFFF7F8F6)
            for (row,name) in ["MIND+","MIND-"].enumerated() {
                for (column,position) in [ReasoningGlyph.rest(name), name == "MIND+" ? CGFloat(1) : 0].enumerated() {
                    let side=KeycapGlyph.side(at:1,name:name)
                    Paint.glyph(c,name,in:Paint.rect(110+CGFloat(column)*136-side/2,44+CGFloat(row)*96-side/2,side,side),reasoningPosition:position)
                    ((column == 0 ? name : name+" hover") as NSString).draw(at:CGPoint(x:80+CGFloat(column)*136,y:66+CGFloat(row)*96),withAttributes:[.font:UIFont.monospacedSystemFont(ofSize:11,weight:.regular),.foregroundColor:UIColor.darkGray])
                }
            }
        }
        try save(reasoning,to:directory.appendingPathComponent("reasoning-slider.png"))
        let mindKeys=Paint.image(CGSize(width:480,height:170),scale:2) { c in
            Paint.shape(c,Paint.rect(0,0,480,170),0,color:0xFFF7F8F6)
            for (index,name) in ["MIND+","MIND-","FAST","APPR"].enumerated() {
                let x=CGFloat(index)*110+27
                drawKey(c,origin:CGPoint(x:x,y:30),width:96,light:.init(signal:.unknown,selected:false),task:false,scale:2)
                let side=KeycapGlyph.side(at:1,name:name)
                Paint.glyph(c,name,in:Paint.rect(x+48-side/2,77.25-side/2,side,side))
            }
        }
        try save(mindKeys,to:directory.appendingPathComponent("mind-keycaps.png"))
        for scale: CGFloat in [1, 1.5, 2] {
            KeyArt.cache.removeAllObjects()
            let sheet = Paint.image(CGSize(width: 780, height: 400), scale: scale) { c in
                Paint.shape(c, Paint.rect(0,0,780,200), 0, color:0xFFF7F8F6)
                Paint.shape(c, Paint.rect(0,200,780,200), 0, color:0xFF182326)
                let states:[LightState] = [
                    .init(signal:.unknown,selected:false), .init(signal:.idle,selected:true),
                    .init(signal:.running,selected:false), .init(signal:.running,selected:true),
                    .init(signal:.waiting,selected:false), .init(signal:.unread,selected:true)]
                for row in 0..<2 {
                    let y:CGFloat = CGFloat(row)*200+46
                    for (i,state) in states.enumerated() {
                        let origin=CGPoint(x:CGFloat(i)*126+27,y:y)
                        drawKey(c, origin:origin, width:96, light:state, task:true, scale:scale)
                        let text="\(state.signal.rawValue)\(state.selected ? " / selected" : "")" as NSString
                        text.draw(at:CGPoint(x:origin.x-5,y:y+120),withAttributes:[.font:UIFont.systemFont(ofSize:10),.foregroundColor:row==0 ? UIColor.darkGray : UIColor.lightGray])
                    }
                }
            }
            try save(sheet, to:directory.appendingPathComponent("lighting-\(scale)x.png"))
            let mic=Paint.image(CGSize(width:290,height:184),scale:scale) { c in
                drawKey(c,origin:CGPoint(x:44,y:44),width:202,light:.init(signal:.unknown,selected:false),task:false,scale:scale)
                let side = KeycapGlyph.side(at: 1)
                Paint.glyph(c,"MIC",in:Paint.rect(145-side/2,91.25-side/2,side,side))
            }
            try save(mic,to:directory.appendingPathComponent("microphone-\(scale)x.png"))
        }
        let scale:CGFloat=2
        let keypad=Paint.image(CGSize(width:590,height:610),scale:scale) { c in
            let shell=ShellView(frame:Paint.rect(0,0,590,610)); shell.contentScaleFactor=scale; shell.draw(shell.bounds)
            let light=LightState(signal:.unknown,selected:false)
            for cell in [1,2,4,5,6,7] {
                drawKey(c,origin:CGPoint(x:88+CGFloat(cell%4)*106,y:98+CGFloat(cell/4)*106),width:96,light:light,task:true,scale:scale)
            }
            for (name,x,y,w) in [("FAST",88.0,310.0,96.0),("APPR",194,310,96),("REJ",300,310,96),("SPLIT",406,310,96),("MIC",194,416,202),("CODEX",406,416,96)] {
                drawKey(c,origin:CGPoint(x:x,y:y),width:w,light:light,task:false,scale:scale)
                let side = KeycapGlyph.side(at: 1)
                Paint.glyph(c,name,in:Paint.rect(x+w/2-side/2,y+47.25-side/2,side,side))
            }
            for (kind,x,y):(HardwareControl.Kind,CGFloat,CGFloat) in [(.dial,88,98),(.joystick,406,98),(.quota,88,416)] {
                c.saveGState(); c.translateBy(x:x,y:y)
                let control=HardwareControl(kind); control.bounds=Paint.rect(0,0,96,96); control.contentScaleFactor=scale; control.draw(control.bounds)
                c.restoreGState()
            }
            Paint.shape(c,Paint.rect(267,63.5,20,7),4,color:0xFF7185EA)
            Paint.shape(c,Paint.rect(309.5,63.5,7,7),4,color:0x55718592)
        }
        try save(keypad,to:directory.appendingPathComponent("keypad-transparent.png"))
        for (name,color):(String,UInt32) in [("light",0xFFFFFFFF),("dark",0xFF182326)] {
            let image=Paint.image(CGSize(width:590,height:610),scale:2) { c in
                Paint.shape(c,Paint.rect(0,0,590,610),0,color:color)
                draw(c,image:keypad,in:Paint.rect(0,0,590,610))
            }
            try save(image,to:directory.appendingPathComponent("keypad-\(name).png"))
        }
        // Render the actual settings views with isolated defaults and no model
        // polling. These artifacts never create a window or execute a binding.
        let suite="com.gantrol.codex-micro.design-export."+UUID().uuidString
        if let defaults=UserDefaults(suiteName:suite) {
            defer { defaults.removePersistentDomain(forName:suite) }
            let preferences=Settings(defaults:defaults)
            var layout=preferences.layout
            layout.keys=KeySlots.defaults.mapValues { KeyOverride(icon:$0,action:KeySlots.defaultAction($0)) }
            preferences.setLayout(layout)
            let model=MicroViewModel(settings:preferences)
            let settings=SettingsViewController(settings:preferences,model:model)
            let editor=KeyEditorViewController(key:"FAST",model:model,settings:preferences)
            for (name,controller):(String,UIViewController) in [("settings",settings),("settings-context",settings),("settings-models",settings),("key-editor",editor)] {
                controller.loadViewIfNeeded()
                controller.view.frame=Paint.rect(0,0,720,760)
                controller.view.overrideUserInterfaceStyle = .light
                controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
                prepare(controller.view)
                if name=="settings-context" { settings.open(key:nil,section:"currentContext"); prepare(controller.view) }
                if name=="settings-models" { settings.open(key:nil,section:"models"); prepare(controller.view) }
                let image=Paint.image(controller.view.bounds.size,scale:2) { c in controller.view.layer.render(in:c) }
                try save(image,to:directory.appendingPathComponent(name+".png"))
            }
            let context=CurrentContextView(frame:Paint.rect(24,24,648,265))
            context.update(source:tr("currentConversation"),title:tr("settings"),id:"00000000-0000-4000-8000-000000000000",model:"GPT-5.6-Sol\ngpt-5.6-sol",effort:"high")
            let canvas=UIView(frame:Paint.rect(0,0,696,313)); canvas.backgroundColor = .white
            canvas.overrideUserInterfaceStyle = .light; canvas.addSubview(context); prepare(canvas)
            let image=Paint.image(canvas.bounds.size,scale:2) { c in canvas.layer.render(in:c) }
            try save(image,to:directory.appendingPathComponent("current-context-example.png"))
        }
        let metadata:[String:Any] = ["version":Bundle.main.object(forInfoDictionaryKey:"CodexMicroReleaseVersion") ?? "development",
            "origin":"Shipping UIKit Paint / KeyArt / ShellView / HardwareControl, offscreen; no window or Codex connection.",
            "states":"Illustrative states, not user data. Whole keypad has unassigned tasks and unknown quota.",
            "designSize":[590,610],"scales":[1,1.5,2]]
        try JSONSerialization.data(withJSONObject:metadata,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("export.json"),options:.atomic)
    }
    private static func prepare(_ view:UIView) {
        (view as? UIButton)?.updateConfiguration()
        view.layoutIfNeeded(); view.layer.displayIfNeeded()
        view.subviews.forEach(prepare)
    }
    private static func drawKey(_ c:CGContext,origin:CGPoint,width:CGFloat,light:LightState,task:Bool,scale:CGFloat) {
        let box=Paint.rect(origin.x-KeyArt.pad,origin.y-KeyArt.pad,width+KeyArt.pad*2,96+KeyArt.pad*2)
        if task {
            draw(c,image:KeyArt.halo(light,near:false,scale:scale),in:box)
            draw(c,image:KeyArt.halo(light,near:true,scale:scale),in:box)
        }
        draw(c,image:KeyArt.far(task:task,white:light.neutral,width:width,scale:scale),in:box)
        if task { draw(c,image:KeyArt.seam(light,scale:scale),in:box) }
        else { Paint.shape(c,Paint.rect(origin.x+0.5,origin.y+2,width-1,93.5),14,color:0xB8ADB4B0) }
        draw(c,image:KeyArt.cap(task:task,width:width,light:light,hover:false,scale:scale),in:box)
    }
    private static func draw(_ c:CGContext,image:UIImage,in rect:CGRect) {
        guard let cg=image.cgImage else { return }
        c.saveGState(); c.translateBy(x:rect.minX,y:rect.maxY); c.scaleBy(x:1,y:-1)
        c.draw(cg,in:CGRect(origin:.zero,size:rect.size)); c.restoreGState()
    }
    private static func save(_ image:UIImage,to url:URL) throws {
        guard let data=image.pngData() else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to:url,options:.atomic)
    }
}
