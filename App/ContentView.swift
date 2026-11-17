import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject private var library: Library
    @State private var pendingDeletion: DeletionRequest?
    @State private var queuedDeletion: DeletionAction?
    @State private var deletionError: String?
    @State private var isDeleting = false
    @State private var selectedRecordingIDs = Set<String>()
    @State private var isSelecting = false
    @State private var choosingExportType = false
    @State private var isExporting = false
    @State private var exportFiles: [URL] = []
    @State private var exportError: String?
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
                    Text("现场对话：用麦克风录身边的人说话。手机声音：录正在播放的视频、直播、会议、通话，只录声音不存画面；想把自己说的话也录进去，在弹出的面板里打开麦克风。本机副本可在「文件」→「我的 iPhone」→「Earshot」查看；双音轨录音还会生成音量均衡后的 balanced.m4a。")
                }

                Section {
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
                    Text("录屏会话会常驻运行；开始前需在系统面板点一次「开始直播」。待命时不保存声音，按 Action Button 后才开始录制。")
                }

                Section {
                    if library.items.isEmpty {
                        Text("还没有录音").foregroundStyle(.secondary)
                    } else {
                        ForEach(library.items) { item in
                            if isSelecting {
                                Button { toggleSelection(item) } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: selectedRecordingIDs.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(selectedRecordingIDs.contains(item.id) ? Color.accentColor : .secondary)
                                        Row(item: item)
                                    }
                                }
                                .buttonStyle(.plain)
                                .disabled(item.isLive || item.info.tracks.isEmpty)
                            } else {
                                NavigationLink(value: item.id) { Row(item: item) }
                                    .swipeActions {
                                        Button("删除", role: .destructive) {
                                            // Let UIKit finish committing the swipe action before presenting a sheet.
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                                requestDeletion([item])
                                            }
                                        }
                                    }
                            }
                        }
                    }
                } header: {
                    if !library.items.isEmpty { Text("录音") }
                }
            }
            .navigationTitle("Earshot")
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    if !library.items.isEmpty {
                        Button(isSelecting ? "完成" : "选择") {
                            isSelecting.toggle()
                            selectedRecordingIDs.removeAll()
                        }
                        if isSelecting {
                            Button(allSelectableItemsSelected ? "取消全选" : "全选") {
                                if allSelectableItemsSelected {
                                    selectedRecordingIDs.removeAll()
                                } else {
                                    selectedRecordingIDs = Set(selectableItems.map(\.id))
                                }
                            }
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: "settings") { Image(systemName: "gearshape") }
                        .accessibilityLabel("设置")
                }
                if isSelecting, !selectedRecordingIDs.isEmpty {
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button {
                            choosingExportType = true
                        } label: {
                            Label(isExporting ? "正在准备" : "导出（\(selectedRecordingIDs.count)）", systemImage: "square.and.arrow.up")
                        }
                        .disabled(isExporting)
                        Spacer()
                        Button(role: .destructive) {
                            requestDeletion(selectedItems)
                        } label: {
                            Label("删除（\(selectedRecordingIDs.count)）", systemImage: "trash")
                        }
                    }
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
            .confirmationDialog("选择导出内容", isPresented: $choosingExportType,
                                titleVisibility: .visible) {
                Button("导出手机声音") { Task { await exportSelected(.phone) } }
                    .disabled(!selectedItems.contains(where: { $0.info.tracks["app"] != nil }))
                Button("导出麦克风") { Task { await exportSelected(.microphone) } }
                    .disabled(!selectedItems.contains(where: { $0.info.tracks["mic"] != nil }))
                Button("按自动均衡导出") { Task { await exportSelected(.automatic) } }
                Button("按手动设置导出") { Task { await exportSelected(.manual) } }
                Button("取消", role: .cancel) {}
            } message: {
                Text("灰色选项表示所选录音没有对应音轨。选择多条时，只导出含对应音轨的录音。")
            }
            .onChange(of: library.items) { _, items in
                selectedRecordingIDs.formIntersection(Set(items.map(\.id)))
            }
            .sheet(isPresented: Binding(get: { !exportFiles.isEmpty }, set: { if !$0 { exportFiles = [] } })) {
                ActivityShareSheet(activityItems: exportFiles)
            }
            .sheet(item: $pendingDeletion, onDismiss: performQueuedDeletion) { request in
                DeleteCopiesSheet(
                    recordingCount: request.items.count,
                    filesCopyCount: request.items.filter { LocalArchive.hasAnyCopy($0.info) }.count,
                    iCloudCopyCount: request.items.filter { Export.isExported($0.dir) }.count
                ) { fromList, filesCopy, iCloudCopy in
                    queuedDeletion = DeletionAction(request: request, fromList: fromList,
                                                    filesCopy: filesCopy, iCloudCopy: iCloudCopy)
                }
            }
            .alert("删除未完成", isPresented: Binding(
                get: { deletionError != nil },
                set: { if !$0 { deletionError = nil } }
            )) {
                Button("好") { deletionError = nil }
            } message: {
                Text(deletionError ?? "")
            }
            .alert("无法导出所选录音", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
                Button("好") { exportError = nil }
            } message: {
                Text(exportError ?? "")
            }
        }
        .overlay {
            if isDeleting {
                ProgressView("正在删除…")
                    .padding(16)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .disabled(isDeleting)
    }

    private var selectableItems: [Recording] {
        library.items.filter { !$0.isLive && !$0.info.tracks.isEmpty }
    }

    private var selectedItems: [Recording] {
        library.items.filter { selectedRecordingIDs.contains($0.id) && !$0.isLive && !$0.info.tracks.isEmpty }
    }

    private var allSelectableItemsSelected: Bool {
        !selectableItems.isEmpty && selectedRecordingIDs == Set(selectableItems.map(\.id))
    }

    private func toggleSelection(_ item: Recording) {
        if selectedRecordingIDs.contains(item.id) { selectedRecordingIDs.remove(item.id) }
        else { selectedRecordingIDs.insert(item.id) }
    }

    private func requestDeletion(_ items: [Recording]) {
        guard !items.isEmpty else { return }
        pendingDeletion = DeletionRequest(items: items)
    }

    private func performQueuedDeletion() {
        guard let action = queuedDeletion else { return }
        queuedDeletion = nil
        isDeleting = true
        Task { @MainActor in
            defer { isDeleting = false }
            // Wait for the sheet dismissal animation before changing the List's data source.
            try? await Task.sleep(nanoseconds: 350_000_000)
            do {
                try await library.delete(ids: Set(action.request.items.map(\.id)), fromList: action.fromList,
                                         filesCopy: action.filesCopy, iCloudCopy: action.iCloudCopy)
                if action.fromList {
                    // Keep rows in selection presentation until SwiftUI commits the item removals.
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    selectedRecordingIDs.subtract(action.request.items.map(\.id))
                    isSelecting = false
                }
            } catch {
                deletionError = error.localizedDescription
            }
        }
    }

    private enum BatchExportSelection {
        case phone, microphone, automatic, manual
    }

    @MainActor
    private func exportSelected(_ selection: BatchExportSelection) async {
        isExporting = true
        defer { isExporting = false }
        do {
            var files: [URL] = []
            for item in selectedItems {
                switch selection {
                case .phone:
                    guard item.info.tracks["app"] != nil else { continue }
                    files.append(try await AudioMix.exportTrack(item, key: "app"))
                case .microphone:
                    guard item.info.tracks["mic"] != nil else { continue }
                    files.append(try await AudioMix.exportTrack(item, key: "mic"))
                case .automatic:
                    let levels: MixLevels
                    if item.info.tracks["app"] != nil, item.info.tracks["mic"] != nil {
                        levels = try await Task.detached(priority: .utility) {
                            try AudioMix.automaticLevels(for: item)
                        }.value
                    } else {
                        levels = .neutral
                    }
                    files.append(try await AudioMix.export(item, levels: levels))
                case .manual:
                    let levels = MixLevels.load(item.dir)
                    files.append(try await AudioMix.export(item, levels: levels))
                }
            }
            guard !files.isEmpty else { return }
            exportFiles = files
        } catch {
            exportError = error.localizedDescription
        }
    }
}

private struct DeletionRequest: Identifiable {
    let id = UUID()
    let items: [Recording]
}

private struct DeletionAction {
    let request: DeletionRequest
    let fromList: Bool
    let filesCopy: Bool
    let iCloudCopy: Bool
}

private struct DeleteCopiesSheet: View {
    @Environment(\.dismiss) private var dismiss
    let recordingCount: Int
    let filesCopyCount: Int
    let iCloudCopyCount: Int
    let onDelete: (Bool, Bool, Bool) -> Void

    @State private var deleteFromList = true
    @State private var deleteFilesCopy = true
    @State private var deleteICloudCopy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("录音列表中的副本（\(recordingCount)）", isOn: $deleteFromList)
                    Toggle("“文件”里的本机副本（\(filesCopyCount)）", isOn: $deleteFilesCopy)
                        .disabled(filesCopyCount == 0)
                    Toggle("iCloud 已同步副本（\(iCloudCopyCount)）", isOn: $deleteICloudCopy)
                        .disabled(iCloudCopyCount == 0)
                } footer: {
                    Text("只删除勾选的副本。若无法访问原 iCloud 文件夹，删除会停止并保留录音列表条目，方便重试。")
                }
            }
            .navigationTitle("选择要删除的副本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("删除", role: .destructive) {
                        onDelete(deleteFromList, deleteFilesCopy, deleteICloudCopy)
                        dismiss()
                    }
                    .disabled(!deleteFromList && !deleteFilesCopy && !deleteICloudCopy)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private struct ActivityShareSheet: UIViewControllerRepresentable {
    let activityItems: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        controller.popoverPresentationController?.sourceView = controller.view
        controller.popoverPresentationController?.sourceRect = CGRect(x: controller.view.bounds.midX,
                                                                       y: controller.view.bounds.midY,
                                                                       width: 0, height: 0)
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct SyncSettingsView: View {
    @EnvironmentObject private var library: Library
    @ObservedObject private var connectivity = Connectivity.shared
    @State private var iCloudSyncMode = SyncPolicy.mode
    @State private var mixPreference = MixPreference.load()
    @State private var actionButtonMode = ActionButtonPreference.mode
    @State private var pickingFolder = false
    @State private var exportFolder = Export.folderDisplayName

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
                VStack(alignment: .leading, spacing: 6) {
                    Text(actionButtonDescription)
                    Text("待命模式会让录屏会话常驻；开始前仍需在系统面板点一次「开始直播」。")
                    NavigationLink("如何设置 iPhone 操作按钮") { ActionButtonHelp() }
                }
            }
            Section {
                Button { pickingFolder = true } label: {
                    LabeledContent("iCloud 文件夹", value: exportFolder ?? "未选择")
                }
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
        .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            try? Export.setFolder(url)
            exportFolder = Export.folderDisplayName
            if connectivity.maySyncNow { Export.copyPending() }
            library.reload()
        }
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
