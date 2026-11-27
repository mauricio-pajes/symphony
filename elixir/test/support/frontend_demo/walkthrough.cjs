const assert = require("node:assert/strict");
const path = require("node:path");
const { setTimeout: hold } = require("node:timers/promises");
const { chromium } = require("playwright");

async function verifyLayout(page) {
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
}

async function installRecordingCursor(page) {
  // Playwright videos capture page pixels, so paint the pointer where the
  // actual mouse events occurred. The overlay is transparent to input.
  await page.evaluate(() => {
    const cursor = document.createElement("div");
    cursor.setAttribute("aria-hidden", "true");
    cursor.style.cssText = "position:fixed;left:0;top:0;pointer-events:none;z-index:2147483647";
    const arrow = document.createElement("div");
    arrow.style.cssText = "width:19px;height:25px;background:#15372b";
    arrow.style.clipPath = "polygon(0 0, 95% 64%, 57% 65%, 77% 95%, 57% 100%, 37% 71%, 10% 93%)";
    const ring = document.createElement("div");
    ring.style.cssText = "position:absolute;inset:-14px auto auto -14px;width:28px;height:28px;border:2px solid #117c57;border-radius:50%;opacity:0";
    cursor.append(ring, arrow);
    window.addEventListener("pointermove", ({ clientX, clientY }) => {
      cursor.style.transform = `translate(${clientX}px, ${clientY}px)`;
    }, true);
    window.addEventListener("pointerdown", () => {
      ring.animate([{ opacity: 1, transform: "scale(.5)" }, { opacity: 0, transform: "scale(1.5)" }], 480);
    }, true);
    document.body.append(cursor);
  });
}

async function pointAt(page, target) {
  const bounds = await target.boundingBox();
  assert.ok(bounds, "The demo target must be visible");
  await page.mouse.move(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2, { steps: 18 });
}

async function click(page, target) {
  await pointAt(page, target);
  await hold(280);
  await page.mouse.down();
  await page.mouse.up();
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
      await installRecordingCursor(page);
      await page.mouse.move(25, 28);
      await hold(850);

      if (scenario === "filter") {
        const filter = page.getByRole("button", { name: "In stock only" });
        assert.equal(await filter.getAttribute("aria-pressed"), "false");
        await click(page, filter);
        await reserved.waitFor({ state: "hidden" });
        assert.equal(await count.innerText(), "1 of 2 items");
        assert.equal(await filter.getAttribute("aria-pressed"), "true");
        await hold(450);
        await pointAt(page, count);
        await page.screenshot({ path: path.join(destination, "browser-result.png") });
        await hold(holdSeconds * 1000);
        await click(page, filter);
        await reserved.waitFor();
        assert.equal(await filter.getAttribute("aria-pressed"), "false");
      } else if (scenario === "sort") {
        const sort = page.getByRole("group", { name: "Sort by" });
        const original = sort.getByRole("radio", { name: "Catalog order" });
        const lowest = sort.getByRole("radio", { name: "Lowest availability" });
        assert.equal(await original.isChecked(), true);
        await click(page, lowest);
        assert.equal(await lowest.isChecked(), true);
        assert.deepEqual(await items.allTextContents(), ["Graphite pencil", "Field notebook"]);
        await hold(450);
        await pointAt(page, reserved);
        await page.screenshot({ path: path.join(destination, "browser-result.png") });
        await hold(holdSeconds * 1000);
        await click(page, original);
        assert.equal(await original.isChecked(), true);
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
