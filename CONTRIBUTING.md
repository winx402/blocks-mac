# Contributing to Blocks for Mac

Project-authored contributions are accepted under the repository's MIT license.
Keep third-party license notices intact. Do not submit credentials, signing
profiles, user clipboard data, private screenshots, or local configuration.

Use a feature branch and describe the behavior change, its tests, and anything
not yet verified. Follow AGENTS.md and the product UI guidelines before changing
interaction or presentation. Tests are not a substitute for installed-app
verification when a change affects focus, paste, capture, or window behavior.

The LocalDevelopment workflow is being implemented. Until its documented
verification is complete, do not assume an unsigned build has full functionality.
Official distribution requires a separately verified signed and notarized build.

Do not run privileged scripts or expose signing credentials to untrusted pull
requests. Report security issues privately as described in SECURITY.md.
