import CoreGraphics
import CoreText
import Foundation

/// Artwork viewboxes have different internal padding. Size and center the ink,
/// preserving its aspect ratio; the keycap's hit area is independent of this.
enum KeycapGlyph {
    // Match the Windows 28-point icon frame. The ink remains proportional to
    // the 96-point key at every window scale; hit targets never shrink to ink.
    static let nominalSide: CGFloat = 28
    static let visibleSide: CGFloat = 24

    // Windows enlarges the shallow reasoning slider to match other keycaps' weight.
    static func opticalScale(_ name: String) -> CGFloat {
        if ReasoningGlyph.names.contains(name) {return 1.35}
        return KeySlots.emptyIcons.contains(name) ? 0.55:1
    }
    static func side(at designScale: CGFloat, name: String = "") -> CGFloat { nominalSide * opticalScale(name) }

    // Windows draws empty caps directly; they have no exported artwork layer.
    static let emptyPath=CGPath(roundedRect:CGRect(x:6,y:6,width:8,height:8),cornerWidth:1.5,cornerHeight:1.5,transform:nil)
        .copy(strokingWithWidth:1.35,lineCap:.round,lineJoin:.round,miterLimit:10)
    // The exported BRANCH artwork contains two open paths without stroke or
    // node circles. Use Windows KeycapIcon.DrawBranch's complete vector here.
    static let branchPath:CGPath = {
        let path=CGMutablePath()
        for center in [CGPoint(x:5.3,y:4.2),CGPoint(x:5.3,y:15.8),CGPoint(x:14.7,y:4.2)] {
            path.addEllipse(in:CGRect(x:center.x-1.8,y:center.y-1.8,width:3.6,height:3.6))
        }
        path.move(to:CGPoint(x:5.3,y:6));path.addLine(to:CGPoint(x:5.3,y:14))
        path.move(to:CGPoint(x:5.3,y:10))
        path.addCurve(to:CGPoint(x:14.7,y:6),control1:CGPoint(x:5.3,y:7),control2:CGPoint(x:14.7,y:9))
        return path.copy(strokingWithWidth:1.35,lineCap:.round,lineJoin:.round,miterLimit:10)
    }()
    static let presetPaths:[String:CGPath] = Dictionary(uniqueKeysWithValues:ComposerTextPreset.allCases.map { preset in
        let font=CTFontCreateWithName("Menlo-Bold" as CFString,16,nil)
        let line=CTLineCreateWithAttributedString(NSAttributedString(string:preset.text,
            attributes:[NSAttributedString.Key(kCTFontAttributeName as String):font]))
        let path=CGMutablePath()
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let count=CTRunGetGlyphCount(run)
            var glyphs=[CGGlyph](repeating:0,count:count),positions=[CGPoint](repeating:.zero,count:count)
            CTRunGetGlyphs(run,CFRange(location:0,length:0),&glyphs)
            CTRunGetPositions(run,CFRange(location:0,length:0),&positions)
            for i in 0..<count {
                if let glyph=CTFontCreatePathForGlyph(font,glyphs[i],nil) {
                    path.addPath(glyph,transform:CGAffineTransform(a:1,b:0,c:0,d:-1,tx:positions[i].x,ty:-positions[i].y))
                }
            }
        }
        return (preset.rawValue,path)
    })
    static let bounds: [String: CGRect] = MicroArtwork.layers.mapValues { layers in
        layers.reduce(CGRect.null) { $0.union($1.path.boundingBoxOfPath) }
    }.merging(Dictionary(uniqueKeysWithValues: ReasoningGlyph.names.map { ($0, ReasoningGlyph.bounds) })) { _, value in value }
        .merging(presetPaths.mapValues(\.boundingBoxOfPath)) { _,value in value }
        .merging(["BRANCH":branchPath.boundingBoxOfPath]) { _,value in value }
        .merging(Dictionary(uniqueKeysWithValues:KeySlots.emptyIcons.map { ($0,emptyPath.boundingBoxOfPath) })) { _,value in value }
    static var names: Set<String> { Set(bounds.keys) }

    static func transform(_ name: String, in rect: CGRect) -> CGAffineTransform? {
        guard let ink = bounds[name], !ink.isNull, ink.width > 0, ink.height > 0,
              rect.width > 0, rect.height > 0 else { return nil }
        // Normalize source padding first; the caller supplies any intentional
        // optical enlargement through the frame size.
        let scale = min(rect.width, rect.height) * visibleSide / nominalSide / max(ink.width, ink.height)
        return CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
            tx: rect.midX - ink.midX * scale, ty: rect.midY - ink.midY * scale)
    }
}
