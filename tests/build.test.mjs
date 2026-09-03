import assert from "node:assert/strict";
import { mkdtemp, mkdir, readFile, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { buildSite } from "../scripts/build.mjs";

async function fixture(manifestOverrides = {}) {
  const root = await mkdtemp(path.join(os.tmpdir(), "flow-hub-"));
  const project = path.join(root, "projects", "demo", "flows");
  await mkdir(project, { recursive: true });
  await mkdir(path.join(root, "src"), { recursive: true });
  await writeFile(path.join(root, "src", "site.css"), "body{}", "utf8");
  await writeFile(path.join(root, "src", "project.js"), "", "utf8");
  await writeFile(path.join(root, "projects", "demo", "cover.png"), "cover", "utf8");
  await writeFile(path.join(project, "overview.html"), '<meta name="generator" content="archify 2.17">', "utf8");
  await writeFile(path.join(project, "overview.json"), "{}", "utf8");
  const manifest = {
    schemaVersion: 1,
    slug: "demo",
    name: "Demo",
    title: "演示项目",
    description: "演示流程",
    status: "开发中",
    updated: "2026-09-03",
    cover: "cover.png",
    flows: [{ id: "00", title: "总览", file: "flows/overview.html", spec: "flows/overview.json" }],
    ...manifestOverrides
  };
  await writeFile(path.join(root, "projects", "demo", "project.json"), JSON.stringify(manifest), "utf8");
  return root;
}

test("builds the home page, project page, flow and health endpoint", async () => {
  const root = await fixture();
  const output = path.join(root, "public");
  const result = await buildSite({ root, outputDir: output });
  assert.equal(result.projects, 1);
  assert.match(await readFile(path.join(output, "index.html"), "utf8"), /演示项目/);
  assert.match(await readFile(path.join(output, "demo", "index.html"), "utf8"), /overview\.html/);
  assert.equal(JSON.parse(await readFile(path.join(output, "health.json"), "utf8")).projects, 1);
});

test("rejects flow paths that leave the project directory", async () => {
  const root = await fixture({
    flows: [{ id: "00", title: "总览", file: "../outside.html", spec: "flows/overview.json" }]
  });
  await assert.rejects(() => buildSite({ root }), /cannot leave the project directory/);
});
