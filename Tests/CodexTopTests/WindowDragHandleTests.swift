import AppKit
import XCTest
import SwiftUI
@testable import CodexTop

final class WindowDragHandleTests: XCTestCase {
    @MainActor
    func testDesktopPointsStayStableWhenTheViewMovesAndEventIsRepeated() async throws {
        let view = NativeWindowDragView(frame: CGRect(x: 2200, y: 200, width: 308, height: 36))
        var points: [CGPoint] = []
        view.started = { points.append($0) }
        view.moved = { point in
            points.append(point)
            view.frame.origin.x -= 500
        }
        let down = try event(.leftMouseDown, at: CGPoint(x: 2300, y: 400))
        let cross = try event(.leftMouseDragged, at: CGPoint(x: 1300, y: 400))
        view.mouseDown(with: down)
        view.mouseDragged(with: cross)
        view.mouseDragged(with: cross)
        XCTAssertEqual(points.count, 3)
        XCTAssertEqual(points[0].x - points[1].x, 1000)
        XCTAssertEqual(points[0].y, points[1].y)
        XCTAssertEqual(points[1], points[2])
    }

    @MainActor
    func testMouseUpDeliversFinalPositionAndStopsTheDrag() async throws {
        let view = NativeWindowDragView()
        var phases: [String] = []
        var endPoint: CGPoint?
        var lastMove: CGPoint?
        view.started = { _ in phases.append("start") }
        view.moved = { phases.append("move"); lastMove = $0 }
        view.ended = { phases.append("end"); endPoint = $0 }
        view.mouseDragged(with: try event(.leftMouseDragged, at: .zero))
        view.mouseDown(with: try event(.leftMouseDown, at: CGPoint(x: 100, y: 200)))
        view.mouseUp(with: try event(.leftMouseUp, at: CGPoint(x: 140, y: 230)))
        view.mouseDragged(with: try event(.leftMouseDragged, at: .zero))
        view.mouseUp(with: try event(.leftMouseUp, at: .zero))
        XCTAssertEqual(phases, ["start", "move", "end"])
        XCTAssertEqual(endPoint, lastMove)
        XCTAssertEqual(endPoint?.x, 140)
    }

    @MainActor
    func testHeaderButtonsAndHiddenOrbDoNotInterceptInput() async {
        let parent = NSView(frame: CGRect(x: 0, y: 0, width: 410, height: 48))
        let view = NativeWindowDragView(frame: parent.bounds)
        parent.addSubview(view)
        view.excludedFrames = [CGRect(x: 320, y: 8, width: 28, height: 30),
                               CGRect(x: 352, y: 8, width: 28, height: 30)]
        func hit(_ x: CGFloat, _ y: CGFloat) -> NSView? {
            view.hitTest(view.convert(CGPoint(x: x, y: y), to: parent))
        }
        XCTAssertTrue(hit(100, 20) === view)
        XCTAssertNil(hit(330, 20))
        XCTAssertNil(hit(365, 20))
        XCTAssertNil(hit(-1, 20))
        view.enabled = false
        XCTAssertNil(hit(100, 20))
    }

    @MainActor
    func testScaledNativeHeaderKeepsButtonHoles() async throws {
        let root = WindowDragHandle(started: { _ in }, moved: { _ in }, ended: { _ in },
            excludedFrames: [CGRect(x: 320, y: 8, width: 28, height: 30)])
            .frame(width: 410, height: 48)
            .scaleEffect(0.75, anchor: .topLeading)
            .frame(width: 307.5, height: 36, alignment: .topLeading)
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 308, height: 36),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        func native(in view: NSView) -> NativeWindowDragView? {
            if let result = view as? NativeWindowDragView { return result }
            return view.subviews.compactMap { native(in: $0) }.first
        }
        let view = try XCTUnwrap(native(in: hosting))
        let parentPoint = view.superview!.convert(CGPoint(x: 330 * 0.75, y: 20 * 0.75), from: hosting)
        XCTAssertNil(view.hitTest(parentPoint), "Scaled button must pass through the drag overlay; bounds=\(view.bounds)")
        window.close()
    }

    @MainActor
    private func event(_ type: CGEventType, at point: CGPoint) throws -> NSEvent {
        // Construct only; never post synthetic events to the desktop.
        let cg = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: type,
                                      mouseCursorPosition: point, mouseButton: .left))
        return try XCTUnwrap(NSEvent(cgEvent: cg))
    }
}
