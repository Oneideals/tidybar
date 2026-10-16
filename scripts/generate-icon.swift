import AppKit

func renderIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }

    let scale = size / 1024.0

    // Canvas & standard macOS squircle geometry
    let squircleInset: CGFloat = 100 * scale
    let squircleSize: CGFloat = 824 * scale
    let cornerRadius: CGFloat = 185 * scale
    let squircleRect = CGRect(x: squircleInset, y: squircleInset, width: squircleSize, height: squircleSize)

    // Outer Drop Shadow
    ctx.saveGState()
    let shadowColor = NSColor.black.withAlphaComponent(0.28).cgColor
    ctx.setShadow(offset: CGSize(width: 0, height: -18 * scale), blur: 32 * scale, color: shadowColor)

    // Squircle Path
    let squirclePath = CGPath(roundedRect: squircleRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    ctx.addPath(squirclePath)
    ctx.setFillColor(NSColor(red: 0.12, green: 0.14, blue: 0.18, alpha: 1.0).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Base Squircle Clip for internal gradient and layers
    ctx.saveGState()
    ctx.addPath(squirclePath)
    ctx.clip()

    // 1. Rich Background Gradient: Deep Slate to Midnight Indigo
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bgColors = [
        NSColor(red: 0.16, green: 0.20, blue: 0.28, alpha: 1.0).cgColor,
        NSColor(red: 0.10, green: 0.12, blue: 0.17, alpha: 1.0).cgColor
    ] as CFArray
    let bgLocations: [CGFloat] = [0.0, 1.0]
    if let bgGradient = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: bgLocations) {
        ctx.drawLinearGradient(bgGradient,
                               start: CGPoint(x: squircleRect.midX, y: squircleRect.maxY),
                               end: CGPoint(x: squircleRect.midX, y: squircleRect.minY),
                               options: [])
    }

    // 2. Subtle top inner highlight
    let highlightRect = CGRect(x: squircleRect.minX, y: squircleRect.maxY - 120 * scale, width: squircleRect.width, height: 120 * scale)
    let hlColors = [
        NSColor.white.withAlphaComponent(0.12).cgColor,
        NSColor.white.withAlphaComponent(0.0).cgColor
    ] as CFArray
    if let hlGradient = CGGradient(colorsSpace: colorSpace, colors: hlColors, locations: [0.0, 1.0]) {
        ctx.saveGState()
        ctx.addPath(squirclePath)
        ctx.clip()
        ctx.drawLinearGradient(hlGradient,
                               start: CGPoint(x: highlightRect.midX, y: highlightRect.maxY),
                               end: CGPoint(x: highlightRect.midX, y: highlightRect.minY),
                               options: [])
        ctx.restoreGState()
    }

    // 3. Middle Menu Bar Tray (Frosted Glass Capsule)
    let barWidth = 620 * scale
    let barHeight = 110 * scale
    let barRect = CGRect(x: squircleRect.midX - barWidth / 2, y: squircleRect.midY + 90 * scale, width: barWidth, height: barHeight)
    let barPath = CGPath(roundedRect: barRect, cornerWidth: 26 * scale, cornerHeight: 26 * scale, transform: nil)

    // Bar Glow & Shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6 * scale), blur: 14 * scale, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(barPath)
    ctx.setFillColor(NSColor(red: 0.18, green: 0.22, blue: 0.30, alpha: 0.85).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Bar Border
    ctx.saveGState()
    ctx.addPath(barPath)
    ctx.setLineWidth(2.5 * scale)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.22).cgColor)
    ctx.strokePath()
    ctx.restoreGState()

    // Status dots and icons inside the top bar
    // Left side: Active dots (Cyan, Violet, Emerald)
    let dotY = barRect.midY
    let dotRadius = 11 * scale
    let dotColors = [
        NSColor(red: 0.20, green: 0.78, blue: 0.95, alpha: 1.0), // Cyan
        NSColor(red: 0.45, green: 0.55, blue: 0.98, alpha: 1.0), // Blue-Indigo
        NSColor(red: 0.22, green: 0.85, blue: 0.55, alpha: 1.0)  // Emerald
    ]
    for (i, c) in dotColors.enumerated() {
        let dotCenter = CGPoint(x: barRect.minX + (45 + CGFloat(i) * 36) * scale, y: dotY)
        ctx.saveGState()
        ctx.setFillColor(c.cgColor)
        ctx.fillEllipse(in: CGRect(x: dotCenter.x - dotRadius, y: dotCenter.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2))
        ctx.restoreGState()
    }

    // Divider Line (Tidy separator)
    let divX = barRect.minX + 175 * scale
    ctx.saveGState()
    ctx.setLineWidth(3 * scale)
    ctx.setLineCap(.round)
    ctx.setStrokeColor(NSColor(red: 0.35, green: 0.75, blue: 1.0, alpha: 0.85).cgColor)
    ctx.move(to: CGPoint(x: divX, y: barRect.minY + 22 * scale))
    ctx.addLine(to: CGPoint(x: divX, y: barRect.maxY - 22 * scale))
    ctx.strokePath()
    ctx.restoreGState()

    // Right side: Tidied items (subtle pill capsules)
    let pillWidth = 56 * scale
    let pillHeight = 22 * scale
    for i in 0..<4 {
        let px = divX + (35 + CGFloat(i) * 76) * scale
        let pillRect = CGRect(x: px, y: dotY - pillHeight / 2, width: pillWidth, height: pillHeight)
        let pillPath = CGPath(roundedRect: pillRect, cornerWidth: 8 * scale, cornerHeight: 8 * scale, transform: nil)
        ctx.saveGState()
        let alpha = 0.25 + CGFloat(i) * 0.18
        ctx.setFillColor(NSColor.white.withAlphaComponent(alpha).cgColor)
        ctx.addPath(pillPath)
        ctx.fillPath()
        ctx.restoreGState()
    }

    // 4. Lower Hero Element: The Tidy Drawer / Shelf (Organized Floating Tray)
    let drawerWidth = 540 * scale
    let drawerHeight = 250 * scale
    let drawerRect = CGRect(x: squircleRect.midX - drawerWidth / 2, y: squircleRect.minY + 110 * scale, width: drawerWidth, height: drawerHeight)
    let drawerPath = CGPath(roundedRect: drawerRect, cornerWidth: 32 * scale, cornerHeight: 32 * scale, transform: nil)

    // Drawer Glow / Shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 12 * scale), blur: 24 * scale, color: NSColor(red: 0.05, green: 0.45, blue: 0.95, alpha: 0.25).cgColor)
    ctx.addPath(drawerPath)
    ctx.setFillColor(NSColor(red: 0.14, green: 0.17, blue: 0.24, alpha: 0.92).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Drawer Gradient Fill
    let drawerColors = [
        NSColor(red: 0.20, green: 0.25, blue: 0.35, alpha: 0.95).cgColor,
        NSColor(red: 0.12, green: 0.15, blue: 0.22, alpha: 0.95).cgColor
    ] as CFArray
    if let dGradient = CGGradient(colorsSpace: colorSpace, colors: drawerColors, locations: [0.0, 1.0]) {
        ctx.saveGState()
        ctx.addPath(drawerPath)
        ctx.clip()
        ctx.drawLinearGradient(dGradient,
                               start: CGPoint(x: drawerRect.midX, y: drawerRect.maxY),
                               end: CGPoint(x: drawerRect.midX, y: drawerRect.minY),
                               options: [])
        ctx.restoreGState()
    }

    // Drawer Border
    ctx.saveGState()
    ctx.addPath(drawerPath)
    ctx.setLineWidth(2 * scale)
    ctx.setStrokeColor(NSColor(red: 0.40, green: 0.65, blue: 1.0, alpha: 0.4).cgColor)
    ctx.strokePath()
    ctx.restoreGState()

    // Drawer Grid of neatly organized icons (2 rows x 4 columns)
    let colSpacing = 110 * scale
    let startGridX = drawerRect.midX - (1.5 * colSpacing)
    let row1Y = drawerRect.midY + 36 * scale
    let row2Y = drawerRect.midY - 48 * scale

    let gridColors: [NSColor] = [
        NSColor(red: 0.98, green: 0.40, blue: 0.35, alpha: 0.9), // Coral Red
        NSColor(red: 0.98, green: 0.75, blue: 0.25, alpha: 0.9), // Gold Amber
        NSColor(red: 0.30, green: 0.85, blue: 0.55, alpha: 0.9), // Mint Green
        NSColor(red: 0.25, green: 0.65, blue: 0.98, alpha: 0.9), // Sky Blue
        NSColor(red: 0.70, green: 0.45, blue: 0.95, alpha: 0.9), // Purple
        NSColor(red: 0.95, green: 0.40, blue: 0.70, alpha: 0.9), // Pink
        NSColor(red: 0.25, green: 0.85, blue: 0.85, alpha: 0.9), // Cyan Teal
        NSColor(red: 0.85, green: 0.88, blue: 0.95, alpha: 0.85) // Crisp White
    ]

    var colorIdx = 0
    for rowY in [row1Y, row2Y] {
        for col in 0..<4 {
            let cx = startGridX + CGFloat(col) * colSpacing
            let itemSize = 44 * scale
            let itemRect = CGRect(x: cx - itemSize / 2, y: rowY - itemSize / 2, width: itemSize, height: itemSize)
            let itemPath = CGPath(roundedRect: itemRect, cornerWidth: 12 * scale, cornerHeight: 12 * scale, transform: nil)

            ctx.saveGState()
            ctx.setFillColor(gridColors[colorIdx % gridColors.count].cgColor)
            ctx.setShadow(offset: CGSize(width: 0, height: -2 * scale), blur: 6 * scale, color: gridColors[colorIdx % gridColors.count].withAlphaComponent(0.4).cgColor)
            ctx.addPath(itemPath)
            ctx.fillPath()
            ctx.restoreGState()

            colorIdx += 1
        }
    }

    // 5. Connective Tuck Arrow / Sparkle Indicator between bar and drawer
    ctx.saveGState()
    let arrowX = squircleRect.midX
    let arrowY = (barRect.minY + drawerRect.maxY) / 2
    let arrowPath = CGMutablePath()
    let aSize = 14 * scale
    arrowPath.move(to: CGPoint(x: arrowX - aSize * 1.5, y: arrowY + aSize * 0.5))
    arrowPath.addLine(to: CGPoint(x: arrowX, y: arrowY - aSize * 0.8))
    arrowPath.addLine(to: CGPoint(x: arrowX + aSize * 1.5, y: arrowY + aSize * 0.5))
    ctx.addPath(arrowPath)
    ctx.setLineWidth(3 * scale)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setStrokeColor(NSColor(red: 0.45, green: 0.75, blue: 1.0, alpha: 0.85).cgColor)
    ctx.strokePath()
    ctx.restoreGState()

    // Outer Rim Stroke on the squircle for crisp border
    ctx.restoreGState() // unclip
    ctx.saveGState()
    ctx.addPath(squirclePath)
    ctx.setLineWidth(1.5 * scale)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.18).cgColor)
    ctx.strokePath()
    ctx.restoreGState()

    image.unlockFocus()
    return image
}

let iconSizes: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

let fileManager = FileManager.default
let currentDir = fileManager.currentDirectoryPath
let iconsetDir = "\(currentDir)/AppIcon.iconset"

try? fileManager.removeItem(atPath: iconsetDir)
try fileManager.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

print("🎨 Rendering TidyBar macOS Iconset...")
for (name, size) in iconSizes {
    let img = renderIcon(size: CGFloat(size))
    if let tiff = img.tiffRepresentation,
       let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
        let dest = "\(iconsetDir)/\(name)"
        try png.write(to: URL(fileURLWithPath: dest))
    }
}

print("🔨 Converting iconset to AppIcon.icns via iconutil...")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconsetDir, "-o", "\(currentDir)/Resources/AppIcon.icns"]
try task.run()
task.waitUntilExit()

if task.terminationStatus == 0 {
    print("✅ Successfully generated Resources/AppIcon.icns")
    try? fileManager.removeItem(atPath: iconsetDir)
} else {
    print("❌ iconutil failed with exit code \(task.terminationStatus)")
    exit(1)
}
