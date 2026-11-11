import Foundation
import Testing
@testable import Prisme

extension PrismeTests {
    /// Older .pbit files (2019 era): queries in the DataMashup package, parameters, page elements.
    @Suite struct PBITLegacyTests {
        static let section = #"""
        section Section1;

        [ Description = "Folder of the data" ]
        shared #"@Folder" = "FOLDER" meta [IsParameterQuery=true, Type="Text", IsParameterQueryRequired=true];

        shared Missing = null meta [IsParameterQuery=true, Type="Text"];

        // A helper query holding the source; tables refer to it.
        shared RawSales = let
            Source = Csv.Document(File.Contents(#"@Folder" & "/ventes.csv"), [Delimiter=";", Encoding=65001]),
            /* "quoted ; in a comment" */
            Promoted = Table.PromoteHeaders(Source)
        in
            Promoted;

        shared Ventes = let
            Source = RawSales,
            Typed = Table.TransformColumnTypes(Source, {{"Montant", Int64.Type}})
        in
            Typed;

        shared Cloud = let Source = Cds.Contents("https://x.crm.dynamics.com") in Source;
        """#

        @Test func readsSectionMembers() {
            let q = PowerBIImporter.sectionMembers(Self.section)
            #expect(Set(q.keys) == ["@Folder", "Missing", "RawSales", "Ventes", "Cloud"])
            #expect(q["Ventes"]?.hasSuffix("Typed") == true)
            #expect(MSource.parameterValue(q["@Folder"]!) == "FOLDER")
            #expect(MSource.parameterValue(q["Missing"]!) == nil)
            #expect(MSource.connector(q["Cloud"]!) == "Dataverse (Cds.Contents)")
        }

        @Test func followsHelperQueriesAndParameters() {
            var q = PowerBIImporter.sectionMembers(Self.section)
            q["@Folder"] = #""/data" meta [IsParameterQuery=true]"#
            let m = MSource.effective(q["Ventes"]!, queries: q, params: MSource.parameters(q))
            #expect(m.contains(#"File.Contents("/data/ventes.csv")"#))
        }

        @Test func importsALegacyTemplate() throws {
            let folder = Fixture.url("")
            let section = Self.section.replacingOccurrences(of: "\"FOLDER\"", with: "\"\(folder.path)\"")
            // DataMashup: [version][size][OPC package with Formulas/Section1.m]
            var pkg = ZipWriter()
            pkg.add("Formulas/Section1.m", Data(section.utf8))
            let zip = pkg.finish()
            var mashup = Data([0, 0, 0, 0])
            mashup += withUnsafeBytes(of: UInt32(zip.count).littleEndian) { Data($0) }
            mashup += zip
            let schema: [String: Any] = ["model": ["tables": [
                ["name": "Ventes", "columns": [["name": "Région", "dataType": "string", "sourceColumn": "Région"],
                                               ["name": "Montant", "dataType": "int64", "sourceColumn": "Montant"]],
                 "partitions": [["name": "Ventes-1", "source": ["type": "query", "query": "SELECT * FROM [Ventes]"]]],
                 "measures": [["name": "Total", "expression": "SUM(Ventes[Montant])"]]],
                ["name": "@Folder", "columns": [["name": "@Folder", "dataType": "string"]],
                 "partitions": [["name": "p", "source": ["type": "query", "query": "SELECT * FROM [@Folder]"]]]],
                ["name": "Cloud", "columns": [["name": "Id", "dataType": "string"]],
                 "partitions": [["name": "p", "source": ["type": "query", "query": "SELECT * FROM [Cloud]"]]]],
            ]]]
            func config(_ type: String, _ objects: String) -> String {
                #"{"name":"x","singleVisual":{"visualType":""# + type + #"","objects":"# + objects + "}}"
            }
            let layout: [String: Any] = ["sections": [["displayName": "Page 1", "width": 1280, "height": 720, "visualContainers": [
                ["x": 10, "y": 10, "width": 300, "height": 40, "config": config("textbox",
                    ##"{"general":[{"properties":{"paragraphs":[{"textRuns":[{"value":"Hello","textStyle":{"fontSize":"16px","color":"#ffffff","fontWeight":"bold"}}]}]}}]}"##)],
                ["x": 10, "y": 60, "width": 300, "height": 100, "config": config("basicShape",
                    #"{"general":[{"properties":{"shapeType":{"expr":{"Literal":{"Value":"'oval'"}}}}}],"fill":[{"properties":{"fillColor":{"solid":{"color":{"expr":{"Literal":{"Value":"'#3B79B7'"}}}}}}}]}"#)],
                ["x": 10, "y": 170, "width": 100, "height": 30, "config": config("actionButton",
                    #"{"text":[{"properties":{"show":{"expr":{"Literal":{"Value":"true"}}},"text":{"expr":{"Literal":{"Value":"'Go'"}}}}}]}"#)],
            ]]]]
            func utf16(_ o: Any) throws -> Data {
                PBITExporter.utf16(String(decoding: try JSONSerialization.data(withJSONObject: o), as: UTF8.self))
            }
            var z = ZipWriter()
            z.add("DataMashup", mashup)
            z.add("DataModelSchema", try utf16(schema))
            z.add("Report/Layout", try utf16(layout))
            let url = Fixture.temp("Legacy.pbit")
            try z.finish().write(to: url)

            Loc.language = .fr
            let st = AppState()
            st.importPowerBI(url, askForFiles: false)
            #expect(st.table("Ventes").rows.count == 4)
            let amounts = st.table("Ventes").rows.compactMap { $0[1].number }
            #expect(amounts.count == 4)
            #expect(close(try st.number("[Total]"), amounts.reduce(0, +)))
            #expect(st.table("@Folder").rows.first?.first == .text(folder.path))
            #expect(st.table("Cloud").rows.isEmpty)
            let message = st.alertMessage ?? ""
            #expect(message.contains("Dataverse (Cds.Contents)"), "\(message)")
            let visuals = st.pages.first?.visuals ?? []
            #expect(visuals.map(\.type) == [.text, .shape, .button])
            #expect(visuals.first?.element.text == "Hello")
            #expect(visuals.first?.element.bold == true)
            #expect(visuals.first?.element.textColor == "FFFFFF")
            #expect(visuals.dropFirst().first?.element.shape == .ellipse)
            #expect(visuals.dropFirst().first?.element.fill == "3B79B7")
            #expect(visuals.last?.element.text == "Go")
        }

        /// Newer templates: the report is stored in the PBIR folder format inside the .pbit.
        @Test func importsAPBIRTemplate() throws {
            func json(_ o: Any) throws -> Data { try JSONSerialization.data(withJSONObject: o) }
            let csv = Fixture.url("ventes.csv").path
            let schema: [String: Any] = ["model": ["tables": [
                ["name": "Ventes", "columns": [["name": "Région", "dataType": "string", "sourceColumn": "Région"]],
                 "partitions": [["name": "p", "source": ["type": "m", "expression":
                    "let Source = Csv.Document(File.Contents(\"\(csv)\"), [Delimiter=\";\"]), P = Table.PromoteHeaders(Source) in P"]]]],
            ]]]
            let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
            let image: [String: Any] = ["position": ["x": 0, "y": 0, "width": 100, "height": 50], "visual": ["visualType": "image",
                "objects": ["general": [["properties": ["imageUrl": ["expr": ["ResourcePackageItem":
                    ["PackageName": "RegisteredResources", "PackageType": 1, "ItemName": "logo123.png"]]]]]]]]]
            let slicer: [String: Any] = ["position": ["x": 0, "y": 60, "width": 200, "height": 40], "visual": ["visualType": "textSlicer",
                "query": ["queryState": ["Values": ["projections": [["field": ["Column": ["Expression": ["SourceRef": ["Entity": "Ventes"]],
                                                                                           "Property": "Région"]]]]]]]]]
            var z = ZipWriter()
            z.add("DataModelSchema", PBITExporter.utf16(String(decoding: try json(schema), as: UTF8.self)))
            z.add("Report/definition/pages/pages.json", try json(["pageOrder": ["p1"]]))
            z.add("Report/definition/pages/p1/page.json", try json(["displayName": "Accueil", "width": 1280, "height": 720]))
            z.add("Report/definition/pages/p1/visuals/a/visual.json", try json(image))
            z.add("Report/definition/pages/p1/visuals/b/visual.json", try json(slicer))
            z.add("Report/StaticResources/RegisteredResources/logo123.png", png)
            let url = Fixture.temp("PBIR.pbit")
            try z.finish().write(to: url)

            Loc.language = .fr
            let st = AppState()
            st.importPowerBI(url, askForFiles: false)
            #expect(st.pages.map(\.name) == ["Accueil"])
            let visuals = st.pages.first?.visuals ?? []
            #expect(visuals.map(\.type) == [.image, .slicer])
            #expect(visuals.first?.element.imageData == png)
            #expect(visuals.last?.axis.first?.column == "Région")
            #expect(st.table("Ventes").rows.count == 4)
        }
    }
}
