#!/usr/bin/env swift

// Renders the clip the App Store screenshots are taken over.
//
//   swift Tools/make-demo-clip.swift out.mp4 [seconds]
//
// Why generate it. The player shots need a picture behind the controls, and
// every other way of getting one is worse: a third-party test stream makes a CI
// run depend on someone else's CDN, and a real film puts someone else's footage
// (and licence) into our store listing. This draws its own frames — no network,
// no dependencies beyond the system frameworks, nothing anyone else owns.
//
// 1920×1080 H.264, which is what `simctl addmedia` wants and what the Videos
// tab will show a thumbnail for.

import AVFoundation
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count > 1 else {
    FileHandle.standardError.write(Data("usage: make-demo-clip.swift <out.mp4> [seconds]\n".utf8))
    exit(2)
}
let outURL = URL(fileURLWithPath: args[1])
let seconds = args.count > 2 ? Double(args[2]) ?? 12 : 12
let fps: Int32 = 30
let width = 1920, height = 1080

try? FileManager.default.removeItem(at: outURL)

let writer = try! AVAssetWriter(outputURL: outURL, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: width,
    AVVideoHeightKey: height,
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 6_000_000],
])
input.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(
    assetWriterInput: input,
    sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
    ]
)
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)

let space = CGColorSpaceCreateDeviceRGB()

/// One frame: a sky that shifts through dusk, a sun that sinks, and slow bands
/// of cloud. Abstract on purpose — it reads as footage without pretending to be
/// anything in particular.
func draw(_ context: CGContext, t: Double) {
    let h = Double(height), w = Double(width)

    // Sky. The stops move with `t`, so the whole frame changes colour over the
    // clip rather than sitting still behind the controls.
    let warm = 0.5 + 0.5 * sin(t * 0.6)
    let colors = [
        CGColor(colorSpace: space, components: [0.05, 0.06, 0.16, 1])!,
        CGColor(colorSpace: space, components: [0.16 + 0.1 * warm, 0.10, 0.28, 1])!,
        CGColor(colorSpace: space, components: [0.85 * warm + 0.25, 0.30 + 0.2 * warm, 0.22, 1])!,
        CGColor(colorSpace: space, components: [0.98, 0.62 + 0.2 * warm, 0.30, 1])!,
    ] as CFArray
    let sky = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.42, 0.74, 1])!
    context.drawLinearGradient(
        sky,
        start: CGPoint(x: 0, y: h),
        end: CGPoint(x: 0, y: h * 0.28),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )

    // Sun, sinking toward the horizon over the length of the clip.
    let horizon = h * 0.42
    let sunY = horizon + 150 - t * 6
    context.setFillColor(CGColor(colorSpace: space, components: [1, 0.86, 0.55, 0.95])!)
    context.fillEllipse(in: CGRect(x: w * 0.52, y: sunY, width: 190, height: 190))

    // Cloud bands: slow, wide, and translucent, drifting at different speeds so
    // the frame has motion a thumbnail can show.
    for band in 0..<7 {
        let phase = t * (0.18 + Double(band) * 0.05)
        let y = horizon + 70 + Double(band) * 88
        let x = (phase * 120).truncatingRemainder(dividingBy: w + 900) - 450
        let alpha = 0.10 + 0.045 * Double((band % 3) + 1)
        context.setFillColor(CGColor(colorSpace: space, components: [1, 0.93, 0.86, alpha])!)
        context.fill(CGRect(x: x, y: y, width: 780, height: 26))
        context.fill(CGRect(x: x - 320, y: y + 34, width: 460, height: 18))
    }

    // Sea: darker, with the sun's reflection broken into a column of glints.
    context.setFillColor(CGColor(colorSpace: space, components: [0.04, 0.05, 0.11, 1])!)
    context.fill(CGRect(x: 0, y: 0, width: w, height: horizon))
    for row in 0..<26 {
        let y = horizon - Double(row) * (horizon / 26)
        let wobble = sin(t * 2.2 + Double(row) * 0.7) * Double(row) * 2.4
        let widthHere = 120 + Double(row) * 9
        context.setFillColor(CGColor(colorSpace: space, components: [1, 0.78, 0.45, 0.30 - Double(row) * 0.01])!)
        context.fill(CGRect(x: w * 0.52 + 95 - widthHere / 2 + wobble, y: y, width: widthHere, height: 5))
    }
}

let totalFrames = Int(seconds * Double(fps))
var frame = 0
while frame < totalFrames {
    guard input.isReadyForMoreMediaData else {
        usleep(5_000)
        continue
    }
    var maybeBuffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &maybeBuffer)
    guard let buffer = maybeBuffer else { break }

    CVPixelBufferLockBaseAddress(buffer, [])
    let context = CGContext(
        data: CVPixelBufferGetBaseAddress(buffer),
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
        space: space,
        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
    )!
    draw(context, t: Double(frame) / Double(fps))
    CVPixelBufferUnlockBaseAddress(buffer, [])

    adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
    frame += 1
}

input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()

if writer.status == .completed {
    print("wrote \(outURL.path) — \(totalFrames) frames at \(fps)fps")
} else {
    FileHandle.standardError.write(Data("write failed: \(writer.error?.localizedDescription ?? "unknown")\n".utf8))
    exit(1)
}
