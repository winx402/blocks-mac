import { createHash } from "node:crypto";
import { createRequire } from "node:module";
import { readFile, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const require = createRequire(import.meta.url);
const { chromium } = require("playwright");

const directory = dirname(fileURLToPath(import.meta.url));
const sourceURL = pathToFileURL(join(directory, "browser-scroll-fixture.html"));
const executablePath = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const viewport = { width: 900, height: 700 };
const requestedScrollPositions = [
  0, 310, 620, 930, 1_240, 1_550, 1_860, 2_170, 2_480, 2_736, 2_992, 9_999,
];

const browser = await chromium.launch({ executablePath, headless: true });
const browserVersion = await browser.version();

async function waitUntilReady(page) {
  await page.waitForFunction(() => document.documentElement.dataset.ready === "true");
  await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));
  await page.waitForTimeout(50);
}

async function captureViewport(requestedScrollY, tick, path) {
  const page = await browser.newPage({ viewport, deviceScaleFactor: 1 });
  const url = new URL(sourceURL);
  url.searchParams.set("scroll", String(requestedScrollY));
  url.searchParams.set("tick", String(tick));
  await page.goto(url.href);
  await waitUntilReady(page);
  const actualScrollY = await page.evaluate(() => window.scrollY);
  await page.screenshot({ path, fullPage: false });
  await page.close();
  return actualScrollY;
}

const frames = [];
for (const [index, requestedScrollY] of requestedScrollPositions.entries()) {
  const fileName = `page-down-${String(index).padStart(2, "0")}.png`;
  const path = join(directory, fileName);
  const scrollY = await captureViewport(requestedScrollY, index, path);
  const bytes = await readFile(path);
  frames.push({
    file: fileName,
    requestedScrollY,
    scrollY,
    sha256: createHash("sha256").update(bytes).digest("hex"),
  });
}

for (const [index, scrollY] of [0, 320, 640, 960].entries()) {
  await captureViewport(
    scrollY,
    `legacy-${index}`,
    join(directory, `frame-${String(scrollY).padStart(4, "0")}.png`)
  );
}

const truthURL = new URL(sourceURL);
truthURL.searchParams.set("truth", "1");
truthURL.searchParams.set("tick", "truth");
const page = await browser.newPage({ viewport, deviceScaleFactor: 1 });
await page.goto(truthURL.href);
await waitUntilReady(page);
const documentSize = await page.evaluate(() => ({
  width: document.documentElement.scrollWidth,
  height: document.documentElement.scrollHeight,
  devicePixelRatio: window.devicePixelRatio,
}));
const truthPath = join(directory, "ground-truth.png");
await page.screenshot({ path: truthPath, fullPage: true });
const truthBytes = await readFile(truthPath);
await page.close();

await writeFile(join(directory, "manifest.json"), `${JSON.stringify({
  generator: "generate-fixtures.mjs",
  browserVersion,
  viewport,
  documentSize,
  contentComparisonRect: {
    x: 136,
    y: 0,
    width: 672,
    height: documentSize.height,
  },
  frames,
  groundTruth: {
    file: "ground-truth.png",
    sha256: createHash("sha256").update(truthBytes).digest("hex"),
  },
}, null, 2)}\n`);

await browser.close();
