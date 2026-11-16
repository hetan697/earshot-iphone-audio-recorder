import SwiftUI
import AVFoundation
import Combine

struct DetailView: View {
    let item: Recording
    @State private var tab = 0
    @State private var levels: MixLevels

    init(item: Recording) {
        self.item = item
        _levels = State(initialValue: MixLevels.load(item.dir))
    }

    private var summary: String? { item.text("summary.md") }
    private var transcript: String? { item.text("transcript.md") }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title).font(.title3.weight(.semibold))
                    Text([Format.date(item.info.startedAt), Format.duration(item.info.duration), item.bytes > 0 ? Format.size(item.bytes) : nil].compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text(Format.sources(item.info)).font(.subheadline).foregroundStyle(.secondary)
                }
                if item.isLive {
                    Label("正在录音，停止后才能播放", systemImage: "waveform").foregroundStyle(.red)
                } else if !item.info.tracks.isEmpty {
                    Player(item: item, levels: levels)
                }
            }

            if !item.isLive && !item.info.tracks.isEmpty {
                Section {
                    LevelSlider(title: "手机声音", db: $levels.app)
                    LevelSlider(title: "麦克风", db: $levels.mic)
                    if !levels.isNeutral {
                        Button("重置音量") {
                            levels = .neutral
                            levels.save(to: item.dir)
                        }
                    }
                } header: {
                    Text("音量")
                } footer: {
                    Text("两轨听感不一样时在这里调：0 dB 是原始音量，可调 −24 到 +12 dB。播放和分享的文件都按这个比例混合，调整会跟着这条录音保存。")
                }
                .onChange(of: levels) { _, new in new.save(to: item.dir) }
            }

            if summary != nil || transcript != nil {
                Section {
                    Picker("", selection: $tab) {
                        Text("纪要").tag(0)
                        Text("文字稿").tag(1)
                    }
                    .pickerStyle(.segmented)
                    MarkdownText(text: (tab == 0 ? summary : transcript) ?? "（没有内容）")
                }
            } else if !item.isLive {
                Section {
                    Text("手机和 Mac 连到同一个 Wi-Fi 后，Mac 会在 10 分钟内把这条录音取走，转成文字、写好纪要，再送回这里。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !item.isLive && !item.info.tracks.isEmpty {
                ShareLink(item: SharedAudio(item: item, levels: levels),
                          preview: SharePreview("\(item.title).m4a", image: Image(systemName: "waveform")))
            }
        }
    }
}

/// One track's gain: a dB slider with its current value.
private struct LevelSlider: View {
    let title: String
    @Binding var db: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(MixLevels.label(db)).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.subheadline)
            Slider(value: $db, in: MixLevels.range, step: 1)
                .accessibilityLabel(title)
                .accessibilityValue(MixLevels.label(db))
        }
        .padding(.vertical, 2)
    }
}

/// Play / pause, scrub, ±15 s over the aligned phone-audio and microphone tracks.
private struct Player: View {
    let item: Recording
    var levels: MixLevels = .neutral
    @State private var player: AVPlayer?
    @State private var tracks: AudioMix.Tracks?
    @State private var playing = false
    @State private var position: Double = 0
    @State private var scrubbing = false
    private let tick = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 8) {
            Slider(value: $position, in: 0...max(item.info.duration, 1)) { editing in
                scrubbing = editing
                if !editing { player?.seek(to: CMTime(seconds: position, preferredTimescale: 600)) }
            }
            HStack {
                Text(Format.duration(position)).monospacedDigit()
                Spacer()
                Button { skip(-15) } label: { Image(systemName: "gobackward.15") }
                Button { toggle() } label: {
                    Image(systemName: playing ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 40))
                }
                .padding(.horizontal, 20)
                Button { skip(15) } label: { Image(systemName: "goforward.15") }
                Spacer()
                Text(Format.duration(item.info.duration)).monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
        .task(id: item.id) {
            guard let built = try? await AudioMix.composition(item) else { return }
            tracks = built
            let playerItem = AVPlayerItem(asset: built.composition)
            playerItem.audioMix = AudioMix.audioMix(built, levels: levels)
            player = AVPlayer(playerItem: playerItem)
        }
        .onChange(of: levels) { _, new in
            guard let tracks else { return }
            player?.currentItem?.audioMix = AudioMix.audioMix(tracks, levels: new)
        }
        .onReceive(tick) { _ in
            guard let player, !scrubbing else { return }
            position = player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0
            playing = player.rate > 0
        }
        .onDisappear { player?.pause() }
    }

    private func toggle() {
        guard let player else { return }
        if playing {
            player.pause()
        } else {
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            try? AVAudioSession.sharedInstance().setActive(true)
            if position >= item.info.duration - 0.5 { player.seek(to: .zero) }
            player.play()
        }
        playing.toggle()
    }

    private func skip(_ by: Double) {
        guard let player else { return }
        position = min(max(0, position + by), item.info.duration)
        player.seek(to: CMTime(seconds: position, preferredTimescale: 600))
    }
}

/// Just enough Markdown for the Mac's summary and transcript: headings, bullets, inline styles.
private struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, raw in
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty {
                    EmptyView()
                } else if line.hasPrefix("#") {
                    Text(inline(line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)))
                        .font(.headline).padding(.top, 6)
                } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                        Text(inline(String(line.dropFirst(2))))
                    }
                } else {
                    Text(inline(line))
                }
            }
        }
        .font(.callout)
        .textSelection(.enabled)
        .padding(.vertical, 4)
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s)) ?? AttributedString(s)
    }
}
