<p align="center"><img src="docs/icon.png" width="128" alt="DlogSort 图标"></p>

<h1 align="center">DlogSort</h1>

<p align="center">一眼分辨 DJI Pocket 4P 拍的视频是 <b>D-Log</b> 还是 <b>D-Log2</b>，并一键整理。</p>

---

DJI Osmo Pocket 4P 有 D-Log 和 D-Log2 两种色彩模式，但导入电脑后文件名完全一样，没法直接区分。DlogSort 读取相机写进视频文件里的元数据，自动标出每段视频的模式。

## 功能

- **拖进来就识别**：把视频或整个文件夹拖进窗口（或拖到 Dock 图标上），子文件夹也会扫描
- **列表展示**：缩略图、时长、镜头、ISO、分辨率、帧率，以及醒目的 D-Log / D-Log2 标记
- **筛选**：全部 / D-Log / D-Log2 / 其他
- **打 Finder 标签**：给视频加上 `Dlog` 或 `Dlog2` 标签，文件位置不变
- **整理到文件夹**：移到所在目录下的 `Dlog/`、`Dlog2/` 子文件夹，同名 `.LRF` 代理文件和 `.SRT` 字幕一起移动
- 双击播放，右键在 Finder 中显示，⌘O 添加文件

## 原理

不分析画面，而是直接读取 DJI 写入 MP4 元数据的字段：

```
com.dji.camera.ColorGammaSxS = D-Log | D-Log2
```

所以结果是确定的，不会误判。用 `ffprobe` 也能看到这个字段：

```bash
ffprobe -v error -show_entries format_tags=com.dji.camera.ColorGammaSxS -of default=nw=1 视频.MP4
```

## 下载

到 [Releases](../../releases) 下载 `DlogSort.zip`，解压后拖进「应用程序」文件夹。

- 需要 macOS 14 或更新版本，Apple 芯片和 Intel Mac 都支持
- 应用没有经过 Apple 公证，第一次打开时请 **右键点应用 → 打开**；或者到「系统设置 → 隐私与安全性」里点「仍要打开」

## 从源码构建

需要 Xcode 命令行工具（装了完整 Xcode 时，图标会编译成 macOS 26 的新格式）：

```bash
./DlogSort/build.sh
```

会在仓库根目录生成 `DlogSort.app`。

| 文件 | 作用 |
|---|---|
| `DlogSort/main.swift` | 应用全部代码（SwiftUI + AVFoundation） |
| `DlogSort/make_icon.swift` | 用代码绘制应用图标 |
| `DlogSort/build.sh` | 编译、生成图标、打包签名 |

## 适用范围

- 已验证：DJI Osmo Pocket 4P 的 D-Log 和 D-Log2
- 其他大疆设备如果写了同一个字段，会显示出模式，但只有 D-Log / D-Log2 会被整理
- 其他品牌（索尼 S-Log、Apple Log 等）的元数据格式不同，会显示为「未识别」
