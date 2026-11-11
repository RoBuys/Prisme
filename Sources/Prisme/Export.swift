import SwiftUI
import AppKit
import UniformTypeIdentifiers

private struct ExportingKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// True while a page is rendered for export: scroll views and text fields are replaced by static content.
    var isExporting: Bool {
        get { self[ExportingKey.self] }
        set { self[ExportingKey.self] = newValue }
    }
}

/// A scroll view on screen, plain clipped content when exporting (ImageRenderer can't draw native scroll views).
struct MaybeScroll<Content: View>: View {
    let axes: Axis.Set
    @ViewBuilder let content: Content
    @Environment(\.isExporting) private var exporting

    var body: some View {
        if exporting {
            GeometryReader { g in
                content.frame(width: g.size.width, height: g.size.height, alignment: .topLeading).clipped()
            }
        } else {
            ScrollView(axes) { content }
        }
    }
}

/// A report page at its logical size, as printed in exports.
struct PageRenderView: View {
    let page: ReportPage
    let state: AppState

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.white
            ForEach(page.visuals) { v in
                VisualContentView(visual: v)
                    .padding(10)
                    .frame(width: v.frame.width, height: v.frame.height)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.white))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.black.opacity(0.06)))
                    .offset(x: v.frame.minX, y: v.frame.minY)
            }
        }
        .frame(width: PageSize.width, height: PageSize.height, alignment: .topLeading)
        .environment(state)
        .environment(\.colorScheme, .light)
        .environment(\.isExporting, true)
    }
}

extension AppState {
    private var exportBaseName: String { fileURL?.deletingPathExtension().lastPathComponent ?? L("Rapport") }

    /// Renders a page; filters, slicers and cross-filters of that page apply.
    @MainActor
    private func withPage<T>(_ page: ReportPage, _ body: () -> T) -> T {
        let saved = currentPageID
        currentPageID = page.id
        defer { currentPageID = saved }
        return body()
    }

    @MainActor
    func exportPDF() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = exportBaseName + ".pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        writePDF(to: url)
    }

    @MainActor
    func writePDF(to url: URL) {
        var box = CGRect(x: 0, y: 0, width: PageSize.width, height: PageSize.height)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else {
            alertMessage = L("Impossible de créer le fichier PDF.")
            return
        }
        for page in pages {
            withPage(page) {
                let renderer = ImageRenderer(content: PageRenderView(page: page, state: self))
                renderer.render { _, draw in
                    ctx.beginPDFPage(nil)
                    draw(ctx)
                    ctx.endPDFPage()
                }
            }
        }
        ctx.closePDF()
    }

    @MainActor
    func exportPNG() {
        let page = currentPage
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(exportBaseName) - \(page.name).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        writePNG(page, to: url)
    }

    @MainActor
    func writePNG(_ page: ReportPage, to url: URL) {
        let renderer = ImageRenderer(content: PageRenderView(page: page, state: self))
        renderer.scale = 2
        guard let cg = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
            alertMessage = L("Impossible de créer l'image.")
            return
        }
        do { try data.write(to: url) } catch { alertMessage = error.localizedDescription }
    }

    /// The data behind a visual, as a grid (header row first).
    func exportGrid(_ v: Visual) -> [[String]] {
        let filters = filters(for: v)
        func plain(_ d: Double) -> String { Fmt.plain(d) }
        switch v.type {
        case .card:
            guard let vf = v.values.first else { return [] }
            let fields = vf.measure ? (model.measure(for: vf.field).map { MeasureCompiler.dependencies($0, model) } ?? []) : [vf.field]
            guard let ctx = Engine.context(for: fields.isEmpty ? [vf.field] : fields, model),
                  let fn = Engine.valueFunction(vf, ctx, MeasureEvaluator(ctx: ctx, model: model)) else { return [] }
            return [[vf.displayName], [fn(ctx.rowIndices(filters), filters).map(plain) ?? ""]]
        case .table:
            let t = Engine.tableData(v, model, filters, limit: .max)
            guard t.message == nil else { return [] }
            return [t.headers] + t.raw
        case .slicer:
            guard let f = v.axis.first else { return [] }
            return [[f.displayName]] + Engine.distinctValues(f, tables).map { [$0] }
        default:
            let d = Engine.chartData(v, model, filters)
            guard d.message == nil else { return [] }
            var grid = [[d.categoryTitle] + d.series]
            for c in d.categories {
                grid.append([c] + d.series.map { s in
                    d.points.first { $0.category == c && $0.series == s }.map { plain($0.value) } ?? ""
                })
            }
            return grid
        }
    }

    @MainActor
    func exportCSV(_ id: UUID) {
        guard let v = visual(id) else { return }
        let grid = exportGrid(v)
        guard !grid.isEmpty else { alertMessage = L("Ce visuel n'a pas de données à exporter."); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = v.displayTitle.replacingOccurrences(of: "/", with: "-") + ".csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        writeCSV(grid, to: url)
    }

    func writeCSV(_ grid: [[String]], to url: URL) {
        // French Excel expects ";" separators and decimal commas.
        let french = !Loc.isEnglish
        let sep = french ? ";" : ","
        func cell(_ s: String) -> String {
            var t = s
            if french, Double(t) != nil { t = t.replacingOccurrences(of: ".", with: ",") }
            return t.contains(sep) || t.contains("\"") || t.contains("\n") ? "\"" + t.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : t
        }
        let text = grid.map { $0.map(cell).joined(separator: sep) }.joined(separator: "\r\n")
        do { try ("\u{FEFF}" + text).write(to: url, atomically: true, encoding: .utf8) }
        catch { alertMessage = error.localizedDescription }
    }
}
