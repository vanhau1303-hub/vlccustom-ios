import Foundation
import MobileVLCKit

/// Pulls one time window of an SMB video's audio out as 16kHz mono Float samples (what WhisperKit wants) using a
/// second, headless libVLC player that transcodes straight to a temporary WAV file (`#transcode{acodec=s16l}` →
/// `std{mux=wav}`) over libVLC's own SMB2 module. `AVAssetReader` cannot do this: it only reads local files (a
/// network URL fails with "Cannot Open") and does not understand MKV at all.
enum VlcAudioExtractor {
    struct ExtractionError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @MainActor
    static func extract(host: String, path: String, login: SmbPlayback.Login?, startMs: Int, durationMs: Int) async throws -> [Float] {
        guard let media = SmbPlayback.media(host: host, path: path, route: .direct, login: login) else {
            throw ExtractionError(message: "Không mở được file để nhận dạng.")
        }
        let wavURL = FileManager.default.temporaryDirectory.appendingPathComponent("asr_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wavURL) }

        media.addOption(":sout=#transcode{vcodec=none,acodec=s16l,channels=1,samplerate=16000}:std{access=file,mux=wav,dst=\(wavURL.path)}")
        media.addOption(":no-sout-video")
        media.addOption(":no-sout-spu")
        media.addOption(":start-time=\(Double(startMs) / 1000)")
        media.addOption(":stop-time=\(Double(startMs + durationMs) / 1000)")

        let player = VLCMediaPlayer()
        VLCControl.play(player, media: media)
        // Handed to VLCControl when done, never released while it may still be stopping.
        defer { VLCControl.retire(player) }

        // A sout-to-file pass is not paced to real time, so 30s of audio normally takes a few seconds.
        let deadline = Date().addingTimeInterval(120)
        var started = false
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { break }
            switch player.state {
            case .opening, .buffering, .playing, .esAdded: started = true
            case .ended: started = true
            case .error:
                throw ExtractionError(message: "VLC không đọc được âm thanh của file này.")
            default: break
            }
            if player.state == .ended || (started && player.state == .stopped) { break }
        }

        guard let data = try? Data(contentsOf: wavURL) else {
            throw ExtractionError(message: "Không tách được âm thanh (không có dữ liệu).")
        }
        return pcmSamples(fromWav: data)
    }

    /// 16-bit little-endian mono PCM from a WAV file → Float in [-1, 1]. Finds the "data" chunk instead of assuming a
    /// 44-byte header (VLC's wav muxer may write extra chunks).
    private static func pcmSamples(fromWav data: Data) -> [Float] {
        var offset = 12 // "RIFF" size "WAVE"
        var pcmRange: Range<Int>?
        while offset + 8 <= data.count {
            let id = String(decoding: data[offset..<offset + 4], as: UTF8.self)
            let size = data[offset + 4..<offset + 8].withUnsafeBytes { Int($0.loadUnaligned(as: UInt32.self).littleEndian) }
            let body = offset + 8
            if id == "data" {
                // Size may still be a placeholder if the muxer did not get to finalize it; read to the end then.
                let end = (size > 0 && body + size <= data.count) ? body + size : data.count
                pcmRange = body..<end
                break
            }
            offset = body + size + (size & 1)
        }
        guard let pcmRange else { return [] }
        let pcm = data[pcmRange]
        let count = pcm.count / 2
        var samples = [Float](repeating: 0, count: count)
        pcm.withUnsafeBytes { raw in
            for i in 0..<count {
                let value = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))
                samples[i] = Float(value) / 32768.0
            }
        }
        return samples
    }
}
