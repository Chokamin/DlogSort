import AVFoundation
import AppKit
import Sparkle
import SwiftUI
import UniformTypeIdentifiers

// DJI 在 MP4 的 moov/meta 里写入 mdta 键 com.dji.camera.ColorGammaSxS，值为 "D-Log" 或 "D-Log2"
let gammaKey = "mdta/com.dji.camera.ColorGammaSxS"
let lensKey = "mdta/com.dji.camera.LensType"
let isoKey = "mdta/com.dji.camera.ExposureIndexAsa"
let videoExts: Set<String> = ["mp4", "mov"]
let sidecarExts = ["LRF", "lrf", "SRT", "srt"]
let tagsAttr = "com.apple.metadata:_kMDItemUserTags"

extension Color {
    init(hex: UInt32) {
        self.init(.displayP3, red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

enum Mode: String {
    case dlog = "D-Log"
    case dlog2 = "D-Log2"
    case other = "其他"
    case unknown = "未识别"
    case pending = "读取中"

    // 与图标里的两条曲线同色
    var color: Color {
        switch self {
        case .dlog: return Color(hex: 0xFF7A33)
        case .dlog2: return Color(hex: 0x8B6CFF)
        case .other: return .gray
        case .unknown: return Color(hex: 0xE5484D)
        case .pending: return .secondary
        }
    }

    // Finder 标签颜色编号：7 橙色，3 紫色
    var tagColor: Int? {
        switch self {
        case .dlog: return 7
        case .dlog2: return 3
        default: return nil
        }
    }

    var folderName: String? {
        switch self {
        case .dlog: return "Dlog"
        case .dlog2: return "Dlog2"
        default: return nil
        }
    }
}

struct ClipInfo {
    var mode: Mode = .unknown
    var rawGamma = ""
    var lens = ""
    var iso = ""
    var duration: Double = 0
    var size: CGSize = .zero
    var fps: Float = 0
}

struct Clip: Identifiable {
    let id = UUID()
    var url: URL
    var info: ClipInfo?
    var thumb: CGImage?

    var mode: Mode { info?.mode ?? .pending }
    var modeLabel: String { mode == .other ? (info?.rawGamma ?? "") : mode.rawValue }
}

// 以下函数都不在主线程上运行，读文件、写标签、移动文件时界面保持响应

func collectVideos(_ urls: [URL]) -> [URL] {
    var found: [URL] = []
    let fm = FileManager.default
    for url in urls {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
        if isDir.boolValue {
            let e = fm.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            while let f = e?.nextObject() as? URL {
                if videoExts.contains(f.pathExtension.lowercased()) { found.append(f) }
            }
        } else if videoExts.contains(url.pathExtension.lowercased()) {
            found.append(url)
        }
    }
    return found
}

// 读取模式和参数，顺便拿到 DJI 内嵌的预览图（itsk/covr 是 960×540 JPEG，itsk/tnal 是小图），
// 有内嵌图就不必解码 4K HEVC 视频来生成缩略图
func loadClip(_ url: URL) async -> (URL, ClipInfo, CGImage?) {
    let asset = AVURLAsset(url: url)
    var info = ClipInfo()
    guard let items = try? await asset.load(.metadata) else { return (url, info, nil) }
    var gamma = ""
    var cover: Data?, small: Data?
    for item in items {
        switch item.identifier?.rawValue {
        case gammaKey: gamma = (try? await item.load(.stringValue)) ?? ""
        case lensKey: info.lens = (try? await item.load(.stringValue)) ?? ""
        case isoKey: info.iso = ((try? await item.load(.stringValue)) ?? "").trimmingCharacters(in: .whitespaces)
        case "itsk/covr": cover = try? await item.load(.dataValue)
        case "itsk/tnal": small = try? await item.load(.dataValue)
        default: break
        }
    }
    info.rawGamma = gamma.trimmingCharacters(in: .whitespaces)
    switch info.rawGamma.lowercased() {
    case "d-log": info.mode = .dlog
    case "d-log2": info.mode = .dlog2
    case "": info.mode = .unknown
    default: info.mode = .other
    }
    info.duration = (try? await asset.load(.duration).seconds) ?? 0
    if let track = try? await asset.loadTracks(withMediaType: .video).first {
        info.size = (try? await track.load(.naturalSize)) ?? .zero
        info.fps = (try? await track.load(.nominalFrameRate)) ?? 0
    }
    var thumb = (cover ?? small).flatMap(decodeThumbnail)
    if thumb == nil { thumb = await makeThumbnail(asset) }
    return (url, info, thumb)
}

func decodeThumbnail(_ data: Data) -> CGImage? {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                 kCGImageSourceThumbnailMaxPixelSize: 320]
    return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
}

func makeThumbnail(_ asset: AVAsset) async -> CGImage? {
    let gen = AVAssetImageGenerator(asset: asset)
    gen.appliesPreferredTrackTransform = true
    gen.maximumSize = CGSize(width: 320, height: 180)
    gen.requestedTimeToleranceAfter = .positiveInfinity
    return try? await gen.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
}

// Finder 只认它自己登记过颜色的标签。以前直接往文件里写「Dlog + 橙色编号」，
// 一旦在 Finder 里打开标签编辑器，Finder 会按自己的登记重写，没登记颜色的 Dlog 就变回无色。
// 现在名称标签（Dlog / Dlog2）不带颜色，颜色交给 Finder 内置的颜色标签（中文系统叫「橙色」「紫色」，
// 英文叫 Orange / Purple，用户也可能改过名），并全部通过系统标签接口写入，颜色由系统按 Finder 的登记分配

// 读文件扩展属性里的原始标签，每项为 "名称\n颜色编号"
func rawTags(_ url: URL) -> [String] {
    let size = getxattr(url.path, tagsAttr, nil, 0, 0, 0)
    guard size > 0 else { return [] }
    var data = Data(count: size)
    _ = data.withUnsafeMutableBytes { getxattr(url.path, tagsAttr, $0.baseAddress, size, 0, 0) }
    return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String] ?? []
}

// 找出这台 Mac 上颜色编号为 color 的标签名：把候选名写到临时文件上，看系统分配给它的颜色
@MainActor
func finderColorTagName(_ color: Int) -> String? {
    let fm = FileManager.default
    let probe = fm.temporaryDirectory.appendingPathComponent("DlogSort-tag-\(UUID().uuidString)")
    guard fm.createFile(atPath: probe.path, contents: nil) else { return nil }
    defer { try? fm.removeItem(at: probe) }
    let favorites = CFPreferencesCopyAppValue("FavoriteTagNames" as CFString, "com.apple.finder" as CFString) as? [String] ?? []
    let builtin = color == 7 ? ["橙色", "Orange"] : ["紫色", "Purple"]
    for name in favorites + NSWorkspace.shared.fileLabels + builtin where !name.isEmpty {
        try? (probe as NSURL).setResourceValue([name], forKey: .tagNamesKey)
        if rawTags(probe) == ["\(name)\n\(color)"] { return name }
    }
    return nil
}

// 保留文件原有的其他标签，去掉旧的 Dlog / Dlog2，再加上名称标签和颜色标签
func writeTag(_ url: URL, tag: String, colorTag: String?) -> Bool {
    var names = rawTags(url).map { $0.components(separatedBy: "\n")[0] }
    names.removeAll { $0 == "Dlog" || $0 == "Dlog2" }
    names.append(tag)
    if let colorTag, !names.contains(colorTag) { names.append(colorTag) }
    // URLResourceValues.tagNames 的 setter 要 macOS 26，用 NSURL 的写法兼容旧系统
    return (try? (url as NSURL).setResourceValue(names, forKey: .tagNamesKey)) != nil
}

// 移到所在目录下的 Dlog / Dlog2 子文件夹，返回移动成功的新位置
func moveClip(_ src: URL, into folder: String) -> (URL?, failed: Bool) {
    let fm = FileManager.default
    let parent = src.deletingLastPathComponent()
    // 已经在对应文件夹里就跳过
    if parent.lastPathComponent == folder { return (nil, false) }
    let dir = parent.appendingPathComponent(folder, isDirectory: true)
    let dst = dir.appendingPathComponent(src.lastPathComponent)
    do {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        guard !fm.fileExists(atPath: dst.path) else { return (nil, true) }
        try fm.moveItem(at: src, to: dst)
    } catch {
        return (nil, true)
    }
    // 同名的 LRF 代理文件、SRT 字幕一起移动
    let stem = src.deletingPathExtension()
    for ext in sidecarExts {
        let side = stem.appendingPathExtension(ext)
        let sideDst = dir.appendingPathComponent(side.lastPathComponent)
        if fm.fileExists(atPath: side.path), !fm.fileExists(atPath: sideDst.path) {
            try? fm.moveItem(at: side, to: sideDst)
        }
    }
    return (dst, false)
}

struct Toast: Equatable {
    let id = UUID()
    let icon: String
    let text: String
    var warning = false
}

struct Activity: Equatable {
    var label: String
    var done: Int
    var total: Int
}

@MainActor
final class Store: ObservableObject {
    static let shared = Store()
    @Published var clips: [Clip] = []
    @Published var toast: Toast?
    // 读取、打标签、整理时显示在底栏的进度
    @Published var activity: Activity?

    private var queue: [URL] = []
    private var loader: Task<Void, Never>?
    private var loadDone = 0, loadTotal = 0
    private var generation = 0

    func show(_ icon: String, _ text: String, warning: Bool = false) {
        let t = Toast(icon: icon, text: text, warning: warning)
        withAnimation(.spring(duration: 0.35)) { toast = t }
        Task {
            try? await Task.sleep(for: .seconds(3))
            if toast == t { withAnimation(.easeOut(duration: 0.25)) { toast = nil } }
        }
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.movie, .folder]
        panel.prompt = "添加"
        if panel.runModal() == .OK { add(panel.urls) }
    }

    func add(_ urls: [URL]) {
        Task {
            let found = await Task.detached(priority: .userInitiated) { collectVideos(urls) }.value
            let existing = Set(clips.map { $0.url.standardizedFileURL })
            let fresh = found.filter { !existing.contains($0.standardizedFileURL) }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            guard !fresh.isEmpty else {
                show("film.stack", "没有找到新的 MP4 / MOV 视频", warning: true)
                return
            }
            withAnimation(.snappy) { clips.append(contentsOf: fresh.map { Clip(url: $0) }) }
            queue.append(contentsOf: fresh)
            loadTotal += fresh.count
            activity = Activity(label: "正在读取", done: loadDone, total: loadTotal)
            if loader == nil {
                let gen = generation
                loader = Task { await runLoader(gen) }
            }
        }
    }

    // 最多同时读 6 个文件，结果攒起来每 0.15 秒刷新一次列表，避免几百次逐个刷新拖慢界面
    private func runLoader(_ gen: Int) async {
        while !queue.isEmpty, gen == generation {
            let batch = queue
            queue.removeAll()
            await withTaskGroup(of: (URL, ClipInfo, CGImage?).self) { group in
                var pending = batch.makeIterator()
                for _ in 0..<6 {
                    guard let u = pending.next() else { break }
                    group.addTask { await loadClip(u) }
                }
                var results: [(URL, ClipInfo, CGImage?)] = []
                var lastFlush = Date()
                for await r in group {
                    guard gen == generation else { group.cancelAll(); return }
                    results.append(r)
                    if let u = pending.next() { group.addTask { await loadClip(u) } }
                    if Date().timeIntervalSince(lastFlush) > 0.15 {
                        apply(results)
                        results.removeAll()
                        lastFlush = Date()
                    }
                }
                apply(results)
            }
        }
        guard gen == generation else { return }
        loader = nil
        loadDone = 0
        loadTotal = 0
        activity = nil
    }

    private func apply(_ results: [(URL, ClipInfo, CGImage?)]) {
        guard !results.isEmpty else { return }
        var updated = clips
        var index: [URL: Int] = [:]
        for (i, c) in updated.enumerated() { index[c.url] = i }
        for (url, info, thumb) in results {
            guard let i = index[url] else { continue }
            updated[i].info = info
            updated[i].thumb = thumb
        }
        clips = updated
        loadDone += results.count
        activity = Activity(label: "正在读取", done: loadDone, total: loadTotal)
    }

    func remove(_ ids: Set<Clip.ID>) {
        withAnimation(.snappy) { clips.removeAll { ids.contains($0.id) } }
    }

    func clear() {
        // 让还在跑的读取任务作废，它之后返回的结果不会再写进列表
        generation += 1
        loader?.cancel()
        loader = nil
        queue.removeAll()
        loadDone = 0
        loadTotal = 0
        activity = nil
        withAnimation(.snappy) { clips = [] }
    }

    func count(_ modes: Mode...) -> Int { clips.filter { modes.contains($0.mode) }.count }

    var sortable: Int { count(.dlog, .dlog2) }
    var isBusy: Bool { activity != nil }

    // 在后台逐个处理文件，每处理约 1% 更新一次进度
    private func runInBackground<T: Sendable>(_ label: String, _ items: [T],
                                              _ work: @escaping @Sendable (T) -> Void) async {
        let total = items.count
        activity = Activity(label: label, done: 0, total: total)
        let step = max(1, total / 100)
        await Task.detached(priority: .userInitiated) {
            for (i, item) in items.enumerated() {
                work(item)
                if (i + 1) % step == 0 || i + 1 == total {
                    let done = i + 1
                    await MainActor.run { Store.shared.activity?.done = done }
                }
            }
        }.value
        activity = nil
    }

    func applyTags() {
        let colorTags = [7: finderColorTagName(7), 3: finderColorTagName(3)]
        let jobs = clips.compactMap { c -> (URL, String, String?)? in
            guard let tag = c.mode.folderName, let color = c.mode.tagColor else { return nil }
            return (c.url, tag, colorTags[color] ?? nil)
        }
        Task {
            let ok = Counter()
            await runInBackground("正在打标签", jobs) { job in
                if writeTag(job.0, tag: job.1, colorTag: job.2) { ok.add() }
            }
            show("tag.fill", "已为 \(ok.value) 个视频添加 Finder 标签")
        }
    }

    // 导出给达芬奇「文件 → 导入元数据 → 媒体池」用的 CSV：按文件名匹配片段，写入关键词 D-Log / D-Log2。
    // 列名必须和达芬奇的元数据字段名一致；不能带 BOM，否则第一列表头匹配不上
    func exportResolveCSV() {
        let rows = clips.filter { $0.mode.folderName != nil }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "DlogSort 达芬奇元数据.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var lines = ["File Name,Clip Directory,Keywords"]
        for c in rows {
            lines.append([c.url.lastPathComponent, c.url.deletingLastPathComponent().path, c.mode.rawValue]
                .map(csvField).joined(separator: ","))
        }
        do {
            try Data((lines.joined(separator: "\r\n") + "\r\n").utf8).write(to: url)
        } catch {
            show("exclamationmark.triangle.fill", "导出失败：\(error.localizedDescription)", warning: true)
            return
        }
        let alert = NSAlert()
        alert.messageText = "已导出 \(rows.count) 个片段的达芬奇元数据"
        alert.informativeText = """
        在达芬奇里：
        1. 把这些视频导入媒体池
        2. 选择「文件 → 导入元数据至 → 媒体池」，选中这个 CSV
        3. 勾选「用文件名称匹配」，取消勾选「使用片段起始和终止时间码匹配」，点确定
        4. 片段会带上关键词 D-Log 或 D-Log2：在元数据面板的「Shot & Scene」组里查看，或在媒体池列表视图中显示「关键词」列
        5. 在偏好设置 → 用户 → 剪辑 →「自动智能媒体夹」里勾选「关键词」，媒体池的智能媒体夹里就会出现 D-Log 和 D-Log2
        """
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "在 Finder 中显示")
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func sortIntoFolders() {
        let jobs = clips.compactMap { c in c.mode.folderName.map { (c.id, c.url, $0) } }
        Task {
            let moved = Results<(UUID, URL)>()
            let failed = Counter()
            await runInBackground("正在整理", jobs) { job in
                let (dst, didFail) = moveClip(job.1, into: job.2)
                if let dst { moved.append((job.0, dst)) }
                if didFail { failed.add() }
            }
            let newURLs = Dictionary(moved.items, uniquingKeysWith: { a, _ in a })
            var updated = clips
            for i in updated.indices { if let u = newURLs[updated[i].id] { updated[i].url = u } }
            clips = updated
            if failed.value > 0 {
                show("exclamationmark.triangle.fill",
                     "已移动 \(newURLs.count) 个，\(failed.value) 个失败（目标已存在或无权限）", warning: true)
            } else {
                show("checkmark.circle.fill", newURLs.isEmpty ? "视频都已在对应文件夹中" : "已整理 \(newURLs.count) 个视频")
            }
        }
    }
}

// 后台任务里累计结果用，加锁保证线程安全
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

final class Results<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [T] = []
    func append(_ x: T) { lock.lock(); list.append(x); lock.unlock() }
    var items: [T] { lock.lock(); defer { lock.unlock() }; return list }
}

enum Filter: String, CaseIterable, Identifiable {
    case all = "全部", dlog = "D-Log", dlog2 = "D-Log2", other = "其他"
    var id: Self { self }

    func matches(_ c: Clip) -> Bool {
        switch self {
        case .all: return true
        case .dlog: return c.mode == .dlog
        case .dlog2: return c.mode == .dlog2
        case .other: return c.mode == .other || c.mode == .unknown
        }
    }
}

func csvField(_ s: String) -> String {
    s.contains(where: { ",\"\r\n".contains($0) }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
}

func formatDuration(_ s: Double) -> String {
    guard s.isFinite, s > 0 else { return "" }
    let t = Int(s.rounded())
    return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
                     : String(format: "%d:%02d", t / 60, t % 60)
}

func displayFolder(_ url: URL) -> String {
    (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
}

// MARK: - 视图

struct ContentView: View {
    @ObservedObject var store = Store.shared
    @State private var targeted = false
    @State private var confirmMove = false
    @State private var filter = Filter.all
    @State private var selection = Set<Clip.ID>()

    var filtered: [Clip] { store.clips.filter(filter.matches) }

    var body: some View {
        Group {
            if store.clips.isEmpty {
                EmptyDropZone(targeted: targeted) { store.openPanel() }
            } else {
                clipList
                    .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
                    .overlay { if targeted { DropOverlay() } }
            }
        }
        .frame(minWidth: 820, minHeight: 440)
        .overlay(alignment: .bottom) {
            if let t = store.toast {
                ToastView(toast: t)
                    .padding(.bottom, store.clips.isEmpty ? 28 : 78)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .navigationTitle("DlogSort")
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .onDrop(of: [.fileURL], isTargeted: $targeted.animation(.easeOut(duration: 0.15))) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in Store.shared.add([url]) } }
                }
            }
            return true
        }
        .confirmationDialog("整理到 Dlog / Dlog2 文件夹？", isPresented: $confirmMove) {
            Button("移动 \(store.sortable) 个视频") { store.sortIntoFolders() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("每个视频会移到它所在目录下的 Dlog 或 Dlog2 子文件夹，同名的 .LRF 代理文件和 .SRT 字幕一起移动。未识别的视频保持不动。")
        }
    }

    var subtitle: String {
        if store.clips.isEmpty { return "" }
        if let a = store.activity { return "\(a.label) \(a.done)/\(a.total)…" }
        return "\(store.clips.count) 个视频"
    }

    @ToolbarContentBuilder
    var toolbar: some ToolbarContent {
        if !store.clips.isEmpty {
            ToolbarItem(placement: .principal) {
                Picker("筛选", selection: $filter.animation(.snappy)) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 280)
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { store.openPanel() } label: { Label("添加视频", systemImage: "plus") }
                .help("添加视频或文件夹（⌘O）")
            if !store.clips.isEmpty {
                Button { store.clear(); selection = [] } label: { Label("清空列表", systemImage: "xmark.circle") }
                    .help("清空列表（不会删除文件）")
                    // 打标签、整理进行中不能清空，读取中可以
                    .disabled(store.isBusy && store.activity?.label != "正在读取")
            }
        }
    }

    var clipList: some View {
        List(selection: $selection) {
            ForEach(filtered) { clip in
                ClipRow(clip: clip).tag(clip.id)
            }
        }
        .listStyle(.inset)
        .overlay {
            if filtered.isEmpty {
                ContentUnavailableView("没有\(filter.rawValue)视频", systemImage: "line.3.horizontal.decrease.circle",
                                       description: Text("换个筛选条件看看"))
            }
        }
        .contextMenu(forSelectionType: Clip.ID.self) { ids in
            let urls = store.clips.filter { ids.contains($0.id) }.map(\.url)
            Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting(urls) }
            Button("用默认播放器打开") { urls.forEach { NSWorkspace.shared.open($0) } }
            Divider()
            Button("从列表中移除") { store.remove(ids); selection.subtract(ids) }
        } primaryAction: { ids in
            store.clips.filter { ids.contains($0.id) }.forEach { NSWorkspace.shared.open($0.url) }
        }
        .onDeleteCommand { store.remove(selection); selection = [] }
    }

    var bottomBar: some View {
        HStack(spacing: 18) {
            if let a = store.activity {
                ActivityView(activity: a)
            } else {
                StatView(mode: .dlog, count: store.count(.dlog))
                StatView(mode: .dlog2, count: store.count(.dlog2))
                let others = store.count(.other, .unknown)
                if others > 0 { StatView(mode: .unknown, count: others, label: "未识别") }
            }
            Spacer()
            Button { store.applyTags() } label: { Label("打 Finder 标签", systemImage: "tag") }
                .help("给 D-Log 视频加上 Dlog 和橙色标签、D-Log2 加上 Dlog2 和紫色标签，文件不移动")
            Button { store.exportResolveCSV() } label: { Label("导出到达芬奇", systemImage: "square.and.arrow.up") }
                .help("导出元数据 CSV，在达芬奇里导入后片段会带上 D-Log / D-Log2 关键词")
            Button { confirmMove = true } label: { Label("整理到文件夹", systemImage: "folder.badge.plus") }
                .buttonStyle(.borderedProminent)
                .help("移到所在目录下的 Dlog / Dlog2 子文件夹")
        }
        .controlSize(.large)
        .disabled(store.sortable == 0 || store.isBusy)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

struct ClipRow: View {
    let clip: Clip

    var details: String {
        guard let i = clip.info else { return " " }
        var parts: [String] = []
        if !i.lens.isEmpty { parts.append(i.lens) }
        if !i.iso.isEmpty { parts.append("ISO \(i.iso)") }
        if i.size != .zero { parts.append("\(Int(i.size.width))×\(Int(i.size.height))") }
        if i.fps > 0 { parts.append(String(format: "%g fps", (Double(i.fps) * 100).rounded() / 100)) }
        return parts.isEmpty ? " " : parts.joined(separator: "  ·  ")
    }

    var body: some View {
        HStack(spacing: 14) {
            Thumbnail(image: clip.thumb, duration: clip.info?.duration ?? 0)
            VStack(alignment: .leading, spacing: 3) {
                Text(clip.url.lastPathComponent)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(details)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(displayFolder(clip.url))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 12)
            ModeBadge(mode: clip.mode, label: clip.modeLabel)
        }
        .padding(.vertical, 5)
        .help(clip.url.path)
    }
}

struct Thumbnail: View {
    let image: CGImage?
    let duration: Double

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                Rectangle().fill(.quaternary)
                    .overlay { Image(systemName: "film").foregroundStyle(.tertiary) }
            }
            if !formatDuration(duration).isEmpty {
                Text(formatDuration(duration))
                    .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1.5)
                    .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                    .padding(4)
            }
        }
        .frame(width: 96, height: 54)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(.primary.opacity(0.1), lineWidth: 0.5)
        }
    }
}

struct ModeBadge: View {
    let mode: Mode
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            if mode == .pending {
                ProgressView().controlSize(.mini)
            } else {
                Circle().fill(mode.color).frame(width: 6, height: 6)
            }
            Text(label)
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(mode == .pending ? Color.secondary : mode.color)
        .padding(.horizontal, 10)
        .padding(.vertical, 4.5)
        .background(mode.color.opacity(mode == .pending ? 0.08 : 0.14), in: Capsule())
        .overlay { Capsule().strokeBorder(mode.color.opacity(0.3), lineWidth: 0.5) }
        .frame(minWidth: 92, alignment: .trailing)
        .contentTransition(.opacity)
    }
}

struct ActivityView: View {
    let activity: Activity

    var body: some View {
        HStack(spacing: 12) {
            ProgressView(value: Double(activity.done), total: Double(max(activity.total, 1)))
                .progressViewStyle(.linear)
                .frame(width: 180)
            Text("\(activity.label)  \(activity.done) / \(activity.total)")
                .font(.system(size: 12.5).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .transition(.opacity)
    }
}

struct StatView: View {
    let mode: Mode
    let count: Int
    var label: String? = nil

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(mode.color).frame(width: 8, height: 8)
            Text("\(count)")
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .contentTransition(.numericText())
            Text(label ?? mode.rawValue)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .animation(.snappy, value: count)
    }
}

struct EmptyDropZone: View {
    let targeted: Bool
    let choose: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 7) {
                Text(targeted ? "松开以添加" : "拖入 DJI 视频或文件夹")
                    .font(.system(size: 22, weight: .semibold))
                Text("自动识别每段视频是 D-Log 还是 D-Log2")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Button(action: choose) { Text("选择文件…").frame(minWidth: 110) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            Text("支持 MP4 / MOV · 直接读取相机写入的元数据，不靠画面猜测")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.accentColor.opacity(targeted ? 0.07 : 0))
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: targeted ? 2 : 1.5, dash: [7, 6]))
                .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.3))
        }
        .padding(22)
        .animation(.snappy, value: targeted)
    }
}

struct DropOverlay: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [7, 6]))
            Label("松开以添加", systemImage: "plus.circle.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.accentColor)
        }
        .padding(12)
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}

struct ToastView: View {
    let toast: Toast

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: toast.icon)
                .foregroundStyle(toast.warning ? Color.orange : Color.green)
            Text(toast.text)
        }
        .font(.system(size: 12.5, weight: .medium))
        .padding(.horizontal, 15)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay { Capsule().strokeBorder(.primary.opacity(0.08), lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
    }
}

// MARK: - 检查更新
// 用 Sparkle：读取 GitHub Pages 上的 appcast.xml，有新版本时弹出标准的更新窗口，
// 下载后校验签名、替换应用并重新打开。启动后按 Sparkle 默认的间隔（一天）自动检查

@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    @Published var canCheck = false

    private init() {
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
    }

    func check() { controller.checkForUpdates(nil) }
}

struct CheckForUpdatesButton: View {
    @ObservedObject var updater = Updater.shared

    var body: some View {
        Button("检查更新…") { updater.check() }
            .disabled(!updater.canCheck)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // 把文件拖到 Dock 图标上
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in Store.shared.add(urls) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct DlogSortApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    init() { _ = Updater.shared }

    var body: some Scene {
        Window("DlogSort", id: "main") { ContentView() }
            .defaultSize(width: 920, height: 580)
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button("添加视频…") { Store.shared.openPanel() }
                        .keyboardShortcut("o")
                }
                CommandGroup(after: .appInfo) {
                    CheckForUpdatesButton()
                }
            }
    }
}
