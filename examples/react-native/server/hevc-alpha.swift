// Encodes raw BGRA frames from standard input as HEVC with alpha, with
// Apple's own encoder (AVAssetWriter, `hevcWithAlpha`):
//
//   ffmpeg ... -f rawvideo -pix_fmt bgra - | swift hevc-alpha.swift out.mov 256 256 30
import AVFoundation
import VideoToolbox

let args = CommandLine.arguments
let out = URL(fileURLWithPath: args[1])
let width = Int(args[2])!
let height = Int(args[3])!
let fps = Int32(args[4])!

try? FileManager.default.removeItem(at: out)
let writer = try AVAssetWriter(outputURL: out, fileType: .mov)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.hevcWithAlpha,
    AVVideoWidthKey: width,
    AVVideoHeightKey: height,
    AVVideoCompressionPropertiesKey: [
        AVVideoQualityKey: 0.7,
        kVTCompressionPropertyKey_TargetQualityForAlpha as String: 0.9,
    ],
])
input.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(
    assetWriterInput: input,
    sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
    ])
writer.add(input)
guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
writer.startSession(atSourceTime: .zero)

let frameBytes = width * height * 4
var frame: Int64 = 0
while true {
    let data = FileHandle.standardInput.readData(ofLength: frameBytes)
    if data.count < frameBytes { break }
    while !input.isReadyForMoreMediaData { usleep(1000) }
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
    let pixels = buffer!
    CVPixelBufferLockBaseAddress(pixels, [])
    let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
    let row = CVPixelBufferGetBytesPerRow(pixels)
    data.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
        for y in 0..<height {
            memcpy(base + y * row, source.baseAddress! + y * width * 4, width * 4)
        }
    }
    CVPixelBufferUnlockBaseAddress(pixels, [])
    adaptor.append(pixels, withPresentationTime: CMTime(value: frame, timescale: fps))
    frame += 1
}
input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
