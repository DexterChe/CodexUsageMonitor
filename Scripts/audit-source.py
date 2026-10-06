"""Static guardrails, not a substitute for reviewing the official CLI or runtime."""
from pathlib import Path
import plistlib
import re
import sys

root = Path(__file__).resolve().parent.parent
issues = []
for directory in ["App", "Shared", "SharedUI", "Transport", "Widget"]:
    for file in (root / directory).glob("*.swift"):
        text = file.read_text()
        for pattern in [r"\bURLSession\b", r"\bURLRequest\b", r"\bNWConnection\b",
                        r"\bNWListener\b", r"\bSecItemCopyMatching\b", r"auth\.json",
                        r"\bimport Network\b"]:
            if re.search(pattern, text):
                issues.append(f"Unexpected networking/credential API: {file.relative_to(root)}")
        if re.search(r"(?:gh[pousr]_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9]{20,}|BEGIN .*PRIVATE KEY)", text):
            issues.append(f"Possible secret: {file.relative_to(root)}")

client = (root / "Transport/CodexRPCClient.swift").read_text()
match = re.search(r"allowedMethods.*?=\s*\[(.*?)\]", client)
methods = set(re.findall(r'"([^"]+)"', match.group(1))) if match else set()
if methods != {"initialize", "account/rateLimits/read", "account/usage/read"}:
    issues.append("RPC allowlist changed")

widget = plistlib.loads((root / "Configuration/Widget.entitlements").read_bytes())
expected = {
    "com.apple.security.app-sandbox": True,
    "com.apple.security.temporary-exception.files.home-relative-path.read-only": [
        "/Library/Application Support/CodexUsageMonitor/usage-snapshot.json"
    ],
}
if widget != expected:
    issues.append("Widget entitlements are broader than sandbox + one read-only snapshot")
app = plistlib.loads((root / "Configuration/App.entitlements").read_bytes())
if app:
    issues.append("Unexpected main-app entitlements")

if issues:
    print("\n".join(issues))
    sys.exit(1)
print("PASS: no own network/credential APIs; exact RPC allowlist; widget sandbox + one read-only file")
