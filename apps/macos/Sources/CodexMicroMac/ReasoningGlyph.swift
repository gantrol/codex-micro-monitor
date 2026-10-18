import UIKit

/// Mirrors Windows KeycapIcon.DrawReasoningSlider, including the hover range.
enum ReasoningGlyph {
    static let names: Set<String> = ["MIND+", "MIND-"]
    static let maxBoundaryColor: UInt32 = 0xFFBE4238
    static let minBoundaryColor: UInt32 = 0xFF2F7D46
    // Fixed across both signs and all thumb positions so the icon never jumps.
    static let bounds = CGRect(x: 0.45, y: 1.3, width: 19.1, height: 14.8)
    static func rest(_ name: String) -> CGFloat { name == "MIND+" ? 2 / 3 : 1 / 3 }

    static func draw(_ c: CGContext, name: String, position: CGFloat, feedbackColor: UInt32? = nil) {
        let position = max(0, min(1, position)), highest = position >= 1
        let fill: UInt32 = feedbackColor ?? (highest ? 0xFF9858EF : 0xFF3978F6)
        let track: UInt32 = feedbackColor.map { ($0 & 0x00FFFFFF) | 0x29000000 } ?? (highest ? 0xFFE4DEF5 : 0xFFDFEAFE)
        let stroke: UInt32 = feedbackColor ?? (highest ? 0xFFDDD8E9 : 0xFFCEDAF2)
        let thumb = 4 + 12 * position
        Paint.shape(c, Paint.rect(1, 9, 18, 6), 3, color: track)
        Paint.shape(c, Paint.rect(1, 9, thumb, 6), 3, color: fill)
        Paint.ellipse(c, Paint.rect(thumb - 3.5, 9.1, 7, 7), 0x201E283C)
        Paint.ellipse(c, Paint.rect(thumb - 3.3, 8.7, 6.6, 6.6), 0xFFFFFFFF)
        c.setStrokeColor(UIColor(argb: stroke).cgColor)
        c.setLineWidth(0.5); c.strokeEllipse(in: Paint.rect(thumb - 3.3, 8.7, 6.6, 6.6))
        c.setStrokeColor(UIColor(argb: fill).cgColor); c.setLineWidth(1.4); c.setLineCap(.round)
        c.move(to: CGPoint(x: 8, y: 4)); c.addLine(to: CGPoint(x: 12, y: 4))
        if name == "MIND+" { c.move(to: CGPoint(x: 10, y: 2)); c.addLine(to: CGPoint(x: 10, y: 6)) }
        c.strokePath()
    }
}
