import assert from "node:assert/strict";
import { copyFile, mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";

const sourceScript = path.resolve("scripts", "import-archify.ps1");

async function fixture(manifestOverrides = {}) {
  const root = await mkdtemp(path.join(os.tmpdir(), "flow-hub-import-"));
  const hub = path.join(root, "hub");
  const source = path.join(root, "source");
  const project = path.join(hub, "projects", "demo");
  await mkdir(path.join(hub, "scripts"), { recursive: true });
  await mkdir(project, { recursive: true });
  await mkdir(source, { recursive: true });
  await copyFile(sourceScript, path.join(hub, "scripts", "import-archify.ps1"));
  await writeFile(path.join(project, "sentinel.txt"), "keep-on-failure", "utf8");
  await writeFile(path.join(source, "overview.html"), '<meta name="generator" content="archify 2.17"><main>ok</main>', "utf8");
  await writeFile(path.join(source, "overview.json"), "{}", "utf8");
  await writeFile(path.join(source, "cover.png"), "cover", "utf8");
  const manifest = {
    schemaVersion: 1,
    slug: "demo",
    name: "Demo",
    title: "演示项目",
    description: "演示流程",
    status: "开发中",
    repository: "https://github.com/example/demo",
    notion: "https://app.notion.com/p/demo",
    source: {
      mode: "remote",
      repository: "https://github.com/example/demo.git",
      ref: "main",
      directory: "diagrams",
      cover: "cover.png"
    },
    updated: "2026-09-03",
    cover: "cover.png",
    flows: [{ id: "00", title: "总览", file: "flows/overview.html", spec: "flows/overview.json" }],
    ...manifestOverrides
  };
  await writeFile(path.join(source, "project-flow.json"), JSON.stringify(manifest), "utf8");
  return { root, hub, source, project, manifest };
}

function importProject({ hub, source }, ...extra) {
  return spawnSync("pwsh", [
    "-NoProfile",
    "-File", path.join(hub, "scripts", "import-archify.ps1"),
    "-Slug", "demo",
    "-SourceDirectory", source,
    "-SourceCommit", "0123456789abcdef0123456789abcdef01234567",
    ...extra
  ], { encoding: "utf8" });
}

test("imports from the source manifest, records provenance, and prunes stale files", async () => {
  const context = await fixture();
  const result = importProject(context);
  assert.equal(result.status, 0, result.stderr || result.stdout);
  const manifest = JSON.parse(await readFile(path.join(context.project, "project.json"), "utf8"));
  assert.equal(manifest.provenance.commit, "0123456789abcdef0123456789abcdef01234567");
  assert.match(manifest.provenance.artifactHash, /^[a-f0-9]{64}$/);
  await assert.rejects(() => readFile(path.join(context.project, "sentinel.txt")), /ENOENT/);
  assert.match(await readFile(path.join(context.project, "flows", "overview.html"), "utf8"), /<main>ok<\/main>/);
});

test("rejects source and target path escapes without changing the existing project", async () => {
  const sourceEscape = await fixture({ source: {
    mode: "remote",
    repository: "https://github.com/example/demo.git",
    ref: "main",
    directory: "diagrams",
    cover: "../outside.png"
  } });
  await writeFile(path.join(sourceEscape.root, "outside.png"), "outside", "utf8");
  const sourceResult = importProject(sourceEscape);
  assert.notEqual(sourceResult.status, 0);
  assert.match(sourceResult.stderr, /must stay inside/);
  assert.equal(await readFile(path.join(sourceEscape.project, "sentinel.txt"), "utf8"), "keep-on-failure");

  const targetEscape = await fixture({
    flows: [{
      id: "00",
      title: "总览",
      sourceFile: "overview.html",
      sourceSpec: "overview.json",
      file: "../outside.html",
      spec: "flows/overview.json"
    }]
  });
  const targetResult = importProject(targetEscape);
  assert.notEqual(targetResult.status, 0);
  assert.match(targetResult.stderr, /must stay inside/);
  assert.equal(await readFile(path.join(targetEscape.project, "sentinel.txt"), "utf8"), "keep-on-failure");
});

test("rejects an escaping CoverSource override", async () => {
  const context = await fixture();
  await writeFile(path.join(context.root, "outside.png"), "outside", "utf8");
  const result = importProject(context, "-CoverSource", "../outside.png");
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /must stay inside/);
  assert.equal(await readFile(path.join(context.project, "sentinel.txt"), "utf8"), "keep-on-failure");
});
