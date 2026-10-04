import UIKit

enum QuotaDrawing {
    static func draw(_ c: CGContext, windows: [UsageWindow], modelID:String, effort:String, showModel:Bool, updating:Bool) {
        let available=windows.filter(\.available)
        if showModel {
            let rank=["low","medium","high","xhigh","max","ultra"].firstIndex(of:effort.lowercased())
            let levels:[Double?]=[rank.map { Double(min($0+1,3))*100/3 },rank.map { Double(max(0,$0-2))*100/3 }]
            let accent:UInt32=rank.map { $0<=2 ? 0xFFA8C7FF : $0<=4 ? 0xFFCEB1FF : 0xFFFFD27A } ?? 0xFF9BDBBD
            for (i,level) in levels.enumerated() { ring(c,diameter:i==0 ? 47 : 41,remaining:level,accent:accent) }
            let label=modelID.lowercased().hasPrefix("gpt-") ? String(modelID.dropFirst(4)) : modelID
            let parts=label.split(separator:"-").map(String.init)
            let version=updating ? "···" : parts.first ?? "—", family=parts.count>1 ? parts.dropFirst().joined(separator:" ").capitalized : "—"
            let a:[NSAttributedString.Key:Any]=[.font:UIFont.systemFont(ofSize:16,weight:.semibold),.foregroundColor:UIColor(argb:0xFFF7FAFF)]
            let b:[NSAttributedString.Key:Any]=[.font:UIFont.systemFont(ofSize:14,weight:.semibold),.foregroundColor:UIColor(argb:0xFFDDE7F2)]
            let va=(version as NSString).size(withAttributes:a), fb=(family as NSString).size(withAttributes:b)
            let scale=min(1,38/max(va.width,fb.width),34/max(34,va.height+fb.height))
            c.saveGState(); c.translateBy(x:26,y:26); c.scaleBy(x:scale,y:scale)
            (version as NSString).draw(at:CGPoint(x:-va.width/2,y:-17),withAttributes:a)
            (family as NSString).draw(at:CGPoint(x:-fb.width/2,y:1),withAttributes:b); c.restoreGState()
            return
        }
        for (i,window) in available.enumerated() {
            let diameter:CGFloat=i==0 ? 47 : 41
            ring(c,diameter:diameter,remaining:window.remaining,accent:window.id=="primary" ? 0xFFA8C7FF : 0xFF9BDBBD)
        }
        if available.count==2 {
            SevenSegment.draw(c,text:available[0].text,in:Paint.rect(9,10,27,14))
            SevenSegment.draw(c,text:available[1].text,in:Paint.rect(16,28,27,14))
            c.setStrokeColor(UIColor(argb:0x80DDE7F2).cgColor); c.setLineWidth(0.8)
            c.move(to:CGPoint(x:23,y:28)); c.addLine(to:CGPoint(x:29,y:24)); c.strokePath()
        } else { SevenSegment.draw(c,text:available.first?.text ?? "—",in:Paint.rect(8,16,36,20)) }
    }
    private static func ring(_ c:CGContext,diameter:CGFloat,remaining:Double?,accent:UInt32) {
        c.setStrokeColor(UIColor(argb:0x2EFFFFFF).cgColor); c.setLineWidth(1.4)
        c.strokeEllipse(in:Paint.rect(26-diameter/2,26-diameter/2,diameter,diameter))
        if let remaining,remaining>0 {
            let color:UInt32=remaining<=10 ? 0xFFFF9E8B : remaining<=30 ? 0xFFFFD27A : accent
            c.setStrokeColor(UIColor(argb:color).cgColor); c.setLineWidth(1.6*diameter/47); c.setLineCap(.round)
            c.addArc(center:CGPoint(x:26,y:26),radius:diameter/2,startAngle:-.pi/2,endAngle:-.pi/2+2 * .pi * remaining/100,clockwise:false); c.strokePath()
        }
    }
}
enum SevenSegment {
    private static let masks = [0x3F, 0x06, 0x5B, 0x4F, 0x66, 0x6D, 0x7D, 0x07, 0x7F, 0x6F]
    private static let segments: [[CGPoint]] = [
        [(1.5,0),(6,0),(6.7,0.7),(6,1.4),(1.5,1.4),(0.8,0.7)],
        [(6.8,1.1),(7.5,1.8),(7.5,5.8),(6.8,6.5),(6.1,5.8),(6.1,1.8)],
        [(6.8,7.5),(7.5,8.2),(7.5,12.2),(6.8,12.9),(6.1,12.2),(6.1,8.2)],
        [(1.5,12.6),(6,12.6),(6.7,13.3),(6,14),(1.5,14),(0.8,13.3)],
        [(0.7,7.5),(1.4,8.2),(1.4,12.2),(0.7,12.9),(0,12.2),(0,8.2)],
        [(0.7,1.1),(1.4,1.8),(1.4,5.8),(0.7,6.5),(0,5.8),(0,1.8)],
        [(1.5,6.3),(6,6.3),(6.7,7),(6,7.7),(1.5,7.7),(0.8,7)]
    ].map { $0.map { CGPoint(x: $0.0, y: $0.1) } }

    static func draw(_ c: CGContext, text:String, in rect:CGRect) {
        let width=text.enumerated().reduce(CGFloat(0)) { $0 + ($1.offset==0 ? 0 : $1.element=="%" ? 4 : 1.5) + ($1.element=="%" ? 6.5 : 7.5) }
        guard width>0 else { return }
        let scale=min(rect.width/width,rect.height/14)
        c.saveGState(); c.translateBy(x:rect.midX-width*scale/2,y:rect.midY-7*scale); c.scaleBy(x:scale,y:scale)
        c.setFillColor(UIColor(argb:0xFFF7FAFF).cgColor); c.setStrokeColor(UIColor(argb:0xFFF7FAFF).cgColor)
        for (i,char) in text.enumerated() {
            if i>0 { c.translateBy(x:char=="%" ? 4 : 1.5,y:0) }
            if char=="%" {
                c.setLineWidth(0.9); c.addPath(Paint.path(Paint.rect(0.5,3,2,2),0.3)); c.addPath(Paint.path(Paint.rect(4,9,2,2),0.3))
                c.move(to:CGPoint(x:0.7,y:11)); c.addLine(to:CGPoint(x:5.8,y:3)); c.strokePath()
            } else {
                let mask=char.wholeNumberValue.flatMap { masks.indices.contains($0) ? masks[$0] : nil } ?? 0x40
                for (bit,points) in segments.enumerated() where mask & (1<<bit) != 0 { c.addLines(between:points); c.closePath(); c.fillPath() }
            }
            c.translateBy(x:char=="%" ? 6.5 : 7.5,y:0)
        }
        c.restoreGState()
    }
}
