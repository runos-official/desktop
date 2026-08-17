#!/usr/bin/env swift

import AppKit
import Foundation

struct SourceIcon {
    let filename: String
    let scale: String
}

let fileManager = FileManager.default
let repository = URL(fileURLWithPath: fileManager.currentDirectoryPath)
let assetCatalog = repository.appending(path: "Sources/RunOSDesktop/Assets.xcassets")
let sourceDirectory = assetCatalog.appending(path: "MenuBarIcon.imageset")
let sources = [
    SourceIcon(filename: "MenuBarIcon.png", scale: "1x"),
    SourceIcon(filename: "MenuBarIcon@2x.png", scale: "2x"),
    SourceIcon(filename: "MenuBarIcon@3x.png", scale: "3x")
]

func angularDistance(_ first: Double, _ second: Double) -> Double {
    abs(atan2(sin(first - second), cos(first - second)))
}

for frame in 0..<3 {
    let outputDirectory = assetCatalog.appending(path: "MenuBarActivity\(frame + 1).imageset")
    try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

    for source in sources {
        let sourceURL = sourceDirectory.appending(path: source.filename)
        guard
            let sourceData = try? Data(contentsOf: sourceURL),
            let sourceRepresentation = NSBitmapImageRep(data: sourceData),
            let outputRepresentation = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: sourceRepresentation.pixelsWide,
                pixelsHigh: sourceRepresentation.pixelsHigh,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        else {
            fatalError("Cannot read \(sourceURL.path)")
        }

        let centerX = Double(sourceRepresentation.pixelsWide - 1) / 2
        let centerY = Double(sourceRepresentation.pixelsHigh - 1) / 2
        let phase = Double(frame) * 2 * .pi / 3

        for y in 0..<sourceRepresentation.pixelsHigh {
            for x in 0..<sourceRepresentation.pixelsWide {
                let angle = atan2(Double(y) - centerY, Double(x) - centerX)
                let distance = angularDistance(angle, phase)
                let highlight = pow(max(0, cos(distance)), 3)
                let opacity = 0.42 + 0.58 * highlight
                var samples = [Int](repeating: 0, count: 4)
                sourceRepresentation.getPixel(&samples, atX: x, y: y)
                samples[3] = Int((Double(samples[3]) * opacity).rounded())
                samples.withUnsafeMutableBufferPointer { buffer in
                    outputRepresentation.setPixel(buffer.baseAddress!, atX: x, y: y)
                }
            }
        }

        guard let pngData = outputRepresentation.representation(using: .png, properties: [:]) else {
            fatalError("Cannot encode activity frame")
        }
        let suffix = source.scale == "1x" ? "" : "@\(source.scale.first!)x"
        let outputURL = outputDirectory.appending(path: "MenuBarActivity\(frame + 1)\(suffix).png")
        try pngData.write(to: outputURL, options: .atomic)
    }
}
