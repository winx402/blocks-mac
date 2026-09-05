import { cp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { renderToStaticMarkup } from "react-dom/server";
import { InformationPage, MarketingPage } from "../app/site-components";
import { copy, locales, pageSlugs, type Locale } from "../app/site-content";

const root = process.cwd();
const output = join(root, "dist");

function documentShell(input: {
  lang: string;
  title: string;
  description: string;
  content: string;
}): string {
  return `<!doctype html>
<html lang="${input.lang}">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="robots" content="noindex, nofollow">
  <meta name="description" content="${escapeAttribute(input.description)}">
  <title>${escapeText(input.title)}</title>
  <link rel="icon" href="/favicon.svg">
  <link rel="stylesheet" href="/styles.css">
</head>
<body>${input.content}</body>
</html>
`;
}

function escapeAttribute(value: string): string {
  return escapeText(value).replaceAll('"', "&quot;");
}

function escapeText(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;");
}

async function writeRoute(route: string, html: string): Promise<void> {
  const directory = join(output, route);
  await mkdir(directory, { recursive: true });
  await writeFile(join(directory, "index.html"), html, "utf8");
}

function titleFor(locale: Locale): string {
  if (locale === "zh") return "积木工具 — Beta 发布预览";
  if (locale === "ja") return "Blocks for Mac — ベータ公開前プレビュー";
  return "Blocks for Mac — Beta pre-release preview";
}

await rm(output, { recursive: true, force: true });
await mkdir(output, { recursive: true });
await cp(join(root, "public"), output, { recursive: true });
await writeFile(
  join(output, "styles.css"),
  await readFile(join(root, "app/globals.css"), "utf8"),
  "utf8",
);

for (const locale of locales) {
  const localeCopy = copy[locale];
  await writeRoute(locale, documentShell({
    lang: localeCopy.lang,
    title: titleFor(locale),
    description: localeCopy.lead,
    content: renderToStaticMarkup(<MarketingPage locale={locale} />),
  }));

  for (const slug of pageSlugs) {
    const page = localeCopy.pages[slug];
    await writeRoute(join(locale, slug), documentShell({
      lang: localeCopy.lang,
      title: `${page.title} — ${localeCopy.brand}`,
      description: page.intro,
      content: renderToStaticMarkup(
        <InformationPage locale={locale} slug={slug} />,
      ),
    }));
  }
}

await writeFile(
  join(output, "index.html"),
  `<!doctype html>
<html lang="zh-Hans"><head><meta charset="utf-8"><meta name="robots" content="noindex, nofollow"><meta http-equiv="refresh" content="0; url=/zh/"><title>积木工具</title></head><body><a href="/zh/">积木工具</a></body></html>
`,
  "utf8",
);
await writeFile(
  join(output, "404.html"),
  `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="robots" content="noindex, nofollow"><title>Not found — Blocks for Mac</title></head><body><h1>Not found</h1><p><a href="/en/">Blocks for Mac</a></p></body></html>
`,
  "utf8",
);
await writeFile(
  join(output, "robots.txt"),
  "User-agent: *\nDisallow: /\n",
  "utf8",
);
await writeFile(
  join(output, "_headers"),
  `/*
  X-Robots-Tag: noindex, nofollow
  X-Content-Type-Options: nosniff
  Referrer-Policy: strict-origin-when-cross-origin
  Content-Security-Policy: default-src 'self'; img-src 'self' data:; style-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'
`,
  "utf8",
);

console.log(
  `Generated ${locales.length * (pageSlugs.length + 1)} static localized pages in ${output}`,
);
