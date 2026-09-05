import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const siteRoot = new URL("../dist/", import.meta.url);

async function render(path) {
  return readFile(
    new URL(`${path.replace(/^\//, "")}/index.html`, siteRoot),
    "utf8",
  );
}

test("renders the pre-release landing page without a live download", async () => {
  const html = await render("/zh");
  assert.match(html, /Beta 1/);
  assert.match(html, /尚未开放下载/);
  assert.match(html, /disabled/);
  assert.match(html, /Apple Silicon/);
  assert.doesNotMatch(html, /support@|privacy@|r2\.dev/);
});

test("renders localized policy and channel pages", async () => {
  for (const [path, brand] of [
    ["/en/privacy", /Blocks for Mac/],
    ["/ja/support", /Blocks for Mac/],
    ["/zh/channels", /积木工具/],
  ]) {
    const html = await render(path);
    assert.match(html, brand);
    assert.match(html, /Pre-release draft/);
  }
});

test("uses the locked public brand and reserved contact identities", async () => {
  const [rootRedirect, zh, en, ja, support, privacy, security] = await Promise.all([
    readFile(new URL("index.html", siteRoot), "utf8"),
    render("/zh"),
    render("/en"),
    render("/ja"),
    render("/en/support"),
    render("/en/privacy"),
    render("/en/security"),
  ]);
  assert.match(zh, />积木工具</);
  assert.match(en, />Blocks for Mac</);
  assert.match(ja, />Blocks for Mac</);
  assert.match(rootRedirect, />积木工具</);
  assert.doesNotMatch(
    rootRedirect + zh + en + ja,
    /积木工具 \/ Blocks|積木ツール \/ Blocks/,
  );
  assert.match(support, /support@orangeforge\.top/);
  assert.match(privacy, /privacy@orangeforge\.top/);
  assert.match(security, /security@orangeforge\.top/);
  for (const html of [zh, en, ja]) {
    assert.doesNotMatch(html, /Orange Forge/);
  }
});

test("emits a static noindex site without client scripts", async () => {
  const [html, robots, headers] = await Promise.all([
    render("/en"),
    readFile(new URL("robots.txt", siteRoot), "utf8"),
    readFile(new URL("_headers", siteRoot), "utf8"),
  ]);
  assert.doesNotMatch(html, /<script\b/i);
  assert.match(html, /name="robots" content="noindex, nofollow"/);
  assert.match(robots, /Disallow: \/$/m);
  assert.match(headers, /X-Robots-Tag: noindex, nofollow/);
});

test("publishes screenshots with accurate formats and intrinsic dimensions", async () => {
  const html = await render("/zh");
  assert.match(
    html,
    /src="\/product\/translation\.jpeg"[^>]*width="678" height="711"/,
  );
  assert.match(
    html,
    /src="\/product\/clipboard\.jpeg"[^>]*width="1920" height="292"/,
  );
  assert.doesNotMatch(html, /clipboard\.png/);
});
