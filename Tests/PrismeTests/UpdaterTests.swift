import CryptoKit
import Foundation
import Testing
@testable import Prisme

extension PrismeTests {
    @Suite struct UpdaterTests {
        @Test func comparesVersions() {
            #expect(Updater.isNewer("v1.1", than: "1.0.2"))
            #expect(Updater.isNewer("1.0.10", than: "1.0.9"))
            #expect(!Updater.isNewer("1.0", than: "1.0.0"))
            #expect(!Updater.isNewer("v0.9", than: "1.0"))
        }

        @Test func readsTheLatestRelease() throws {
            let json = #"""
            {"tag_name": "v1.1", "draft": false, "prerelease": false, "body": "Notes", "html_url": "https://github.com/RoBuys/Prisme/releases/tag/v1.1",
             "assets": [{"name": "Other.txt", "browser_download_url": "https://example.com/x"},
                        {"name": "Prisme-1.1-macOS.zip", "size": 123, "digest": "sha256:abc",
                         "browser_download_url": "https://github.com/RoBuys/Prisme/releases/download/v1.1/Prisme-1.1-macOS.zip"}]}
            """#
            let r = try #require(Updater.parseRelease(Data(json.utf8)))
            #expect(r.version == "1.1" && r.assetURL.lastPathComponent == "Prisme-1.1-macOS.zip" && r.digest == "sha256:abc")
            #expect(Updater.parseRelease(Data(json.replacingOccurrences(of: "\"prerelease\": false", with: "\"prerelease\": true").utf8)) == nil)
            #expect(Updater.parseRelease(Data(json.replacingOccurrences(of: "https://github.com/RoBuys/Prisme/releases/download", with: "http://github.com/x").utf8)) == nil)
        }

        @Test func checksDigests() throws {
            let data = Data("prisme".utf8)
            let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            try Updater.verifyDigest(data, "sha256:" + hex)
            try Updater.verifyDigest(data, nil)
            #expect(throws: (any Error).self) { try Updater.verifyDigest(data, "sha256:" + String(repeating: "0", count: 64)) }
        }

        /// A fake Prisme.app with the given version.
        static func fakeApp(in dir: URL, version: String, id: String = "local.prisme", marker: String) throws -> URL {
            let app = dir.appendingPathComponent("Prisme.app")
            try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            try (["CFBundleIdentifier": id, "CFBundleShortVersionString": version] as NSDictionary)
                .write(to: app.appendingPathComponent("Contents/Info.plist"))
            try marker.write(to: app.appendingPathComponent("Contents/marker.txt"), atomically: true, encoding: .utf8)
            return app
        }

        static func zip(_ app: URL, to zip: URL) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-c", "-k", "--keepParent", app.path, zip.path]
            try p.run(); p.waitUntilExit()
        }

        @Test func unpacksVerifiesAndSwaps() throws {
            let root = Fixture.temp("update")
            let build = root.appendingPathComponent("build"), installed = root.appendingPathComponent("Applications"), dl = root.appendingPathComponent("dl")
            for d in [build, installed, dl] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
            let newApp = try Self.fakeApp(in: build, version: "1.1", marker: "new")
            let zip = dl.appendingPathComponent("Prisme-1.1-macOS.zip")
            try Self.zip(newApp, to: zip)
            let release = Updater.Release(version: "1.1", tag: "v1.1", notes: "", assetURL: URL(string: "https://x/Prisme-1.1-macOS.zip")!,
                                          assetSize: 0, digest: nil, page: nil)
            let unpacked = try Updater.unpackAndVerify(zip: zip, release: release)
            // Wrong version or identifier is refused.
            var wrong = release
            wrong.version = "1.2"
            #expect(throws: (any Error).self) { try Updater.unpackAndVerify(zip: zip, release: wrong) }

            // The script waits for the process to end, swaps the bundles and removes the old one.
            let current = try Self.fakeApp(in: installed, version: "1.0.2", marker: "old")
            let sleeper = Process()
            sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
            sleeper.arguments = ["0.5"]
            try sleeper.run()
            let script = root.appendingPathComponent("install.sh")
            try Updater.swapScript(pid: sleeper.processIdentifier, current: current, new: unpacked, relaunch: false, trash: false)
                .write(to: script, atomically: true, encoding: .utf8)
            let sh = Process()
            sh.executableURL = URL(fileURLWithPath: "/bin/sh")
            sh.arguments = [script.path]
            try sh.run(); sh.waitUntilExit()
            #expect(sh.terminationStatus == 0)
            #expect(try String(contentsOf: current.appendingPathComponent("Contents/marker.txt"), encoding: .utf8) == "new")
            let left = try FileManager.default.contentsOfDirectory(atPath: installed.path)
            #expect(left == ["Prisme.app"])
        }
    }
}
