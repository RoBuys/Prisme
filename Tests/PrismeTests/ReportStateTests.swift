import Foundation
import Testing
@testable import Prisme

extension PrismeTests {
    /// Filters, slicer selections, hidden visuals and groups, bookmarks and button actions of Power BI reports.
    @Suite struct ReportStateTests {
        // MARK: Building test files

        static func column(_ e: String, _ p: String, source: String? = nil) -> [String: Any] {
            ["Column": ["Expression": ["SourceRef": source.map { ["Source": $0] } ?? ["Entity": e]], "Property": p]]
        }

        static func lit(_ v: String) -> [String: Any] { ["Literal": ["Value": v]] }

        static func filter(_ entity: String, _ condition: [String: Any]) -> [String: Any] {
            ["Version": 2, "From": [["Name": "x", "Entity": entity, "Type": 0]], "Where": [["Condition": condition]]]
        }

        static func inValues(_ e: String, _ p: String, _ values: [String]) -> [String: Any] {
            ["In": ["Expressions": [column(e, p, source: "x")], "Values": values.map { [lit($0)] }]]
        }

        static func entry(_ e: String, _ p: String, _ condition: [String: Any]?, type: String = "Categorical") -> [String: Any] {
            var d: [String: Any] = ["name": UUID().uuidString, "expression": column(e, p), "type": type]
            if let condition { d["filter"] = filter(e, condition) }
            return d
        }

        static func json(_ o: Any) -> String { String(decoding: try! JSONSerialization.data(withJSONObject: o), as: UTF8.self) }

        static func config(_ name: String, _ visual: [String: Any]?, group: [String: Any]? = nil, parent: String? = nil) -> String {
            var c: [String: Any] = ["name": name]
            if let visual { c["singleVisual"] = visual }
            if let group { c["singleVisualGroup"] = group }
            if let parent { c["parentGroupName"] = parent }
            return json(c)
        }

        static func link(_ type: String, _ key: String? = nil, _ target: String? = nil) -> [String: Any] {
            var p: [String: Any] = ["show": ["expr": lit("true")], "type": ["expr": lit("'\(type)'")]]
            if let key, let target { p[key] = ["expr": lit("'\(target)'")] }
            return ["visualLink": [["properties": p]]]
        }

        static func card(_ name: String, x: Double, parent: String? = nil, filters: [[String: Any]] = [], hidden: Bool = false) -> [String: Any] {
            var sv: [String: Any] = [
                "visualType": "card", "projections": ["Values": [["queryRef": "Ventes.Montant"]]],
                "prototypeQuery": ["Version": 2, "From": [["Name": "v", "Entity": "Ventes", "Type": 0]],
                                   "Select": [["Aggregation": ["Expression": column("Ventes", "Montant", source: "v"), "Function": 0],
                                               "Name": "Ventes.Montant"]]],
            ]
            if hidden { sv["display"] = ["mode": "hidden"] }
            return ["x": x, "y": 0, "width": 200, "height": 100, "config": config(name, sv, parent: parent), "filters": json(filters)]
        }

        /// The sample model exported as a .pbit, with `layout` as its report.
        static func template(layout: [String: Any]) throws -> URL {
            let st = Fixture.sample()
            let pbit = Fixture.temp("base.pbit")
            try st.pbitData().data.write(to: pbit)
            let dir = try PowerBIImporter.unzip(pbit)
            defer { try? FileManager.default.removeItem(at: dir) }
            var z = ZipWriter()
            for name in ["Version", "DataModelSchema", "Settings", "Metadata"] {
                z.add(name, try Data(contentsOf: dir.appendingPathComponent(name)))
            }
            z.add("Report/Layout", PBITExporter.utf16(json(layout)))
            let url = Fixture.temp("State.pbit")
            try z.finish().write(to: url)
            return url
        }

        static func imported(_ url: URL) -> AppState {
            Loc.language = .fr
            let st = AppState()
            st.importPowerBI(url, askForFiles: false)
            return st
        }

        // MARK: Tests

        @Test func importsFiltersVisibilityBookmarksAndActions() throws {
            let slicer: [String: Any] = [
                "visualType": "slicer", "projections": ["Values": [["queryRef": "Ventes.Canal"]]],
                "prototypeQuery": ["Version": 2, "From": [["Name": "v", "Entity": "Ventes", "Type": 0]],
                                   "Select": [Self.column("Ventes", "Canal", source: "v").merging(["Name": "Ventes.Canal"]) { a, _ in a }]],
                "objects": ["general": [["properties": ["filter": ["filter": Self.filter("Ventes", Self.inValues("Ventes", "Canal", ["'Magasin'"]))]]]]],
            ]
            let button: [String: Any] = ["visualType": "actionButton", "vcObjects": Self.link("Bookmark", "bookmark", "BM1")]
            let pageButton: [String: Any] = ["visualType": "actionButton", "vcObjects": Self.link("PageNavigation", "navigationSection", "S2")]
            let bookmark: [String: Any] = [
                "displayName": "Tout magasin", "name": "BM1",
                "explorationState": ["activeSection": "S1", "sections": ["S1": [
                    "filters": ["byExpr": [Self.entry("Ventes", "Canal", Self.inValues("Ventes", "Canal", ["'Magasin'"]))]],
                    "visualContainerGroups": ["G1": ["isHidden": false]],
                    "visualContainers": ["c1": ["singleVisual": ["display": ["mode": "hidden"]]]],
                ]]],
            ]
            let layout: [String: Any] = [
                "config": Self.json(["bookmarks": [["displayName": "Groupe", "children": [bookmark]]]]),
                "filters": Self.json([Self.entry("Ventes", "Canal", Self.inValues("Ventes", "Canal", ["'Magasin'", "'En ligne'"]))]),
                "sections": [
                    ["name": "S1", "displayName": "Une", "width": 1280, "height": 720,
                     "filters": Self.json([
                        Self.entry("Ventes", "Région", ["Not": ["Expression": Self.inValues("Ventes", "Région", ["'Grand Est'"])]]),
                        Self.entry("Ventes", "Montant", ["Comparison": ["ComparisonKind": 2, "Left": Self.column("Ventes", "Montant", source: "x"),
                                                                         "Right": Self.lit("100L")]], type: "Advanced"),
                        Self.entry("Ventes", "Produit", nil),
                     ]),
                     "visualContainers": [
                        Self.card("c1", x: 0, filters: [Self.entry("Ventes", "Canal", Self.inValues("Ventes", "Canal", ["'Magasin'"]))]),
                        ["x": 0, "y": 200, "width": 400, "height": 300, "config": Self.config("G1", nil, group: ["displayName": "Groupe", "isHidden": true])],
                        Self.card("c2", x: 300, parent: "G1"),
                        ["x": 600, "y": 0, "width": 200, "height": 300, "config": Self.config("s1", slicer)],
                        ["x": 900, "y": 0, "width": 120, "height": 40, "config": Self.config("b1", button)],
                        ["x": 900, "y": 60, "width": 120, "height": 40, "config": Self.config("b2", pageButton)],
                        ["x": 0, "y": 600, "width": 400, "height": 40, "config": Self.config("n1", ["visualType": "pageNavigator"])],
                     ]],
                    ["name": "S2", "displayName": "Deux", "width": 1280, "height": 720, "visualContainers": []],
                ],
            ]
            let st = Self.imported(try Self.template(layout: layout))
            #expect(st.reportFilters.count == 1)
            #expect(st.reportFilters[0].selected == ["Magasin", "En ligne"])
            let page = st.pages[0]
            let regions = Set(Engine.distinctValues(FieldRef(table: "Ventes", column: "Région"), st.tables))
            #expect(page.filters.count == 3)
            #expect(page.filters[0].selected == regions.subtracting(["Grand Est"]))           // Not In, computed on the data
            #expect(page.filters[1].lower == 100 && page.filters[1].upper == nil)            // >= 100
            #expect(!page.filters[2].isActive)                                               // field without a condition
            let c1 = try #require(page.visuals.first { $0.type == .card && $0.frame.minX == 0 })
            #expect(c1.filters?.first?.selected == ["Magasin"])
            let c2 = try #require(page.visuals.first { $0.type == .card && $0.frame.minX > 0 })
            #expect(c2.hidden == true)                                                       // its group is hidden
            #expect(page.visuals.first { $0.type == .slicer }?.slicerSelection == ["Magasin"])
            // Filters reach the queries (report, page, visual and slicer): store sales outside Grand Est, amount >= 100.
            let expected = try st.number(#"CALCULATE(SUM(Ventes[Montant]), Ventes[Canal] = "Magasin", Ventes[Région] <> "Grand Est", Ventes[Montant] >= 100)"#)
            let shown = try #require(st.filters(for: c1).isEmpty ? nil : Engine.cardValue(c1, st.model, st.filters(for: c1)))
            #expect(shown.value == Fmt.measure(expected, .auto, compact: true))
            // Bookmark (inside a group): page, filters, visibility; button actions.
            #expect(st.bookmarks.map(\.name) == ["Tout magasin"])
            let bm = st.bookmarks[0]
            #expect(bm.pageID == page.id)
            #expect(bm.visuals[c1.id]?.hidden == true && bm.visuals[c2.id] != nil && bm.visuals[c2.id]?.hidden == nil)
            let buttons = page.visuals.filter { $0.type == .button }
            #expect(buttons.contains { $0.element.action == .bookmark(bm.id) })
            #expect(buttons.contains { $0.element.action == .page(st.pages[1].id) })
            #expect(buttons.filter { $0.element.text == "Une" || $0.element.text == "Deux" }.count == 2)   // page navigator
            st.applyBookmark(bm.id)
            #expect(st.pages[0].visuals.first { $0.id == c1.id }?.hidden == true)
            #expect(st.pages[0].visuals.first { $0.id == c2.id }?.hidden == nil)
            #expect(st.pages[0].filters.map(\.selected) == [["Magasin"]])
        }

        @Test func readsPBIRFiltersAndBookmarks() throws {
            func json(_ o: Any) throws -> Data { try JSONSerialization.data(withJSONObject: o) }
            let base = try Self.template(layout: ["sections": []])
            let dir = try PowerBIImporter.unzip(base)
            defer { try? FileManager.default.removeItem(at: dir) }
            var z = ZipWriter()
            for name in ["Version", "DataModelSchema", "Settings", "Metadata"] { z.add(name, try Data(contentsOf: dir.appendingPathComponent(name))) }
            func pbirEntry(_ e: String, _ p: String, _ cond: [String: Any]) -> [String: Any] {
                ["name": UUID().uuidString, "field": Self.column(e, p), "type": "Categorical", "filter": Self.filter(e, cond)]
            }
            z.add("Report/definition/report.json", try json(["filterConfig": ["filters": [pbirEntry("Ventes", "Canal", Self.inValues("Ventes", "Canal", ["'Magasin'"]))]]]))
            z.add("Report/definition/pages/pages.json", try json(["pageOrder": ["p1"]]))
            z.add("Report/definition/pages/p1/page.json", try json(["name": "p1", "displayName": "Accueil", "width": 1280, "height": 720,
                "filterConfig": ["filters": [pbirEntry("Ventes", "Région", Self.inValues("Ventes", "Région", ["'Grand Est'"]))]]]))
            z.add("Report/definition/pages/p1/visuals/g/visual.json", try json(["name": "g", "visualGroup": ["displayName": "G"], "isHidden": true]))
            z.add("Report/definition/pages/p1/visuals/a/visual.json", try json(["name": "a", "parentGroupName": "g",
                "position": ["x": 0, "y": 0, "width": 200, "height": 100], "visual": ["visualType": "textbox"]]))
            z.add("Report/definition/bookmarks/bookmarks.json", try json(["items": [["name": "B1"]]]))
            z.add("Report/definition/bookmarks/B1.bookmark.json", try json(["name": "B1", "displayName": "Montrer",
                "options": ["suppressData": true],
                "explorationState": ["activeSection": "p1", "sections": ["p1": ["visualContainerGroups": ["g": ["isHidden": false]]]]]]))
            let url = Fixture.temp("PBIRState.pbit")
            try z.finish().write(to: url)
            let st = Self.imported(url)
            #expect(st.reportFilters.first?.selected == ["Magasin"])
            #expect(st.pages[0].filters.first?.selected == ["Grand Est"])
            let text = try #require(st.pages[0].visuals.first)
            #expect(text.hidden == true)
            let bm = try #require(st.bookmarks.first)
            #expect(bm.name == "Montrer" && bm.applyData == false)
            st.applyBookmark(bm.id)
            #expect(st.pages[0].visuals[0].hidden == nil)
            #expect(st.pages[0].filters.first?.selected == ["Grand Est"])   // suppressData: filters unchanged
        }

        @Test func relativeAndLiteralValues() {
            #expect(PBIFilters.literal(Self.lit("'O''Neil'")) == .text("O'Neil"))
            #expect(PBIFilters.literal(Self.lit("12L")) == .number(12))
            #expect(PBIFilters.literal(Self.lit("2.5D")) == .number(2.5))
            #expect(PBIFilters.literal(Self.lit("null")) == .empty)
            #expect(PBIFilters.literal(Self.lit("datetime'2024-03-01T00:00:00'"))?.date.map { Fmt.day($0) } == Fmt.day(Date(timeIntervalSince1970: 1_709_251_200)))
            let span: [String: Any] = ["DateSpan": ["Expression": ["DateAdd": ["Expression": ["Now": [:] as [String: Any]], "Amount": -3, "TimeUnit": 2]], "TimeUnit": 0]]
            let d = PBIFilters.dateExpression(span)
            let expected = Fmt.calendar.startOfDay(for: Fmt.calendar.date(byAdding: .month, value: -3, to: Date())!)
            #expect(d == expected)
        }
    }
}
