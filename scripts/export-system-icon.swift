import AppKit
import ImageIO
import UniformTypeIdentifiers

// Export the existing approved artwork for the system icon renderer. This is
// asset preparation, not a redraw: trim the master's transparent outer margin,
// composite onto its own background colour and export an opaque square. macOS
// applies the final rounded mask when actool compiles the Icon Composer package.
// A loose opaque PNG alone does not carry the required system icon metadata.
guard CommandLine.arguments.count == 3,
      let source = NSImage(contentsOfFile: CommandLine.arguments[1]),
      let image = source.cgImage(forProposedRect: nil, context: nil, hints: nil),
      image.width == image.height else { fatalError("Expected a square approved icon master") }

let side = CGFloat(image.width)
// Both approved 1254px masters put their rounded background inside this 7% edge.
let crop = CGRect(x: (side * 0.07).rounded(), y: (side * 0.07).rounded(),
                  width: (side * 0.86).rounded(), height: (side * 0.86).rounded())
guard let artwork = image.cropping(to: crop) else { fatalError("Cannot crop approved icon") }
let bitmap = NSBitmapImageRep(cgImage: artwork)
guard let background = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: 16)?.usingColorSpace(.sRGB),
      let context = CGContext(data: nil, width: 1024, height: 1024,
                              bitsPerComponent: 8, bytesPerRow: 4096,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("Cannot prepare opaque icon")
}
let canvas = CGRect(x: 0, y: 0, width: 1024, height: 1024)
context.setFillColor(CGColor(red: background.redComponent, green: background.greenComponent,
                             blue: background.blueComponent, alpha: 1))
context.fill(canvas)
context.interpolationQuality = .high
context.draw(artwork, in: canvas)
guard let rendered = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[2]) as CFURL,
                                                       UTType.png.identifier as CFString, 1, nil) else {
    fatalError("Cannot create system icon export")
}
CGImageDestinationAddImage(destination, rendered, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Cannot save system icon export") }
