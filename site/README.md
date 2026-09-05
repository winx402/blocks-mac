# Blocks for Mac pre-release website

Local-only static draft for the staged Blocks for Mac public beta. It generates 24
Chinese, English, and Japanese landing, release, known-issue, privacy, terms,
support, security, and channel-difference pages under `dist/`.

The site intentionally has no live download, active support mailbox, form,
analytics, Cloudflare project, R2 bucket, or deployed production endpoint. It
contains the locked public URLs and reserved mailbox identities, with explicit
pre-launch warnings. `robots` remains `noindex` while signing, notarization,
clean-machine, and external-resource gates remain incomplete. The generated
site has no client
JavaScript, Worker, database, authentication, or external runtime dependency.

```bash
npm run dev
npm run build
npm test
npm run lint
```
