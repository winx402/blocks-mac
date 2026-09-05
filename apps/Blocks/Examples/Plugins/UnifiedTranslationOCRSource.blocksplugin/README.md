# Unified Translation and OCR Source

This schema-v3 compatibility example exposes both `translation` and `ocr`
capabilities through the same isolated plugin lifecycle. It does not use the
network or secrets. The returned text is a deterministic description of the
authorized input so the host can verify capability routing without sending
user data to a third party.

The screenshot attachment is session-only. The example returns metadata and a
SHA-256 digest, never image bytes or Base64 text.
