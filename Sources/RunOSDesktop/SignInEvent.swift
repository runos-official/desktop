import Foundation

/*
 One line of `runos login --json` / `runos vpn up --json`, read as an event.

 Why a window needs these at all: the CLI's browser device-code flow has two facts a person must
 have, and until now both were prose on stdout that the app never showed. The DEVICE ID is what they
 compare against the page in the browser, which is the whole anti-spoofing property of the flow: a
 code that does not match means the page is not the one the CLI opened. The URL is the only way in
 when the browser does not open at all, which is routine on a locked-down machine. Clicking Sign In
 gave a spinner and neither.

 Parsing is separate from the window so both are testable without the other, and unknown lines are
 IGNORED rather than treated as failures: the CLI may add an event this build has never heard of,
 and a sign-in must not break because of one.
*/
enum SignInEvent: Equatable {
    /// Fires once. `id` is what the person checks against the browser.
    case deviceCode(id: String, url: String, browserOpened: Bool)
    /// The browser has not authorised yet. Expected, repeatedly, and not a problem.
    case pending
    /// The browser authorised. The CLI is now exchanging the token.
    case authorized
    /// `reason` is for branching, `message` is the sentence for a person.
    case failed(reason: String, message: String)

    /// Returns nil for anything this build does not recognise, including non-JSON noise.
    static func parse(_ line: String) -> SignInEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        switch object["event"] as? String {
        case "device_code":
            guard let id = (object["deviceId"] as? String)?.trimmingCharacters(in: .whitespaces),
                  let url = (object["url"] as? String)?.trimmingCharacters(in: .whitespaces),
                  !id.isEmpty, !url.isEmpty
            else { return nil }
            // Absent reads as "did not open", which is the safe way round: it makes the app show
            // the URL prominently rather than assume a browser the person cannot see.
            return .deviceCode(id: id, url: url, browserOpened: object["browserOpened"] as? Bool ?? false)
        case "pending":
            return .pending
        case "authorized":
            return .authorized
        case "error":
            let reason = (object["reason"] as? String) ?? "failed"
            let message = (object["message"] as? String) ?? "Sign in failed."
            return .failed(reason: reason, message: message)
        default:
            return nil
        }
    }
}
