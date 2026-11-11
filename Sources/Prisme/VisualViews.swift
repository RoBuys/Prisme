import SwiftUI
import Charts

struct VisualContentView: View {
    let visual: Visual
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if visual.showTitle && visual.type != .card {
                Text(visual.displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x252A33))
                    .lineLimit(1)
            }
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var content: some View {
        let filters = state.filters(for: visual)
        let selected = state.highlighted(in: visual)
        let onSelect: (String?) -> Void = { label in state.toggleCrossFilter(from: visual, label: label) }
        switch visual.type {
        case .column, .bar, .line, .area:
            CartesianChartView(data: Engine.chartData(visual, state.model, filters), type: visual.type,
                               selected: selected, onSelect: onSelect)
        case .pie, .donut:
            PieChartView(data: Engine.chartData(visual, state.model, filters), donut: visual.type == .donut,
                         selected: selected, onSelect: onSelect)
        case .card:
            CardVisualView(result: Engine.cardValue(visual, state.model, filters),
                           title: visual.showTitle && !visual.title.isEmpty ? visual.title : nil)
        case .table:
            TableVisualView(data: Engine.tableData(visual, state.model, filters), selected: selected, onSelect: onSelect)
        case .slicer:
            SlicerView(visual: visual)
        }
    }
}

struct PlaceholderView: View {
    let message: String
    let symbol: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 26, weight: .light)).foregroundStyle(Color.gray.opacity(0.5))
            Text(message).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Column / bar / line / area

struct CartesianChartView: View {
    let data: ChartData
    let type: VisualType
    let selected: String?
    let onSelect: (String?) -> Void

    var body: some View {
        if let m = data.message {
            PlaceholderView(message: m, symbol: type.symbol)
        } else if type == .bar {
            base
                .chartXAxis { valueAxis(.bottom) }
                .chartYScale(domain: data.categories)
        } else {
            base
                .chartYAxis { valueAxis(.leading) }
                .chartXAxis {
                    AxisMarks(values: categoryTicks) { _ in
                        AxisValueLabel(collisionResolution: .greedy)
                    }
                }
                .chartXScale(domain: data.categories)
        }
    }

    private func opacity(_ p: ChartPoint) -> Double {
        selected == nil || selected == p.category ? 1 : 0.3
    }

    private var base: some View {
        Chart(data.points) { p in
            if type == .bar {
                BarMark(x: .value("Valeur", p.value), y: .value("Catégorie", p.category))
                    .foregroundStyle(by: .value("Série", p.series))
                    .position(by: .value("Série", p.series))
                    .opacity(opacity(p))
            } else if type == .line {
                LineMark(x: .value("Catégorie", p.category), y: .value("Valeur", p.value))
                    .foregroundStyle(by: .value("Série", p.series))
                    .interpolationMethod(.monotone)
                PointMark(x: .value("Catégorie", p.category), y: .value("Valeur", p.value))
                    .foregroundStyle(by: .value("Série", p.series))
                    .symbolSize(selected == p.category ? 60 : 14)
            } else if type == .area {
                AreaMark(x: .value("Catégorie", p.category), y: .value("Valeur", p.value))
                    .foregroundStyle(by: .value("Série", p.series))
                    .interpolationMethod(.monotone)
                    .opacity(0.75)
            } else {
                BarMark(x: .value("Catégorie", p.category), y: .value("Valeur", p.value))
                    .foregroundStyle(by: .value("Série", p.series))
                    .position(by: .value("Série", p.series))
                    .opacity(opacity(p))
            }
        }
        .chartForegroundStyleScale(domain: data.series, range: Theme.colors(data.series.count))
        .chartLegend(data.series.count > 1 ? .visible : .hidden)
        .chartLegend(position: .top, alignment: .leading)
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onTapGesture { loc in
                        guard let pf = proxy.plotFrame else { onSelect(nil); return }
                        let frame = geo[pf]
                        guard frame.contains(loc) else { onSelect(nil); return }
                        let cat: String? = type == .bar
                            ? proxy.value(atY: loc.y - frame.minY, as: String.self)
                            : proxy.value(atX: loc.x - frame.minX, as: String.self)
                        onSelect(cat)
                    }
            }
        }
    }

    /// At most ~10 labels on a category axis so they stay readable.
    private var categoryTicks: [String] {
        let n = data.categories.count
        guard n > 10 else { return data.categories }
        let step = Int((Double(n) / 8).rounded(.up))
        return data.categories.enumerated().filter { $0.offset % step == 0 }.map(\.element)
    }

    private func valueAxis(_ position: AxisMarkPosition) -> some AxisContent {
        AxisMarks(position: position) { v in
            AxisGridLine()
            AxisValueLabel {
                if let d = v.as(Double.self) { Text(Fmt.compact(d)) }
            }
        }
    }
}

// MARK: - Pie / donut

struct PieChartView: View {
    let data: ChartData
    let donut: Bool
    let selected: String?
    let onSelect: (String?) -> Void

    var body: some View {
        if let m = data.message {
            PlaceholderView(message: m, symbol: donut ? "circle.circle" : "chart.pie.fill")
        } else {
            let total = data.points.reduce(0) { $0 + $1.value }
            Chart(data.points) { p in
                SectorMark(angle: .value("Valeur", p.value), innerRadius: .ratio(donut ? 0.58 : 0), angularInset: 1)
                    .foregroundStyle(by: .value("Catégorie", p.category))
                    .opacity(selected == nil || selected == p.category ? 1 : 0.3)
            }
            .chartForegroundStyleScale(domain: data.categories, range: Theme.colors(data.categories.count))
            .chartLegend(position: .trailing, alignment: .center)
            .chartBackground { proxy in
                if donut {
                    GeometryReader { geo in
                        if let pf = proxy.plotFrame {
                            let frame = geo[pf]
                            VStack(spacing: 0) {
                                Text(Fmt.compact(total)).font(.system(size: 17, weight: .semibold))
                                Text("Total").font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            .position(x: frame.midX, y: frame.midY)
                        }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onTapGesture { loc in
                            guard let pf = proxy.plotFrame, total > 0 else { onSelect(nil); return }
                            let frame = geo[pf]
                            let dx = loc.x - frame.midX, dy = loc.y - frame.midY
                            guard hypot(dx, dy) <= min(frame.width, frame.height) / 2 else { onSelect(nil); return }
                            var angle = atan2(dx, -dy)
                            if angle < 0 { angle += 2 * .pi }
                            var acc = 0.0
                            for p in data.points {
                                acc += p.value / total * 2 * .pi
                                if Double(angle) <= acc { onSelect(p.category); return }
                            }
                            onSelect(nil)
                        }
                }
            }
        }
    }
}

// MARK: - Card

struct CardVisualView: View {
    let result: (value: String, label: String)?
    let title: String?

    var body: some View {
        if let r = result {
            VStack(spacing: 4) {
                Text(r.value)
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(hex: 0x252A33))
                    .lineLimit(1)
                    .minimumScaleFactor(0.3)
                Text(title ?? r.label)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            PlaceholderView(message: "Ajoutez un champ dans « Champs »", symbol: "123.rectangle")
        }
    }
}

// MARK: - Table

struct TableVisualView: View {
    let data: TableData
    let selected: String?
    let onSelect: (String?) -> Void

    var body: some View {
        if let m = data.message {
            PlaceholderView(message: m, symbol: "tablecells")
        } else {
            let widths = columnWidths()
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders, .sectionFooters]) {
                    Section {
                        ForEach(data.rows.indices, id: \.self) { i in
                            let key = data.rowKeys[i]
                            row(data.rows[i], widths: widths, bold: false)
                                .background(i % 2 == 1 ? Color.black.opacity(0.025) : Color.clear)
                                .background(selected == key ? Theme.accent.opacity(0.14) : Color.clear)
                                .opacity(selected == nil || selected == key ? 1 : 0.45)
                                .contentShape(Rectangle())
                                .onTapGesture { onSelect(key) }
                        }
                        if data.totalRowCount > data.rows.count {
                            Text("… \(data.totalRowCount - data.rows.count) lignes supplémentaires")
                                .font(.system(size: 10)).foregroundStyle(.secondary).padding(6)
                        }
                    } header: {
                        row(data.headers, widths: widths, bold: true)
                            .background(Color.white)
                            .overlay(alignment: .bottom) { Rectangle().fill(Color.black.opacity(0.15)).frame(height: 1) }
                    } footer: {
                        if let t = data.totals {
                            row(t, widths: widths, bold: true)
                                .background(Color.white)
                                .overlay(alignment: .top) { Rectangle().fill(Color.black.opacity(0.15)).frame(height: 1) }
                        }
                    }
                }
            }
        }
    }

    private func columnWidths() -> [CGFloat] {
        data.headers.indices.map { c in
            var longest = data.headers[c].count
            for r in data.rows.prefix(200) { longest = max(longest, r[c].count) }
            if let t = data.totals { longest = max(longest, t[c].count) }
            return min(260, max(60, CGFloat(longest) * 6.8 + 16))
        }
    }

    private func row(_ cells: [String], widths: [CGFloat], bold: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(cells.indices, id: \.self) { c in
                Text(cells[c])
                    .font(.system(size: 11, weight: bold ? .semibold : .regular))
                    .lineLimit(1)
                    .frame(width: widths[c], alignment: data.numeric[c] ? .trailing : .leading)
                    .padding(.horizontal, 4)
            }
        }
        .padding(.vertical, 4)
        .foregroundStyle(Color(hex: 0x252A33))
    }
}

// MARK: - Slicer

struct SlicerView: View {
    let visual: Visual
    @Environment(AppState.self) private var state
    @State private var search = ""

    var body: some View {
        if let f = visual.axis.first {
            let all = Engine.distinctValues(f, state.tables)
            let values = search.isEmpty ? all : all.filter { $0.localizedCaseInsensitiveContains(search) }
            VStack(alignment: .leading, spacing: 4) {
                if all.count > 8 {
                    HStack(spacing: 4) {
                        Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(.secondary)
                        TextField("Rechercher", text: $search).textFieldStyle(.plain).font(.system(size: 11))
                    }
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 4).stroke(Color.black.opacity(0.12)))
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        item("Tout sélectionner", checked: visual.slicerSelection.isEmpty) {
                            state.clearSlicer(visual.id)
                        }
                        ForEach(values, id: \.self) { v in
                            item(v, checked: visual.slicerSelection.contains(v)) { state.toggleSlicer(visual.id, v) }
                        }
                    }
                }
            }
        } else {
            PlaceholderView(message: "Ajoutez un champ dans « Champ »", symbol: VisualType.slicer.symbol)
        }
    }

    private func item(_ label: String, checked: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .foregroundStyle(checked ? Theme.accent : Color.gray)
            Text(label).font(.system(size: 12)).foregroundStyle(Color(hex: 0x252A33)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }
}
