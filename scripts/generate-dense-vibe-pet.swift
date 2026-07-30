#!/usr/bin/env swift

import AppKit
import Foundation

struct Palette {
    let core: NSColor
    let edge: NSColor
}

struct SourcePixel {
    let x: Int
    let y: Int
    let color: NSColor
}

let projectRoot = URL(
    fileURLWithPath: CommandLine.arguments.dropFirst().first
        ?? FileManager.default.currentDirectoryPath,
    isDirectory: true
)
let sourceDirectory = projectRoot
    .appendingPathComponent("ClaudeIsland/Resources/VibePet", isDirectory: true)
let outputDirectory = projectRoot
    .appendingPathComponent("ClaudeIsland/Resources/DenseVibePet", isDirectory: true)

let cellStride = 10
let outerBlockSize = 19
let innerInset = 2
let innerBlockSize = outerBlockSize - innerInset * 2

try FileManager.default.createDirectory(
    at: outputDirectory,
    withIntermediateDirectories: true
)

let sourceURLs = try FileManager.default.contentsOfDirectory(
    at: sourceDirectory,
    includingPropertiesForKeys: nil
)
.filter { $0.pathExtension.lowercased() == "png" }
.sorted { $0.lastPathComponent < $1.lastPathComponent }

func palette(for filename: String) -> Palette {
    if filename.contains("working-blue") {
        return Palette(
            core: NSColor(calibratedRed: 0.36, green: 0.64, blue: 0.88, alpha: 1),
            edge: NSColor(calibratedRed: 0.34, green: 0.50, blue: 0.68, alpha: 1)
        )
    }
    if filename.contains("waiting-orange") {
        return Palette(
            core: NSColor(calibratedRed: 0.90, green: 0.58, blue: 0.32, alpha: 1),
            edge: NSColor(calibratedRed: 0.70, green: 0.44, blue: 0.28, alpha: 1)
        )
    }
    return Palette(
        core: NSColor(calibratedRed: 0.26, green: 0.78, blue: 0.48, alpha: 1),
        edge: NSColor(calibratedRed: 0.30, green: 0.57, blue: 0.42, alpha: 1)
    )
}

func coreColor(for source: NSColor, palette: Palette) -> NSColor {
    guard let rgb = source.usingColorSpace(.deviceRGB) else {
        return palette.core
    }
    let maximum = max(rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
    let minimum = min(rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
    let saturation = maximum - minimum
    let luminance =
        rgb.redComponent * 0.2126
        + rgb.greenComponent * 0.7152
        + rgb.blueComponent * 0.0722

    // Keep the pet's pale eye/highlight pixels distinct from its state color.
    if luminance > 0.72 && saturation < 0.22 {
        return NSColor(
            calibratedRed: 0.96,
            green: 0.95,
            blue: 0.86,
            alpha: rgb.alphaComponent
        )
    }

    let base = palette.core.usingColorSpace(.deviceRGB) ?? palette.core
    let shade = min(1.08, max(0.78, 0.78 + luminance * 0.34))
    return NSColor(
        calibratedRed: min(1, base.redComponent * shade),
        green: min(1, base.greenComponent * shade),
        blue: min(1, base.blueComponent * shade),
        alpha: rgb.alphaComponent
    )
}

func fill(
    _ bitmap: NSBitmapImageRep,
    x: Int,
    y: Int,
    size: Int,
    color: NSColor
) {
    let minX = max(0, x)
    let minY = max(0, y)
    let maxX = min(bitmap.pixelsWide, x + size)
    let maxY = min(bitmap.pixelsHigh, y + size)
    guard minX < maxX, minY < maxY else { return }

    for outputY in minY..<maxY {
        for outputX in minX..<maxX {
            bitmap.setColor(color, atX: outputX, y: outputY)
        }
    }
}

for sourceURL in sourceURLs {
    let sourceData = try Data(contentsOf: sourceURL)
    guard let source = NSBitmapImageRep(data: sourceData) else {
        throw NSError(
            domain: "DenseVibePet",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Cannot decode \(sourceURL.path)"]
        )
    }

    let outputWidth = (source.pixelsWide - 1) * cellStride + outerBlockSize
    let outputHeight = (source.pixelsHigh - 1) * cellStride + outerBlockSize
    guard let output = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: outputWidth,
        pixelsHigh: outputHeight,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(
            domain: "DenseVibePet",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Cannot create output bitmap"]
        )
    }

    var pixels: [SourcePixel] = []
    for y in 0..<source.pixelsHigh {
        for x in 0..<source.pixelsWide {
            guard let color = source.colorAt(x: x, y: y)?
                .usingColorSpace(NSColorSpace.deviceRGB),
                  color.alphaComponent > 0.08 else {
                continue
            }
            pixels.append(SourcePixel(x: x, y: y, color: color))
        }
    }

    let framePalette = palette(for: sourceURL.lastPathComponent)
    // The 19px backing blocks leave a single transparent pixel between source
    // cells that were two pixels apart: one tenth of the original 10px gap.
    for pixel in pixels {
        fill(
            output,
            x: pixel.x * cellStride,
            y: pixel.y * cellStride,
            size: outerBlockSize,
            color: framePalette.edge
        )
    }
    for pixel in pixels {
        fill(
            output,
            x: pixel.x * cellStride + innerInset,
            y: pixel.y * cellStride + innerInset,
            size: innerBlockSize,
            color: coreColor(for: pixel.color, palette: framePalette)
        )
    }

    guard let png = output.representation(
        using: NSBitmapImageRep.FileType.png,
        properties: [:]
    ) else {
        throw NSError(
            domain: "DenseVibePet",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "Cannot encode output PNG"]
        )
    }
    let targetURL = outputDirectory.appendingPathComponent(
        "dense-\(sourceURL.lastPathComponent)"
    )
    try png.write(to: targetURL, options: Data.WritingOptions.atomic)
}

print("Generated \(sourceURLs.count) dense pet frames in \(outputDirectory.path)")
