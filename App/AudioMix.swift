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
