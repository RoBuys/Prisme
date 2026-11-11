import Foundation
import CoreGraphics

/// A deterministic sales dataset (star schema: Sales → Products, Sales → Regions; French or English names) and a starter report.
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
        func w(_ fr: String, _ en: String) -> String { Loc.isEnglish ? en : fr }
        let online = w("En ligne", "Online")
        let cRegion = w("Région", "Region"), cChannel = w("Canal", "Channel"), cProduct = w("Produit", "Product")
        let cQty = w("Quantité", "Quantity"), cAmount = w("Montant", "Amount"), cCategory = w("Catégorie", "Category")
        let cZone = "Zone"
        let mRevenue = w("Chiffre d'affaires", "Revenue"), mCount = w("Nombre de ventes", "Number of sales")
        let mBasket = w("Panier moyen", "Average basket"), mShare = w("Part du CA", "Revenue share")
        let mPerCapita = w("CA par habitant", "Revenue per capita")
        var rng = RNG(state: 42)
        let products: [((String, String, Double), Double)] = [
            ((w("Ordinateur portable", "Laptop"), w("Informatique", "Computers"), 899), 1.2), ((w("Écran 27 pouces", "27-inch monitor"), w("Informatique", "Computers"), 249), 1.0),
            ((w("Tablette", "Tablet"), w("Informatique", "Computers"), 449), 0.9), ((w("Clavier", "Keyboard"), w("Accessoires", "Accessories"), 49), 1.6),
            ((w("Souris", "Mouse"), w("Accessoires", "Accessories"), 25), 2.0), ((w("Chargeur", "Charger"), w("Accessoires", "Accessories"), 19), 1.8),
            ((w("Casque audio", "Headphones"), "Audio", 129), 1.3), ((w("Enceinte", "Speaker"), "Audio", 89), 1.1),
            (("Smartphone", w("Téléphonie", "Phones"), 699), 1.4), ((w("Montre connectée", "Smartwatch"), w("Téléphonie", "Phones"), 299), 0.8),
        ]
        let regions: [(String, Double)] = [
            ("Île-de-France", 3.0), ("Auvergne-Rhône-Alpes", 2.0), ("Nouvelle-Aquitaine", 1.5),
            ("Occitanie", 1.4), ("Hauts-de-France", 1.2), ("Grand Est", 1.0),
        ]
        let channels: [(String, Double)] = [(online, 1.3), (w("Magasin", "Store"), 1.0)]
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
                let unit = (price * (channel == online ? 0.95 : 1.0) * (0.9 + rng.next() * 0.15)).rounded()
                _ = category
                rows.append([
                    .date(date), .text(rng.pick(regions)), .text(channel), .text(product),
                    .number(qty), .number(unit), .number(qty * unit),
                ])
            }
        }
        let table = DataTable(name: name, columns: [
            DataColumn(name: "Date", type: .date), DataColumn(name: cRegion, type: .text),
            DataColumn(name: cChannel, type: .text), DataColumn(name: cProduct, type: .text),
            DataColumn(name: cQty, type: .number),
            DataColumn(name: w("Prix unitaire", "Unit price"), type: .number), DataColumn(name: cAmount, type: .number),
        ], rows: rows)

        let productTable = DataTable(name: names.products, columns: [
            DataColumn(name: cProduct, type: .text), DataColumn(name: cCategory, type: .text),
            DataColumn(name: w("Prix catalogue", "List price"), type: .number),
        ], rows: products.map { p, _ in [.text(p.0), .text(p.1), .number(p.2)] })

        let zones = ["Île-de-France": w("Nord", "North"), "Hauts-de-France": w("Nord", "North"), "Grand Est": w("Est", "East"),
                     "Auvergne-Rhône-Alpes": w("Est", "East"), "Nouvelle-Aquitaine": w("Ouest", "West"), "Occitanie": w("Sud", "South")]
        let population = ["Île-de-France": 12.3, "Hauts-de-France": 6.0, "Grand Est": 5.6,
                          "Auvergne-Rhône-Alpes": 8.1, "Nouvelle-Aquitaine": 6.1, "Occitanie": 6.0]
        let regionTable = DataTable(name: names.regions, columns: [
            DataColumn(name: cRegion, type: .text), DataColumn(name: cZone, type: .text),
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
            Measure(name: mRevenue, table: name, expression: "SUM(\(sales)[\(cAmount)])", format: .currency),
            Measure(name: mCount, table: name, expression: "COUNTROWS(\(sales))", format: .integer),
            Measure(name: mBasket, table: name,
                    expression: "DIVIDE([\(mRevenue)], [\(mCount)])", format: .currency),
            Measure(name: mShare, table: name,
                    expression: "DIVIDE([\(mRevenue)], CALCULATE([\(mRevenue)], ALLSELECTED(\(sales))))",
                    format: .percent),
            Measure(name: mPerCapita, table: name,
                    expression: "DIVIDE([\(mRevenue)], SUM(\(regionsRef)[Population (M)]) * 1000000)",
                    format: .decimal),
        ]
        func ms(_ n: String) -> ValueField { ValueField(field: FieldRef(table: name, column: n), aggregation: .sum, isMeasure: true) }

        let visuals = [
            Visual(type: .card, frame: r(20, 20, 312, 116), values: [ms(mRevenue)]),
            Visual(type: .card, frame: r(344, 20, 312, 116), values: [ms(mCount)]),
            Visual(type: .card, frame: r(668, 20, 312, 116), values: [ms(mBasket)]),
            Visual(type: .column, frame: r(20, 152, 468, 280), axis: [f(cRegion)], values: [ms(mRevenue)]),
            Visual(type: .line, frame: r(500, 152, 480, 280), axis: [f("Date", .month)], legend: f(cChannel),
                   values: [sum(cAmount)]),
            Visual(type: .donut, frame: r(20, 448, 400, 252), axis: [pf(cCategory)], values: [sum(cAmount)]),
            Visual(type: .table, frame: r(432, 448, 548, 252), axis: [f(cProduct)],
                   values: [sum(cQty), ms(mRevenue), ms(mShare)]),
            Visual(type: .slicer, frame: r(996, 20, 264, 156), axis: [f("Date", .year)]),
            Visual(type: .slicer, frame: r(996, 192, 264, 132), axis: [f(cChannel)]),
            Visual(type: .slicer, frame: r(996, 340, 264, 176), axis: [rf(cZone)]),
            Visual(type: .card, frame: r(996, 532, 264, 168), values: [ms(mPerCapita)]),
        ]
        return ([table, productTable, regionTable], measures, ReportPage(name: w("Vue d'ensemble", "Overview"), visuals: visuals))
    }
}
