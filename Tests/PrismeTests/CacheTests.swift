import Foundation
import Testing
@testable import Prisme

extension PrismeTests {
    /// Query caches: results follow data changes and never leak between documents.
    @Suite struct CacheTests {
        func card(_ measure: String) -> Visual {
            var v = Visual(type: .card, frame: .zero)
            v.values = [ValueField(field: FieldRef(table: "Ventes", column: measure), aggregation: .sum, isMeasure: true)]
            return v
        }

        @Test func cachedValuesFollowDataChanges() throws {
            let st = Fixture.sample()
            let v = card("Chiffre d'affaires")
            let before = try #require(Engine.cardValue(v, st.model, [])?.value)
            #expect(Engine.cardValue(v, st.model, [])?.value == before)     // served from the cache
            let ci = try #require(st.table("Ventes").columnIndex("Montant"))
            st.tables[0].rows[0][ci] = .number(1_000_000_000)
            #expect(Engine.cardValue(v, st.model, [])?.value != before)
        }

        @Test func documentsDoNotShareCachedResults() throws {
            let a = Fixture.sample(), b = Fixture.sample()
            let ci = try #require(b.table("Ventes").columnIndex("Montant"))
            b.tables[0].rows = b.tables[0].rows.map { var r = $0; r[ci] = .number(1); return r }
            let v = card("Chiffre d'affaires")
            #expect(Engine.cardValue(v, a.model, [])?.value != Engine.cardValue(v, b.model, [])?.value)
        }

        @Test func narrowedCalculateMatchesFullScan() throws {
            let st = Fixture.sample()
            st.measures.append(Measure(name: "Gros", table: "Ventes",
                                       expression: "CALCULATE(COUNTROWS(Ventes), FILTER(Ventes, Ventes[Montant] > 1000), Ventes[Canal] = \"Magasin\")"))
            var v = Visual(type: .column, frame: .zero)
            v.axis = [FieldRef(table: "Ventes", column: "Région")]
            v.values = [ValueField(field: FieldRef(table: "Ventes", column: "Gros"), aggregation: .sum, isMeasure: true)]
            let data = Engine.chartData(v, st.model, [])
            #expect(!data.points.isEmpty)
            for p in data.points {
                let expected = try st.number(#"CALCULATE(COUNTROWS(FILTER(Ventes, Ventes[Montant] > 1000 && Ventes[Canal] = "Magasin")), Ventes[Région] = ""#
                                             + p.category + #"")"#)
                #expect(close(p.value, expected), "\(p.category)")
            }
            #expect(close(data.points.map(\.value).reduce(0, +), try st.number(#"CALCULATE(COUNTROWS(FILTER(Ventes, Ventes[Montant] > 1000)), Ventes[Canal] = "Magasin")"#)))
        }
    }
}
