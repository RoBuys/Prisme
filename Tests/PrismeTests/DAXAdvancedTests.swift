import Foundation
import Testing
@testable import Prisme

extension PrismeTests {
    /// CROSSJOIN, UNION, GENERATE, GROUPBY, table constructors, date periods, calculation groups and row-level security.
    @Suite struct DAXAdvancedTests {
        let st = Fixture.sample()

        var regions: Double { Double(Set(st.table("Ventes").rows.compactMap { $0[st.table("Ventes").columnIndex("Région")!].text }).count) }
        var channels: Double { Double(Set(st.table("Ventes").rows.compactMap { $0[st.table("Ventes").columnIndex("Canal")!].text }).count) }

        @Test func tableFunctions() throws {
            #expect(try st.number("COUNTROWS(CROSSJOIN(VALUES(Ventes[Région]), VALUES(Ventes[Canal])))") == regions * channels)
            // Context transition on virtual rows: each (region, channel) pair filters the measure.
            #expect(close(try st.number("SUMX(CROSSJOIN(VALUES(Ventes[Région]), VALUES(Ventes[Canal])), [Chiffre d'affaires])"), 1_415_422))
            #expect(close(try st.number(#"SUMX(FILTER(CROSSJOIN(VALUES(Ventes[Région]), VALUES(Ventes[Canal])), Ventes[Canal] = "Magasin"), [Chiffre d'affaires])"#), 603_375))
            #expect(try st.number("COUNTROWS(UNION(VALUES(Ventes[Région]), VALUES(Ventes[Canal])))") == regions + channels)
            #expect(try st.number("COUNTROWS(GENERATE(VALUES(Ventes[Région]), VALUES(Ventes[Canal])))") == regions * channels)
            #expect(close(try st.number(#"SUMX(GROUPBY(Ventes, Ventes[Région], "Total", SUMX(CURRENTGROUP(), Ventes[Montant])), [Total])"#), 1_415_422))
            #expect(close(try st.number(#"MAXX(GROUPBY(Ventes, Ventes[Région], "Total", SUMX(CURRENTGROUP(), Ventes[Montant])), [Total])"#), 412_123))
        }

        @Test func tableConstructors() throws {
            #expect(try st.number("COUNTROWS({1, 2, 3})") == 3)
            #expect(try st.number("SUMX({1, 2, 3}, [Value])") == 6)
            #expect(try st.number(#"SUMX({("a", 10), ("b", 20)}, [Value2])"#) == 30)
            #expect(try st.value("NAMEOF([Chiffre d'affaires])").string == "'Ventes'[Chiffre d'affaires]")
            // Field parameter table.
            #expect(st.saveCalculatedTable(name: "Paramètre", expression: #"{ ("CA", NAMEOF([Chiffre d'affaires]), 0), ("Nombre", NAMEOF([Nombre de ventes]), 1) }"#) == nil)
            #expect(st.table("Paramètre").rows.count == 2)
            #expect(st.table("Paramètre").rows[1][1] == .text("'Ventes'[Nombre de ventes]"))
        }

        @Test func calculateTransitionsInRowContext() throws {
            // CALCULATE in an iterator sees the current row.
            #expect(close(try st.number("SUMX(VALUES(Ventes[Région]), CALCULATE(SUM(Ventes[Montant])))"), 1_415_422))
            #expect(close(try st.number("MAXX(VALUES(Ventes[Région]), CALCULATE(SUM(Ventes[Montant])))"), 412_123))
        }

        @Test func datePeriods() throws {
            let all = try st.number("[Chiffre d'affaires]")
            let y2024 = try st.number("CALCULATE([Chiffre d'affaires], YEAR(Ventes[Date]) = 2024)")
            #expect(close(try st.number("CALCULATE([Chiffre d'affaires], DATESBETWEEN(Ventes[Date], DATE(2024, 1, 1), DATE(2024, 12, 31)))"), y2024))
            #expect(close(try st.number("CALCULATE([Chiffre d'affaires], DATESBETWEEN(Ventes[Date], BLANK(), BLANK()))"), all))
            #expect(close(try st.number("CALCULATE([Chiffre d'affaires], DATESINPERIOD(Ventes[Date], DATE(2024, 12, 31), -12, MONTH))"), y2024))
            #expect(close(try st.number("CALCULATE([Chiffre d'affaires], DATESINPERIOD(Ventes[Date], DATE(2024, 1, 1), 1, YEAR))"), y2024))
            let march2024 = FilterSpec(field: FieldRef(table: "Ventes", column: "Date", dateLevel: .month), allowed: [GroupKey.of(.date(Date(timeIntervalSince1970: 1_709_251_200)), .month).label])
            let feb = try st.number("CALCULATE([Chiffre d'affaires], DATESBETWEEN(Ventes[Date], DATE(2024, 2, 1), DATE(2024, 2, 29)))")
            #expect(close(try st.number("CALCULATE([Chiffre d'affaires], PARALLELPERIOD(Ventes[Date], -1, MONTH))", filters: [march2024]), feb))
            let april = try st.number("CALCULATE([Chiffre d'affaires], DATESBETWEEN(Ventes[Date], DATE(2024, 4, 1), DATE(2024, 4, 30)))")
            #expect(close(try st.number("CALCULATE([Chiffre d'affaires], NEXTMONTH(Ventes[Date]))", filters: [march2024]), april))
        }

        @Test func calculationGroups() throws {
            var group = DataTable(name: "Temps", columns: [DataColumn(name: "Calcul", type: .text)],
                                  rows: [[.text("Courant")], [.text("N-1")], [.text("Double")]])
            group.calculationItems = [CalculationItem(name: "Courant", expression: "SELECTEDMEASURE()"),
                                      CalculationItem(name: "N-1", expression: "CALCULATE(SELECTEDMEASURE(), SAMEPERIODLASTYEAR(Ventes[Date]))"),
                                      CalculationItem(name: "Double", expression: "SELECTEDMEASURE() * 2")]
            st.tables.append(group)
            func pick(_ item: String) -> FilterSpec { FilterSpec(field: FieldRef(table: "Temps", column: "Calcul"), allowed: [item], isGroup: true) }
            let ca = try st.number("[Chiffre d'affaires]")
            #expect(close(try st.number("[Chiffre d'affaires]", filters: [pick("Courant")]), ca))
            #expect(close(try st.number("[Chiffre d'affaires]", filters: [pick("Double")]), ca * 2))
            #expect(close(try st.number("[Chiffre d'affaires]", filters: [pick("N-1")]),
                          try st.number("CALCULATE([Chiffre d'affaires], SAMEPERIODLASTYEAR(Ventes[Date]))")))
            // In a matrix: one column per item.
            var v = Visual(type: .matrix, frame: .zero)
            v.axis = [FieldRef(table: "Ventes", column: "Canal")]
            v.legend = FieldRef(table: "Temps", column: "Calcul")
            v.values = [ValueField(field: FieldRef(table: "Ventes", column: "Chiffre d'affaires"), aggregation: .sum, isMeasure: true)]
            let data = Engine.matrixData(v, st.model, [])
            #expect(data.headers.contains("Double"))
        }

        @Test func rowLevelSecurity() throws {
            st.roles = [SecurityRole(name: "Sud", filters: ["Régions": #"[Zone] = "Sud""#]),
                        SecurityRole(name: "Moi", filters: ["Ventes": "[Région] = USERNAME()"])]
            let south = try st.number(#"CALCULATE([Chiffre d'affaires], Régions[Zone] = "Sud")"#)
            st.viewAsRole = "Sud"
            // The filter on Régions reaches Ventes; ALL() can't remove it.
            #expect(close(try st.number("[Chiffre d'affaires]"), south))
            #expect(close(try st.number("CALCULATE([Chiffre d'affaires], ALL(Ventes))"), south))
            #expect(st.tables.first { $0.name == "Ventes" }!.rows.count == 2822)   // the data itself is untouched
            st.viewAsRole = "Moi"
            st.viewAsUser = "Grand Est"
            let grandEst = try st.number(#"CALCULATE([Chiffre d'affaires], Ventes[Région] = "Grand Est")"#)
            #expect(close(try st.number("[Chiffre d'affaires]"), grandEst))
            st.viewAsRole = nil
            #expect(close(try st.number("[Chiffre d'affaires]"), 1_415_422))
        }

        @Test func rolesAndCalculationGroupsRoundTrip() throws {
            var group = DataTable(name: "Temps", columns: [DataColumn(name: "Calcul", type: .text)], rows: [[.text("Courant")]])
            group.calculationItems = [CalculationItem(name: "Courant", expression: "SELECTEDMEASURE()")]
            st.tables.append(group)
            st.roles = [SecurityRole(name: "Sud", filters: ["Régions": #"[Zone] = "Sud""#])]
            let url = Fixture.temp("Roles.pbit")
            try st.pbitData().data.write(to: url)
            let back = AppState()
            back.importPowerBI(url, askForFiles: false)
            #expect(back.roles.first?.filters["Régions"] == #"[Zone] = "Sud""#)
            #expect(back.table("Temps").calculationItems?.map(\.name) == ["Courant"])
            #expect(back.table("Temps").rows.first?.first == .text("Courant"))
        }
    }
}
