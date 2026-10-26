import Foundation
import XCTest

/*
 The golden CLI outputs under Tests/RunOSDesktopTests/Fixtures, loaded from the test bundle.

 The folder is a folder reference in the project, so it lands in the bundle as a directory and a new
 fixture file needs no project edit. The contract tests also check that every file in a family has
 an expectation, so a fixture nobody asserts on fails the suite instead of sitting there unused.
*/
enum Fixtures {
    private final class BundleToken {}

    static var root: URL {
        get throws {
            let bundle = Bundle(for: BundleToken.self)
            guard let url = bundle.url(forResource: "Fixtures", withExtension: nil) else {
                throw FixtureError.missingFolder
            }
            return url
        }
    }

    /// The file stems in one family, e.g. "vpn-status" -> ["normal-connected", ...], sorted.
    static func stems(in family: String) throws -> [String] {
        let folder = try root.appending(path: family, directoryHint: .isDirectory)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        return names.map { ($0 as NSString).deletingPathExtension }.sorted()
    }

    static func data(_ family: String, _ stem: String) throws -> Data {
        let folder = try root.appending(path: family, directoryHint: .isDirectory)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        guard let name = names.first(where: { ($0 as NSString).deletingPathExtension == stem }) else {
            throw FixtureError.missingFile("\(family)/\(stem)")
        }
        return try Data(contentsOf: folder.appending(path: name))
    }

    static func text(_ family: String, _ stem: String) throws -> String {
        String(decoding: try data(family, stem), as: UTF8.self)
    }

    enum FixtureError: Error, CustomStringConvertible {
        case missingFolder
        case missingFile(String)

        var description: String {
            switch self {
            case .missingFolder: return "The Fixtures folder is not in the test bundle. Add it to the test target's Resources."
            case .missingFile(let name): return "No fixture named \(name)."
            }
        }
    }
}
