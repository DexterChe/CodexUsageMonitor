# Source release process

A public release requires the owner's explicit approval after the final audit. Until Developer ID signing and notarization are available, distribute source archives, not a prebuilt binary intended for other computers.

1. Run the complete audit and fix failures. Build Debug, run tests, build Release, verify entitlements, and check the installed widget with live data. Record any unverified case.
2. Review every staged file and local Git history for secrets, personal paths and build output. Check `git diff --check`, the static privacy guard, README, license and security/privacy documentation.
3. Commit the audited source tree. Create a `.zip` using `git archive` from that commit; record its SHA-256 and verify the archive's file list and integrity. Keep private reports and logs outside the archive.
4. Present the final report and archive to the owner. Create the remote repository and push only after approval. Verify the published file list, license, security reporting configuration and GitHub Actions results.
5. Never publish a signed binary until a separate Developer ID, hardened-runtime, notarization and Gatekeeper review is complete. Do not instruct users to remove quarantine or bypass macOS protection.

There is no self-updater. Later releases repeat these checks and require a fresh approval when the owner requests publication.
