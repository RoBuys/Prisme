import Foundation
import Testing
@testable import Prisme

extension PrismeTests {
    @Suite struct DAXTests {
        let st = Fixture.sample()

        @Test(arguments: [
            ("SUM(Ventes[Montant])", 1_415_422.0),
            ("[Chiffre d'affaires]", 1_415_422),
            ("COUNTROWS(Ventes)", 2822),
            ("SUMX(Ventes, Ventes[Quantité] * Ventes[Prix unitaire])", 1_415_422),
            ("SUMX(Ventes, Ventes[Quantité] * RELATED(Produits[Prix catalogue]))", 1_491_953),
            ("COUNTROWS(FILTER(Ventes, Ventes[Montant] > 1000))", 408),
            ("CALCULATE(COUNTROWS(Ventes), Ventes[Montant] > 1000)", 408),
            ("CALCULATE([Chiffre d'affaires], Régions[Zone] = \"Sud\")", 216_950),
            ("CALCULATE([Chiffre d'affaires], Ventes[Canal] = \"Magasin\")", 603_375),
            ("CALCULATE([Chiffre d'affaires], KEEPFILTERS(Ventes[Canal] = \"Magasin\"))", 603_375),
            ("CALCULATE([Chiffre d'affaires]; Ventes[Canal] = \"Magasin\") + CALCULATE([Chiffre d'affaires], Ventes[Canal] = \"En ligne\")", 1_415_422),
            ("CALCULATE([Chiffre d'affaires], FILTER(Produits, Produits[Catégorie] = \"Audio\"))", 120_454),
            ("CALCULATE([Chiffre d'affaires], DATESYTD(Ventes[Date]))", 790_410),
            ("TOTALYTD([Chiffre d'affaires], Ventes[Date])", 790_410),
            ("CALCULATE([Chiffre d'affaires], SAMEPERIODLASTYEAR(Ventes[Date]))", 625_012),
            ("COUNTROWS(VALUES(Ventes[Produit]))", 10),
            ("SUMX(VALUES(Ventes[Région]), [Chiffre d'affaires])", 1_415_422),
            ("MAXX(VALUES(Ventes[Région]), [Chiffre d'affaires])", 412_123),
            ("SUMX(TOPN(3, VALUES(Ventes[Produit]), [Chiffre d'affaires]), [Chiffre d'affaires])", 1_006_921),
            ("VAR ca = [Chiffre d'affaires] VAR n = [Nombre de ventes] RETURN ROUND(DIVIDE(ca, n), 2)", 501.57),
            ("DATEDIFF(DATE(2024, 1, 1), DATE(2025, 3, 15), MONTH)", 14),
            ("DATEDIFF(DATE(2024, 1, 1), DATE(2025, 3, 15), DAY)", 439),
            ("MOD(17, 5) + POWER(2, 3) + SQRT(16) + INT(2.7)", 16),
            ("SWITCH(2, 1, 10, 2, 20, 30)", 20),
            ("DIVIDE(1, 0, -1)", -1),
            ("IF([Panier moyen] > 500 && NOT(ISBLANK([CA par habitant])), 1, 0)", 1),
        ])
        func evaluates(_ expr: String, _ expected: Double) throws {
            #expect(close(try st.number(expr), expected), "\(expr)")
        }

        @Test func textResults() throws {
            #expect(try st.value(#"SWITCH(TRUE(), [Chiffre d'affaires] > 1000000, "Gros", "Petit")"#).string == "Gros")
            #expect(try st.value(#"LOOKUPVALUE(Produits[Catégorie], Produits[Produit], "Souris")"#).string == "Accessoires")
            #expect(try st.value(#"FORMAT(EOMONTH(DATE(2024, 2, 10), 0), "dd/MM/yyyy")"#).string == "29/02/2024")
            #expect(try st.value(#"SELECTEDVALUE(Ventes[Canal], "plusieurs")"#).string == "plusieurs")
            #expect(try st.value(#"CALCULATE(SELECTEDVALUE(Ventes[Canal]), Ventes[Canal] = "Magasin")"#).string == "Magasin")
            #expect(try st.value(#""x" & 3 & UPPER("ab")"#).string == "x3AB")
        }

        @Test(arguments: [
            "SUM(Ventes[Inconnu])", "[Test]", "SUM(Ventes[Montant]", "ALL(Ventes)", "FOO(1)", "VALUES(Ventes[Produit])",
            "VAR x = 1 RETURN x +", "DATESYTD(Ventes[Date])", "FILTER(Ventes, Ventes[Montant] > 1)",
        ])
        func rejectsInvalidExpressions(_ expr: String) {
            #expect(throws: MeasureError.self) { try st.value(expr) }
        }

        @Test func previousYearKeepsMonthEnds() throws {
            // February 2025 last year must include 29 February 2024.
            st.measures.append(Measure(name: "CA N-1", table: "Ventes",
                                       expression: "CALCULATE([Chiffre d'affaires], SAMEPERIODLASTYEAR(Ventes[Date]))"))
            let v = Visual(type: .table, frame: .zero, axis: [field("Date", "Ventes", .month)],
                           values: [st.measureField("Chiffre d'affaires"), st.measureField("CA N-1")])
            let raw = Engine.tableData(v, st.model, []).raw
            let feb24 = try #require(raw.first { $0[0] == "févr. 2024" }), feb25 = try #require(raw.first { $0[0] == "févr. 2025" })
            #expect(feb25[2] == feb24[1])
        }

        @Test func rankingFollowsContextTransition() throws {
            st.measures.append(Measure(name: "Rang", table: "Ventes", expression: "RANKX(ALL(Ventes[Région]), [Chiffre d'affaires])"))
            let v = Visual(type: .table, frame: .zero, axis: [field("Région")], values: [st.measureField("Rang")])
            let ranks = Dictionary(uniqueKeysWithValues: Engine.tableData(v, st.model, []).raw.map { ($0[0], $0[1]) })
            #expect(ranks["Île-de-France"] == "1")
            #expect(ranks["Auvergne-Rhône-Alpes"] == "2")
            #expect(ranks["Grand Est"] == "6")
        }

        @Test func calculatedColumnsUseRowContext() throws {
            #expect(st.saveColumn(MeasureDraft(id: nil, name: "Taille", table: "Ventes",
                                               expression: #"IF(Ventes[Montant] > 1000, "Gros", "Petit")"#, format: .auto, isColumn: true)) == nil)
            let v = Visual(type: .table, frame: .zero, axis: [field("Taille")], values: [ValueField(field: field("Montant"), aggregation: .count)])
            let counts = Engine.tableData(v, st.model, []).raw.map { $0[1] }
            #expect(counts == ["408", "2414"])
            // Aggregations in a calculated column see the whole table.
            let (_, values) = try st.computeColumn(table: "Ventes", expression: "SUM(Ventes[Montant])")
            #expect(values.first == .number(1_415_422))
        }
    }
}
