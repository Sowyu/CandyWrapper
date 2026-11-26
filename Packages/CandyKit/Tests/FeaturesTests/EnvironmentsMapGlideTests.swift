import AppKit
import Testing
import DesignSystem
@testable import Features

/// The map's glide (EnvironmentsMap.tsx:1037, :160): 200 ms ease-out on zoom, fit and a stack opening, ending on
/// the resting view exactly, with nothing running once it ends.
@MainActor
struct EnvironmentsMapGlideTests {
    @Test func easeOutIsTailwinds() {
        #expect(EnvironmentsMapCanvasView.easeOut(0) == 0)
        #expect(EnvironmentsMapCanvasView.easeOut(1) == 1)
        let half = EnvironmentsMapCanvasView.easeOut(0.5)
        #expect(half > 0.75 && half < 0.85)  // cubic-bezier(0, 0, 0.2, 1) at 0.5 is about 0.80
        var last = 0.0
        for i in 1...20 { let v = EnvironmentsMapCanvasView.easeOut(Double(i) / 20); #expect(v >= last); last = v }
    }

    @Test func zoomGlidesAndEndsOnTheRestingView() {
        let canvas = EnvironmentsMapViewTests.make("shared").canvas
        var clock = 100.0
        canvas.now = { clock }
        canvas.reducedMotion = { false }
        let before = canvas.shown
        canvas.zoomGliding(1.25)
        #expect(canvas.glide != nil)
        #expect(canvas.shown == before)
        clock += 0.1
        #expect(canvas.shown != before && canvas.shown != canvas.view)
        clock += 0.15
        canvas.glideFrame()
        #expect(canvas.glide == nil)
        #expect(canvas.shown == canvas.view)
    }

    @Test func reducedMotionJumps() {
        let canvas = EnvironmentsMapViewTests.make("shared").canvas
        canvas.reducedMotion = { true }
        canvas.zoomGliding(1.25)
        #expect(canvas.glide == nil)
        canvas.fitView()
        #expect(canvas.glide == nil && canvas.state.held == nil)
    }

    @Test func aPanStopsTheGlide() {
        let canvas = EnvironmentsMapViewTests.make("shared").canvas
        canvas.reducedMotion = { false }
        canvas.zoomGliding(1.25)
        canvas.zoom(1.1)
        #expect(canvas.glide == nil)
    }

    @Test func anOpenedStackKeepsItsCardInPlace() throws {
        let view = EnvironmentsMapViewTests.make("default")
        let canvas = view.canvas
        canvas.reducedMotion = { false }
        let stack = try #require(canvas.stacks.first { !$0.expanded })
        let face = try #require(canvas.fleetLayout.stacks[stack.id]?.face)
        let before = canvas.toView(face)
        canvas.toggleStack(stack.id)
        #expect(canvas.state.expanded.contains(stack.id))
        #expect(canvas.glide?.stack == stack.id)
        canvas.endGlide()
        let after = try #require(canvas.fleetLayout.stacks[stack.id]?.face)
        let now = canvas.toView(after)
        #expect(abs(now.minX - before.minX) < 0.5 && abs(now.minY - before.minY) < 0.5)
    }
}
