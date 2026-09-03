import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { chromium } from "playwright";

const dist = path.resolve("dist");
const server = createServer(async (request, response) => {
  try {
    const url = new URL(request.url, "http://localhost");
    const relative = decodeURIComponent(url.pathname).replace(/^\/+/, "") || "index.html";
    const file = path.resolve(dist, relative.endsWith("/") ? `${relative}index.html` : relative);
    if (file !== dist && !file.startsWith(`${dist}${path.sep}`)) throw new Error("Invalid path");
    const content = await readFile(file);
    response.writeHead(200, { "content-type": file.endsWith(".html") ? "text/html; charset=utf-8" : "application/octet-stream" });
    response.end(content);
  } catch {
    response.writeHead(404).end("Not found");
  }
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const { port } = server.address();
const home = `http://127.0.0.1:${port}/`;
const browser = await chromium.launch({ headless: true });

try {
  for (const viewport of [{ width: 1440, height: 900 }, { width: 390, height: 844 }]) {
    const page = await browser.newPage({ viewport });
    const errors = [];
    page.on("console", (message) => {
      if (message.type() === "error") errors.push(message.text());
    });
    page.on("pageerror", (error) => errors.push(error.message));
    await page.goto(home);
    const projects = page.locator(".project-card .primary-action");
    const projectCount = await projects.count();
    assert.ok(projectCount > 0, "No projects rendered");
    const projectUrls = [];
    for (let index = 0; index < projectCount; index++) {
      projectUrls.push(await projects.nth(index).getAttribute("href"));
    }
    for (const projectUrl of projectUrls) {
      await page.goto(new URL(projectUrl, home).href);
      const flowButtons = page.locator("#flow-nav button");
      const flowCount = await flowButtons.count();
      assert.ok(flowCount > 0, `No flows rendered for ${projectUrl}`);
      for (let index = 0; index < flowCount; index++) {
        await flowButtons.nth(index).click();
        const frame = page.frameLocator("#viewer");
        await frame.locator('meta[name="generator"][content^="archify"]').waitFor({ state: "attached" });
        assert.ok(await frame.locator("body").evaluate((body) => body.scrollHeight > 100), `Blank flow ${projectUrl}#${index}`);
      }
    }
    assert.deepEqual(errors, [], `Browser errors at ${viewport.width}x${viewport.height}: ${errors.join(" | ")}`);
    await page.close();
  }
} finally {
  await browser.close();
  await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
}
