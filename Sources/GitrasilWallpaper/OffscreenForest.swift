import AppKit
import SwiftUI
import GitrasilCore

/// The forest study (docs/forest/PLAN.md): `--forest <folder>` lays the pinned repositories out as a
/// crowd of N trees in each layout, on each display, and writes the numbers (`metrics.csv`) and, as
/// asked, a picture per layout and a contact sheet per N and display. Test aid like the others:
/// offscreen, nothing saved. Chosen by environment:
///
/// - GITRASIL_FOREST_COUNTS (`4,8,16`), GITRASIL_FOREST_MODES (`plain,canopy`),
///   GITRASIL_OFFSCREEN_SCREENS (`0,1,2`, default all three)
/// - GITRASIL_FOREST_OUTPUT: any of `single`, `sheet` (default none: the numbers only)
/// - GITRASIL_FOREST_TIME=1 adds the time to plan the names and to draw the trees
@MainActor
extension Offscreen {

    struct ForestRow {
        var count: Int
        var screen: String
        var mode: ForestMode
        var lines = 1
        var frontScale: CGFloat = 0
        var minScale: CGFloat = 0
        var treePx: CGFloat = 0
        var leafPx: CGFloat = 0
        var overlap = 0.0
        var clipped = 0
        var wanted = 0
        var placed = 0
        var platesAcross = 0
        var platesDown = 0
        var platesDropped = 0
        var platesOverlapping = 0
        var layoutMs = 0.0
        var planMs = 0.0
        var drawMs = 0.0
    }

    static func forest(_ background: BackgroundModel, to folder: URL) async {
        let environment = ProcessInfo.processInfo.environment
        let counts = (environment["GITRASIL_FOREST_COUNTS"] ?? "4,8,12,16,24,32,48,64").split(separator: ",").compactMap { Int($0) }
        let modes = environment["GITRASIL_FOREST_MODES"].map { list in
            list.split(separator: ",").compactMap { ForestMode(rawValue: String($0)) }
        } ?? [.plain, .canopy, .rows, .activity, .groves]
        let displays = environment["GITRASIL_OFFSCREEN_SCREENS"].map { list in
            list.split(separator: ",").compactMap { Int($0) }.filter { allScreens.indices.contains($0) }.map { allScreens[$0] }
        } ?? allScreens
        let output = Set((environment["GITRASIL_FOREST_OUTPUT"] ?? "").split(separator: ",").map(String.init))
        let timed = environment["GITRASIL_FOREST_TIME"] == "1"
        let dark = NSApp.appearance?.name == .darkAqua
        await settle(background)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let everyone = panes(background)
        print("forest study: \(everyone.count) repositories, \(background.settings.medium.rawValue), \(dark ? "dark" : "light")")
        var rows: [ForestRow] = []
        for screen in displays {
            for count in counts where count <= max(everyone.count, 1) {
                let chosen = sample(everyone, count)
                var images: [(mode: ForestMode, image: CGImage, row: ForestRow)] = []
                for mode in modes {
                    let (row, image) = measure(background, chosen, count: count, mode: mode, screen: screen, dark: dark,
                                               timed: timed, wantsImage: !output.isEmpty)
                    rows.append(row)
                    print(describe(row))
                    guard let image else { continue }
                    images.append((mode, image, row))
                    if output.contains("single") {
                        write(image, to: folder.appendingPathComponent("n\(count)-\(slug(screen))-\(mode.rawValue).jpg"))
                    }
                }
                if output.contains("sheet"), !images.isEmpty {
                    let sheet = contactSheet(images, count: count, screen: screen, medium: background.settings.medium, dark: dark)
                    if let sheet { write(sheet, to: folder.appendingPathComponent("sheet-n\(count)-\(slug(screen)).jpg")) }
                }
            }
        }
        let header = "n,screen,mode,lines,frontScale,minScale,treePx,leafPx,overlap,clipped,wanted,placed,platesAcross,"
            + "platesDown,platesDropped,platesOverlapping,layoutMs,planMs,drawMs\n"
        let csv = rows.map { r in
            [String(r.count), r.screen, r.mode.rawValue, String(r.lines), f1(r.frontScale), f1(r.minScale), f1(r.treePx), f1(r.leafPx),
             f2(r.overlap), String(r.clipped), String(r.wanted), String(r.placed), String(r.platesAcross), String(r.platesDown),
             String(r.platesDropped), String(r.platesOverlapping), f1(r.layoutMs), f1(r.planMs), f1(r.drawMs)].joined(separator: ",")
        }.joined(separator: "\n")
        try? (header + csv + "\n").write(to: folder.appendingPathComponent("metrics.csv"), atomically: true, encoding: .utf8)
        print("wrote \(folder.path)")
    }

    // MARK: Measuring

    /// `count` of `panes`, spread evenly through them, so every folder keeps its share.
    static func sample(_ panes: [Pane], _ count: Int) -> [Pane] {
        guard count < panes.count else { return panes }
        return (0..<count).map { panes[Int(Double($0) * Double(panes.count) / Double(count))] }
    }

    static func measure(_ background: BackgroundModel, _ chosen: [Pane], count: Int, mode: ForestMode, screen: Screen, dark: Bool,
                        timed: Bool, wantsImage: Bool) -> (ForestRow, CGImage?) {
        let style = WallpaperStyle.make(background.settings.medium, dark: dark)
        let landscape = Landscape(style: style, now: background.now, size: screen.size, shuffle: background.settings.layoutSeed,
                                  trunkGrowIn: nil, forest: mode)
        var row = ForestRow(count: count, screen: screen.name, mode: mode)
        let layoutStart = DispatchTime.now().uptimeNanoseconds
        let planted: [Landscape.Planted]
        var plan = ForestPlan()
        if mode.isPacked {
            let scene = landscape.forestScene(chosen)
            planted = scene.planted
            plan = scene.plan
        } else {
            planted = landscape.orchard(chosen)
        }
        row.layoutMs = Double(DispatchTime.now().uptimeNanoseconds - layoutStart) / 1e6
        let scales = planted.map(\.frame.scale).sorted()
        let front = planted.filter { ($0.forest?.line ?? 0) == 0 }.map(\.frame.scale).sorted()
        row.lines = max(plan.lines, 1)
        row.frontScale = front.isEmpty ? 0 : front[front.count / 2]
        row.minScale = scales.first ?? 0
        let heights = planted.map { CGFloat($0.full.bounds.maxY) * $0.frame.scale }.sorted()
        row.treePx = heights.isEmpty ? 0 : heights[heights.count / 2]
        if let middle = planted.sorted(by: { $0.frame.scale < $1.frame.scale }).dropFirst(planted.count / 2).first {
            row.leafPx = style.leafSize * middle.frame.detail
        }
        // How much neighbouring crowns overlap, and how many crowns run off the screen.
        var overlaps: [Double] = []
        let lines = Dictionary(grouping: planted) { $0.forest?.line ?? 0 }
        for members in lines.values {
            let sorted = members.sorted { $0.frame.origin.x < $1.frame.origin.x }
            for (a, b) in zip(sorted, sorted.dropFirst()) {
                let aRight = a.frame.origin.x + CGFloat(a.full.bounds.maxX) * a.frame.scale
                let bLeft = b.frame.origin.x + CGFloat(b.full.bounds.minX) * b.frame.scale
                let narrower = min(CGFloat(a.full.bounds.width) * a.frame.scale, CGFloat(b.full.bounds.width) * b.frame.scale)
                overlaps.append(Double(max(aRight - bLeft, 0) / max(narrower, 1)))
            }
        }
        row.overlap = overlaps.isEmpty ? 0 : overlaps.reduce(0, +) / Double(overlaps.count)
        row.clipped = planted.filter { p in
            p.frame.origin.x + CGFloat(p.full.bounds.minX) * p.frame.scale < 0
                || p.frame.origin.x + CGFloat(p.full.bounds.maxX) * p.frame.scale > screen.size.width
        }.count
        // Names: pennants asked for and placed, and what became of each repository's own name.
        let start = DispatchTime.now().uptimeNanoseconds
        let banners = landscape.plan(chosen, arrangement: .orchard, branchNames: true, repoNames: false)
        row.planMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        row.wanted = planted.reduce(0) { total, p in
            let allowance = p.forest.flatMap { ForestLayout.pennantAllowance(scale: p.frame.scale, fade: $0.fade) }
            let named = p.full.stems.filter { $0.name != nil && $0.tip != nil }.count
            return total + min(named, allowance ?? named)
        }
        row.placed = banners.banners.count
        let font = style.plateMetrics
        let line0 = planted.filter { ($0.forest?.line ?? 0) == 0 }
        for p in line0 {
            let name = chosen[p.index].name
            let size = (name as NSString).size(withAttributes: [.font: font])
            let slot = p.forest?.slot ?? screen.size.width / CGFloat(chosen.count)
            if mode.isPacked {
                switch PlateFit.of(width: size.width, height: size.height, slot: slot) {
                case .across: row.platesAcross += 1
                case .down: row.platesDown += 1
                case .none: row.platesDropped += 1
                }
            } else {
                row.platesAcross += 1
                if size.width > slot { row.platesOverlapping += 1 }
            }
        }
        if timed {
            let canvas = treeCanvas(landscape, chosen)
            row.drawMs = median(5) { render(canvas, screen: screen, dark: dark) }
            row.planMs = (0..<3).map { _ -> Double in
                let t = DispatchTime.now().uptimeNanoseconds
                _ = landscape.plan(chosen, arrangement: .orchard, branchNames: true, repoNames: false)
                return Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6
            }.sorted()[1]
        }
        guard wantsImage else { return (row, nil) }
        let view = ZStack {
            paperCanvas(background, style: style)
            treeCanvas(landscape, chosen)
            BannerLayer(plan: banners, shown: [:], style: style, breeze: background.breeze)
        }
        return (row, render(view, screen: screen, dark: dark))
    }

    static func treeCanvas(_ landscape: Landscape, _ chosen: [Pane]) -> some View {
        Canvas { context, _ in
            landscape.draw(chosen, arrangement: .orchard, in: &context)
        }
    }

    // MARK: Output

    static func slug(_ screen: Screen) -> String { screen.name.replacingOccurrences(of: "×", with: "x").replacingOccurrences(of: "@", with: "-") }
    static func f1(_ v: some BinaryFloatingPoint) -> String { String(format: "%.1f", Double(v)) }
    static func f2(_ v: Double) -> String { String(format: "%.2f", v) }

    static func describe(_ r: ForestRow) -> String {
        let size = String(format: "front %5.1f px/unit (min %5.1f)  tree %5.1f px  leaf %4.1f px", Double(r.frontScale),
                          Double(r.minScale), Double(r.treePx), Double(r.leafPx))
        let fit = String(format: "overlap %3.0f%%  clipped %d  pennants %d/%d", r.overlap * 100, r.clipped, r.placed, r.wanted)
        let plates = "plates \(r.platesAcross) across, \(r.platesDown) down, \(r.platesDropped) dropped, \(r.platesOverlapping) overlapping"
        let cost = String(format: "layout %.1f ms  plan %.0f ms  draw %.1f ms", r.layoutMs, r.planMs, r.drawMs)
        return "  N=\(r.count) \(r.screen) \(r.mode.rawValue) lines \(r.lines)  \(size)  \(fit)  \(plates)  \(cost)"
    }

    /// The layouts side by side for one N and display, each captioned, with the numbers in the last cell.
    static func contactSheet(_ cells: [(mode: ForestMode, image: CGImage, row: ForestRow)], count: Int, screen: Screen,
                             medium: Medium, dark: Bool) -> CGImage? {
        let columns = cells.count <= 2 ? cells.count : (cells.count <= 4 ? 2 : 3)
        let slots = cells.count + 1
        let rows = (slots + columns - 1) / columns
        let cellWidth: CGFloat = columns == 1 ? 1600 : (columns == 2 ? 1400 : 1100)
        let cellHeight = (cellWidth * screen.size.height / screen.size.width).rounded()
        let gap: CGFloat = 16, caption: CGFloat = 34, title: CGFloat = 54
        let width = Int(CGFloat(columns) * cellWidth + CGFloat(columns + 1) * gap)
        let height = Int(title + CGFloat(rows) * (cellHeight + caption + gap) + gap)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(CGColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let graphics = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        defer { NSGraphicsContext.restoreGraphicsState() }
        func text(_ string: String, at point: CGPoint, size: CGFloat, weight: NSFont.Weight = .regular, alpha: CGFloat = 0.92) {
            NSAttributedString(string: string, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: size, weight: weight),
                .foregroundColor: NSColor(white: 1, alpha: alpha)
            ]).draw(at: point)
        }
        text("N = \(count) · \(screen.name) · \(medium.rawValue), \(dark ? "dark" : "light")", at: CGPoint(x: gap, y: 14), size: 24,
             weight: .semibold)
        for (index, cell) in cells.enumerated() {
            let column = index % columns, row = index / columns
            let origin = CGPoint(x: gap + CGFloat(column) * (cellWidth + gap), y: title + CGFloat(row) * (cellHeight + caption + gap))
            text(cell.mode.rawValue, at: CGPoint(x: origin.x, y: origin.y + 4), size: 20, weight: .semibold)
            text(String(format: "front %.0f px/unit · %d line%@ · overlap %.0f%% · pennants %d/%d",
                        Double(cell.row.frontScale), cell.row.lines, cell.row.lines == 1 ? "" : "s", cell.row.overlap * 100,
                        cell.row.placed, cell.row.wanted),
             at: CGPoint(x: origin.x + 150, y: origin.y + 7), size: 14, alpha: 0.6)
            let rect = CGRect(x: origin.x, y: origin.y + caption, width: cellWidth, height: cellHeight)
            context.saveGState()
            context.translateBy(x: rect.minX, y: rect.maxY)
            context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .high
            context.draw(cell.image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
            context.restoreGState()
        }
        // The numbers.
        let index = cells.count
        let origin = CGPoint(x: gap + CGFloat(index % columns) * (cellWidth + gap),
                             y: title + CGFloat(index / columns) * (cellHeight + caption + gap))
        text("numbers", at: CGPoint(x: origin.x, y: origin.y + 4), size: 20, weight: .semibold)
        var y = origin.y + caption + 6
        for cell in cells {
            let r = cell.row
            text(cell.mode.rawValue, at: CGPoint(x: origin.x, y: y), size: 16, weight: .semibold)
            text(String(format: "tree %.0f px · leaf %.1f px · min scale %.0f", Double(r.treePx), Double(r.leafPx), Double(r.minScale)),
                 at: CGPoint(x: origin.x + 20, y: y + 22), size: 14, alpha: 0.75)
            text("plates \(r.platesAcross) across, \(r.platesDown) down, \(r.platesDropped) dropped, \(r.platesOverlapping) overlapping"
                 + (r.clipped > 0 ? " · \(r.clipped) clipped" : ""),
                 at: CGPoint(x: origin.x + 20, y: y + 42), size: 14, alpha: 0.75)
            y += 72
        }
        return context.makeImage()
    }
}

/// How a repository's name fits the room its neighbours leave under its tree.
enum PlateFit {
    case across(CGFloat)
    case down(CGFloat)
    case none

    /// Whole (scaled down to half its size at most) when it fits across; down the ground at a small
    /// fixed size when the room is narrow; left out when even that would be too small to read.
    static func of(width: CGFloat, height: CGFloat, slot: CGFloat) -> PlateFit {
        guard width > 0 else { return .none }
        let across = slot * 0.94 / width
        if across >= 0.5 { return .across(min(across, 1)) }
        let k = min(0.4, slot * 0.8 / height)
        return height * k >= 7.5 ? .down(k) : .none
    }
}

extension WallpaperStyle {
    /// The face a repository's name is written in under its tree, for measuring it.
    var plateMetrics: NSFont {
        medium == .chalk ? NSFont(name: "Chalkduster", size: 28) ?? .systemFont(ofSize: 28)
            : NSFont(name: "Snell Roundhand", size: 34) ?? .systemFont(ofSize: 34)
    }
}
