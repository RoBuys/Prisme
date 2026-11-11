import Foundation
import CoreGraphics

/// A deterministic sales dataset (star schema: Ventes → Produits, Ventes → Régions) and a starter report.
enum SampleData {
    private struct RNG {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(UInt64(1) << 53)
        }
        mutating func pick<T>(_ items: [(T, Double)]) -> T {
            let total = items.reduce(0) { $0 + $1.1 }
            var r = next() * total
            for (item, w) in items {
                r -= w
                if r <= 0 { return item }
            }
            return items[items.count - 1].0
        }
    }

    static func make(names: (sales: String, products: String, regions: String)) -> (tables: [DataTable], measures: [Measure], page: ReportPage) {
        let name = names.sales
        var rng = RNG(state: 42)
        let products: [((String, String, Double), Double)] = [
            (("Ordinateur portable", "Informatique", 899), 1.2), (("Écran 27 pouces", "Informatique", 249), 1.0),
            (("Tablette", "Informatique", 449), 0.9), (("Clavier", "Accessoires", 49), 1.6),
            (("Souris", "Accessoires", 25), 2.0), (("Chargeur", "Accessoires", 19), 1.8),
            (("Casque audio", "Audio", 129), 1.3), (("Enceinte", "Audio", 89), 1.1),
            (("Smartphone", "Téléphonie", 699), 1.4), (("Montre connectée", "Téléphonie", 299), 0.8),
        ]
        let regions: [(String, Double)] = [
            ("Île-de-France", 3.0), ("Auvergne-Rhône-Alpes", 2.0), ("Nouvelle-Aquitaine", 1.5),
            ("Occitanie", 1.4), ("Hauts-de-France", 1.2), ("Grand Est", 1.0),
        ]
        let channels: [(String, Double)] = [("En ligne", 1.3), ("Magasin", 1.0)]
        let seasonality: [Double] = [0.8, 0.7, 0.85, 0.9, 0.95, 1.0, 0.9, 0.85, 1.0, 1.05, 1.4, 1.8]

        let start = Fmt.calendar.date(from: DateComponents(year: 2024, month: 1, day: 1))!
        var rows: [[CellValue]] = []
        for dayOffset in 0..<731 {
            let date = Fmt.calendar.date(byAdding: .day, value: dayOffset, to: start)!
            let month = Fmt.calendar.component(.month, from: date)
            let growth = 1 + Double(dayOffset) / 731 * 0.35
            let orders = Int((3.2 * seasonality[month - 1] * growth * (0.6 + rng.next() * 0.8)).rounded())
            for _ in 0..<orders {
                let (product, category, price) = rng.pick(products)
                let channel = rng.pick(channels)
                let qty = Double(1 + Int(rng.next() * rng.next() * 6))
                let unit = (price * (channel == "En ligne" ? 0.95 : 1.0) * (0.9 + rng.next() * 0.15)).rounded()
                _ = category
                rows.append([
                    .date(date), .text(rng.pick(regions)), .text(channel), .text(product),
                    .number(qty), .number(unit), .number(qty * unit),
                ])
            }
        }
        let table = DataTable(name: name, columns: [
            DataColumn(name: "Date", type: .date), DataColumn(name: "Région", type: .text),
            DataColumn(name: "Canal", type: .text), DataColumn(name: "Produit", type: .text),
            DataColumn(name: "Quantité", type: .number),
            DataColumn(name: "Prix unitaire", type: .number), DataColumn(name: "Montant", type: .number),
        ], rows: rows)

        let productTable = DataTable(name: names.products, columns: [
            DataColumn(name: "Produit", type: .text), DataColumn(name: "Catégorie", type: .text),
            DataColumn(name: "Prix catalogue", type: .number),
        ], rows: products.map { p, _ in [.text(p.0), .text(p.1), .number(p.2)] })

        let zones = ["Île-de-France": "Nord", "Hauts-de-France": "Nord", "Grand Est": "Est",
                     "Auvergne-Rhône-Alpes": "Est", "Nouvelle-Aquitaine": "Ouest", "Occitanie": "Sud"]
        let population = ["Île-de-France": 12.3, "Hauts-de-France": 6.0, "Grand Est": 5.6,
                          "Auvergne-Rhône-Alpes": 8.1, "Nouvelle-Aquitaine": 6.1, "Occitanie": 6.0]
        let regionTable = DataTable(name: names.regions, columns: [
            DataColumn(name: "Région", type: .text), DataColumn(name: "Zone", type: .text),
            DataColumn(name: "Population (M)", type: .number),
        ], rows: regions.map { r, _ in [.text(r), .text(zones[r] ?? ""), .number(population[r] ?? 0)] })

        func f(_ c: String, _ level: DateLevel? = nil) -> FieldRef { FieldRef(table: name, column: c, dateLevel: level) }
        func pf(_ c: String) -> FieldRef { FieldRef(table: names.products, column: c) }
        func rf(_ c: String) -> FieldRef { FieldRef(table: names.regions, column: c) }
        func sum(_ c: String) -> ValueField { ValueField(field: f(c), aggregation: .sum) }
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x, y: y, width: w, height: h) }

        func q(_ t: String) -> String { t.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" } ? t : "'\(t)'" }
        let sales = q(name), regionsRef = q(names.regions)
        let measures = [
            Measure(name: "Chiffre d'affaires", table: name, expression: "SUM(\(sales)[Montant])", format: .currency),
            Measure(name: "Nombre de ventes", table: name, expression: "COUNTROWS(\(sales))", format: .integer),
            Measure(name: "Panier moyen", table: name,
                    expression: "DIVIDE([Chiffre d'affaires], [Nombre de ventes])", format: .currency),
            Measure(name: "Part du CA", table: name,
                    expression: "DIVIDE([Chiffre d'affaires], CALCULATE([Chiffre d'affaires], ALLSELECTED(\(sales))))",
                    format: .percent),
            Measure(name: "CA par habitant", table: name,
                    expression: "DIVIDE([Chiffre d'affaires], SUM(\(regionsRef)[Population (M)]) * 1000000)",
                    format: .decimal),
        ]
        func ms(_ n: String) -> ValueField { ValueField(field: FieldRef(table: name, column: n), aggregation: .sum, isMeasure: true) }

        let visuals = [
            Visual(type: .card, frame: r(20, 20, 312, 116), values: [ms("Chiffre d'affaires")]),
            Visual(type: .card, frame: r(344, 20, 312, 116), values: [ms("Nombre de ventes")]),
            Visual(type: .card, frame: r(668, 20, 312, 116), values: [ms("Panier moyen")]),
            Visual(type: .column, frame: r(20, 152, 468, 280), axis: [f("Région")], values: [ms("Chiffre d'affaires")]),
            Visual(type: .line, frame: r(500, 152, 480, 280), axis: [f("Date", .month)], legend: f("Canal"),
                   values: [sum("Montant")]),
            Visual(type: .donut, frame: r(20, 448, 400, 252), axis: [pf("Catégorie")], values: [sum("Montant")]),
            Visual(type: .table, frame: r(432, 448, 548, 252), axis: [f("Produit")],
                   values: [sum("Quantité"), ms("Chiffre d'affaires"), ms("Part du CA")]),
            Visual(type: .slicer, frame: r(996, 20, 264, 156), axis: [f("Date", .year)]),
            Visual(type: .slicer, frame: r(996, 192, 264, 132), axis: [f("Canal")]),
            Visual(type: .slicer, frame: r(996, 340, 264, 176), axis: [rf("Zone")]),
            Visual(type: .card, frame: r(996, 532, 264, 168), values: [ms("CA par habitant")]),
        ]
        return ([table, productTable, regionTable], measures, ReportPage(name: "Vue d'ensemble", visuals: visuals))
    }
}
