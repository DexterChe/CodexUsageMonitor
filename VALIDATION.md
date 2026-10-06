# Validation: version 0.1.4

Checked 2026-10-05 on arm64 macOS 27.0.1, Xcode 27.0, Swift 6.4 and official Codex CLI 0.160.0. No account values or credentials are included here.

| Check | Result |
|---|---|
| Swift Package tests | 29 passed, 0 failures |
| Xcode Debug build-for-testing | Passed |
| Native Xcode XCTest bundle, direct xcrun xctest | 33 passed, 0 failures |
| Xcode Release app + WidgetKit extension | Passed |
| Local ad-hoc deep/strict signature verification | Passed |
| Installed version | 0.1.4 |
| Installed widget registration | Bundle identified as version 0.1.4 |
| Live account/rateLimits/read | Passed; both five-hour and weekly windows available |
| Live account/usage/read | Passed; token summary decoded |
| Installed application --self-check | Quotas, local store and snapshot round trip passed |
| Snapshot permissions | Directory 0700, file 0600 |
| Signed widget entitlements | Sandbox plus exact read-only snapshot; no network entitlement |
| Static privacy guardrails | Passed |
| Publication source inventory scan | No private paths/identities or credential patterns found |
| Automatic polling | Four consecutive successful updates: 65.15, 67.84, 65.20, 65.20 seconds without clicks |
| Idle CPU observation | 303 seconds: monitor average 0.069% of one CPU core, final RSS 36.42 MiB |
| Code warnings | 0 compiler/linker/Swift-concurrency warnings attributable to project code in final builds |
| Synthetic visual review | 30 SwiftUI renders across light/dark, menu/small/medium and normal/stale/error/empty/extremes |
| Menu geometry | Tests passed for placement below bar and inside two display coordinate systems |

The owner accepted the compact menu-bar appearance and confirmed that the 0.1.4 Notification Center widget visibly shows percentages and update time. A previous empty-sidebar report was traced to launchd retaining a Debug extension path. The final installer cleaned development registration and restarted the current user's widget host using its explicit option. The installed app's self-check found both windows and a valid widget snapshot.

A previous automated xcodebuild test orchestration stalled during runner preparation. The final Xcode test bundle was built successfully and all 33 tests were run directly through xcrun xctest; the stalled orchestrator is not counted as a passing run. Xcode also printed CoreSimulator service diagnostics unrelated to the macOS target.

## Limits of this evidence

- Synthetic transport tests use a local Python fixture, not credentials or network calls.
- Live checks verify the two read methods and normalized local storage; they are not a packet capture of the official CLI.
- CPU figures are short idle observations from CPU-time deltas, not an energy benchmark or a guarantee under every UI interaction. System-wide `codex` processes include unrelated Codex app/agent processes; name-based counts cannot be attributed to this monitor. The observed release candidate preceded a final parser-only adjustment rejecting out-of-range percentages; the final installed build passed self-check but has not had a second five-minute observation.
- WidgetKit controls visible refresh timing. Minute-level polling is not a guaranteed minute-level widget redraw.
- macOS 14–26, alternate CLI installations, real sleep/wake, login-item behavior, multiple actual monitors, all themes/locales and binary distribution have not been fully tested.
- Ad-hoc signing is for local use. Developer ID, notarization, Gatekeeper on another machine and App Store review remain outside this delivery.
- GitHub CI is prepared but has not run remotely. GitHub publication requires owner approval.
