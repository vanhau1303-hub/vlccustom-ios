import Foundation
import AVFoundation

/// Pulls one time window of a video's audio track out as 16kHz mono Float samples in [-1, 1] — the format WhisperKit
/// expects — for a local file URL or an SMB file (played through `SmbHttpProxy`, exactly like the thumbnail
/// generator and the player already do). Mirrors the Android app's approach of decoding audio in short windows
/// instead of the whole file, but uses `AVAssetReader` directly instead of a second libVLC transcode pass.
enum AudioPcmExtractor {
    struct ExtractionError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func extract(url: URL, startMs: Int, durationMs: Int) async throws -> [Float] {
        try await Task.detached(priority: .userInitiated) {
            try await extractInner(url: url, startMs: startMs, durationMs: durationMs)
        }.value
    }

    private static func extractInner(url: URL, startMs: Int, durationMs: Int) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(
            start: CMTime(value: Int64(startMs), timescale: 1000),
            duration: CMTime(value: Int64(durationMs), timescale: 1000)
        )

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        guard reader.canAdd(output) else { throw ExtractionError(message: "Không đọc được luồng âm thanh.") }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? ExtractionError(message: "Không đọc được âm thanh.")
        }

        var samples: [Float] = []
        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let length = CMBlockBufferGetDataLength(blockBuffer)
            guard length > 0 else { continue }
            var data = [UInt8](repeating: 0, count: length)
            CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: &data)
            data.withUnsafeBytes { raw in
                let int16Buffer = raw.bindMemory(to: Int16.self)
                samples.reserveCapacity(samples.count + int16Buffer.count)
                for value in int16Buffer {
                    samples.append(Float(value) / 32768.0)
                }
            }
        }
        reader.cancelReading()
        return samples
    }
}
