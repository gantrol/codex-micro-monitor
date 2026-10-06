import UIKit
import Accelerate

extension UIColor {
    convenience init(argb: UInt32) {
        self.init(red: CGFloat((argb >> 16) & 255) / 255, green: CGFloat((argb >> 8) & 255) / 255,
                  blue: CGFloat(argb & 255) / 255, alpha: CGFloat(argb >> 24) / 255)
    }
}
struct Stop { let color: UInt32; let at: CGFloat; init(_ color: UInt32, _ at: CGFloat) { self.color = color; self.at = at } }
enum Paint {
    static let paper: UInt32 = 0xFFF7F8F6
    static func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x, y: y, width: w, height: h) }
    static func path(_ r: CGRect, _ radius: CGFloat) -> CGPath {
        CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }
    static func gradient(_ stops: [Stop]) -> CGGradient {
        CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: stops.map { UIColor(argb: $0.color).cgColor } as CFArray, locations: stops.map(\.at))!
    }
    static func shape(_ c: CGContext, _ r: CGRect, _ radius: CGFloat, color: UInt32) {
        c.setFillColor(UIColor(argb: color).cgColor); c.addPath(path(r, radius)); c.fillPath()
    }
    static func fill(_ c: CGContext, _ p: CGPath, color: UInt32) { c.addPath(p); c.setFillColor(UIColor(argb: color).cgColor); c.fillPath() }
    static func shade(_ c: CGContext, _ r: CGRect, _ radius: CGFloat, _ stops: [Stop], diagonal: Bool = false, horizontal: Bool = false, stroke: CGFloat = 0) {
        c.saveGState()
        if stroke > 0 {
            c.addPath(path(r.insetBy(dx: stroke / 2, dy: stroke / 2), max(0, radius - stroke / 2)))
            c.setLineWidth(stroke); c.replacePathWithStrokedPath()
        } else { c.addPath(path(r, radius)) }
        c.clip()
        c.drawLinearGradient(gradient(stops), start: r.origin,
            end: CGPoint(x: diagonal || horizontal ? r.maxX : r.minX, y: horizontal ? r.minY : r.maxY), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        c.restoreGState()
    }
    static func stroke(_ c: CGContext, _ r: CGRect, _ radius: CGFloat, _ color: UInt32, _ width: CGFloat) {
        shade(c, r, radius, [Stop(color, 0), Stop(color, 1)], stroke: width)
    }
    static func insetBorder(_ c: CGContext, _ rect: CGRect, radius: CGFloat, edges: UIEdgeInsets, color: UInt32) {
        // WPF Border.Radii: outer radii add half each edge's thickness;
        // inner radii subtract it. An even-odd fill joins unequal sides
        // continuously instead of cutting a uniform stroke into half-rectangles.
        func outline(_ r: CGRect, outer: Bool) -> CGPath {
            let direction: CGFloat = outer ? 0.5 : -0.5
            let left=max(0,radius+edges.left*direction), right=max(0,radius+edges.right*direction)
            let top=max(0,radius+edges.top*direction), bottom=max(0,radius+edges.bottom*direction)
            let k:CGFloat=0.5522847498307936
            let p=CGMutablePath()
            p.move(to:CGPoint(x:r.minX+left,y:r.minY))
            p.addLine(to:CGPoint(x:r.maxX-right,y:r.minY))
            p.addCurve(to:CGPoint(x:r.maxX,y:r.minY+top),control1:CGPoint(x:r.maxX-right+k*right,y:r.minY),control2:CGPoint(x:r.maxX,y:r.minY+top-k*top))
            p.addLine(to:CGPoint(x:r.maxX,y:r.maxY-bottom))
            p.addCurve(to:CGPoint(x:r.maxX-right,y:r.maxY),control1:CGPoint(x:r.maxX,y:r.maxY-bottom+k*bottom),control2:CGPoint(x:r.maxX-right+k*right,y:r.maxY))
            p.addLine(to:CGPoint(x:r.minX+left,y:r.maxY))
            p.addCurve(to:CGPoint(x:r.minX,y:r.maxY-bottom),control1:CGPoint(x:r.minX+left-k*left,y:r.maxY),control2:CGPoint(x:r.minX,y:r.maxY-bottom+k*bottom))
            p.addLine(to:CGPoint(x:r.minX,y:r.minY+top))
            p.addCurve(to:CGPoint(x:r.minX+left,y:r.minY),control1:CGPoint(x:r.minX,y:r.minY+top-k*top),control2:CGPoint(x:r.minX+left-k*left,y:r.minY))
            p.closeSubpath(); return p
        }
        c.saveGState(); c.setFillColor(UIColor(argb:color).cgColor)
        c.addPath(outline(rect,outer:true)); c.addPath(outline(rect.inset(by:edges),outer:false))
        c.drawPath(using:.eoFill); c.restoreGState()
    }
    static func ellipse(_ c: CGContext, _ r: CGRect, _ color: UInt32) {
        c.setFillColor(UIColor(argb: color).cgColor); c.fillEllipse(in: r)
    }
    static func radial(_ c: CGContext, _ r: CGRect, center: CGPoint, radii: CGSize, stops: [Stop]) {
        c.saveGState(); c.addEllipse(in: r); c.clip()
        c.translateBy(x: r.minX + r.width * center.x, y: r.minY + r.height * center.y)
        c.scaleBy(x: r.width * radii.width, y: r.height * radii.height)
        c.drawRadialGradient(gradient(stops), startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1, options: [.drawsAfterEndLocation]); c.restoreGState()
    }
    static func image(_ size: CGSize, scale: CGFloat, _ draw: (CGContext) -> Void) -> UIImage {
        let f = UIGraphicsImageRendererFormat(); f.scale = scale; f.opaque = false; f.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: f).image { draw($0.cgContext) }
    }
    // WPF CMilBlurEffectDuce::CalculateSamplingWeights: finite Gaussian,
    // sigma=radius/3 and normalized weights. Accelerate performs two passes.
    // Source: dotnet/wpf src/Microsoft.DotNet.Wpf/src/WpfGfx/core/resources/BlurEffect.cpp
    // Rasterization/color-space/device rounding are still subject to visual calibration.
    static func blur(_ image: UIImage, radius: CGFloat) -> UIImage {
        guard radius > 0, let cg = image.cgImage else { return image }
        // WPF truncates the local radius before scaling, then truncates again.
        let r = Int(CGFloat(Int(radius)) * image.scale)
        guard r > 0 else { return image }
        let sigma = Double(r) / 3
        var kernel = (-r...r).map { Float(exp(-Double($0 * $0) / (2 * sigma * sigma))) }
        let total = kernel.reduce(0, +); kernel = kernel.map { $0 / total }
        let w = cg.width, h = cg.height, bytes = w * 4
        let source = UnsafeMutableRawPointer.allocate(byteCount: bytes * h, alignment: 64)
        let dest = UnsafeMutableRawPointer.allocate(byteCount: bytes * h, alignment: 64)
        defer { source.deallocate(); dest.deallocate() }
        // A CGContext backed by caller-owned memory does not clear that memory.
        // Source-over drawing would retain old heap pixels wherever cg is
        // transparent, then convolution would spread them through the halo.
        source.initializeMemory(as: UInt8.self, repeating: 0, count: bytes * h)
        dest.initializeMemory(as: UInt8.self, repeating: 0, count: bytes * h)
        let info = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let input = CGContext(data: source, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bytes, space: colorSpace, bitmapInfo: info) else { return image }
        input.setBlendMode(.copy)
        input.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var a = vImage_Buffer(data: source, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: bytes)
        var b = vImage_Buffer(data: dest, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: bytes)
        let result = kernel.withUnsafeBufferPointer { k in
            vImageSepConvolve_ARGB8888(&a, &b, nil, 0, 0, k.baseAddress!, UInt32(k.count), k.baseAddress!, UInt32(k.count), 0, nil, vImage_Flags(kvImageEdgeExtend))
        }
        guard result == kvImageNoError else { return image }
        // The returned CGImage owns its pixels independently of both scratch buffers.
        let pixels = Data(bytes: dest, count: bytes * h)
        guard let provider = CGDataProvider(data: pixels as CFData),
              let value = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                  bytesPerRow: bytes, space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: info),
                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return image }
        return UIImage(cgImage: value, scale: image.scale, orientation: .up)
    }
    static func effect(_ c: CGContext, box: CGRect, radius: CGFloat, scale: CGFloat, opacity: CGFloat = 1, draw: (CGContext) -> Void) {
        guard opacity > 0 else { return }
        let pad = ceil(radius + 2), size = CGSize(width: box.width + pad * 2, height: box.height + pad * 2)
        let raw = image(size, scale: scale) { inner in inner.translateBy(x: pad - box.minX, y: pad - box.minY); draw(inner) }
        c.saveGState(); c.setAlpha(opacity)
        if let image = blur(raw, radius: radius).cgImage {
            // Draw into this context explicitly, preserving the requested alpha.
            c.translateBy(x: box.minX - pad, y: box.minY - pad + size.height)
            c.scaleBy(x: 1, y: -1)
            c.draw(image, in: CGRect(origin: .zero, size: size))
        }
        c.restoreGState()
    }
    static func glyph(_ c: CGContext, _ name: String, in rect: CGRect, color: UInt32 = 0xFF171717, reasoningPosition: CGFloat? = nil) {
        guard let transform = KeycapGlyph.transform(name, in: rect) else { return }
        c.saveGState(); c.concatenate(transform)
        if ReasoningGlyph.names.contains(name) {
            ReasoningGlyph.draw(c, name: name, position: reasoningPosition ?? ReasoningGlyph.rest(name))
        } else {
            c.setFillColor(UIColor(argb: color).cgColor)
            if let path=KeycapGlyph.presetPaths[name] {c.addPath(path);c.fillPath()}
            else if KeySlots.emptyIcons.contains(name) {c.addPath(KeycapGlyph.emptyPath);c.fillPath()}
            else if name == "BRANCH" {c.addPath(KeycapGlyph.branchPath);c.fillPath()}
            else {for layer in MicroArtwork.layers[name] ?? [] { c.addPath(layer.path); c.drawPath(using: layer.evenOdd ? .eoFill : .fill) }}
        }
        c.restoreGState()
    }
}

struct LightState: Equatable {
    let signal: TaskSignal; let selected: Bool
    var active: Bool { ![.unknown, .idle].contains(signal) }
    var neutral: Bool { selected && !active }
    var color: UInt32 {
        if neutral { return 0xFFFFFFFF }
        switch signal {
        case .running: return 0xFF304FFE
        case .waiting: return 0xFFFF6D00
        case .question: return 0xFFFFD54F
        case .unread: return 0xFF00FF4C
        case .error: return 0xFFFF0033
        default: return 0x008DB5FF
        }
    }
    var display: CGFloat { active ? (selected ? 1 : 0.94) : (selected ? 1 : 0) }
    var wide: CGFloat { neutral ? 0.96 : active ? (selected ? 0.82 : 0.42) : 0 }
    var near: CGFloat { neutral ? 0.68 : active ? (selected ? 0.48 : 0.22) : 0 }
    var wash: CGFloat { neutral ? 0.18 : active ? (selected ? 0.28 : 0.12) : 0 }
    var field: CGFloat { selected ? 0.52 : active ? 0.43 : 0 }
    var well: CGFloat { neutral ? 0.38 : active ? (selected ? 0.48 : 0.40) : 0 }
}

@MainActor enum KeyArt {
    static let cache = NSCache<NSString, UIImage>()
    static let pad: CGFloat = 36
    static func image(_ key: String, width: CGFloat = 96, scale: CGFloat, draw: (CGContext) -> Void) -> UIImage {
        let id = "\(key):\(width):\(scale)" as NSString
        if let cached = cache.object(forKey: id) { return cached }
        let image = Paint.image(CGSize(width: width + pad * 2, height: 96 + pad * 2), scale: scale) { c in
            c.translateBy(x: pad, y: pad); draw(c)
        }
        cache.totalCostLimit = 64 * 1024 * 1024
        cache.setObject(image, forKey: id, cost: (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0))
        return image
    }
    static func halo(_ light: LightState, near: Bool, scale: CGFloat) -> UIImage {
        image("halo:\(near):\(light.signal):\(light.selected)", scale: scale) { c in
            let size:CGFloat = near ? 100 : 106, corner:CGFloat = near ? 18 : 21
            let r = Paint.rect(48-size/2,48-size/2,size,size)
            Paint.effect(c, box: r, radius: near ? 16 : 28, scale: scale, opacity: (near ? light.near : light.wide) * (light.neutral ? 1 : light.display)) { Paint.shape($0,r,corner,color:light.color) }
        }
    }
    static func far(task: Bool, white: Bool, width: CGFloat, scale: CGFloat) -> UIImage {
        image("far:\(task):\(white)", width: width, scale: scale) { c in
            let r = task ? Paint.rect(2,5,92,92) : Paint.rect(2.5,4.5,width-5,91)
            Paint.effect(c, box: r, radius: 8, scale: scale) { Paint.shape($0,r,14,color: task ? (white ? 0x093A403D : 0x243A403D) : 0x33363C39) }
        }
    }
    static func seam(_ light: LightState, scale: CGFloat) -> UIImage {
        image("seam:\(light.neutral)", scale: scale) { c in
            if light.neutral { let r = Paint.rect(-1,-1,98,98); Paint.effect(c,box:r,radius:5,scale:scale) { Paint.stroke($0,r,15,0x756EF0B0,1.6) } }
        }
    }
    static func cap(task: Bool, width: CGFloat, light: LightState, hover: Bool, scale: CGFloat) -> UIImage {
        image("cap:\(task):\(light.signal):\(light.selected):\(hover)", width: width, scale: scale) { c in
            let r = task ? Paint.rect(0,0,96,96) : Paint.rect(0.5,0.5,width-1,93.5)
            let shadow = r.offsetBy(dx: 0, dy: task ? 2 : 1)
            Paint.effect(c,box:shadow,radius:task ? 3 : 2,scale:scale,opacity:task ? (light.neutral ? 0.05 : 0.20) : 0.12) {
                Paint.shape($0,shadow,14,color:task ? 0xFF3A403D : 0xFF5F6662)
            }
            Paint.shape(c,r,14,color:Paint.paper)
            Paint.stroke(c,r,14,hover ? (task ? 0xF7FFFFFF : 0xFFFFFFFF) : (task ? 0x99FFFFFF : 0xF2FFFFFF),1)
            let inner = r.insetBy(dx: 1, dy: 1)
            if task {
                let wash = inner.insetBy(dx: 4, dy: 4)
                Paint.effect(c,box:wash,radius:6.5,scale:scale,opacity:light.wash * light.display) { Paint.shape($0,wash,10,color:light.color) }
                if light.neutral {
                    let ret = inner.insetBy(dx: 2, dy: 2)
                    Paint.effect(c,box:ret,radius:1.8,scale:scale) { Paint.shade($0,ret,11,[Stop(0x008CECB4,0),Stop(0x128CECB4,0.42),Stop(0x668CECB4,1)],diagonal:true,stroke:1.5) }
                }
            }
            // Directional inset borders, not a generic outer drop shadow.
            c.saveGState(); c.setAlpha(task && light.neutral ? 0.25 : 1)
            let dark = Paint.rect(inner.minX+1,inner.minY+1,inner.width-1,inner.height-1)
            let thickness:CGFloat=task ? 2 : 1.5
            Paint.insetBorder(c,dark,radius:13,edges:UIEdgeInsets(top:0,left:0,bottom:thickness,right:thickness),color:task ? 0x334E5451 : 0x295F6662)
            c.restoreGState()
            let bright = Paint.rect(inner.minX,inner.minY,inner.width-1,inner.height-1)
            Paint.insetBorder(c,bright,radius:13,edges:UIEdgeInsets(top:thickness,left:thickness,bottom:0,right:0),color:task ? 0xB8FFFFFF : 0xF2FFFFFF)
            let wellW: CGFloat = width > 100 ? 160 : 76
            let well = Paint.rect(r.midX-wellW/2,r.midY-38,wellW,76)
            if task {
                let field = Paint.rect(7,7,82,82)
                Paint.effect(c,box:field,radius:5.5,scale:scale,opacity:light.field * light.display) { Paint.ellipse($0,field,light.color) }
                if light.neutral { let ring = Paint.rect(7.5,7.5,81,81); Paint.effect(c,box:ring,radius:3.2,scale:scale) { Paint.stroke($0,ring,40.5,0x6874E7AD,3) } }
            }
            Paint.shape(c,well,38,color:Paint.paper)
            if task {
                if light.neutral { Paint.radial(c,well,center:CGPoint(x:0.46,y:0.4),radii:CGSize(width:0.54,height:0.57),stops:[Stop(0x00FAFFFC,0),Stop(0x08C8FBDD,0.4),Stop(0x2698EDC1,0.74),Stop(0x4481E9B2,1)]) }
                c.saveGState(); c.setAlpha(light.well * light.display); Paint.ellipse(c,well,light.color); c.restoreGState()
            }
            c.saveGState(); c.setAlpha(hover && task ? 0.86 : 1)
            Paint.shade(c,well,38,[Stop(task && light.neutral ? 0x0A747B77 : 0x28747B77,0),Stop(task && light.neutral ? 0x05747B77 : 0x14747B77,0.42),Stop(0x8CFFFFFF,0.58),Stop(0xCCFFFFFF,1)],diagonal:true,stroke:1.6)
            c.restoreGState()
            if task {
                let dot = Paint.rect(39,39,18,18), color: UInt32 = light.neutral ? 0xFFB9EFD2 : 0xFF685FAE
                c.saveGState(); c.setAlpha(light.neutral ? 1 : 0.6)
                Paint.effect(c,box:dot,radius:4,scale:scale,opacity:0.38 * (light.neutral ? 1 : 0.6)) { Paint.ellipse($0,dot,color) }
                Paint.ellipse(c,dot,color)
                if light.neutral { Paint.stroke(c,dot,9,0x28939A96,0.8) }
                c.restoreGState()
            }
        }
    }
}
