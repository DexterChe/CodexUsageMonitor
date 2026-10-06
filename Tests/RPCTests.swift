import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import CodexUsageCore
#endif

final class RPCTests: XCTestCase {
    private var fixture: URL {
        #if SWIFT_PACKAGE
        return Bundle.module.url(forResource: "mock_server", withExtension: "py", subdirectory: "Fixtures")!
        #else
        return Bundle(for: Self.self).url(forResource: "mock_server", withExtension: "py", subdirectory: "Fixtures")!
        #endif
    }

    func client(_ mode: String = "normal", timeout: Double = 2) async throws -> CodexRPCClient {
        let rpc = CodexRPCClient(timeoutSeconds: timeout)
        try await rpc.connect(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [fixture.path, mode])
        return rpc
    }

    func testHandshakeFragmentedResponsesAndServerTokenRequestRejection() async throws {
        let rpc = try await client()
        let limits = try await rpc.readRateLimits()
        XCTAssertEqual(try RateLimitParser.buckets(from: limits)[0].fiveHour?.remainingPercent, 68)
        let usage = try await rpc.readUsage()
        XCTAssertEqual(try JSONDecoder().decode(TokenUsageResponse.self, from: usage).summary.lifetimeTokens, 123)
        await rpc.stop()
    }

    func testDisallowedMethodNeverSent() async throws {
        let rpc = try await client()
        do { _ = try await rpc.request("account/login/start"); XCTFail("Must reject") }
        catch { XCTAssertEqual(error as? RPCError, .unsupportedMethod) }
        await rpc.stop()
    }

    func testUnsupportedUsageAndAuthErrors() async throws {
        let rpc = try await client("unsupported")
        _ = try await rpc.readRateLimits()
        do { _ = try await rpc.readUsage(); XCTFail("Must reject") }
        catch { XCTAssertEqual(error as? RPCError, .server(code: -32601, category: .unsupported)) }
        await rpc.stop()
        let auth = try await client("auth")
        do { _ = try await auth.readRateLimits(); XCTFail("Must require login") }
        catch { XCTAssertEqual(error as? RPCError, .server(code: -32600, category: .authentication)) }
        await auth.stop()
    }

    func testTimeoutAndReconnect() async throws {
        let rpc = try await client("timeout", timeout: 1)
        do { _ = try await rpc.readRateLimits(); XCTFail("Must timeout") }
        catch { XCTAssertEqual(error as? RPCError, .timeout) }
        await rpc.stop()
        try await rpc.connect(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [fixture.path, "normal"])
        _ = try await rpc.readRateLimits()
        await rpc.stop()
    }

    func testExitAndMalformedMessagesFailPromptly() async throws {
        for mode in ["exit", "malformed"] {
            let rpc = try await client(mode)
            do { _ = try await rpc.readRateLimits(); XCTFail("Must fail") }
            catch { XCTAssertEqual(error as? RPCError, .disconnected) }
            await rpc.stop()
        }
    }

    func testCancellationReleasesPendingRequest() async throws {
        let rpc = try await client("timeout")
        let task = Task { try await rpc.readRateLimits() }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("Must cancel") } catch { }
        await rpc.stop()
    }

    func testPrivacyArgumentsDisableAllExporters() {
        for argument in ["analytics.enabled=false", "otel.exporter=\"none\"",
                         "otel.trace_exporter=\"none\"", "otel.metrics_exporter=\"none\""] {
            XCTAssertTrue(CodexRPCClient.privacyArguments.contains(argument))
        }
    }

    func testChildEnvironmentDoesNotForwardCredentialOrUnknownVariables() {
        let environment = CodexRPCClient.childEnvironment(from: [
            "PATH": "/usr/bin", "LANG": "en_US.UTF-8", "HOME": "/synthetic-wrong-home",
            "OPENAI_ACCESS_TOKEN": "synthetic-only", "OPENAI_REFRESH_TOKEN": "synthetic-only",
            "UNRECOGNIZED_SECRET": "synthetic-only", "CODEX_HOME": "/synthetic-codex-home"
        ], home: "/synthetic-home")
        XCTAssertEqual(environment["HOME"], "/synthetic-home")
        XCTAssertNil(environment["CODEX_HOME"])
        XCTAssertEqual(environment["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin")
        XCTAssertNil(environment["OPENAI_ACCESS_TOKEN"])
        XCTAssertNil(environment["OPENAI_REFRESH_TOKEN"])
        XCTAssertNil(environment["UNRECOGNIZED_SECRET"])
    }
    func testInvalidEnvelopeIDsAndOversizedOutputFailClosed() async throws {
        for mode in ["bool-id", "fraction-id", "array-result", "both-fields", "huge", "flood"] {
            let rpc = try await client(mode, timeout: 1)
            do { _ = try await rpc.readRateLimits(); XCTFail("Accepted malformed output: \(mode)") }
            catch { }
            await rpc.stop()
        }
    }

    func testStopWaitsForChildThatIgnoresTermination() async throws {
        let rpc = try await client("stubborn")
        let data = try await rpc.readRateLimits()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let pid = try XCTUnwrap(object["pid"] as? Int32)
        let started = Date()
        await rpc.stop()
        // CI hosts can delay task scheduling; the essential guarantee is bounded cleanup.
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertEqual(kill(pid, 0), -1, "Child still alive after stop returned")
        XCTAssertEqual(errno, ESRCH)
    }

    func testTimeoutClosesConnectionBeforeRetry() async throws {
        let rpc = try await client("timeout", timeout: 1)
        do { _ = try await rpc.readRateLimits(); XCTFail("Expected timeout") } catch { }
        await rpc.stop()
        do { _ = try await rpc.readRateLimits(); XCTFail("Connection must be closed") }
        catch { XCTAssertEqual(error as? RPCError, .disconnected) }
    }

}
