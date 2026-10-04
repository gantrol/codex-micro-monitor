import UIKit

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

struct DialActions {
    let step: (Int) -> Void
    let end: (Bool) -> Void
    let tap: () -> Void
}

// Touch/drag and wheel gestures share one captured target. Scroll input never
// produces a click; cancellation never commits an unstarted click.
final class DialInput: NSObject, UIGestureRecognizerDelegate {
    weak var view: UIControl?
    var prepare: (() -> DialActions?)?
    var inspect: (() -> Void)?
    private var actions: DialActions?
    private var tracker = DialGestureTracker()
    private var scrollRemainder: CGFloat = 0
    private var scrollLast = CGPoint.zero
    private var wheelEnd: DispatchWorkItem?
    private var held = false
    private var suppressedTap = false

    init(view: UIControl) {
        self.view = view
        super.init()
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
        scroll.allowedScrollTypesMask = .all
        scroll.allowedTouchTypes = []
        scroll.delegate = self
        view.addGestureRecognizer(scroll)
        let inspect = UILongPressGestureRecognizer(target: self, action: #selector(inspected(_:)))
        inspect.minimumPressDuration = 0.65
        inspect.delegate = self
        view.addGestureRecognizer(inspect)
        let secondary = UITapGestureRecognizer(target: self, action: #selector(secondaryClicked(_:)))
        secondary.buttonMaskRequired = .secondary
        view.addGestureRecognizer(secondary)
    }
    func begin(_ point: CGPoint) {
        cancel()
        held = true; suppressedTap = false; tracker.begin(point); actions = prepare?()
    }
    func move(_ point: CGPoint) {
        guard held else { return }
        let steps = tracker.move(point)
        if steps != 0 { actions?.step(steps) }
    }
    func end(inside: Bool) {
        guard held else { return }
        held = false
        let captured = actions; actions = nil
        captured?.end(false)
        if inside && !tracker.dragging && !suppressedTap { captured?.tap() }
    }
    func cancel() {
        wheelEnd?.cancel(); wheelEnd = nil
        let captured = actions; actions = nil
        held = false; scrollRemainder = 0
        captured?.end(true)
    }
    func activate() -> Bool {
        guard let captured = prepare?() else { return false }
        captured.end(false); captured.tap(); return true
    }
    func adjust(_ step: Int) {
        guard let captured = prepare?() else { return }
        captured.step(step); captured.end(false)
    }
    @objc private func inspected(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, !tracker.dragging else { return }
        suppressedTap = true; cancel(); inspect?()
    }
    @objc private func secondaryClicked(_ gesture: UITapGestureRecognizer) {
        if gesture.state == .ended { cancel(); inspect?() }
    }
    @objc private func scrolled(_ gesture: UIPanGestureRecognizer) {
        guard let view else { return }
        let position = gesture.translation(in: view)
        if gesture.state == .began {
            wheelEnd?.cancel(); wheelEnd = nil
            if held { suppressedTap = true }
            if actions == nil { actions = prepare?() }
            scrollLast = .zero
        }
        if gesture.state == .began || gesture.state == .changed || gesture.state == .ended {
            let delta = position.y - scrollLast.y
            scrollLast = position
            // UIKit supplies point deltas for both wheel and trackpad input.
            scrollRemainder -= delta
            let steps = Int(scrollRemainder / 12)
            scrollRemainder -= CGFloat(steps) * 12
            if steps != 0 { actions?.step(steps) }
        }
        if gesture.state == .cancelled || gesture.state == .failed { cancel() }
        if gesture.state == .ended {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let captured = self.actions; self.actions = nil
                self.scrollRemainder = 0; captured?.end(false)
            }
            wheelEnd = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
        }
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        !(gestureRecognizer is UILongPressGestureRecognizer) || (!tracker.dragging && !suppressedTap)
    }
}
