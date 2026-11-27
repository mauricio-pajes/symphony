const assert = require("node:assert/strict");
const path = require("node:path");
const { setTimeout: hold } = require("node:timers/promises");
const { chromium } = require("playwright");

async function verifyLayout(page) {
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
}

async function record(origin, scenario, viewport, holdSeconds, destination) {
  const size = viewport === "mobile" ? { width: 430, height: 740 } : { width: 1280, height: 760 };
  const browser = await chromium.launch({ channel: "chrome", headless: true });
  try {
    const context = await browser.newContext({
      viewport: size,
      reducedMotion: "reduce",
      recordVideo: { dir: destination, size },
    });
    try {
      await context.route("**/*", (route) =>
        new URL(route.request().url()).origin === origin ? route.continue() : route.abort()
      );
      const page = await context.newPage();
      const video = page.video();
      await page.goto(origin);
      const available = page.getByRole("rowheader", { name: "Field notebook" });
      const reserved = page.getByRole("rowheader", { name: "Graphite pencil" });
      const items = page.getByRole("rowheader");
      const count = page.getByRole("status");
      await available.waitFor();
      await reserved.waitFor();
      await verifyLayout(page);
      assert.deepEqual(await items.allTextContents(), ["Field notebook", "Graphite pencil"]);

      if (scenario === "filter") {
        const filter = page.getByRole("button", { name: "In stock only" });
        assert.equal(await filter.getAttribute("aria-pressed"), "false");
        await filter.focus();
        await hold(1300);
        await filter.press("Space");
        await reserved.waitFor({ state: "hidden" });
        assert.equal(await count.innerText(), "1 of 2 items");
        assert.equal(await filter.getAttribute("aria-pressed"), "true");
        await page.screenshot({ path: path.join(destination, "browser-result.png") });
        await hold(holdSeconds * 1000);
        await filter.press("Space");
        await reserved.waitFor();
        assert.equal(await filter.getAttribute("aria-pressed"), "false");
      } else if (scenario === "sort") {
        const sort = page.getByRole("combobox", { name: "Sort by" });
        assert.equal(await sort.getAttribute("id"), "stock-order");
        await sort.focus();
        await hold(1300);
        await sort.selectOption("stock");
        assert.deepEqual(await items.allTextContents(), ["Graphite pencil", "Field notebook"]);
        await page.screenshot({ path: path.join(destination, "browser-result.png") });
        await hold(holdSeconds * 1000);
        await sort.selectOption("catalog");
      } else {
        throw new Error("Unknown catalog scenario");
      }
      assert.deepEqual(await items.allTextContents(), ["Field notebook", "Graphite pencil"]);
      assert.equal(await count.innerText(), "2 of 2 items");
      await verifyLayout(page);
      await hold(1100);
      await context.close();
      await video.saveAs(path.join(destination, "stockroom.webm"));
    } finally {
      await context.close();
    }
  } finally {
    await browser.close();
  }
}

record(...process.argv.slice(2)).catch((error) => {
  console.error(error.message);
  process.exitCode = 1;
});
