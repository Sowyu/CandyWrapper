// Draws the Sticker app icon layers: `swiftc scripts/icon/extrude.swift -o /tmp/extrude && /tmp/extrude <white glyph.png> /tmp/x 16 44 1.02`, then copy /tmp/x-fill.png and /tmp/x-body.png into App/Resources/AppIcon.icon/Assets.
import CoreImage
import AppKit
let src = CIImage(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))!
let out = CommandLine.arguments[2]
let r = Double(CommandLine.arguments[3])!, depth = Int(CommandLine.arguments[4])!
let ext = src.extent
let s = Double(CommandLine.arguments[5]) ?? 0.8
let g = src.transformed(by: CGAffineTransform(translationX: -ext.midX, y: -ext.midY).concatenating(.init(scaleX: s, y: s)).concatenating(.init(translationX: ext.midX - Double(depth)/2, y: ext.midY + Double(depth)/2)))
func solid(_ mask: CIImage, _ c: CIColor) -> CIImage {
    CIImage(color: c).cropped(to: ext).applyingFilter("CIBlendWithAlphaMask", parameters: ["inputBackgroundImage": CIImage.empty(), "inputMaskImage": mask])
}
let fat = g.applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": r])
// Thin outline on the top left, thick on the bottom right: the outline swept down-right like Capy's extruded sticker.
var body = fat
for k in stride(from: 2, through: depth, by: 2) {
    body = fat.transformed(by: .init(translationX: Double(k), y: -Double(k))).composited(over: body)
}
let black = solid(body, CIColor(red: 0, green: 0, blue: 0))
let fill = solid(g, CIColor(red: 1, green: 1, blue: 1))
// A thin light edge on the top left only, like light catching the sticker's rim (dark appearance).
let lit = body.transformed(by: .init(translationX: -4, y: 4)).applyingFilter("CISourceOutCompositing", parameters: ["inputBackgroundImage": body])
let rim = solid(lit, CIColor(red: 1, green: 1, blue: 1))
let ctx = CIContext(); let cs = CGColorSpace(name: CGColorSpace.sRGB)!
try! ctx.writePNGRepresentation(of: fill.cropped(to: ext), to: URL(fileURLWithPath: out + "-fill.png"), format: .RGBA8, colorSpace: cs)
try! ctx.writePNGRepresentation(of: rim.cropped(to: ext), to: URL(fileURLWithPath: out + "-rim.png"), format: .RGBA8, colorSpace: cs)
try! ctx.writePNGRepresentation(of: black.cropped(to: ext), to: URL(fileURLWithPath: out + "-body.png"), format: .RGBA8, colorSpace: cs)
