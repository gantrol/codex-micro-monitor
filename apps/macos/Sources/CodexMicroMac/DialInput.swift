import UIKit

// macOS secondary click includes Control-click as well as a mouse's secondary
// button and the trackpad's configured secondary tap.
final class SecondaryClickGesture: UITapGestureRecognizer {
    private let controlClick:Bool
    init(target:Any?,action:Selector?,controlClick:Bool) {
        self.controlClick=controlClick
        super.init(target:target,action:action)
        buttonMaskRequired=controlClick ? .primary : .secondary
    }
    override func shouldReceive(_ event:UIEvent) -> Bool {
        super.shouldReceive(event) && (!controlClick || event.modifierFlags.contains(.control))
    }
    static func matches(_ event:UIEvent?) -> Bool {
        guard let event else {return false}
        return event.buttonMask.contains(.secondary) || (event.buttonMask.contains(.primary) && event.modifierFlags.contains(.control))
    }
    static func install(on view:UIView,target:Any,action:Selector,delegate:UIGestureRecognizerDelegate? = nil) {
        for controlClick in [false,true] {
            let gesture=SecondaryClickGesture(target:target,action:action,controlClick:controlClick)
            gesture.delegate=delegate;view.addGestureRecognizer(gesture)
        }
    }
}

// Touch/drag and wheel gestures share one captured target. Scroll input never
// produces a click; cancellation never commits an unstarted click.
final class DialInput: NSObject, UIGestureRecognizerDelegate {
    weak var view: UIControl?
    var prepare: (() -> DialActions?)?
    var inspect: (() -> Void)?
    var longPress: (() -> Void)?
    var interaction: ((Bool) -> Void)?
    private var actions: DialActions?
    private var tracker = DialGestureTracker()
    private var scroll = DialScrollAccumulator()
    private var scrollLast = CGPoint.zero
    private var wheelEnd: DispatchWorkItem?
    private var held = false
    private var suppressedTap = false
    private var scrolling = false

    init(view: UIControl) {
        self.view = view
        super.init()
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
        scroll.allowedScrollTypesMask = .all
        scroll.allowedTouchTypes = []
        scroll.cancelsTouchesInView = false
        scroll.delegate = self
        view.addGestureRecognizer(scroll)
        let inspect = UILongPressGestureRecognizer(target: self, action: #selector(inspected(_:)))
        inspect.minimumPressDuration = 0.65
        inspect.cancelsTouchesInView = false
        inspect.delegate = self
        view.addGestureRecognizer(inspect)
        SecondaryClickGesture.install(on:view,target:self,action:#selector(secondaryClicked(_:)))
    }
    func begin(_ point: CGPoint) {
        cancel()
        held = true; suppressedTap = false; tracker.begin(point); actions = prepare?();interaction?(true)
    }
    func move(_ point: CGPoint) {
        guard held,!scrolling else { return }
        let steps = tracker.move(point)
        if steps != 0 { actions?.step(steps) }
    }
    func end(inside: Bool) {
        guard held else { return }
        held = false
        guard !scrolling else { return }
        let captured = actions; actions = nil
        captured?.end(false)
        if inside && !tracker.dragging && !suppressedTap { captured?.tap() }
        interaction?(false)
    }
    func cancel() {
        wheelEnd?.cancel(); wheelEnd = nil
        let captured = actions; actions = nil
        held = false; scrolling=false;scroll.reset();view?.isHighlighted=false
        captured?.end(true)
        interaction?(false)
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
        suppressedTap = true; cancel(); (longPress ?? inspect)?()
    }
    @objc private func secondaryClicked(_ gesture: UITapGestureRecognizer) {
        if gesture.state == .ended { cancel(); inspect?() }
    }
    @objc private func scrolled(_ gesture: UIPanGestureRecognizer) {
        guard let view else { return }
        let position = gesture.translation(in: view)
        if gesture.state == .began {
            beginScroll()
            scrollLast = .zero
        }
        if gesture.state == .began || gesture.state == .changed || gesture.state == .ended {
            let delta = CGPoint(x:position.x-scrollLast.x,y:position.y-scrollLast.y)
            scrollLast = position
            // UIKit supplies point deltas for both wheel and trackpad input.
            let steps = scroll.add(horizontal:delta.x,vertical:delta.y)
            if steps != 0 { actions?.step(steps) }
        }
        if gesture.state == .cancelled || gesture.state == .failed { cancel() }
        if gesture.state == .ended { finishScrollSoon() }
    }
    func nativeScroll(dx:CGFloat,dy:CGFloat,precise:Bool,phase:String) {
        if phase == "cancel" { cancel();return }
        if phase == "begin",scrolling { finishScroll() }
        if phase == "end" {
            guard scrolling else { return }
        } else { beginScroll() }
        let steps=scroll.add(horizontal:dx,vertical:dy,precise:precise)
        if steps != 0 { actions?.step(steps) }
        if phase == "end" || phase == "wheel" { finishScrollSoon() }
    }
    private func beginScroll() {
        wheelEnd?.cancel();wheelEnd=nil
        if held { suppressedTap=true }
        guard !scrolling else { return }
        scrolling=true;scroll.reset()
        if actions == nil { actions=prepare?() }
        interaction?(true)
    }
    private func finishScrollSoon() {
        wheelEnd?.cancel()
        let work=DispatchWorkItem { [weak self] in self?.finishScroll() }
        wheelEnd=work
        DispatchQueue.main.asyncAfter(deadline:.now()+0.18,execute:work)
    }
    private func finishScroll() {
        wheelEnd?.cancel();wheelEnd=nil
        let captured=actions;actions=nil;scrolling=false;scroll.reset()
        captured?.end(false);interaction?(false)
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        !(gestureRecognizer is UILongPressGestureRecognizer) || (held && !tracker.dragging && !suppressedTap && !scrolling)
    }
    func gestureRecognizer(_ gestureRecognizer:UIGestureRecognizer,shouldReceive event:UIEvent) -> Bool {
        !(gestureRecognizer is UILongPressGestureRecognizer) || !SecondaryClickGesture.matches(event)
    }
}
