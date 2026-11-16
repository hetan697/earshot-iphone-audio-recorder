import AVFoundation
import CoreTransferable
import UniformTypeIdentifiers

/// Lines the phone-audio and microphone files up by their offsets, for playback and for sharing as one file.
/// `MixLevels` turns each track up or down; the same balance is used for playback and for the shared file.
enum AudioMix {
    /// The composition plus the two tracks it was made from, so the balance can change without rebuilding it.
    struct Tracks {
        let composition: AVComposition
        let app: AVCompositionTrack?
        let mic: AVCompositionTrack?
    }

    static func composition(_ item: Recording) async throws -> Tracks {
        let comp = AVMutableComposition()
        var app: AVCompositionTrack?
        var mic: AVCompositionTrack?
        for (name, track) in item.info.tracks {
            let asset = AVURLAsset(url: item.dir.appendingPathComponent(track.file))
            guard let source = try await asset.loadTracks(withMediaType: .audio).first,
                  let target = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            let range = try await source.load(.timeRange)
            try target.insertTimeRange(range, of: source, at: CMTime(seconds: track.offset, preferredTimescale: 600))
            if name == "app" { app = target } else if name == "mic" { mic = target }
        }
        return Tracks(composition: comp, app: app, mic: mic)
    }

    /// The two gains as an AVAudioMix. Assigning a new one to a playing item changes the balance live.
    static func audioMix(_ tracks: Tracks, levels: MixLevels) -> AVAudioMix? {
        var parameters: [AVMutableAudioMixInputParameters] = []
        for (track, db) in [(tracks.app, levels.app), (tracks.mic, levels.mic)] {
            guard let track else { continue }
            let parameter = AVMutableAudioMixInputParameters(track: track)
            parameter.setVolume(MixLevels.linear(db), at: .zero)
            parameters.append(parameter)
        }
        guard !parameters.isEmpty else { return nil }
        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        return mix
    }

    static func export(_ item: Recording, levels: MixLevels = .neutral) async throws -> URL {
        let tracks = try await composition(item)
        let name = "\(item.mac?.title ?? "录音") \(item.id).m4a".replacingOccurrences(of: "/", with: "-")
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: out)
        guard let session = AVAssetExportSession(asset: tracks.composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw NSError(domain: "Earshot", code: 3)
        }
        session.outputURL = out
        session.outputFileType = .m4a
        session.audioMix = audioMix(tracks, levels: levels)
        await session.export()
        if let error = session.error { throw error }
        return out
    }

    /// Creates an automatic level-balanced file for the Files archive. Each source is sampled at
    /// regular points through the recording, then track gains bring their average loudness closer
    /// together while leaving headroom for peaks when both tracks overlap.
    static func exportBalanced(_ item: Recording, to out: URL) async throws {
        guard item.info.tracks["app"] != nil, item.info.tracks["mic"] != nil else { return }
        let levels = try balancedLevels(item)
        let tracks = try await composition(item)
        try? FileManager.default.removeItem(at: out)
        guard let session = AVAssetExportSession(asset: tracks.composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw NSError(domain: "Earshot", code: 3)
        }
        session.outputURL = out
        session.outputFileType = .m4a
        session.audioMix = audioMix(tracks, levels: levels)
        await session.export()
        if let error = session.error { throw error }
    }

    private struct Meter {
        var rms: Double
        var peak: Double
    }

    private static func meter(_ url: URL) throws -> Meter {
        let file = try AVAudioFile(forReading: url)
        let frames = file.length
        guard frames > 0 else { return Meter(rms: 0, peak: 0) }
        let format = file.processingFormat
        let windowFrames = max(1, Int64(format.sampleRate * 0.5))
        let windows = min(40, max(1, Int((frames + windowFrames - 1) / windowFrames)))
        let sampleCount = min(windowFrames, frames)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleCount))!
        var sumSquares = 0.0
        var samples = 0
        var peak = 0.0
        let channels = Int(format.channelCount)

        for index in 0..<windows {
            let start = windows == 1 ? 0 : (frames - sampleCount) * Int64(index) / Int64(windows - 1)
            file.framePosition = start
            try file.read(into: buffer, frameCount: AVAudioFrameCount(sampleCount))
            guard let data = buffer.floatChannelData else { continue }
            for channel in 0..<channels {
                for frame in 0..<Int(buffer.frameLength) {
                    let value = Double(data[channel][frame])
                    sumSquares += value * value
                    peak = max(peak, abs(value))
                    samples += 1
                }
            }
        }
        return Meter(rms: samples == 0 ? 0 : sqrt(sumSquares / Double(samples)), peak: peak)
    }

    private static func balancedLevels(_ item: Recording) throws -> MixLevels {
        let appURL = item.dir.appendingPathComponent(item.info.tracks["app"]!.file)
        let micURL = item.dir.appendingPathComponent(item.info.tracks["mic"]!.file)
        let app = try meter(appURL)
        let mic = try meter(micURL)
        let silence = 0.00001
        var appGain = 1.0
        var micGain = 1.0
        if app.rms > silence, mic.rms > silence {
            let target = sqrt(app.rms * mic.rms)
            appGain = min(4, max(0.25, target / app.rms))
            micGain = min(4, max(0.25, target / mic.rms))
        }
        let combinedPeak = app.peak * appGain + mic.peak * micGain
        let headroom = combinedPeak > 0.9 ? 0.9 / combinedPeak : 1
        let headroomDB = 20 * log10(headroom)
        return MixLevels(app: 20 * log10(appGain) + headroomDB,
                         mic: 20 * log10(micGain) + headroomDB).clamped()
    }
}

/// Shared from the detail screen: the mixed file is only made when the person actually shares.
struct SharedAudio: Transferable {
    let item: Recording
    var levels: MixLevels = .neutral
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .mpeg4Audio) {
            SentTransferredFile(try await AudioMix.export($0.item, levels: $0.levels))
        }
    }
}
