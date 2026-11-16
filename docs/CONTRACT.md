# Earshot 手机 ⇄ Mac 文件契约 v2

iPhone App `Earshot`（bundle `<prefix>.earshot`，prefix 见 config.example.env）用系统录屏的 Broadcast Upload 扩展只录声音。
扩展和 App 共用 App Group `group.<prefix>.earshot`；Mac 用 `xcrun devicectl` 读写这个 App Group 容器，App 内不含任何网络代码。

## 容器布局（相对 App Group 容器根目录）

录音放在 `Library/` 下：devicectl 的容器访问策略只允许读写 App Group 容器里的 `Library/`，放在根目录会被拒（error 11007）。

```
Library/Recordings/<id>/info.json      手机写：录音元数据（见下）
Library/Recordings/<id>/app.m4a        手机写：手机播放出来的声音（AAC，单声道）；可能不存在
Library/Recordings/<id>/mic.m4a        手机写：麦克风（用户在录屏面板里打开麦克风时才有）；可能不存在
Library/Recordings/<id>/levels.json    手机写：两轨音量（App 本地用，不参与交换）
Library/Recordings/<id>/mac.json       Mac 写：{"version":1,"syncedAt":ISO8601,"title":"短标题"}
Library/Recordings/<id>/summary.md     Mac 写：纪要
Library/Recordings/<id>/transcript.md  Mac 写：带时间戳的文字稿
```

`<id>` 形如 `20261106T155012Z`（UTC 开始时间），按字典序即时间序。
音频是分片 MP4（每 10 秒落一次盘），扩展中途被杀也能读到被杀前的内容。

## info.json

```json
{
  "version": 1,
  "id": "20261106T155012Z",
  "startedAt": "2026-11-06T15:50:12Z",
  "updatedAt": "2026-11-06T16:20:40Z",
  "endedAt": "2026-11-06T16:20:41Z",
  "state": "recording | finished | failed",
  "scene": "conversation | media",
  "tracks": {
    "app": {"file": "app.m4a", "offset": 0.0,  "seconds": 1828.3},
    "mic": {"file": "mic.m4a", "offset": 0.42, "seconds": 1827.9}
  }
}
```

- `scene`（v2 新增，缺省按 `media`）：`conversation` = 手机麦克风录现场对话（App 自己录，只有 mic 轨，文件是 `mic.caf`）；`media` = 系统录屏扩展录手机里正在播放的声音（视频、直播、线上会议、通话），可能带 mic 轨。
- `scene` 还可以是 `mac`：Mac App（`macos/`）录的电脑声音，`app.m4a` 是选中的 App 放出来的声音，`mic.m4a` 是通话时的麦克风；两轨 `offset` 都是 0。Mac 把它写进 `icloud_dir`，文件夹名 `<YYYY-MM-DD HHMM> 电脑声音`（北京时间），和手机的一样由 `earshot.py` 处理。
- 轨道文件名以 `tracks.*.file` 为准：`app.m4a`、`mic.m4a` 或 `mic.caf`（CAF 里是 AAC，被杀时也可读）。
- `offset`：该轨第一个声音相对整段录音起点的秒数；两轨对齐时把 mic 延后 `offset` 秒（app 同理）。
- `seconds`：该轨已写入的时长。`tracks` 里没有的轨就是没录到。
- 录音中扩展每约 10 秒刷新一次 `updatedAt` 和 `seconds`。
- `state == "recording"` 且 `updatedAt` 超过 5 分钟没动：扩展已被系统杀掉，按已结束处理（文件可读）。

## Mac 端约定

- 只处理 `finished`、`failed` 或判定为已中断的录音；`recording` 中的不碰。
- 处理完把 `mac.json`、`summary.md`、`transcript.md` 写回同一目录，手机据此显示"已整理"与纪要。
- 手机上删除录音只删手机这份；Mac 自己的副本和处理记录不受影响，也不会重新拉取。

## 第二条通道：iCloud 云盘文件夹（v2）

用户在 App 里选一次 iCloud 云盘里的文件夹（录音写进它的 `录音` 子文件夹；直接选名为 `录音` 的文件夹则写进它本身），之后每条录音结束时手机把它复制进去：

```
<所选文件夹>/<YYYY-MM-DD HHMM 现场对话|手机声音>/   手机本地时间（北京）
    app.m4a / mic.m4a / mic.caf                     手机先复制音频
    info.json                                       最后复制：出现 info.json 即音频已写完
    纪要.md、文字稿.md、文字稿.srt、mac.json          Mac 处理后写在同一目录
```

Mac 对应路径由配置 `icloud_dir` 指定（默认 `~/Library/Mobile Documents/com~apple~CloudDocs/Earshot/录音`）。同一条录音（按 info.json 的 `id`）无论从 devicectl 还是 iCloud 来，只处理一次。

## iPhone 本地副本与 iCloud 同步设置

- App 还会把已结束录音复制到自身 `Documents/Earshot/<文件夹名> <id>/`，通过 iOS「文件」App 的「我的 iPhone」位置访问。这份副本不属于 App Group，也不改变 `devicectl` 的容器布局。
- 当 `app` 与 `mic` 两轨都存在时，App 会在本机副本中额外生成 `balanced.m4a`。设置里可选自动按两轨多个时间点的采样响度均衡并留峰值余量，或手动调整两轨增益；更改设置会重新生成已有混音。原始分轨不变，单轨录音不生成混音文件。
- iCloud 设置提供「总是」「从不」「仅 Wi-Fi」，只控制是否把录音复制到用户选择的 iCloud 文件夹。「总是」在 Wi-Fi 或蜂窝网络可用时复制；「从不」不复制；「仅 Wi-Fi」只在 Wi-Fi 下复制。Wi-Fi-only 模式下，广播扩展会延迟导出，等 App 前台确认 Wi-Fi 后补传。该偏好保存在 App Group defaults，不写入 `info.json`，也不改变 Mac 的独立 `devicectl` 通道。
- Mac 回写的 `mac.json`、纪要和文字稿会在 App 下次刷新录音库时同步到「文件」里的本地副本。
