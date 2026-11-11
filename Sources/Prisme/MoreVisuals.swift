import SwiftUI
import Charts
import MapKit
import CoreLocation

// MARK: - Scatter

/// X = first value, Y = second value, bubble size = optional third value; one point per category.
struct ScatterVisualView: View {
    let data: ChartData
    let format: VisualFormat
    let selected: String?
    let onSelect: (String?) -> Void
    @State private var hover: (category: String, location: CGPoint)?

    private struct Bubble: Identifiable {
        let id: String
        let x: Double
        let y: Double
        let size: Double?
    }

    private var bubbles: [Bubble] {
        guard data.series.count >= 2 else { return [] }
        var byCat: [String: [String: Double]] = [:]
        for p in data.points { byCat[p.category, default: [:]][p.series] = p.value }
        return data.categories.compactMap { c in
            guard let v = byCat[c], let x = v[data.series[0]], let y = v[data.series[1]] else { return nil }
            return Bubble(id: c, x: x, y: y, size: data.series.count > 2 ? v[data.series[2]] : nil)
        }
    }

    var body: some View {
        if let m = data.message {
            PlaceholderView(message: m, symbol: "chart.dots.scatter")
        } else if data.series.count < 2 {
            PlaceholderView(message: L("Ajoutez des champs dans « Axe X » et « Axe Y »"), symbol: "chart.dots.scatter")
        } else {
            let bs = bubbles
            let maxSize = bs.compactMap(\.size).max() ?? 1
            let color = Theme.colors(1, first: format.color)[0]
            Chart(bs) { b in
                PointMark(x: .value("x", b.x), y: .value("y", b.y))
                    .symbolSize(b.size.map { 30 + 600 * max(0, $0) / max(maxSize, 1e-9) } ?? 50)
                    .foregroundStyle(color.opacity(selected == nil || selected == b.id ? 0.75 : 0.2))
                    .annotation(position: .top, spacing: 2) {
                        if format.dataLabels { Text(b.id).font(.system(size: 8)).foregroundStyle(.secondary) }
                    }
            }
            .chartXAxis { AxisMarks { v in
                if format.gridlines { AxisGridLine() }
                AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.measure(d, .auto, compact: true)) } }
            } }
            .chartYAxis { AxisMarks(position: .leading) { v in
                if format.gridlines { AxisGridLine() }
                AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.measure(d, .auto, compact: true)) } }
            } }
            .chartXAxisLabel(data.series[0])
            .chartYAxisLabel(data.series[1])
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onTapGesture { loc in onSelect(nearest(loc, bs, proxy, geo)) }
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let loc): hover = nearest(loc, bs, proxy, geo).map { ($0, loc) }
                            case .ended: hover = nil
                            }
                        }
                    if let h = hover, let b = bs.first(where: { $0.id == h.category }) {
                        ChartTooltip(title: b.id, rows: [
                            (data.series[0], Fmt.measure(b.x, data.format, compact: false), color),
                            (data.series[1], Fmt.measure(b.y, data.format, compact: false), color),
                        ] + (b.size.map { [(data.series[2], Fmt.measure($0, data.format, compact: false), color)] } ?? []))
                        .position(x: min(max(h.location.x + 70, 80), geo.size.width - 80),
                                  y: min(max(h.location.y - 30, 30), geo.size.height - 30))
                        .allowsHitTesting(false)
                    }
                }
            }
        }
    }

    private func nearest(_ loc: CGPoint, _ bs: [Bubble], _ proxy: ChartProxy, _ geo: GeometryProxy) -> String? {
        guard let pf = proxy.plotFrame else { return nil }
        let origin = geo[pf].origin
        var best: (String, CGFloat)?
        for b in bs {
            guard let px = proxy.position(forX: b.x), let py = proxy.position(forY: b.y) else { continue }
            let d = hypot(px + origin.x - loc.x, py + origin.y - loc.y)
            if d < 18, d < (best?.1 ?? .infinity) { best = (b.id, d) }
        }
        return best?.0
    }
}

// MARK: - Gauge

struct GaugeArc: Shape {
    var from: Double
    var to: Double

    func path(in rect: CGRect) -> Path {
        let r = min(rect.width / 2, rect.height)
        let center = CGPoint(x: rect.midX, y: rect.midY + r / 2)
        var p = Path()
        p.addArc(center: center, radius: r, startAngle: .degrees(180 + 180 * from), endAngle: .degrees(180 + 180 * to),
                 clockwise: false)
        return p
    }
}

/// Semicircular gauge: value (slot 1), optional target (slot 2) and maximum (slot 3).
struct GaugeVisualView: View {
    let values: [Double?]
    let label: String
    let format: MeasureFormat
    let color: Color

    var body: some View {
        if let value = values.first ?? nil {
            let target = values.count > 1 ? values[1] : nil
            let maxV = (values.count > 2 ? values[2] : nil) ?? Swift.max((target ?? 0) * 1.25, value * 1.25, 1)
            let frac = Swift.min(Swift.max(value / maxV, 0), 1)
            GeometryReader { g in
                let side = Swift.min(g.size.width, g.size.height * 1.7)
                let line = side * 0.12
                ZStack {
                    GaugeArc(from: 0, to: 1).stroke(Color.gray.opacity(0.15), style: StrokeStyle(lineWidth: line, lineCap: .butt))
                    GaugeArc(from: 0, to: frac).stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .butt))
                    if let t = target, maxV > 0 {
                        GaugeArc(from: Swift.min(t / maxV, 1) - 0.004, to: Swift.min(t / maxV, 1) + 0.004)
                            .stroke(Color(hex: 0x252A33), style: StrokeStyle(lineWidth: line * 1.35))
                    }
                }
                .frame(width: side * 0.86, height: side * 0.43)
                .position(x: g.size.width / 2, y: g.size.height * 0.42)
                VStack(spacing: 1) {
                    Text(Fmt.measure(value, format, compact: true))
                        .font(.system(size: side * 0.11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color(hex: 0x252A33))
                    Text(target.map { L("Cible : %@", Fmt.measure($0, format, compact: true)) } ?? label)
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                .position(x: g.size.width / 2, y: g.size.height * 0.62)
                HStack {
                    Text("0")
                    Spacer()
                    Text(Fmt.measure(maxV, format, compact: true))
                }
                .font(.system(size: 9)).foregroundStyle(.secondary)
                .frame(width: side * 0.86 + line)
                .position(x: g.size.width / 2, y: g.size.height * 0.42 + side * 0.215 + 10)
            }
        } else {
            PlaceholderView(message: L("Ajoutez un champ dans « Valeur »"), symbol: "gauge.with.dots.needle.67percent")
        }
    }
}

// MARK: - KPI

/// Value (slot 1) compared with a target (slot 2), with a trend sparkline over the axis field.
struct KPIVisualView: View {
    let values: [Double?]
    let label: String
    let format: MeasureFormat
    let trend: ChartData?
    let color: Color

    var body: some View {
        if let value = values.first ?? nil {
            let target = values.count > 1 ? values[1] : nil
            VStack(spacing: 4) {
                Text(Fmt.measure(value, format, compact: true))
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(hex: 0x252A33))
                    .minimumScaleFactor(0.4).lineLimit(1)
                if let t = target {
                    let delta = t != 0 ? (value - t) / abs(t) : 0
                    let good = value >= t
                    HStack(spacing: 4) {
                        Image(systemName: good ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                        Text(delta.formatted(.percent.precision(.fractionLength(1)).sign(strategy: .always())))
                        Text(L("vs objectif %@", Fmt.measure(t, format, compact: true))).foregroundStyle(.secondary)
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(good ? Color(hex: 0x2BA37A) : Color(hex: 0xD9534F))
                } else {
                    Text(label).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                if let tr = trend, tr.message == nil, tr.points.count > 1 {
                    Chart(tr.points.filter { $0.series == tr.series.first }) { p in
                        AreaMark(x: .value("c", p.category), y: .value("v", p.value))
                            .foregroundStyle(color.opacity(0.15))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("c", p.category), y: .value("v", p.value))
                            .foregroundStyle(color)
                            .interpolationMethod(.monotone)
                    }
                    .chartXScale(domain: tr.categories)
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                    .chartLegend(.hidden)
                    .frame(maxHeight: 50)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            PlaceholderView(message: L("Ajoutez un champ dans « Valeur »"), symbol: "arrow.up.right.circle")
        }
    }
}

// MARK: - Map

/// Geocodes place names with Apple's geocoder (one request at a time) and caches the results on disk.
@Observable
final class GeoCache {
    static let shared = GeoCache()
    private(set) var coordinates: [String: CLLocationCoordinate2D] = [:]
    private var failed: Set<String> = []
    private var queue: [String] = []
    private var running = false
    private let geocoder = CLGeocoder()
    private let key = "prisme.geocache"

    init() {
        if let saved = UserDefaults.standard.dictionary(forKey: key) as? [String: [Double]] {
            for (k, v) in saved where v.count == 2 {
                coordinates[k] = CLLocationCoordinate2D(latitude: v[0], longitude: v[1])
            }
        }
    }

    func request(_ names: [String]) {
        for n in names where coordinates[n] == nil && !failed.contains(n) && !queue.contains(n) && n != GroupKey.blankLabel {
            queue.append(n)
        }
        guard !running else { return }
        running = true
        Task { @MainActor in
            while !queue.isEmpty {
                let name = queue.removeFirst()
                if let place = try? await geocoder.geocodeAddressString(name).first, let loc = place.location {
                    coordinates[name] = loc.coordinate
                    save()
                } else {
                    failed.insert(name)
                }
            }
            running = false
        }
    }

    private func save() {
        UserDefaults.standard.set(coordinates.mapValues { [$0.latitude, $0.longitude] }, forKey: key)
    }
}

struct MapVisualView: View {
    let data: ChartData
    let format: VisualFormat
    let selected: String?
    let onSelect: (String?) -> Void
    @State private var geo = GeoCache.shared
    @State private var position: MapCameraPosition = .automatic
    @Environment(\.isExporting) private var exporting

    private struct Spot: Identifiable {
        let id: String
        let coordinate: CLLocationCoordinate2D
        let value: Double
    }

    var body: some View {
        if let m = data.message {
            PlaceholderView(message: m, symbol: "map")
        } else if exporting {
            PlaceholderView(message: L("Carte géographique (non incluse dans l'export)"), symbol: "map")
        } else {
            let series = data.series.first
            let spots = data.points.filter { $0.series == series }.compactMap { p in
                geo.coordinates[p.category].map { Spot(id: p.category, coordinate: $0, value: p.value) }
            }
            let maxV = spots.map(\.value).max() ?? 1
            let color = Theme.colors(1, first: format.color)[0]
            MapReader { reader in
                Map(position: $position) {
                    ForEach(spots) { s in
                        let ratio = sqrt(max(0, s.value) / max(maxV, 1e-9))
                        MapCircle(center: s.coordinate, radius: 15_000 + 85_000 * ratio)
                            .foregroundStyle(color.opacity(selected == nil || selected == s.id ? 0.6 : 0.15))
                            .stroke(Color.white, lineWidth: 1)
                        if format.dataLabels {
                            Annotation(s.id, coordinate: s.coordinate) { EmptyView() }
                        }
                    }
                }
                .onTapGesture { point in
                    guard let c = reader.convert(point, from: .local) else { onSelect(nil); return }
                    let here = CLLocation(latitude: c.latitude, longitude: c.longitude)
                    let hit = spots.min { here.distance(from: CLLocation(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude))
                        < here.distance(from: CLLocation(latitude: $1.coordinate.latitude, longitude: $1.coordinate.longitude)) }
                    if let h = hit, here.distance(from: CLLocation(latitude: h.coordinate.latitude, longitude: h.coordinate.longitude)) < 120_000 {
                        onSelect(h.id)
                    } else {
                        onSelect(nil)
                    }
                }
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
            .onAppear { geo.request(data.categories) }
            .onChange(of: data.categories) { _, c in geo.request(c) }
            .onChange(of: spots.count) { _, _ in position = .automatic }
            .overlay(alignment: .bottomLeading) {
                let missing = data.categories.filter { geo.coordinates[$0] == nil }.count
                if missing > 0 {
                    Text(L("Localisation de %@ lieu(x)…", missing))
                        .font(.system(size: 9)).padding(4)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.85)))
                        .padding(6)
                }
            }
        }
    }
}

// MARK: - Waterfall

/// Running total: each category adds (green) or removes (red) from the previous total, ending with a total bar.
struct WaterfallView: View {
    let data: ChartData
    let format: VisualFormat
    let selected: String?
    let onSelect: (String?) -> Void

    private struct Step: Identifiable {
        let id: String
        let start: Double
        let end: Double
        let isTotal: Bool
    }

    var body: some View {
        if let m = data.message {
            PlaceholderView(message: m, symbol: VisualType.waterfall.symbol)
        } else {
            let series = data.series.first
            var running = 0.0
            let steps: [Step] = data.categories.compactMap { c in
                guard let v = data.points.first(where: { $0.category == c && $0.series == series })?.value else { return nil }
                defer { running += v }
                return Step(id: c, start: running, end: running + v, isTotal: false)
            } + [Step(id: L("Total"), start: 0, end: running, isTotal: true)]
            Chart(steps) { s in
                BarMark(x: .value("c", s.id), yStart: .value("a", s.start), yEnd: .value("b", s.end))
                    .foregroundStyle(s.isTotal ? Theme.palette[0] : (s.end >= s.start ? Color(hex: 0x2BA37A) : Color(hex: 0xD9534F)))
                    .opacity(selected == nil || selected == s.id || s.isTotal ? 1 : 0.35)
                    .annotation(position: .top, spacing: 2) {
                        if format.dataLabels {
                            Text(Fmt.measure(s.end - s.start, data.format, compact: true)).font(.system(size: 8)).foregroundStyle(.secondary)
                        }
                    }
            }
            .chartXScale(domain: steps.map(\.id))
            .chartYAxis { AxisMarks(position: .leading) { v in
                if format.gridlines { AxisGridLine() }
                AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.measure(d, .auto, compact: true)) } }
            } }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle()).onTapGesture { loc in
                        guard let pf = proxy.plotFrame else { return }
                        let c: String? = proxy.value(atX: loc.x - geo[pf].minX, as: String.self)
                        onSelect(c == L("Total") ? nil : c)
                    }
                }
            }
        }
    }
}

// MARK: - Funnel

struct FunnelView: View {
    let data: ChartData
    let format: VisualFormat
    let selected: String?
    let onSelect: (String?) -> Void

    var body: some View {
        if let m = data.message {
            PlaceholderView(message: m, symbol: VisualType.funnel.symbol)
        } else {
            let series = data.series.first
            let pts = data.categories.compactMap { c in data.points.first { $0.category == c && $0.series == series } }
            let top = pts.first?.value ?? 1
            let color = Theme.colors(1, first: format.color)[0]
            Chart(pts) { p in
                BarMark(xStart: .value("a", -p.value / 2), xEnd: .value("b", p.value / 2), y: .value("c", p.category))
                    .foregroundStyle(color.opacity(selected == nil || selected == p.category ? 0.85 : 0.25))
                    .annotation(position: .overlay) {
                        Text(Fmt.measure(p.value, data.format, compact: true) + (format.dataLabels && top > 0
                             ? " · " + (p.value / top).formatted(.percent.precision(.fractionLength(0))) : ""))
                            .font(.system(size: 9, weight: .semibold)).foregroundStyle(.white)
                    }
            }
            .chartYScale(domain: pts.map(\.category))
            .chartXAxis(.hidden)
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle()).onTapGesture { loc in
                        guard let pf = proxy.plotFrame else { return }
                        onSelect(proxy.value(atY: loc.y - geo[pf].minY, as: String.self))
                    }
                }
            }
        }
    }
}
