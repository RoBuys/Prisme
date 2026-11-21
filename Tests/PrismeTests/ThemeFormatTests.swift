import Foundation
import Testing
@testable import Prisme

extension PrismeTests {
    /// Imported report theme colors and chart formatting.
    @Suite struct ThemeFormatTests {
        static func lit(_ v: String) -> [String: Any] { ["expr": ["Literal": ["Value": v]]] }

        @Test func readsChartFormatting() throws {
            let objects: [String: Any] = [
                "dataPoint": [["properties": ["fill": ["solid": ["color": Self.lit("'#415663'")]]]]],
                "labels": [["properties": ["show": Self.lit("true")]]],
                "legend": [["properties": ["show": Self.lit("false")]]],
                "valueAxis": [["properties": ["showAxisTitle": Self.lit("true"), "gridlineShow": Self.lit("false")]]],
            ]
            let f = try #require(PowerBIImporter.visualFormat(objects))
            #expect(f.color == "415663" && f.dataLabels && !f.showLegend && f.axisTitles && !f.gridlines)
            #expect(PowerBIImporter.visualFormat([:]) == nil)
        }

        @Test func readsThemeColors() throws {
            let report = Fixture.temp("Report")
            let res = report.appendingPathComponent("StaticResources/RegisteredResources")
            try FileManager.default.createDirectory(at: res, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: report.appendingPathComponent("definition"), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["themeCollection": ["customTheme": ["name": "Mon.json"]]])
                .write(to: report.appendingPathComponent("definition/report.json"))
            try JSONSerialization.data(withJSONObject: ["name": "Mon", "dataColors": ["#2B465B", "#0098FF"]])
                .write(to: res.appendingPathComponent("Mon.json"))
            #expect(PowerBIImporter.themeColors(report) == [0x2B465B, 0x0098FF])
            AppState.shared.customColors = [0x2B465B, 0x0098FF]
            AppState.shared.theme = "custom"
            defer { AppState.shared.customColors = []; AppState.shared.theme = Theme.defaultName }
            #expect(Theme.all.last?.id == "custom")
            #expect(Theme.palette.count == 2)
        }
    }
}
