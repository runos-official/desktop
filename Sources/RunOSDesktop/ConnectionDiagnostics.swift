import Foundation

/*
 The Connection Status window's test plan and parsing, kept pure so every verdict is testable
 without spawning a process. The runner spawns /sbin/ping, /usr/bin/dscacheutil and the RunOS
 CLI; these functions decide what their output MEANS.
 */
enum ConnectionDiagnostics {
    struct PingVerdict: Equatable {
        let reachable: Bool
        /// "1.2 ms" when the output carried a round-trip line.
        let detail: String
    }

    static func pingVerdict(exitCode: Int32, output: String) -> PingVerdict {
        guard exitCode == 0 else {
            return PingVerdict(reachable: false, detail: "no reply")
        }
        // "round-trip min/avg/max/stddev = 1.177/1.377/1.577/nan ms" — the average is the number
        // a person compares between nodes.
        if let range = output.range(of: "round-trip"),
           let equals = output.range(of: "= ", range: range.lowerBound..<output.endIndex) {
            let numbers = output[equals.upperBound...]
                .split(separator: " ")[0]
                .split(separator: "/")
            if numbers.count >= 2 {
                return PingVerdict(reachable: true, detail: "\(numbers[1]) ms")
            }
        }
        return PingVerdict(reachable: true, detail: "reachable")
    }

    /// The addresses dscacheutil resolved, in order. Empty means the name did not resolve.
    static func resolvedAddresses(_ output: String) -> [String] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "ip_address" else {
                return nil
            }
            return parts[1].trimmingCharacters(in: .whitespaces)
        }
    }

    /// Whether a resolved address is private (RFC1918), which is what "over the VPN" means here.
    static func isPrivateIPv4(_ address: String) -> Bool {
        let octets = address.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return false }
        if octets[0] == 10 { return true }
        if octets[0] == 172, (16...31).contains(octets[1]) { return true }
        if octets[0] == 192, octets[1] == 168 { return true }
        return false
    }
}

/// One node as the diagnostics need it, decoded from `runos nodes list --cid <cid> -j`.
struct DiagnosticsNode: Decodable, Equatable, Sendable {
    let name: String?
    let hostname: String?
    let vpnIp: String?

    var label: String {
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return hostname ?? "node"
    }
}

struct DiagnosticsNodeList: Decodable, Sendable {
    let nodes: [DiagnosticsNode]
}
