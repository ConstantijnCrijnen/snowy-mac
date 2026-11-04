# Security and privacy

Snowy’s native app reads public window geometry and pointer position to place its snow. It does not capture screen contents, read window titles, request Accessibility access, install input hooks, or send desktop data over the network. Only app preferences are saved.

Please don’t put credentials or unrelated private desktop contents in a public report. If you find a security issue, use GitHub’s **Report a vulnerability** option when available. Otherwise, open an issue asking for a private contact without posting exploit details or sensitive data.

Release ZIPs include SHA-256 checksums. Current app releases use an ad-hoc signature rather than an Apple Developer ID or notarization ticket. Build from source if you prefer to review the exact code you run.
