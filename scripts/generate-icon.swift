#!/usr/bin/swift

import AppKit

// Icon sizes needed for macOS app icon
let sizes: [(size: Int, scale: Int, name: String)] = [
    (16, 1, "icon_16x16.png"),
    (16, 2, "icon_16x16@2x.png"),
    (32, 1, "icon_32x32.png"),
    (32, 2, "icon_32x32@2x.png"),
    (128, 1, "icon_128x128.png"),
    (128, 2, "icon_128x128@2x.png"),
    (256, 1, "icon_256x256.png"),
    (256, 2, "icon_256x256@2x.png"),
    (512, 1, "icon_512x512.png"),
    (512, 2, "icon_512x512@2x.png"),
]

let outputDir = "SoundMaxx/Assets.xcassets/AppIcon.appiconset"

// Create icon with SF Symbol on gradient background
func createIcon(size: Int) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))

    image.lockFocus()

    // Draw rounded rect background with gradient (matching app theme)
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let cornerRadius = CGFloat(size) * 0.22 // ~22% corner radius like macOS icons
    let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)

    // Gradient from dark purple to pink (matching landing page)
    let gradient = NSGradient(colors: [
        NSColor(red: 0.1, green: 0.08, blue: 0.18, alpha: 1.0),  // Dark purple (#1a1a2e)
        NSColor(red: 0.09, green: 0.13, blue: 0.24, alpha: 1.0), // Slightly lighter (#16213e)
    ])!
    gradient.draw(in: path, angle: -45)

    // Draw SF Symbol
    let symbolSize = CGFloat(size) * 0.55
    let config = NSImage.SymbolConfiguration(pointSize: symbolSize, weight: .medium)

    if let symbolImage = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {

        // Tint the symbol with accent color (pink/red)
        let tintedImage = NSImage(size: symbolImage.size)
        tintedImage.lockFocus()
        NSColor(red: 0.91, green: 0.27, blue: 0.38, alpha: 1.0).set() // #e94560
        let imageRect = NSRect(origin: .zero, size: symbolImage.size)
        symbolImage.draw(in: imageRect)
        imageRect.fill(using: .sourceAtop)
        tintedImage.unlockFocus()

        // Center the symbol
        let x = (CGFloat(size) - tintedImage.size.width) / 2
        let y = (CGFloat(size) - tintedImage.size.height) / 2
        tintedImage.draw(at: NSPoint(x: x, y: y), from: .zero, operation: .sourceOver, fraction: 1.0)
    }

    image.unlockFocus()
    return image
}

// Generate all sizes
for (size, scale, name) in sizes {
    let pixelSize = size * scale
    let image = createIcon(size: pixelSize)

    if let tiffData = image.tiffRepresentation,
       let bitmap = NSBitmapImageRep(data: tiffData),
       let pngData = bitmap.representation(using: .png, properties: [:]) {
        let url = URL(fileURLWithPath: outputDir).appendingPathComponent(name)
        try? pngData.write(to: url)
        print("Created: \(name) (\(pixelSize)x\(pixelSize))")
    }
}

// Create Contents.json
let contentsJson = """
{
  "images" : [
    { "filename" : "icon_16x16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
"""

let contentsUrl = URL(fileURLWithPath: outputDir).appendingPathComponent("Contents.json")
try? contentsJson.write(to: contentsUrl, atomically: true, encoding: .utf8)
print("Created: Contents.json")

print("\nIcon generation complete!")
