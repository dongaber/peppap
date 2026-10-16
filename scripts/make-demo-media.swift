// Делает из записи демо (Peppap → «Записать демо-ролик…») файлы для README:
//   docs/demo.mp4 — полный ролик (H.264), docs/demo.gif — фрагмент,
//   docs/screenshot-<имя>.png — кадры в полном разрешении (аргументы вида имя@секунда).
//
//   swiftc scripts/make-demo-media.swift -o /tmp/make-demo-media
//   /tmp/make-demo-media ~/Movies/Peppap/peppap-demo.mov docs [начало, с] [длительность, с] [ширина, px] [кадров/с] [имя@с …]
import AVFoundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("Использование: make-demo-media <запись.mov> <папка> [начало] [длительность] [ширина] [fps]")
    exit(1)
}
let input = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[2], isDirectory: true)
let gifStart = args.count > 3 ? Double(args[3])! : 3.5
let gifLength = args.count > 4 ? Double(args[4])! : 22
let gifWidth = args.count > 5 ? Int(args[5])! : 720
let fps = args.count > 6 ? Double(args[6])! : 10
let shots: [(String, Double)] = args.dropFirst(7).compactMap { arg in
    let parts = arg.split(separator: "@")
    guard parts.count == 2, let t = Double(parts[1]) else { return nil }
    return (String(parts[0]), t)
}
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let asset = AVURLAsset(url: input)

// MP4
let mp4 = outDir.appendingPathComponent("demo.mp4")
try? FileManager.default.removeItem(at: mp4)
let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality)!
export.outputURL = mp4
export.outputFileType = .mp4
export.shouldOptimizeForNetworkUse = true
let done = DispatchSemaphore(value: 0)
export.exportAsynchronously { done.signal() }
done.wait()
if export.status != .completed { print("MP4 не получился: \(export.error?.localizedDescription ?? "?")"); exit(1) }

// GIF
let gen = AVAssetImageGenerator(asset: asset)
gen.appliesPreferredTrackTransform = true
gen.requestedTimeToleranceBefore = .zero
gen.requestedTimeToleranceAfter = .zero
let gif = outDir.appendingPathComponent("demo.gif")
let frames = Int(gifLength * fps)
guard let dest = CGImageDestinationCreateWithURL(gif as CFURL, UTType.gif.identifier as CFString, frames, nil) else { exit(1) }
CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary

for i in 0..<frames {
    let t = CMTime(seconds: gifStart + Double(i) / fps, preferredTimescale: 600)
    guard let cg = try? gen.copyCGImage(at: t, actualTime: nil) else { continue }
    let h = Int(Double(cg.height) * Double(gifWidth) / Double(cg.width))
    guard let ctx = CGContext(data: nil, width: gifWidth, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { continue }
    ctx.interpolationQuality = .high
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: gifWidth, height: h))
    if let scaled = ctx.makeImage() { CGImageDestinationAddImage(dest, scaled, frameProps) }
}
CGImageDestinationFinalize(dest)

// Скриншоты
var outputs = [mp4, gif]
for (name, t) in shots {
    let png = outDir.appendingPathComponent("screenshot-\(name).png")
    guard let cg = try? gen.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil),
          let dest = CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        print("Кадр \(name)@\(t) не получился")
        continue
    }
    CGImageDestinationAddImage(dest, cg, nil)
    CGImageDestinationFinalize(dest)
    outputs.append(png)
}

for f in outputs {
    let size = (try? FileManager.default.attributesOfItem(atPath: f.path)[.size] as? Int) ?? 0
    print("\(f.lastPathComponent): \(String(format: "%.1f", Double(size) / 1_048_576)) МБ")
}
