import SwiftUI
import Charts

struct VisualContentView: View {
    let visual: Visual
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if visual.showTitle && visual.type != .card {
                HStack(spacing: 4) {
                    Text(visual.displayTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(hex: 0x252A33))
                        .lineLimit(1)
                    if visual.level > 0 {
                        let path = (visual.drillPath ?? []).prefix(visual.level)
                        Text(path.isEmpty ? "›" : "› " + path.joined(separator: " › "))
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .padding(.trailing, visual.axis.count > 1 && visual.supportsHierarchy ? 96 : 24)
            }
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var content: some View {
        let filters = state.filters(for: visual)
        let selected = state.highlighted(in: visual)
        let onSelect: (String?) -> Void = { label in state.chartClicked(visual, label: label) }
        switch visual.type {
        case .column, .bar, .line, .area:
            CartesianChartView(data: Engine.chartData(visual, state.model, filters), type: visual.type,
                               format: visual.fmt, selected: selected, onSelect: onSelect)
        case .pie, .donut:
            PieChartView(data: Engine.chartData(visual, state.model, filters), donut: visual.type == .donut,
                         format: visual.fmt, selected: selected, onSelect: onSelect)
        case .card:
            CardVisualView(result: Engine.cardValue(visual, state.model, filters),
                           title: visual.showTitle && !visual.title.isEmpty ? visual.title : nil)
        case .table:
            TableVisualView(data: Engine.tableData(visual, state.model, filters), selected: selected, onSelect: onSelect,
                            sortColumn: visual.fmt.tableSortColumn, sortDescending: visual.fmt.tableSortDescending) { col in
                state.mutateFormat(visual.id) { f in
                    if f.tableSortColumn == col { f.tableSortDescending.toggle() } else { f.tableSortColumn = col; f.tableSortDescending = col > 0 }
                }
            }
        case .slicer:
            SlicerView(visual: visual)
        case .combo:
            CartesianChartView(data: Engine.chartData(visual, state.model, filters), type: .combo,
                               format: visual.fmt, selected: selected, onSelect: onSelect)
        case .scatter:
            ScatterVisualView(data: Engine.chartData(visual, state.model, filters), format: visual.fmt,
                              selected: selected, onSelect: onSelect)
        case .matrix:
            TableVisualView(data: Engine.matrixData(visual, state.model, filters), selected: selected, onSelect: onSelect)
        case .gauge:
            GaugeVisualView(values: Engine.scalars(visual, state.model, filters), label: visual.values.first?.displayName ?? "",
                            format: Engine.valueFormat(visual, state.model), color: Theme.colors(1, first: visual.fmt.color)[0])
        case .kpi:
            KPIVisualView(values: Engine.scalars(visual, state.model, filters), label: visual.values.first?.displayName ?? "",
                          format: Engine.valueFormat(visual, state.model), trend: kpiTrend(filters),
                          color: Theme.colors(1, first: visual.fmt.color)[0])
        case .map:
            MapVisualView(data: Engine.chartData(visual, state.model, filters), format: visual.fmt,
                          selected: selected, onSelect: onSelect)
        }
    }
}

extension VisualContentView {
    /// KPI sparkline: the first value along the axis field, as a line chart.
    func kpiTrend(_ filters: [FilterSpec]) -> ChartData? {
        guard !visual.axis.isEmpty, let vf = visual.values.first else { return nil }
        var line = visual
        line.type = .line
        line.values = [vf]
        line.legend = nil
        line.format = nil
        return Engine.chartData(line, state.model, filters)
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

/// Hover tooltip listing the values of one category.
struct ChartTooltip: View {
    let title: String
    let rows: [(name: String, value: String, color: Color)]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11, weight: .semibold))
            ForEach(rows.indices, id: \.self) { i in
                HStack(spacing: 5) {
                    Circle().fill(rows[i].color).frame(width: 7, height: 7)
                    Text(rows[i].name).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(rows[i].value).font(.system(size: 10, weight: .semibold)).monospacedDigit()
                }
            }
        }
        .padding(7)
        .frame(maxWidth: 220)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white).shadow(color: .black.opacity(0.18), radius: 4, y: 1))
        .foregroundStyle(Color(hex: 0x252A33))
        .fixedSize()
    }
}

struct CartesianChartView: View {
    let data: ChartData
    let type: VisualType
    let format: VisualFormat
    let selected: String?
    let onSelect: (String?) -> Void
    @State private var hover: (category: String, location: CGPoint)?

    var body: some View {
        if let m = data.message {
            PlaceholderView(message: m, symbol: type.symbol)
        } else if type == .bar {
            base
                .chartXAxis { valueAxis(.bottom) }
                .chartYScale(domain: data.categories)
                .applyIf(format.axisTitles) { $0.chartXAxisLabel(data.valueTitle).chartYAxisLabel(data.categoryTitle) }
        } else {
            base
                .chartYAxis { valueAxis(.leading) }
                .chartXAxis {
                    AxisMarks(values: categoryTicks) { _ in
                        AxisValueLabel(collisionResolution: .greedy)
                    }
                }
                .chartXScale(domain: data.categories)
                .applyIf(format.axisTitles) { $0.chartXAxisLabel(data.categoryTitle).chartYAxisLabel(data.valueTitle) }
        }
    }

    private var colors: [Color] { Theme.colors(data.series.count, first: format.color) }

    private func opacity(_ p: ChartPoint) -> Double {
        if let s = selected { return s == p.category ? 1 : 0.3 }
        if let h = hover?.category, type != .line && type != .area { return h == p.category ? 1 : 0.75 }
        return 1
    }

    private func label(_ v: Double) -> String { Fmt.measure(v, data.format, compact: true) }

    private var base: some View {
        Chart(data.points) { p in
            if type == .bar {
                BarMark(x: .value("v", p.value), y: .value("c", p.category))
                    .foregroundStyle(by: .value("s", p.series))
                    .position(by: .value("s", p.series))
                    .opacity(opacity(p))
                    .annotation(position: .trailing, spacing: 2) {
                        if format.dataLabels { Text(label(p.value)).font(.system(size: 9)).foregroundStyle(.secondary) }
                    }
            } else if type == .line {
                LineMark(x: .value("c", p.category), y: .value("v", p.value))
                    .foregroundStyle(by: .value("s", p.series))
                    .interpolationMethod(.monotone)
                PointMark(x: .value("c", p.category), y: .value("v", p.value))
                    .foregroundStyle(by: .value("s", p.series))
                    .symbolSize(selected == p.category || hover?.category == p.category ? 60 : 14)
                    .annotation(position: .top, spacing: 2) {
                        if format.dataLabels { Text(label(p.value)).font(.system(size: 9)).foregroundStyle(.secondary) }
                    }
            } else if type == .area {
                AreaMark(x: .value("c", p.category), y: .value("v", p.value))
                    .foregroundStyle(by: .value("s", p.series))
                    .interpolationMethod(.monotone)
                    .opacity(0.75)
            } else if type == .combo && p.series != data.series.first {
                LineMark(x: .value("c", p.category), y: .value("v", p.value))
                    .foregroundStyle(by: .value("s", p.series))
                    .interpolationMethod(.monotone)
                PointMark(x: .value("c", p.category), y: .value("v", p.value))
                    .foregroundStyle(by: .value("s", p.series))
                    .symbolSize(22)
                    .annotation(position: .top, spacing: 2) {
                        if format.dataLabels { Text(label(p.value)).font(.system(size: 9)).foregroundStyle(.secondary) }
                    }
            } else {
                BarMark(x: .value("c", p.category), y: .value("v", p.value))
                    .foregroundStyle(by: .value("s", p.series))
                    .position(by: .value("s", p.series))
                    .opacity(opacity(p))
                    .annotation(position: .top, spacing: 2) {
                        if format.dataLabels { Text(label(p.value)).font(.system(size: 9)).foregroundStyle(.secondary) }
                    }
            }
            if let h = hover?.category, h == p.category, type == .line || type == .area {
                RuleMark(x: .value("c", h)).foregroundStyle(Color.gray.opacity(0.35)).lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        .chartForegroundStyleScale(domain: data.series, range: colors)
        .chartLegend(format.showLegend && data.series.count > 1 ? .visible : .hidden)
        .chartLegend(position: .top, alignment: .leading)
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onTapGesture { loc in onSelect(category(at: loc, proxy, geo)) }
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let loc):
                            if let c = category(at: loc, proxy, geo) { hover = (c, loc) } else { hover = nil }
                        case .ended: hover = nil
                        }
                    }
                if let h = hover {
                    tooltip(h.category)
                        .position(x: min(max(h.location.x + 70, 80), geo.size.width - 80),
                                  y: min(max(h.location.y - 30, 30), geo.size.height - 30))
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func category(at loc: CGPoint, _ proxy: ChartProxy, _ geo: GeometryProxy) -> String? {
        guard let pf = proxy.plotFrame else { return nil }
        let frame = geo[pf]
        guard frame.contains(loc) else { return nil }
        return type == .bar
            ? proxy.value(atY: loc.y - frame.minY, as: String.self)
            : proxy.value(atX: loc.x - frame.minX, as: String.self)
    }

    private func tooltip(_ category: String) -> some View {
        let pts = data.points.filter { $0.category == category }
        let rows = pts.map { p in
            (name: p.series, value: Fmt.measure(p.value, data.format, compact: false),
             color: colors[(data.series.firstIndex(of: p.series) ?? 0) % max(colors.count, 1)])
        }
        return ChartTooltip(title: category, rows: rows)
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
            if format.gridlines { AxisGridLine() }
            AxisValueLabel {
                if let d = v.as(Double.self) { Text(Fmt.measure(d, data.format == .percent ? .percent : .auto, compact: true)) }
            }
        }
    }
}

// MARK: - Pie / donut

struct PieChartView: View {
    let data: ChartData
    let donut: Bool
    let format: VisualFormat
    let selected: String?
    let onSelect: (String?) -> Void
    @State private var hover: (category: String, location: CGPoint)?

    var body: some View {
        if let m = data.message {
            PlaceholderView(message: m, symbol: donut ? "circle.circle" : "chart.pie.fill")
        } else {
            let total = data.points.reduce(0) { $0 + $1.value }
            let colors = Theme.colors(data.categories.count, first: format.color)
            Chart(data.points) { p in
                SectorMark(angle: .value("v", p.value), innerRadius: .ratio(donut ? 0.58 : 0), angularInset: 1)
                    .foregroundStyle(by: .value("c", p.category))
                    .opacity(selected == nil ? (hover == nil || hover?.category == p.category ? 1 : 0.7)
                             : (selected == p.category ? 1 : 0.3))
                    .annotation(position: .overlay) {
                        if format.dataLabels && total > 0 && p.value / total >= 0.04 {
                            Text((p.value / total).formatted(.percent.precision(.fractionLength(0))))
                                .font(.system(size: 9, weight: .semibold)).foregroundStyle(.white)
                        }
                    }
            }
            .chartForegroundStyleScale(domain: data.categories, range: colors)
            .chartLegend(format.showLegend ? .visible : .hidden)
            .chartLegend(position: .trailing, alignment: .center)
            .chartBackground { proxy in
                if donut {
                    GeometryReader { geo in
                        if let pf = proxy.plotFrame {
                            let frame = geo[pf]
                            VStack(spacing: 0) {
                                Text(Fmt.measure(total, data.format, compact: true)).font(.system(size: 17, weight: .semibold))
                                Text(L("Total")).font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            .position(x: frame.midX, y: frame.midY)
                        }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onTapGesture { loc in onSelect(category(at: loc, proxy, geo, total)) }
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let loc):
                                if let c = category(at: loc, proxy, geo, total) { hover = (c, loc) } else { hover = nil }
                            case .ended: hover = nil
                            }
                        }
                    if let h = hover, let p = data.points.first(where: { $0.category == h.category }) {
                        let share = total > 0 ? p.value / total : 0
                        ChartTooltip(title: h.category, rows: [
                            (name: p.series, value: Fmt.measure(p.value, data.format, compact: false),
                             color: colors[(data.categories.firstIndex(of: p.category) ?? 0) % colors.count]),
                            (name: "%", value: share.formatted(.percent.precision(.fractionLength(1))), color: .clear),
                        ])
                        .position(x: min(max(h.location.x + 70, 80), geo.size.width - 80),
                                  y: min(max(h.location.y - 30, 30), geo.size.height - 30))
                        .allowsHitTesting(false)
                    }
                }
            }
        }
    }

    private func category(at loc: CGPoint, _ proxy: ChartProxy, _ geo: GeometryProxy, _ total: Double) -> String? {
        guard let pf = proxy.plotFrame, total > 0 else { return nil }
        let frame = geo[pf]
        let dx = loc.x - frame.midX, dy = loc.y - frame.midY
        let r = min(frame.width, frame.height) / 2
        let d = hypot(dx, dy)
        guard d <= r, !donut || d >= r * 0.58 else { return nil }
        var angle = atan2(dx, -dy)
        if angle < 0 { angle += 2 * .pi }
        var acc = 0.0
        for p in data.points {
            acc += p.value / total * 2 * .pi
            if Double(angle) <= acc { return p.category }
        }
        return nil
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
            PlaceholderView(message: L("Ajoutez un champ dans « Champs »"), symbol: "123.rectangle")
        }
    }
}

// MARK: - Table

struct TableVisualView: View {
    let data: TableData
    let selected: String?
    let onSelect: (String?) -> Void
    var sortColumn: Int?
    var sortDescending = false
    var onSort: (Int) -> Void = { _ in }

    var body: some View {
        if let m = data.message {
            PlaceholderView(message: m, symbol: "tablecells")
        } else {
            let widths = columnWidths()
            MaybeScroll(axes: [.vertical, .horizontal]) {
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
                            Text(L("… %@ lignes supplémentaires", data.totalRowCount - data.rows.count))
                                .font(.system(size: 10)).foregroundStyle(.secondary).padding(6)
                        }
                    } header: {
                        header(widths)
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
            return min(260, max(60, CGFloat(longest) * 6.8 + 24))
        }
    }

    private func header(_ widths: [CGFloat]) -> some View {
        HStack(spacing: 0) {
            ForEach(data.headers.indices, id: \.self) { c in
                HStack(spacing: 2) {
                    if data.numeric[c] { Spacer(minLength: 0) }
                    Text(data.headers[c]).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    if sortColumn == c {
                        Image(systemName: sortDescending ? "chevron.down" : "chevron.up").font(.system(size: 8, weight: .bold))
                    }
                    if !data.numeric[c] { Spacer(minLength: 0) }
                }
                .frame(width: widths[c])
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
                .onTapGesture { onSort(c) }
            }
        }
        .padding(.vertical, 4)
        .foregroundStyle(Color(hex: 0x252A33))
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
    @Environment(\.isExporting) private var exporting
    @State private var search = ""

    var body: some View {
        if let f = visual.axis.first {
            let all = Engine.distinctValues(f, state.tables)
            let values = search.isEmpty ? all : all.filter { $0.localizedCaseInsensitiveContains(search) }
            VStack(alignment: .leading, spacing: 4) {
                if all.count > 8 && !exporting {
                    HStack(spacing: 4) {
                        Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(.secondary)
                        TextField(L("Rechercher"), text: $search).textFieldStyle(.plain).font(.system(size: 11))
                    }
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 4).stroke(Color.black.opacity(0.12)))
                }
                MaybeScroll(axes: .vertical) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        item(L("Tout sélectionner"), checked: visual.slicerSelection.isEmpty) {
                            state.clearSlicer(visual.id)
                        }
                        ForEach(values, id: \.self) { v in
                            item(v, checked: visual.slicerSelection.contains(v)) { state.toggleSlicer(visual.id, v) }
                        }
                    }
                }
            }
        } else {
            PlaceholderView(message: L("Ajoutez un champ dans « Champ »"), symbol: VisualType.slicer.symbol)
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
