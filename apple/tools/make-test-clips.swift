// Writes the small HEVC-with-alpha clips the real-video tests play, with
// Apple's own encoder (AVAssetWriter, `hevcWithAlpha`):
//
//   swift apple/tools/make-test-clips.swift apple/Tests/MaskoPlayerTests/Clips
//
// Each clip is 96 x 96 pixels at 30 frames a second: a coloured box on a
// transparent background. The top-left corner is always transparent and the
// centre is always opaque, so a test can read the alpha channel back.
import AVFoundation
import CoreVideo
import VideoToolbox

struct Clip {
    let name: String
    let frames: Int
    /// Blue, green, red.
    let color: (UInt8, UInt8, UInt8)
}

let size = 96
let clips = [
    Clip(name: "loop", frames: 15, color: (0x02, 0x5D, 0xF9)),
    Clip(name: "move", frames: 12, color: (0x8C, 0x4B, 0xC9)),
]

func write(_ clip: Clip, to url: URL) throws {
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.hevcWithAlpha,
        AVVideoWidthKey: size,
        AVVideoHeightKey: size,
        AVVideoCompressionPropertiesKey: [
            AVVideoQualityKey: 0.6,
            kVTCompressionPropertyKey_TargetQualityForAlpha as String: 0.8,
        ],
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size,
            kCVPixelBufferHeightKey as String: size,
        ])
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<clip.frames {
        while !input.isReadyForMoreMediaData { usleep(1000) }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
        let pixels = buffer!
        CVPixelBufferLockBaseAddress(pixels, [])
        let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(pixels)
        // The box grows and shrinks around the centre.
        let half = 16 + (frame % 8) * 2
        for y in 0..<size {
            for x in 0..<size {
                let p = base + y * row + x * 4
                let inBox = abs(x - size / 2) < half && abs(y - size / 2) < half
                p[0] = inBox ? clip.color.0 : 0
                p[1] = inBox ? clip.color.1 : 0
                p[2] = inBox ? clip.color.2 : 0
                p[3] = inBox ? 255 : 0
            }
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
    }
    input.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
}

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")
for clip in clips {
    let url = out.appendingPathComponent("\(clip.name).mov")
    try write(clip, to: url)
    print("wrote \(url.path)")
}
