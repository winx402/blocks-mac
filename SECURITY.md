# Security

Do not include API keys, pairing secrets, clipboard contents, provisioning
profiles, or personal screenshots in public issues.

Use GitHub's private vulnerability reporting for this repository when that
facility is enabled. If it is unavailable, request a private reporting channel
without publishing exploit details or sensitive data in a public issue.

Only artifacts explicitly published as official releases are distribution
builds. Development builds are not a substitute for Developer ID signing,
notarization, or authenticated update verification. Never disable Gatekeeper or
reset TCC permissions as an installation workaround.

LocalDevelopment uses a separate app identity and data namespace. Its local
trust policy must never be accepted by official release services.
