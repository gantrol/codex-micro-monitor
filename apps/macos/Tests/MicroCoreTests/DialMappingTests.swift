import XCTest
@testable import MicroPanelModel

final class DialMappingTests:XCTestCase {
    func testWindowsDragVectorsMatchAndLockTheirInitialAxis() {
        var dial=DialGestureTracker()
        dial.begin(.zero)
        XCTAssertEqual(dial.move(.init(x:5,y:0)),0);XCTAssertFalse(dial.dragging)
        XCTAssertEqual(dial.move(.init(x:18,y:0)),1);XCTAssertTrue(dial.dragging)
        XCTAssertEqual(dial.move(.init(x:30,y:100)),1) // vertical jitter cannot switch axis
        dial.begin(.zero)
        XCTAssertEqual(dial.move(.init(x:0,y:-18)),1)
        XCTAssertEqual(dial.move(.init(x:0,y:6)),-2)
    }
    func testTrackpadFractionalDeltasAccumulateAndReverseWithoutPhantomSteps() {
        var wheel=DialScrollAccumulator()
        XCTAssertEqual([-3.0,-4,-5].map { wheel.add(vertical:$0) },[0,0,1])
        XCTAssertEqual(wheel.add(vertical:6),0)
        XCTAssertEqual(wheel.add(vertical:-6),0)
        XCTAssertEqual(wheel.add(vertical:24),-2)
        wheel.reset();XCTAssertEqual(wheel.add(vertical:Double.nan),0)
        XCTAssertEqual(wheel.add(vertical:Double.infinity),0)
        XCTAssertEqual(wheel.add(vertical:-12),1)
    }
    func testWindowsDirectionMappingAndUserInversionApplyToBothDialModes() {
        XCTAssertEqual(DialMapping.reasoning(1,inverted:false),-1)
        XCTAssertEqual(DialMapping.reasoning(-1,inverted:false),1)
        XCTAssertEqual(DialMapping.reasoning(1,inverted:true),1)
        XCTAssertTrue(DialMapping.forward(1,inverted:false))
        XCTAssertFalse(DialMapping.forward(1,inverted:true))
        XCTAssertEqual(DialMapping.reasoning(Int.min,inverted:false),64)
    }
}
