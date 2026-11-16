import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var library: Library
    @State private var pendingDelete: Recording?
    @State private var pickingFolder = false
    @State private var exportFolder = Export.folderDisplayName
    @State private var standby = Standby.enabled
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    RecordControls(broadcast: library.liveBroadcast)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                } footer: {
                    Text("现场对话：用麦克风录身边的人说话。手机声音：录正在播放的视频、直播、会议、通话，只录声音不存画面；想把自己说的话也录进去，在弹出的面板里打开麦克风。")
                }

                Section {
                    Button { pickingFolder = true } label: {
                        LabeledContent("存到 iCloud", value: exportFolder ?? "未选择")
                    }
                    NavigationLink("设置 Action Button", value: "help")
                    Toggle("待命模式", isOn: Binding(get: { standby }, set: { standby = $0; Standby.enabled = $0 }))
                    if standby {
                        TimelineView(.periodic(from: .now, by: 2)) { _ in
                            if Standby.isRunning {
                                Label(Standby.armed ? "待命中 · 正在录" : "待命中：按 Action Button 开始录",
                                      systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            } else {
                                Button("开启待命（点一次「开始直播」）") { AppState.shared.picker.tap() }
                            }
                        }
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(exportFolder == nil
                             ? "选 iCloud 云盘里一个和 Mac 共享的文件夹，录音会自动存进它的「录音」子文件夹，Mac 不在家也能收到并写好纪要。"
                             : "录完自动存进去；Mac 写好的纪要和文字稿会出现在同一个文件夹里。")
                        Text("本机副本在「文件」→「我的 iPhone」→「Earshot」；同时录到手机声音和麦克风时，还会生成音量均衡后的 balanced.m4a。")
                        Text("待命模式：录屏只开一次、一直在后台等着（不存任何声音，顶上红点常亮），之后看视频、直播时按一下 Action Button 就开始录，不用再点「开始直播」。")
                    }
                }

                if library.items.isEmpty {
                    Section { Text("还没有录音").foregroundStyle(.secondary) }
                } else {
                    Section("录音") {
                        ForEach(library.items) { item in
                            NavigationLink(value: item.id) { Row(item: item) }
                                .swipeActions {
                                    Button("删除", role: .destructive) { pendingDelete = item }
                                }
                        }
                    }
                }
            }
            .navigationTitle("Earshot")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: "settings") { Image(systemName: "gearshape") }
                        .accessibilityLabel("设置")
                }
            }
            .navigationDestination(for: String.self) { id in
                if id == "help" {
                    ActionButtonHelp()
                } else if id == "settings" {
                    SyncSettingsView()
                } else if let item = library.items.first(where: { $0.id == id }) {
                    DetailView(item: item)
                }
            }
            .onAppear {                                   // screenshots only: open a screen directly
                let args = ProcessInfo.processInfo.arguments
                if args.contains("-EarshotDemoDetail"), let first = library.items.first { path = [first.id] }
                if args.contains("-EarshotDemoHelp") { path = ["help"] }
            }
            .refreshable { library.reload() }
            .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
                guard case .success(let url) = result else { return }
                try? Export.setFolder(url)
                exportFolder = Export.folderDisplayName
                if Connectivity.shared.maySyncNow { Export.copyPending() }
                library.reload()
            }
            .confirmationDialog("删除这条录音？", isPresented: Binding(get: { pendingDelete != nil },
                                                                 set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    if let item = pendingDelete { library.delete(item) }
                    pendingDelete = nil
                }
            } message: {
                Text("只删手机上的这份；已经传到 Mac 的不受影响。")
            }
        }
    }
}

private struct SyncSettingsView: View {
    @EnvironmentObject private var library: Library
    @ObservedObject private var connectivity = Connectivity.shared
    @State private var iCloudSyncMode = SyncPolicy.mode
    @State private var mixPreference = MixPreference.load()
    @State private var actionButtonMode = ActionButtonPreference.mode

    var body: some View {
        Form {
            Section {
                Picker("Action Button 默认行为", selection: Binding(
                    get: { actionButtonMode },
                    set: { mode in
                        actionButtonMode = mode
                        ActionButtonPreference.mode = mode
                    }
                )) {
                    Text("手机声音 + 麦克风").tag(ActionButtonPreference.Mode.phoneSound)
                    Text("现场对话（仅麦克风）").tag(ActionButtonPreference.Mode.conversation)
                    Text("自动判断").tag(ActionButtonPreference.Mode.automatic)
                }
                .pickerStyle(.navigationLink)
            } header: {
                Text("Action Button")
            } footer: {
                Text(actionButtonDescription)
            }

            Section {
                Picker("同步至 iCloud", selection: Binding(
                    get: { iCloudSyncMode },
                    set: { mode in
                        iCloudSyncMode = mode
                        SyncPolicy.mode = mode
                        if connectivity.maySyncNow { Export.copyPending() }
                    }
                )) {
                    Text("总是").tag(SyncPolicy.Mode.always)
                    Text("从不").tag(SyncPolicy.Mode.never)
                    Text("仅 Wi-Fi").tag(SyncPolicy.Mode.wifiOnly)
                }
                .pickerStyle(.navigationLink)
                LabeledContent("当前网络", value: networkDescription)
            } header: {
                Text("iCloud 同步")
            } footer: {
                Text(syncDescription)
            }

            Section {
                Picker("音量均衡", selection: Binding(
                    get: { mixPreference.mode },
                    set: { mixPreference.mode = $0; saveMixPreference() }
                )) {
                    Text("自动").tag(MixPreference.Mode.automatic)
                    Text("手动").tag(MixPreference.Mode.manual)
                }
                .pickerStyle(.segmented)

                if mixPreference.mode == .manual {
                    mixSlider("手机声音", value: $mixPreference.levels.app)
                    mixSlider("麦克风", value: $mixPreference.levels.mic)
                }
            } header: {
                Text("本地混音比例")
            } footer: {
                Text(mixPreference.mode == .automatic
                     ? "自动按两轨的采样响度均衡，并为重叠峰值留余量。"
                     : "手动调整两轨在本机 balanced.m4a 中的音量；0 dB 保持原始音量。更改会重新生成已有混音文件。")
            }

            Section {
                if let expirationDate = ActivationStatus.expirationDate {
                    TimelineView(.periodic(from: .now, by: 60)) { timeline in
                        let days = ActivationStatus.remainingDays(at: timeline.date) ?? 0
                        let value = expirationDate <= timeline.date ? "已过期" : (days == 0 ? "不足 1 天" : "\(days) 天")
                        LabeledContent("签名剩余", value: value)
                            .foregroundStyle(days <= 1 ? .orange : .primary)
                        LabeledContent("到期时间", value: expirationDate.formatted(date: .abbreviated, time: .shortened))
                    }
                } else {
                    LabeledContent("签名剩余", value: "无法读取")
                }
            } header: {
                Text("签名状态")
            } footer: {
                Text("根据当前安装包中的开发签名配置文件显示；重新安装后会更新。")
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func mixSlider(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(MixLevels.label(value.wrappedValue)).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.subheadline)
            Slider(value: value, in: MixLevels.range, step: 1) { editing in
                if !editing { saveMixPreference() }
            }
            .accessibilityLabel(title)
            .accessibilityValue(MixLevels.label(value.wrappedValue))
        }
        .padding(.vertical, 2)
    }

    private func saveMixPreference() {
        mixPreference.levels = mixPreference.levels.clamped()
        mixPreference.save()
        library.reload()
    }

    private var networkDescription: String {
        guard connectivity.pathResolved else { return "检测中" }
        if connectivity.onWiFi { return "Wi-Fi" }
        return connectivity.isConnected ? "蜂窝网络" : "无网络"
    }

    private var actionButtonDescription: String {
        switch actionButtonMode {
        case .phoneSound:
            "按 Action Button 打开系统录制面板，录手机播放的声音；要同时录入你说的话，请在面板中打开麦克风。"
        case .conversation:
            "按 Action Button 直接开始或停止麦克风录音。"
        case .automatic:
            "检测到手机正在播放声音时打开系统录制面板，否则直接录麦克风。"
        }
    }

    private var syncDescription: String {
        switch iCloudSyncMode {
        case .always: "录音完成后，有网络时自动复制到所选 iCloud 文件夹。"
        case .never: "录音只保存在本机，不复制到 iCloud。"
        case .wifiOnly: "录音仍保存在本机；连接 Wi-Fi 后才复制到所选 iCloud 文件夹。"
        }
    }
}

private struct Row: View {
    let item: Recording

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: item.info.isConversation ? "mic.fill" : "iphone.radiowaves.left.and.right")
                    .foregroundStyle(item.info.isConversation ? Color.accentColor : .indigo)
                    .font(.subheadline)
                Text(item.title).font(.body.weight(.medium)).lineLimit(1)
                Spacer()
                Status(item: item)
            }
            Text("\(Format.date(item.info.startedAt)) · \(Format.minutes(item.info.duration)) · \(Format.sources(item.info))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}

struct Status: View {
    let item: Recording

    var body: some View {
        if item.isLive {
            Label("录音中", systemImage: "circle.fill").foregroundStyle(.red)
                .font(.caption).labelStyle(.titleAndIcon)
        } else if item.mac != nil {
            Label("已整理", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                .font(.caption)
        } else {
            Text("待整理").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct ActionButtonHelp: View {
    var body: some View {
        List {
            Section {
                Text("1. 打开 设置 › 操作按钮")
                Text("2. 左右滑到「快捷指令」，点「选择快捷指令」")
                Text("3. 在「App」里找到 Earshot，选「录音」")
            } header: { Text("设置一次") }
            Section {
                Label("手机在放声音（视频、直播、会议、通话）→ 打开 Earshot 并弹出录屏面板，点一下「开始直播」就开始录这个声音。苹果规定这一下必须你自己点。", systemImage: "iphone.radiowaves.left.and.right")
                Label("没在放声音 → 直接用麦克风录现场对话，不用打开 App，灵动岛显示计时。", systemImage: "mic.fill")
                Label("录音中再按一次 → 停止。", systemImage: "stop.fill")
                Label("开了待命模式并开启待命后：手机在放声音时按一下直接开始录，不弹面板。", systemImage: "bolt.fill")
            } header: { Text("按一下会怎样") }
        }
        .navigationTitle("Action Button")
        .navigationBarTitleDisplayMode(.inline)
    }
}
