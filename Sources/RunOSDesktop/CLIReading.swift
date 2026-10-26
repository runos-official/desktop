import Foundation

/*
 Reading what the CLI printed, and saying so plainly when it cannot be read.

 WHY THIS EXISTS (FCR 1730). `runos vpn status --json` once sent `"clusters": null`. The app
 decoded with `try?`, so the whole decode failed, the VPN status became nil, and the menu lost its
 cluster rows, the Connect entry and the Restart VPN item with no word about it anywhere. A bare
 menu is the worst answer to "I cannot read this": the person sees a working app that does nothing.

 Every place the app decodes CLI output goes through `CLIReading.decode`, so a failure always comes
 back as a `ReadFailure` with a headline ("Cannot read the VPN status") and a reason line, and the
 caller has to do something with it. The reason is written for a person; Foundation's own text for
 a decode error ("The data couldn't be read because it is missing.") names neither the command nor
 the field.
*/
struct ReadFailure: Error, Equatable, Sendable {
    /// What could not be read, as one sentence for a menu line: "Cannot read the VPN status".
    let headline: String
    /// Why, in plain words: the field that is missing, or what the CLI printed instead of JSON.
    let reason: String

    /// Both parts as one sentence, for a place that has a single line to put it in.
    var summary: String { "\(headline): \(reason)" }
}

extension ReadFailure: LocalizedError {
    var errorDescription: String? { summary }
}

enum CLIReading {
    /*
     Decode `type` from the CLI's stdout, or say why not.

     STRICT FIRST, THEN LENIENT. A CLI that prints a notice line before its JSON (an update banner on
     stdout is something released CLIs have done) is still answering, and refusing the whole answer
     over a banner would be the bare menu again. The fallback decodes the outermost `{...}` and is
     tried only after the strict read fails, so a clean answer is never reinterpreted. If both
     fail, the STRICT failure is the one reported: it describes the output as it is.
    */
    static func decode<T: Decodable>(_ type: T.Type, from data: Data, what: String) -> Result<T, ReadFailure> {
        let decoder = JSONDecoder.runOS
        do {
            return .success(try decoder.decode(type, from: data))
        } catch {
            if let object = outermostObject(in: data),
               let value = try? decoder.decode(type, from: object) {
                return .success(value)
            }
            return .failure(ReadFailure(headline: "Cannot read \(what)", reason: reason(for: error, data: data)))
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, from result: CLIResult, what: String) -> Result<T, ReadFailure> {
        decode(type, from: result.stdout, what: what)
    }

    /// The bytes from the first `{` to the last `}`, when there are both and they are not the whole input.
    private static func outermostObject(in data: Data) -> Data? {
        guard let first = data.firstIndex(of: UInt8(ascii: "{")),
              let last = data.lastIndex(of: UInt8(ascii: "}")),
              first < last else { return nil }
        let slice = data[first...last]
        return slice.count == data.count ? nil : Data(slice)
    }

    /*
     One plain sentence for why a decode failed.

     The CLI's own words are used wherever it printed something that is not JSON, because those are
     the words that name the real problem ("command not found", a banner, an HTML error page).
    */
    static func reason(for error: Error, data: Data) -> String {
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "RunOS printed nothing." }
        guard let failure = error as? DecodingError else {
            return error.localizedDescription
        }
        switch failure {
        case .keyNotFound(let key, _):
            return "the field \"\(key.stringValue)\" is missing."
        case .valueNotFound(_, let context):
            if context.codingPath.isEmpty { return wrongKind }
            return "the field \"\(path(context.codingPath))\" is empty but is needed."
        case .typeMismatch(_, let context):
            if context.codingPath.isEmpty { return wrongKind }
            return "the field \"\(path(context.codingPath))\" has an unexpected type."
        case .dataCorrupted(let context):
            if !context.codingPath.isEmpty {
                return "the field \"\(path(context.codingPath))\" holds a value that cannot be read."
            }
            return notJSONReason(text: text, context: context)
        @unknown default:
            return "the output has an unexpected shape."
        }
    }

    private static let wrongKind = "RunOS printed JSON of the wrong kind."

    private static func path(_ codingPath: [CodingKey]) -> String {
        let parts = codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }
        return parts.isEmpty ? "(top level)" : parts.joined(separator: ".").replacingOccurrences(of: ".[", with: "[")
    }

    private static func notJSONReason(text: String, context: DecodingError.Context) -> String {
        let detail = (context.underlyingError as NSError?)?.userInfo[NSDebugDescriptionErrorKey] as? String ?? ""
        if text.hasPrefix("{") || text.hasPrefix("["), detail.localizedCaseInsensitiveContains("end of file")
            || detail.localizedCaseInsensitiveContains("unterminated") || detail.localizedCaseInsensitiveContains("premature") {
            return "the output ends too early; it looks cut off."
        }
        if text.hasPrefix("{") || text.hasPrefix("[") {
            return "the output is not valid JSON."
        }
        // What the CLI printed instead, in its own words, kept to one short line.
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let clipped = firstLine.count > 80 ? String(firstLine.prefix(79)) + "\u{2026}" : firstLine
        return "RunOS printed text instead of JSON: \(clipped)"
    }
}

/*
 Lenient reading of the fields the app only DISPLAYS.

 A field that decides what the menu does (`running`, `authenticated`, `connected`) is read strictly:
 a wrong type there is a CLI the app cannot work with, and `CLIReading` reports it. A field that is
 only shown (a version, an endpoint, a byte count) must never cost the person the whole menu, so a
 null, a missing key and a value of the wrong type all read as "not stated".
*/
extension KeyedDecodingContainer {
    /// nil when the key is absent, null, or holds a value of another type.
    func lossy<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }

    /// An integer that may arrive as a number or as a numeric string. nil for anything else.
    func lossyInt64(forKey key: Key) -> Int64? {
        if let number = lossy(Int64.self, forKey: key) { return number }
        if let text = lossy(String.self, forKey: key) { return Int64(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    func lossyInt(forKey key: Key) -> Int? {
        lossyInt64(forKey: key).flatMap { Int(exactly: $0) }
    }

    /// A list where null and a missing key both mean empty. A value that is not a list still throws.
    func list<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> [T] {
        try decodeIfPresent([T].self, forKey: key) ?? []
    }

    /// A flag where null and a missing key both mean `fallback`. A value that is not a flag still throws.
    func flag(forKey key: Key, fallback: Bool = false) throws -> Bool {
        try decodeIfPresent(Bool.self, forKey: key) ?? fallback
    }
}

/*
 The one place a CLI timestamp becomes a Date.

 Foundation's `.iso8601` strategy takes fractional seconds on some macOS releases and refuses them on
 others, so the same status line decoded on a newer Mac and failed on an older one. This parser splits the
 fraction off itself and adds it back, so a whole-second time, a fraction of any length and a UTC offset
 read the same on every macOS the app runs on. A string that is not a time returns nil.
 */
enum ContractDate {
    static func parse(_ text: String) -> Date? {
        var base = text
        var fraction = 0.0
        if let dot = text.firstIndex(of: ".") {
            var end = text.index(after: dot)
            while end < text.endIndex, text[end].isASCII, text[end].isNumber { end = text.index(after: end) }
            let digits = text[text.index(after: dot)..<end]
            guard !digits.isEmpty, let value = Double("0." + digits) else { return nil }
            fraction = value
            base = String(text[text.startIndex..<dot]) + String(text[end...])
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: base) else { return nil }
        return date.addingTimeInterval(fraction)
    }
}
