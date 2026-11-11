import Foundation
import Testing
@testable import Prisme

extension PrismeTests {
    @Suite struct EngineTests {
        let st = Fixture.sample()

        @Test func detectsSampleRelationships() {
            #expect(Set(st.relationships.map(\.label)) == ["Ventes[Produit] → Produits[Produit]", "Ventes[Région] → Régions[Région]"])
        }

        @Test func columnChartSortsByValue() {
            let v = Visual(type: .column, frame: .zero, axis: [field("Région")], values: [st.measureField("Chiffre d'affaires")])
            let d = Engine.chartData(v, st.model, [])
            #expect(d.categories.first == "Île-de-France")
            #expect(close(d.points.reduce(0) { $0 + $1.value }, 1_415_422))
        }

        @Test func filtersFlowThroughRelationships() {
            let card = Visual(type: .card, frame: .zero, values: [st.measureField("Chiffre d'affaires")])
            let filters = [FilterSpec(field: field("Zone", "Régions"), allowed: ["Sud"])]
            #expect(close(Engine.scalars(card, st.model, filters)[0] ?? 0, 216_950))
            // Filters on the "many" side don't reach a lookup table.
            let regions = Visual(type: .slicer, frame: .zero, axis: [field("Zone", "Régions")])
            #expect(Engine.distinctValues(regions.axis[0], st.tables).count == 4)
        }

        @Test func matrixTotalsMatch() {
            let v = Visual(type: .matrix, frame: .zero, axis: [field("Catégorie", "Produits")], legend: field("Canal"),
                           values: [st.measureField("Chiffre d'affaires")])
            let m = Engine.matrixData(v, st.model, [])
            #expect(m.headers == ["Catégorie", "En ligne", "Magasin", "Total"])
            let info = m.raw.first { $0[0] == "Informatique" }
            #expect(info?[1] == "394485")
            #expect(m.raw.map { Double($0[3]) ?? 0 }.reduce(0, +) == 1_415_422)
        }

        @Test func drillDownFiltersTheNextLevel() {
            let id = st.addVisual(.column)
            st.addField(field("Date"), to: .axis, visualID: id)
            st.addField(field("Montant"), to: .values, visualID: id)
            st.expandDateHierarchy(st.visual(id)!, at: 0)
            #expect(Engine.chartData(st.visual(id)!, st.model, []).categories == ["2024", "2025"])
            st.drillDown(st.visual(id)!, into: "2025")
            st.drillDown(st.visual(id)!, into: "T2 2025")
            #expect(Engine.chartData(st.visual(id)!, st.model, []).categories == ["avr. 2025", "mai 2025", "juin 2025"])
            st.drillUp(st.visual(id)!)
            #expect(Engine.chartData(st.visual(id)!, st.model, []).categories.count == 4)
        }

        @Test func tableSortAndTopN() {
            var f = VisualFormat()
            f.tableSortColumn = 1
            f.tableSortDescending = true
            f.topN = 3
            let v = Visual(type: .table, frame: .zero, axis: [field("Produit")], values: [st.measureField("Chiffre d'affaires")], format: f)
            let rows = Engine.tableData(v, st.model, []).raw
            #expect(rows.map { $0[0] } == ["Ordinateur portable", "Smartphone", "Tablette"])
        }

        @Test func crossFilterAndDrillthrough() {
            let column = st.currentPage.visuals.first { $0.type == .column }!
            st.toggleCrossFilter(from: column, label: "Occitanie")
            let card = st.currentPage.visuals.first { $0.type == .card }!
            #expect(close(Engine.cardValueNumber(card, st), 216_950))
            let detail = st.pages[1].id
            st.selectPage(detail)
            st.addDrillthroughField(field("Région"))
            st.selectPage(st.pages[0].id)
            st.toggleCrossFilter(from: column, label: "Occitanie")
            st.drillthrough(to: detail, field: st.crossFilter!.field, label: "Occitanie")
            #expect(st.currentPageID == detail)
            let kpi = st.currentPage.visuals.first { $0.type == .kpi }!
            #expect(close(Engine.scalars(kpi, st.model, st.filters(for: kpi))[0] ?? 0, 216_950))
            st.drillthroughBack()
            #expect(st.currentPageID == st.pages[0].id)
        }

        @Test func syncedSlicersAndBookmarks() {
            let canal = st.currentPage.visuals.first { $0.type == .slicer && $0.axis.first?.column == "Canal" }!
            st.addSlicerToAllPages(canal.id)
            st.toggleSlicer(canal.id, "Magasin")
            let all = st.pages.flatMap(\.visuals).filter { $0.type == .slicer && $0.axis.first?.column == "Canal" }
            #expect(all.count == 2 && all.allSatisfy { $0.slicerSelection == ["Magasin"] })
            st.addBookmark()
            st.clearSlicer(canal.id)
            st.applyBookmark(st.bookmarks[0].id)
            #expect(st.visual(canal.id)?.slicerSelection == ["Magasin"])
        }
    }
}

extension Engine {
    static func cardValueNumber(_ v: Visual, _ st: AppState) -> Double { scalars(v, st.model, st.filters(for: v))[0] ?? .nan }
}
