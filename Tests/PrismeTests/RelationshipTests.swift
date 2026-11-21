import Foundation
import Testing
@testable import Prisme

extension PrismeTests {
    /// Filters through both-way and many-to-many relationships.
    @Suite struct RelationshipTests {
        /// Sample model + Stocks (second fact on Produits) + Budget (per category, many-to-many with Produits).
        static func model() -> AppState {
            let st = Fixture.sample()
            let products = st.table("Produits").rows.map { $0[0] }
            st.tables.append(DataTable(name: "Stocks", columns: [DataColumn(name: "Produit", type: .text), DataColumn(name: "Qté", type: .number)],
                                       rows: products.enumerated().map { [$0.element, .number(Double($0.offset + 1))] }))
            let ci = st.table("Produits").columnIndex("Catégorie")!
            let categories = Array(Set(st.table("Produits").rows.map { $0[ci] })).sorted { ($0.text ?? "") < ($1.text ?? "") }
            st.tables.append(DataTable(name: "Budget", columns: [DataColumn(name: "Catégorie", type: .text), DataColumn(name: "Montant", type: .number)],
                                       rows: categories.flatMap { [[$0, .number(100)], [$0, .number(10)]] }))
            st.relationships.append(Relationship(fromTable: "Stocks", fromColumn: "Produit", toTable: "Produits", toColumn: "Produit"))
            st.relationships.append(Relationship(fromTable: "Budget", fromColumn: "Catégorie", toTable: "Produits", toColumn: "Catégorie",
                                                 manyToMany: true))
            return st
        }

        /// Products sold for more than `amount` in one sale.
        static func bigSaleProducts(_ st: AppState, _ amount: Double) -> Set<String> {
            let v = st.table("Ventes"), p = v.columnIndex("Produit")!, m = v.columnIndex("Montant")!
            return Set(v.rows.filter { ($0[m].number ?? 0) > amount }.compactMap { $0[p].text })
        }

        func stockOf(_ st: AppState, _ products: Set<String>) -> Double {
            st.table("Stocks").rows.filter { products.contains($0[0].text ?? "") }.compactMap { $0[1].number }.reduce(0, +)
        }

        @Test func filtersFlowBothWaysWhenAsked() throws {
            let st = Self.model()
            let big = FilterSpec(field: FieldRef(table: "Ventes", column: "Montant"), allowed: [], range: 3000...Double.greatestFiniteMagnitude)
            let all = try st.number("SUM(Stocks[Qté])", table: "Stocks")
            // One way only: a filter on sales doesn't reach the products, so stocks aren't filtered.
            #expect(try st.number("SUM(Stocks[Qté])", table: "Stocks", filters: [big]) == all)
            // Both ways on Ventes → Produits: only the products of big sales.
            let i = st.relationships.firstIndex { $0.fromTable == "Ventes" && $0.toTable == "Produits" }!
            st.relationships[i].bothDirections = true
            let products = Self.bigSaleProducts(st, 3000)
            #expect(!products.isEmpty && products.count < st.table("Produits").rows.count)
            #expect(try st.number("SUM(Stocks[Qté])", table: "Stocks", filters: [big]) == stockOf(st, products))
            #expect(try st.number("COUNTROWS(Produits)", table: "Ventes", filters: [big]) == Double(products.count))
        }

        @Test func manyToManyRelationshipsFilter() throws {
            let st = Self.model()
            let pi = st.table("Produits").columnIndex("Produit")!, ci = st.table("Produits").columnIndex("Catégorie")!
            let first = st.table("Produits").rows[0]
            let filter = FilterSpec(field: FieldRef(table: "Produits", column: "Produit"), allowed: [first[pi].text!])
            // Products → budget lines of their category (two lines of 100 and 10).
            #expect(try st.number("SUM(Budget[Montant])", table: "Budget", filters: [filter]) == 110)
            #expect(try st.number("SUM(Budget[Montant])", table: "Budget") == Double(Set(st.table("Produits").rows.map { $0[ci] }).count) * 110)
            // Not followed row by row: Budget can't group by product attributes.
            #expect(!st.model.reachable(from: "Budget").contains { $0.table == "Produits" })
        }

        @Test func importsAndExportsDirectionAndCardinality() throws {
            let st = Self.model()
            let i = st.relationships.firstIndex { $0.fromTable == "Ventes" && $0.toTable == "Produits" }!
            st.relationships[i].bothDirections = true
            let url = Fixture.temp("Rel.pbit")
            try st.pbitData().data.write(to: url)
            let back = AppState()
            back.importPowerBI(url, askForFiles: false)
            #expect(back.relationships.first { $0.fromTable == "Ventes" && $0.toTable == "Produits" }?.crossBoth == true)
            #expect(back.relationships.first { $0.fromTable == "Budget" }?.isManyToMany == true)
            #expect(!(back.alertMessage ?? "").contains("bidirectionnel"))
        }
    }
}
