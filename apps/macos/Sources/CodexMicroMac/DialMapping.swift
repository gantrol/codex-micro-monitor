import Foundation
import CoreGraphics

// Windows DialGestureTracker: right/up is clockwise, dominant axis is locked
// after six design points, one detent is twelve design points.
struct DialGestureTracker {
    private var origin = CGPoint.zero
    private var previous: CGFloat = 0
    private var remainder: CGFloat = 0
    private var horizontal = false
    private(set) var dragging = false

    mutating func begin(_ point: CGPoint) {
        origin = point; previous = 0; remainder = 0; dragging = false
    }
    mutating func move(_ point: CGPoint) -> Int {
        if !dragging {
            let dx = point.x - origin.x, dy = point.y - origin.y
            guard hypot(dx, dy) >= 6 else { return 0 }
            dragging = true; horizontal = abs(dx) > abs(dy)
            let movement = horizontal ? dx : dy
            previous = (horizontal ? origin.x : origin.y) + (movement < 0 ? -6 : 6)
        }
        let position = horizontal ? point.x : point.y
        remainder += horizontal ? position - previous : previous - position
        previous = position
        let steps = Int(remainder / 12)
        remainder -= CGFloat(steps) * 12
        return steps
    }
}

/// UIKit reports point deltas rather than WPF's wheel units. Accumulate
/// fractional trackpad motion without turning a scroll into a click.
struct DialScrollAccumulator {
    private var remainder:CGFloat=0
    private var horizontal:Bool?
    private var pending = CGPoint.zero
    mutating func add(horizontal dx:CGFloat, vertical dy:CGFloat, precise:Bool = true) -> Int {
        guard dx.isFinite,dy.isFinite else { return 0 }
        if !precise {
            // Mouse wheels report lines, not points. One line is one detent.
            let movement=abs(dx)>abs(dy) ? dx : -dy
            remainder += max(-64,min(64,movement))
            let steps=Int(remainder);remainder -= CGFloat(steps)
            return steps
        }
        if horizontal == nil {
            pending.x += dx;pending.y += dy
            guard max(abs(pending.x),abs(pending.y)) >= 2 else { return 0 }
            horizontal=abs(pending.x)>abs(pending.y)
            let movement=horizontal == true ? -pending.x : pending.y
            pending = .zero
            return add(vertical:movement)
        }
        return add(vertical:horizontal == true ? -dx : dy)
    }
    mutating func add(vertical:CGFloat) -> Int {
        guard vertical.isFinite else { return 0 }
        remainder -= max(-768,min(768,vertical))
        let steps=Int(remainder/12)
        remainder -= CGFloat(steps)*12
        return steps
    }
    mutating func reset() { remainder=0;horizontal=nil;pending = .zero }
}

enum DialMapping {
    // Windows DialDirectionSettings: reported clockwise lowers reasoning.
    static func reasoning(_ physical:Int,inverted:Bool) -> Int {
        let bounded=max(-64,min(64,physical))
        return inverted ? bounded : -bounded
    }
    static func forward(_ physical:Int,inverted:Bool) -> Bool { inverted ? physical < 0 : physical > 0 }
}
