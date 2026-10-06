// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodexUsageMonitor",
    platforms: [.macOS(.v14)],
    products: [.library(name: "CodexUsageCore", targets: ["CodexUsageCore"])],
    targets: [
        .target(name: "CodexUsageCore", path: ".", exclude: [
            "App", "Widget", "SharedUI", "Resources", "Configuration", "Tests", "Scripts",
            "CodexUsageMonitor.xcodeproj", "README.md", "LICENSE", ".github", ".gitignore", "VALIDATION.md", "SECURITY_AUDIT.md", "SECURITY.md", "PRIVACY.md", "CONTRIBUTING.md", "RELEASE.md", "Docs"
        ], sources: ["Shared", "Transport"]),
        .testTarget(name: "CodexUsageCoreTests", dependencies: ["CodexUsageCore"],
                    path: "Tests", exclude: ["AppTests.swift", "install_local_smoke.sh"],
                    resources: [.copy("Fixtures")])
    ]
)
