// 绘制 DlogSort 图标：深色石墨底板上，两条从同一点出发的 Log 曲线分岔
// 橙色 = D-Log，紫色 = D-Log2（与软件里的颜色一致）
// 用法: swift make_icon.swift 输出.png [--full-bleed]
// --full-bleed 画满整个方形画布，不带圆角、投影和描边，交给系统套用 macOS 26+ 的图标外形
import AppKit
import CoreGraphics

let size = 1024
let cs = CGColorSpace(name: CGColorSpace.displayP3)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat((hex >> 16) & 0xFF) / 255,
                                          CGFloat((hex >> 8) & 0xFF) / 255,
                                          CGFloat(hex & 0xFF) / 255, a])!
}

func gradient(_ colors: [CGColor], _ locs: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: locs)!
}

// macOS 风格的连续圆角（超椭圆）底板，四周留出 100px 的标准边距
func squircle(_ r: CGRect) -> CGPath {
    let p = CGMutablePath()
    let n: CGFloat = 5
    let a = r.width / 2, b = r.height / 2, cx = r.midX, cy = r.midY
    for i in 0...720 {
        let t = CGFloat(i) / 720 * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * copysign(pow(abs(c), 2 / n), c)
        let y = cy + b * copysign(pow(abs(s), 2 / n), s)
        i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
    }
    p.closeSubpath()
    return p
}

let fullBleed = CommandLine.arguments.contains("--full-bleed")
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = fullBleed ? CGPath(rect: tile, transform: nil) : squircle(tile)

// 满版模式下把 824px 的底板放大铺满画布，其余绘制代码不变
if fullBleed {
    let k = CGFloat(size) / tile.width
    ctx.scaleBy(x: k, y: k)
    ctx.translateBy(x: -tile.minX, y: -tile.minY)
}

// 底板投影
if !fullBleed {
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: rgb(0x000000, 0.45))
ctx.addPath(tilePath)
ctx.setFillColor(rgb(0x15151B))
ctx.fillPath()
ctx.restoreGState()
}

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()

// 石墨渐变
ctx.drawLinearGradient(gradient([rgb(0x2E2D36), rgb(0x16161C), rgb(0x0B0B0F)], [0, 0.55, 1]),
                       start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
// 曲线分岔处的暖色与冷色光晕
ctx.drawRadialGradient(gradient([rgb(0xFF7A3D, 0.20), rgb(0xFF7A3D, 0)], [0, 1]),
                       startCenter: CGPoint(x: 700, y: 700), startRadius: 0,
                       endCenter: CGPoint(x: 700, y: 700), endRadius: 420, options: [])
ctx.drawRadialGradient(gradient([rgb(0x7B5CFF, 0.22), rgb(0x7B5CFF, 0)], [0, 1]),
                       startCenter: CGPoint(x: 720, y: 420), startRadius: 0,
                       endCenter: CGPoint(x: 720, y: 420), endRadius: 420, options: [])

// 细网格，像调色软件里的曲线面板
let chart = CGRect(x: 236, y: 236, width: 552, height: 552)
ctx.setLineWidth(2)
ctx.setStrokeColor(rgb(0xFFFFFF, 0.055))
for i in 0...4 {
    let f = CGFloat(i) / 4
    ctx.move(to: CGPoint(x: chart.minX + chart.width * f, y: chart.minY))
    ctx.addLine(to: CGPoint(x: chart.minX + chart.width * f, y: chart.maxY))
    ctx.move(to: CGPoint(x: chart.minX, y: chart.minY + chart.height * f))
    ctx.addLine(to: CGPoint(x: chart.maxX, y: chart.minY + chart.height * f))
}
ctx.strokePath()

// Log 曲线：y = log(1 + k·x) / log(1 + k)，再缩放到终点高度
func logCurve(k: CGFloat, endY: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let start = CGPoint(x: chart.minX, y: chart.minY + 20)
    for i in 0...200 {
        let x = CGFloat(i) / 200
        let y = log(1 + k * x) / log(1 + k)
        let pt = CGPoint(x: start.x + chart.width * x, y: start.y + (endY - start.y) * y)
        i == 0 ? p.move(to: pt) : p.addLine(to: pt)
    }
    return p
}

func drawCurve(_ path: CGPath, colors: [CGColor], glow: CGColor, end: CGPoint) {
    let stroked = path.copy(strokingWithWidth: 34, lineCap: .round, lineJoin: .round, miterLimit: 10)
    // 外发光
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 46, color: glow)
    ctx.addPath(stroked)
    ctx.setFillColor(colors.last!)
    ctx.fillPath()
    ctx.restoreGState()
    // 沿曲线方向的渐变
    ctx.saveGState()
    ctx.addPath(stroked)
    ctx.clip()
    ctx.drawLinearGradient(gradient(colors, [0, 1]), start: CGPoint(x: chart.minX, y: chart.minY),
                           end: CGPoint(x: chart.maxX, y: chart.maxY), options: [])
    // 顶部一道细高光，增加立体感
    ctx.drawLinearGradient(gradient([rgb(0xFFFFFF, 0.12), rgb(0xFFFFFF, 0)], [0, 1]),
                           start: CGPoint(x: 0, y: chart.maxY), end: CGPoint(x: 0, y: chart.minY), options: [])
    ctx.restoreGState()
    // 终点亮珠
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 30, color: glow)
    ctx.setFillColor(rgb(0xFFFFFF))
    ctx.fillEllipse(in: CGRect(x: end.x - 19, y: end.y - 19, width: 38, height: 38))
    ctx.restoreGState()
}

let dlog2End = CGPoint(x: chart.maxX, y: chart.minY + 300)
let dlogEnd = CGPoint(x: chart.maxX, y: chart.maxY - 10)
drawCurve(logCurve(k: 6, endY: dlog2End.y), colors: [rgb(0xB592FF), rgb(0x5B3BFF)],
          glow: rgb(0x7B5CFF, 0.9), end: dlog2End)
drawCurve(logCurve(k: 30, endY: dlogEnd.y), colors: [rgb(0xFFC46B), rgb(0xFF5A1F)],
          glow: rgb(0xFF7A3D, 0.9), end: dlogEnd)

// 共同起点
ctx.setFillColor(rgb(0xFFFFFF))
ctx.fillEllipse(in: CGRect(x: chart.minX - 18, y: chart.minY + 2, width: 36, height: 36))

ctx.restoreGState()

// 边缘一圈细高光
if !fullBleed {
ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
ctx.addPath(tilePath)
ctx.setLineWidth(4)
ctx.replacePathWithStrokedPath()
ctx.clip()
ctx.drawLinearGradient(gradient([rgb(0xFFFFFF, 0.22), rgb(0xFFFFFF, 0.02)], [0, 1]),
                       start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
ctx.restoreGState()
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: out)
