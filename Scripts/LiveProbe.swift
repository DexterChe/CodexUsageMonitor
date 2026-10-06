import Foundation

/// Read-only smoke test. Prints only schema/window availability; never prints raw RPC data.
@main
struct LiveProbe {
    static func main() async {
        guard CommandLine.arguments.count == 2 else {
            print("Usage: CodexUsageProbe /absolute/path/to/codex")
            exit(2)
        }
        let rpc = CodexRPCClient()
        do {
            try await rpc.connect(executable: URL(fileURLWithPath: CommandLine.arguments[1]))
            let data = try await rpc.readRateLimits()
            let buckets = try RateLimitParser.buckets(from: data)
            let selected = RateLimitParser.select(buckets, preferredID: "codex")
            print("rateLimits/read: OK; buckets=\(buckets.count); fiveHour=\(selected?.fiveHour != nil); weekly=\(selected?.weekly != nil)")
            let usage = try await rpc.readUsage()
            let summary = try JSONDecoder().decode(TokenUsageResponse.self, from: usage).summary
            print("usage/read: OK; token summary available=\(summary.lifetimeTokens != nil)")
            await rpc.stop()
        } catch {
            // Error descriptions from the CLI can contain private data, so never print them.
            print("Live probe failed; check official CLI login and compatibility.")
            await rpc.stop()
            exit(1)
        }
    }
}
