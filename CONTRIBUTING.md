# Contributing

Keep the app minimal and preserve the credential boundary. Propose changes in a pull request with the behavior, reason, tests and privacy impact. Do not include account screenshots, credentials, authentication dumps or private paths in issues, fixtures or logs.

Write public documentation, comments, test names, and screenshots in English. Keep Russian text only in the intentional `Resources/ru.lproj` interface localization. Run `python3 Scripts/check-repository-language.py` before submitting a change.

Build with Xcode's shared `CodexUsageMonitor` scheme or `bash Scripts/build-local.sh Release`. Run `swift test` and `python3 Scripts/audit-source.py`. For changes to the app or widget, compile both Debug and Release and inspect Small/Medium in light and dark appearance. The synthetic fixture in `Tests/Fixtures` does not use real credentials or network access.

Avoid third-party runtime dependencies, direct network requests, additional RPC methods and broad entitlements. Document and review any necessary exception before changing these boundaries. Please report potential vulnerabilities privately using [SECURITY.md](SECURITY.md).
