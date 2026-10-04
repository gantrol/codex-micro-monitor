import UIKit

/// Offline design artifact export. Uses the shipping painter without creating
/// UIApplication, windows, a desktop bridge, polling, or any Codex connection.
@MainActor enum DesignExport {
    static func write(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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
                Paint.glyph(c,"MIC",in:Paint.rect(129,75.25,32,32))
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
                Paint.glyph(c,name,in:Paint.rect(x+w/2-16,y+47.25-16,32,32))
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
        let metadata:[String:Any] = ["version":Bundle.main.object(forInfoDictionaryKey:"CodexMicroReleaseVersion") ?? "development",
            "origin":"Shipping UIKit Paint / KeyArt / ShellView / HardwareControl, offscreen; no window or Codex connection.",
            "states":"Illustrative states, not user data. Whole keypad has unassigned tasks and unknown quota.",
            "designSize":[590,610],"scales":[1,1.5,2]]
        try JSONSerialization.data(withJSONObject:metadata,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("export.json"),options:.atomic)
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
