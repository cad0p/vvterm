import XCTest
@testable import VVTerm

final class TerminalSplitNodeTests: XCTestCase {
    func testAllPaneIdsPreservesLeafOrder() {
        let left = UUID()
        let right = UUID()
        let node = TerminalSplitNode.split(.init(
            direction: .horizontal,
            ratio: 0.5,
            left: .leaf(paneId: left),
            right: .leaf(paneId: right)
        ))

        XCTAssertEqual(node.allPaneIds(), [left, right])
        XCTAssertEqual(node.leafCount, 2)
        XCTAssertTrue(node.isSplit)
    }

    func testRemovingPaneCollapsesSingleChild() {
        let left = UUID()
        let right = UUID()
        let node = TerminalSplitNode.split(.init(
            direction: .vertical,
            ratio: 0.4,
            left: .leaf(paneId: left),
            right: .leaf(paneId: right)
        ))

        let collapsed = node.removingPane(left)

        XCTAssertEqual(collapsed, .leaf(paneId: right))
    }

    func testEqualizedUsesRelativeLeafWeightsForMatchingDirection() {
        let a = UUID()
        let b = UUID()
        let c = UUID()

        let node = TerminalSplitNode.split(.init(
            direction: .horizontal,
            ratio: 0.2,
            left: .split(.init(
                direction: .horizontal,
                ratio: 0.5,
                left: .leaf(paneId: a),
                right: .leaf(paneId: b)
            )),
            right: .leaf(paneId: c)
        ))

        guard case .split(let split) = node.equalized() else {
            return XCTFail("Expected split node")
        }

        XCTAssertEqual(split.ratio, 2.0 / 3.0, accuracy: 0.0001)
    }
}
