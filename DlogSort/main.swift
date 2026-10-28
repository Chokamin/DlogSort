import AVFoundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// DJI 在 MP4 的 moov/meta 里写入 mdta 键 com.dji.camera.ColorGammaSxS，值为 "D-Log" 或 "D-Log2"
let gammaKey = "mdta/com.dji.camera.ColorGammaSxS"
let lensKey = "mdta/com.dji.camera.LensType"
let isoKey = "mdta/com.dji.camera.ExposureIndexAsa"
let videoExts: Set<String> = ["mp4", "mov"]
let sidecarExts = ["LRF", "lrf", "SRT", "srt"]

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

func readInfo(_ url: URL) async -> ClipInfo {
    let asset = AVURLAsset(url: url)
    var info = ClipInfo()
    guard let items = try? await asset.load(.metadata) else { return info }
    var gamma = ""
    for item in items {
        switch item.identifier?.rawValue {
        case gammaKey: gamma = (try? await item.load(.stringValue)) ?? ""
        case lensKey: info.lens = (try? await item.load(.stringValue)) ?? ""
        case isoKey: info.iso = ((try? await item.load(.stringValue)) ?? "").trimmingCharacters(in: .whitespaces)
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
    return info
}

func makeThumbnail(_ url: URL) async -> CGImage? {
    let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    gen.appliesPreferredTrackTransform = true
    gen.maximumSize = CGSize(width: 320, height: 180)
    gen.requestedTimeToleranceAfter = .positiveInfinity
    return try? await gen.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
}

struct Toast: Equatable {
    let id = UUID()
    let icon: String
    let text: String
    var warning = false
}

@MainActor
final class Store: ObservableObject {
    static let shared = Store()
    @Published var clips: [Clip] = []
    @Published var toast: Toast?

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
        let existing = Set(clips.map { $0.url.standardizedFileURL })
        let fresh = found.filter { !existing.contains($0.standardizedFileURL) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard !fresh.isEmpty else {
            show("film.stack", "没有找到新的 MP4 / MOV 视频", warning: true)
            return
        }
        withAnimation(.snappy) { clips.append(contentsOf: fresh.map { Clip(url: $0) }) }
        for url in fresh {
            Task {
                let info = await readInfo(url)
                if let i = clips.firstIndex(where: { $0.url == url }) {
                    withAnimation(.snappy) { clips[i].info = info }
                }
                let thumb = await makeThumbnail(url)
                if let i = clips.firstIndex(where: { $0.url == url }) {
                    withAnimation(.easeIn(duration: 0.2)) { clips[i].thumb = thumb }
                }
            }
        }
    }

    func remove(_ ids: Set<Clip.ID>) {
        withAnimation(.snappy) { clips.removeAll { ids.contains($0.id) } }
    }

    func clear() {
        withAnimation(.snappy) { clips = [] }
    }

    func count(_ modes: Mode...) -> Int { clips.filter { modes.contains($0.mode) }.count }

    var sortable: Int { count(.dlog, .dlog2) }
    var isReading: Bool { count(.pending) > 0 }

    func applyTags() {
        var n = 0
        for c in clips {
            guard let tag = c.mode.folderName else { continue }
            var tags = ((try? c.url.resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? [])
                .filter { $0 != "Dlog" && $0 != "Dlog2" }
            tags.append(tag)
            // URLResourceValues.tagNames 的 setter 要 macOS 26，用 NSURL 的写法兼容旧系统
            if (try? (c.url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)) != nil { n += 1 }
        }
        show("tag.fill", "已为 \(n) 个视频添加 Finder 标签")
    }

    func sortIntoFolders() {
        let fm = FileManager.default
        var moved = 0, failed = 0
        for i in clips.indices {
            guard let folder = clips[i].mode.folderName else { continue }
            let src = clips[i].url
            let parent = src.deletingLastPathComponent()
            // 已经在对应文件夹里就跳过
            if parent.lastPathComponent == folder { continue }
            let dir = parent.appendingPathComponent(folder, isDirectory: true)
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let dst = dir.appendingPathComponent(src.lastPathComponent)
                guard !fm.fileExists(atPath: dst.path) else { failed += 1; continue }
                try fm.moveItem(at: src, to: dst)
                clips[i].url = dst
                moved += 1
                // 同名的 LRF 代理文件、SRT 字幕一起移动
                let stem = src.deletingPathExtension()
                for ext in sidecarExts {
                    let side = stem.appendingPathExtension(ext)
                    let sideDst = dir.appendingPathComponent(side.lastPathComponent)
                    if fm.fileExists(atPath: side.path), !fm.fileExists(atPath: sideDst.path) {
                        try? fm.moveItem(at: side, to: sideDst)
                    }
                }
            } catch {
                failed += 1
            }
        }
        if failed > 0 {
            show("exclamationmark.triangle.fill", "已移动 \(moved) 个，\(failed) 个失败（目标已存在或无权限）", warning: true)
        } else {
            show("checkmark.circle.fill", moved > 0 ? "已整理 \(moved) 个视频" : "视频都已在对应文件夹中")
        }
    }
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
        .frame(minWidth: 680, minHeight: 440)
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
        } message: {
            Text("每个视频会移到它所在目录下的 Dlog 或 Dlog2 子文件夹，同名的 .LRF 代理文件和 .SRT 字幕一起移动。未识别的视频保持不动。")
        }
    }

    var subtitle: String {
        if store.clips.isEmpty { return "" }
        if store.isReading { return "正在读取 \(store.count(.pending)) 个视频…" }
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
            StatView(mode: .dlog, count: store.count(.dlog))
            StatView(mode: .dlog2, count: store.count(.dlog2))
            let others = store.count(.other, .unknown)
            if others > 0 { StatView(mode: .unknown, count: others, label: "未识别") }
            Spacer()
            Button { store.applyTags() } label: { Label("打 Finder 标签", systemImage: "tag") }
                .help("给每个视频加上 Dlog / Dlog2 标签，文件不移动")
            Button { confirmMove = true } label: { Label("整理到文件夹", systemImage: "folder.badge.plus") }
                .buttonStyle(.borderedProminent)
                .help("移到所在目录下的 Dlog / Dlog2 子文件夹")
        }
        .controlSize(.large)
        .disabled(store.sortable == 0 || store.isReading)
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

    var body: some Scene {
        Window("DlogSort", id: "main") { ContentView() }
            .defaultSize(width: 880, height: 580)
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button("添加视频…") { Store.shared.openPanel() }
                        .keyboardShortcut("o")
                }
            }
    }
}
