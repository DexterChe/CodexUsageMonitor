# Security and publication audit

Date: 2026-10-05. Reviewed version: 0.1.4 release candidate, with final build and runtime evidence recorded separately in VALIDATION.md.

## Scope and conclusion

Review covered all application, shared, transport and widget Swift files, entitlements, Info plists, local build/install scripts, synthetic fixtures, documentation, workflow and the prospective Git publication inventory. No credential collection, own network client, backend, telemetry destination, or embedded private credential was found in this source review. No unresolved critical or high-severity issue was identified within that scope. This is a local source review with targeted tests, not an independent penetration test or a certification of the official CLI.

## Trust boundaries

1. The main application runs outside App Sandbox to launch the official CLI. It has the current user's file permissions. Its empty entitlement file is not an operating-system restriction on its file or network access.
2. The official CLI owns authentication and contacts OpenAI. The monitor uses pipes, not an HTTP endpoint, and does not read the CLI's credential files. Fresh server-side quota information needs the CLI's network access.
3. The WidgetKit extension is sandboxed, without network entitlements. Its only temporary file exception is read-only access to `/Library/Application Support/CodexUsageMonitor/usage-snapshot.json` relative to the current user's home.
4. Processes already running as the same user can read or alter the snapshot. Unix permissions do not isolate mutually untrusted applications belonging to that user.
5. A CLI selected in settings is executable code with user permissions. The application checks executability, not a trusted vendor signature. Selection must refer to a trusted official installation.

## Findings and implemented controls

| Area | Evidence and control | Residual limitation |
|---|---|---|
| Credentials | No credential file read or Keychain API in active source; server requests including external token refresh are rejected | Authentication inside the external official CLI is outside this review |
| RPC operations | Allowlist: initialize, account/rateLimits/read, account/usage/read; initialized notification for handshake | Experimental API and CLI compatibility can change |
| Environment | Explicit allowlist; HOME assigned explicitly; unknown variables and token variables not inherited | Child PATH is fixed, CODEX_HOME is not inherited; explicit executable path remains trusted local input |
| Network | No URLSession, URLRequest, Network framework or backend in own source; widget has no network entitlement | Main app is not sandboxed; CLI has its own network behavior |
| Telemetry | Child-only analytics and all OpenTelemetry exporter overrides disabled | Internal remote-control switch is version-specific, not a security boundary |
| Transport | Direct Process execution, no shell; 15-second RPC timeout, 1 MiB framing limit, cancellation and reconnect tests | Trusted child process can still consume resources; this is not a process sandbox |
| Local snapshot | Normalized quota data only, atomic write, directory 0700/file 0600; read rejects symlinks, nonregular files, oversized data and unknown schema | Quota percentages/reset timestamps are personal usage information stored locally |
| Data minimization | No account ID, access/refresh token, raw RPC response or daily token history in snapshot; token summary is memory-only | CLI path and selected quota group are local preferences |
| Logging | Raw stderr directed to null device; no raw response logging; widget emits only availability booleans/generic failure | OS diagnostics outside the app's logger may include executable paths |
| Widget permissions | Exact sandbox + one read-only file grant verified statically and in signed build | Temporary entitlement is for the local distribution approach; App Store approval is not implied |
| Supply chain | No third-party app libraries or downloaded build scripts; Xcode project included | Xcode, system tools, official CLI and GitHub Actions are external trust dependencies |
| Release | Local ad-hoc signature verified; publication inventory excludes builds, logs, snapshots and credentials | No Developer ID signature or notarization; distributed binary acceptance untested |

## Tests and runtime evidence

The final run passed 29 Swift Package tests and 33 native Xcode XCTest tests, including server token-request rejection, forbidden RPC rejection, environment filtering, timeout/reconnect, malformed messages, cancellation, quota parsing, file permissions, symlink/size rejection and menu placement. The final 0.1.4 Release build, ad-hoc signature, installed self-check and the owner's visible Notification Center check passed; see [VALIDATION.md](VALIDATION.md). Live checks print only method/window availability, not personal quota values.

Static guardrails run with `python3 Scripts/audit-source.py`. They detect selected forbidden APIs and entitlement/RPC changes, but do not replace manual review or a full data-flow analysis.

## Personal data and publication inventory

The prospective tracked source set was scanned for private home paths, personal name/email strings, private-key headers, common GitHub/OpenAI token forms and JWT-like strings. No such private values were found. Fixtures and previews use synthetic numbers and dates. The icon was generated for this project and contains no personal image. Git author uses the selected public GitHub handle with its GitHub noreply address. MIT copyright uses project contributors.

Exclude from publication: `.git` internals, local preferences, application-support snapshot, compiler caches, build products, system logs, live protocol captures, signing credentials and provisioning profiles. Public GitHub handle/bundle identifiers are intentional project metadata. The private delivery report is kept outside this repository.

GitHub repository creation and upload require the owner's explicit approval after reviewing the delivery report. No remote CI or public release has been validated before that approval.

## Follow-up requirements

Repeat source/inventory review when adding dependencies, networking, logging or new RPC methods. Recheck live operation after a CLI update. Validate the widget visually on each supported macOS version; macOS controls WidgetKit refresh timing. A distributable binary needs a separate signing/notarization and Gatekeeper review.

## Widget-host recovery follow-up

A blank Notification Center widget was traced to a stale development-extension path retained by launchd. Registration cleanup and a current-user widget-host restart restored live loading; the owner subsequently confirmed visible percentages and update time in the 0.1.4 sidebar widget. Installation provides an explicit `--refresh-widget-host` option; it restarts chronod for the current user without deleting preferences or changing entitlements. Ordinary installation does not restart the host. No credential or application-data access was added.

## Final adversarial review of the 25 required threats

This table assesses the application source. A malicious process already running as the same macOS user or a compromised official CLI has the user's own permissions; the monitor cannot isolate those system-level actors.

| # | Threat | Exposure, mitigation and remaining action | Residual severity |
|---:|---|---|---|
| 1 | Malicious local process | Quota snapshot and preferences are readable by that user; directory/file modes prevent access by other users. A same-user attacker is outside the OS permission boundary. | Medium |
| 2 | Compromised future update | There is no self-updater. Every source release needs review, commit/archive hash and owner approval; GitHub account compromise remains an external risk. | Medium |
| 3 | Replaced `codex` executable | Known absolute candidate paths and manual selection; resolved target must be a non-group/world-writable regular executable. This is not vendor-signature authentication. | Medium |
| 4 | PATH manipulation | Resolution never searches PATH. Child gets a fixed PATH; an attacker who already controls those user-writable directories remains a local-user threat. | Low |
| 5 | Environment injection | Child receives only locale, fixed HOME/PATH and one internal switch. Unknown variables, tokens and dynamic-loader overrides are not forwarded. | Low |
| 6 | Argument injection | Launch uses fixed Process argument array, no user text in CLI arguments. | Low |
| 7 | Shell injection | No shell is used to launch CLI or process RPC values. Build/install scripts quote paths. | Low |
| 8 | Symlink/path attacks | Snapshot read rejects the final symlink; write pins a no-follow directory and atomically replaces the destination. CLI selection resolves symlinks before checking target. Same-user races remain possible. | Low |
| 9 | Temporary-file attacks | Snapshot replacement uses a random, exclusive 0600 file inside a 0700 directory and cleanup. Build scripts use mktemp and traps. | Low |
| 10 | Unintended credential access | No auth-file/Keychain/API-key read in own code; official CLI is external and owns authentication. | Low |
| 11 | Token leakage through stdout/stderr | RPC results are parsed in memory, not logged; raw stderr is discarded without reading it. The official CLI may have independent logs. | Low |
| 12 | Sensitive logs | Widget logs only availability booleans and generic errors. OS-owned diagnostics may contain executable paths. | Low |
| 13 | UserDefaults | Stores selected CLI path and bucket ID only; no usage summary or credentials. Both values are local-user readable. | Low |
| 14 | App Group | None used; the widget has one exact read-only file exception. | Low |
| 15 | Broad filesystem access | Main app is unsandboxed to launch external CLI, so its OS-level file rights remain broad despite the narrow behavior of reviewed code. Widget is sandboxed. | Medium |
| 16 | Unnecessary entitlements | Main app entitlement file is empty; widget has sandbox plus one read-only file. Verify the final signed product again. | Low |
| 17 | Additional macOS permissions | No Accessibility, Full Disk Access, Screen Recording, Automation, camera, microphone or location request. | Low |
| 18 | Insecure IPC | Only anonymous local stdio pipes to CLI and a private on-disk snapshot; no listener or WebSocket. A same-user process can access its own files. | Low |
| 19 | Malformed JSON-RPC | Bounded framing/queue, allowlisted method, exact pending ID and object-shape checks; malformed replies fail closed. | Low |
| 20 | Huge responses/resource exhaustion | 1 MiB per line, bounded reader queue and total-input limit per request. A malicious CLI can still consume its own resources. | Low |
| 21 | Hung/zombie CLI | Request timeout and cancellation close the connection; SIGTERM then SIGKILL, with bounded cleanup wait. Final live process check is required. | Low |
| 22 | Refresh races | Main model allows one refresh; transport permits one pending RPC and uses generation tokens. Confirm final sleep/wake and shutdown behavior. | Low |
| 23 | Widget data exposure | Snapshot contains quota values, dates, status and bucket ID only; no account ID, token summary or credentials. Widget presentation is visible to someone with access to the user's unlocked desktop. | Low |
| 24 | Dependency supply chain | No third-party runtime package. GitHub checkout is pinned to a verified commit; Apple toolchain and official CLI remain external dependencies. | Low |
| 25 | Release tampering | Source archive must come from an audited commit with a published SHA-256. Ad-hoc signatures do not prove publisher identity; binary distribution awaits Developer ID/notarization. | Medium |

**Adversarial conclusion:** No credible route was found in this reviewed source for a quota response to choose an arbitrary file path, execute shell code, create a network listener, or extract credentials. A compromised CLI or malicious process with the same user's rights can bypass this application's boundary and must be treated separately. The release verdict also depends on the final builds and installed-widget checks in `VALIDATION.md`.
