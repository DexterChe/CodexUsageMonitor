# Security policy

This is an independent, unofficial macOS utility. The currently reviewed source version is 0.1.4. Older builds are not maintained; review the latest source before installing an update. Private vulnerability reporting should be used once enabled for this repository.

## Report a vulnerability

After the GitHub repository is published and **Private vulnerability reporting** is enabled, use the repository's **Security → Report a vulnerability** form. Until then, send the maintainer a private message through an existing trusted channel. Do not put a proof of concept, account details, tokens, logs containing private data, or a vulnerability in a public issue. No dedicated email address is asserted.

## Credential boundary

The application launches an installed `codex app-server --stdio` directly and asks for `account/rateLimits/read` and `account/usage/read` only, after the required handshake. The official CLI owns authentication and any necessary network traffic. The monitor does not read Codex authentication files, Keychain credentials, cookies, access/refresh tokens or API keys, and it has no network client or backend.

The main app is not sandboxed because it launches an external CLI. Its own code accesses an explicit CLI path, a local quota snapshot and two local preferences. The WidgetKit extension is sandboxed and may read only the snapshot file through a specific read-only exception. The file holds quota percentages, reset/refresh timestamps, status and a quota-bucket ID; it does not hold credentials. Details and residual risks are in [SECURITY_AUDIT.md](SECURITY_AUDIT.md).

A manually selected executable runs with the user's permissions. Select a trusted official installation. Ad-hoc local signing does not authenticate the publisher for distribution; a future binary release needs Developer ID signing and notarization.
