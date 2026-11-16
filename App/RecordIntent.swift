import AppIntents
import AVFoundation

/// What the app should do once it is in front (set by the Action Button intent).
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    enum Pending { case picker, mic }
    @Published var pending: Pending?
    let picker = BroadcastPicker()
}

/// The Action Button follows the selected preference (phone sound by default):
/// - 待命模式 session running → start / stop storing the phone's sound right away, no sheet;
/// - recording already → stop (a screen-recorder session is stopped from Apple's sheet, opened for you);
/// - 自动判断: another app is playing sound (video, live stream, meeting, call) → record that sound: the app opens
///   Apple's screen-recorder sheet, one tap on 开始直播 (Apple requires that tap);
/// - silence → record the microphone (a conversation) at once, in the background, with a Live Activity.
struct RecordIntent: AudioRecordingIntent {
    static let title: LocalizedStringResource = "Earshot 录音"
    static let description = IntentDescription("按设置的 Action Button 默认行为录音；录音中再按一次就停止。")
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @MainActor
    func perform() async throws -> some IntentResult {
        let mic = MicRecorder.shared
        if mic.isRecording {
            mic.stop()
            return .result()
        }
        if Standby.isRunning {                           // 待命模式: no sheet, no tap
            if Standby.armed { StandbyControl.disarm(); return .result() }
            if AVAudioSession.sharedInstance().isOtherAudioPlaying { StandbyControl.arm(); return .result() }
        }
        let mode = ActionButtonPreference.mode
        let shouldRecordPhoneSound: Bool
        if Store.broadcastIsLive() {
            // Always bring up Apple's sheet to stop an active broadcast, regardless of preference.
            AppState.shared.pending = .picker
            try await continueInForeground(nil, alwaysConfirm: false)
            return .result()
        } else {
            switch mode {
            case .phoneSound:
                shouldRecordPhoneSound = true
            case .conversation:
                shouldRecordPhoneSound = false
            case .automatic:
                shouldRecordPhoneSound = AVAudioSession.sharedInstance().isOtherAudioPlaying
            }
        }

        if shouldRecordPhoneSound {
            AppState.shared.pending = .picker
            try await continueInForeground(nil, alwaysConfirm: false)
            return .result()
        }
        guard MicRecorder.hasPermission else {           // first time: the permission prompt needs the app in front
            AppState.shared.pending = .mic
            try await continueInForeground(nil, alwaysConfirm: false)
            return .result()
        }
        try mic.start()
        return .result()
    }
}

struct EarshotShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: RecordIntent(), phrases: ["用 \(.applicationName) 录音"],
                    shortTitle: "录音", systemImageName: "waveform")
    }
}
