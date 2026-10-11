import AppKit
import SceneKit

/// Procedural Android shell from phoneScene.ts:29-153 and shapeProfile.ts:83-112.
/// SceneKit renders only after a frame, resize or input; no playback or display-link loop.
public final class DeviceThreeDView: SCNView {
    public var onTouch: ((String, Double, Double) -> Void)?
    public var onKey: ((UInt16, String?, Bool) -> Void)?
    private let phone = SCNNode()
    private let display = SCNNode()
    private let cameraNode = SCNNode()
    private var aspect: CGFloat = 0
    private var lastPoint = NSPoint.zero
    private var lastTouch: CGPoint?
    private var orbiting = false
    public override var acceptsFirstResponder: Bool { true }
    public override init(frame: NSRect, options: [String: Any]? = nil) {
        super.init(frame: frame, options: options)
        scene = SCNScene(); backgroundColor = .clear
        rendersContinuously = false; isPlaying = false
        antialiasingMode = .multisampling4X
        autoenablesDefaultLighting = false
        scene?.rootNode.addChildNode(phone)
        cameraNode.camera = SCNCamera(); cameraNode.camera?.fieldOfView = 32
        cameraNode.position = SCNVector3(0, 0, 5)
        scene?.rootNode.addChildNode(cameraNode); pointOfView = cameraNode
        for (position, intensity) in [(SCNVector3(-3, 4, 5), CGFloat(900)), (SCNVector3(3, 1, -3), CGFloat(600))] {
            let light = SCNNode(); light.light = SCNLight(); light.light?.type = .omni
            light.light?.intensity = intensity; light.position = position
            scene?.rootNode.addChildNode(light)
        }
        let ambient = SCNNode(); ambient.light = SCNLight(); ambient.light?.type = .ambient
        ambient.light?.intensity = 250; scene?.rootNode.addChildNode(ambient)
        setAccessibilityLabel("Interactive 3D device. Drag the screen to interact. Drag outside it or swipe with two fingers to turn.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func material(_ color: NSColor, metal: CGFloat = 0) -> SCNMaterial {
        let value = SCNMaterial(); value.diffuse.contents = color
        value.lightingModel = .physicallyBased; value.metalness.contents = metal; value.roughness.contents = 0.27
        return value
    }
    public func present(_ image: CGImage) {
        let next = CGFloat(image.width) / CGFloat(image.height)
        if next != aspect { build(aspect: next) }
        display.geometry?.firstMaterial?.diffuse.contents = image
        needsDisplay = true
    }
    // ponytail: procedural Android family shell; port named model meshes and Duo hinges when native assets are available.
    private func build(aspect: CGFloat) {
        self.aspect = aspect
        phone.childNodes.forEach { $0.removeFromParentNode() }
        let tablet = min(aspect, 1 / aspect) >= 0.6
        let bezel: CGFloat = tablet ? 0.065 : 0.035
        let depth: CGFloat = tablet ? 0.055 : 0.085
        let width = 2.2 * aspect
        let body = SCNBox(width: width + bezel * 2, height: 2.2 + bezel * 2, length: depth, chamferRadius: tablet ? 0.045 : 0.08)
        body.firstMaterial = material(NSColor(red: 0.71, green: 0.74, blue: 0.78, alpha: 1), metal: 0.88)
        let shell = SCNNode(geometry: body); shell.position.z = (-depth / 2)
        phone.addChildNode(shell)
        let face = SCNPlane(width: width + 0.014, height: 2.214); face.cornerRadius = tablet ? 0.045 : 0.08
        face.firstMaterial = material(NSColor(red: 0.08, green: 0.094, blue: 0.125, alpha: 1))
        phone.addChildNode(SCNNode(geometry: face))
        let panel = SCNPlane(width: width, height: 2.2); panel.cornerRadius = tablet ? 0.045 : 0.08
        let texture = SCNMaterial(); texture.lightingModel = .constant; texture.diffuse.contents = NSColor.black
        panel.firstMaterial = texture; display.geometry = panel; display.position.z = 0.003
        phone.addChildNode(display)
        let back = SCNPlane(width: width, height: 2.2); back.cornerRadius = tablet ? 0.045 : 0.08
        back.firstMaterial = material(NSColor(red: 0.204, green: 0.267, blue: 0.286, alpha: 1), metal: 0.45)
        let rear = SCNNode(geometry: back); rear.position.z = (-depth - 0.001); rear.eulerAngles.y = .pi
        phone.addChildNode(rear)
        for offset: CGFloat in [0.2, 0.65] {
            let button = SCNBox(width: 0.026, height: offset == 0.2 ? 0.24 : 0.32, length: depth * 0.65, chamferRadius: 0.006)
            button.firstMaterial = body.firstMaterial
            let node = SCNNode(geometry: button); node.position = SCNVector3(width / 2 + bezel + 0.015, offset, -depth / 2)
            phone.addChildNode(node)
        }
        for offset: CGFloat in [-0.11, 0.11] {
            let lens = SCNCylinder(radius: 0.056, height: 0.025)
            lens.firstMaterial = material(NSColor(red: 0.027, green: 0.075, blue: 0.149, alpha: 1), metal: 0.6)
            let node = SCNNode(geometry: lens); node.eulerAngles.x = .pi / 2
            node.position = SCNVector3(width / 2 - 0.18, 1.1 - 0.29 + offset, -depth - 0.015)
            phone.addChildNode(node)
        }
        layout()
    }
    public override func layout() {
        super.layout()
        let fit = max(1, (aspect * 2.2 + 0.15) / max(0.1, bounds.width / max(1, bounds.height)) / 2.2)
        cameraNode.position.z = (4.8 * fit)
        needsDisplay = true
    }
    public func resetPose() { phone.eulerAngles = SCNVector3Zero; needsDisplay = true }
    public func releaseResources() {
        if let lastTouch { onTouch?("end", lastTouch.x, lastTouch.y) }
        lastTouch = nil; orbiting = false
        display.geometry?.firstMaterial?.diffuse.contents = nil
        phone.childNodes.forEach { $0.removeFromParentNode() }
        display.geometry = nil; pointOfView = nil; cameraNode.camera = nil
        scene = nil
    }
    private func screenPoint(_ point: NSPoint) -> CGPoint? {
        guard let hit = hitTest(point, options: [.firstFoundOnly: false]).first, hit.node === display else { return nil }
        let uv = hit.textureCoordinates(withMappingChannel: 0)
        return CGPoint(x: max(0, min(1, uv.x)), y: max(0, min(1, 1 - uv.y)))
    }
    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        lastPoint = convert(event.locationInWindow, from: nil)
        lastTouch = event.modifierFlags.contains(.option) ? nil : screenPoint(lastPoint)
        orbiting = lastTouch == nil
        if let lastTouch { onTouch?("begin", lastTouch.x, lastTouch.y) }
    }
    public override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if orbiting { orbit(x: point.x - lastPoint.x, y: point.y - lastPoint.y) }
        else if let touch = screenPoint(point) { lastTouch = touch; onTouch?("move", touch.x, touch.y) }
        lastPoint = point
    }
    public override func mouseUp(with event: NSEvent) {
        if let lastTouch { onTouch?("end", lastTouch.x, lastTouch.y) }
        lastTouch = nil; orbiting = false
    }
    private func orbit(x: CGFloat, y: CGFloat) {
        phone.eulerAngles.y += (x / max(1, bounds.width) * CGFloat.pi * 2)
        phone.eulerAngles.x -= (y / max(1, bounds.height) * CGFloat.pi * 2)
        needsDisplay = true
    }
    public override func scrollWheel(with event: NSEvent) {
        guard lastTouch == nil else { return }
        orbit(x: -event.scrollingDeltaX, y: event.scrollingDeltaY)
    }
    public override func keyDown(with event: NSEvent) { onKey?(event.keyCode, event.characters, true) }
    public override func keyUp(with event: NSEvent) { onKey?(event.keyCode, event.characters, false) }
}
