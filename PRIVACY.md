# Privacy

CodexUsageMonitor has no analytics, advertising, tracking SDK, telemetry endpoint, crash-reporting service, updater or backend. Its own code makes no direct external network requests and listens on no port. The official Codex CLI may contact OpenAI to obtain fresh quota data; that behavior belongs to the CLI.

The app never reads or stores the Codex authentication file or access/refresh tokens. A local JSON snapshot stores only remaining 5-hour/weekly percentages, reset timestamps, the last successful refresh, attempt time, status and selected quota-bucket ID for the widget. The snapshot is in `~/Library/Application Support/CodexUsageMonitor/`, with 0700 directory and 0600 file permissions. Token usage summary from `account/usage/read` is displayed in settings but kept only in memory. UserDefaults stores the selected executable path and quota-bucket ID, not credentials.

Other processes running as the same macOS user can access data that user owns, including the local quota snapshot. The widget's own logs contain only booleans indicating whether a snapshot and windows were available; raw CLI replies and stderr are not logged by the app. macOS may separately log executable paths and service diagnostics.

Closing the menu-bar app stops the automatic checks. The widget can then show its last saved snapshot until macOS redraws it or the application refreshes again.
