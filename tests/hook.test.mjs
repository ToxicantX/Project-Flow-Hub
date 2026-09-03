import assert from "node:assert/strict";
import { copyFile, mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";

async function fixture() {
  const root = await mkdtemp(path.join(os.tmpdir(), "flow-hub-hook-"));
  const hub = path.join(root, "hub");
  const source = path.join(root, "source");
  await mkdir(path.join(hub, "scripts"), { recursive: true });
  await mkdir(path.join(source, "diagrams"), { recursive: true });
  await copyFile(path.resolve("scripts", "install-local-hook.ps1"), path.join(hub, "scripts", "install-local-hook.ps1"));
  await writeFile(path.join(hub, "scripts", "sync-project.ps1"), "", "utf8");
  assert.equal(spawnSync("git", ["init", "-q", source]).status, 0);
  return { hub, source, hook: path.join(source, ".git", "hooks", "post-commit") };
}

function install({ hub, source }, ...extra) {
  return spawnSync("pwsh", [
    "-NoProfile",
    "-File", path.join(hub, "scripts", "install-local-hook.ps1"),
    "-SourceRepository", source,
    "-Slug", "demo",
    ...extra
  ], { encoding: "utf8" });
}

test("installs a managed hook with failure reporting", async () => {
  const context = await fixture();
  const result = install(context);
  assert.equal(result.status, 0, result.stderr || result.stdout);
  const hook = await readFile(context.hook, "utf8");
  assert.match(hook, /project-flow-hub managed hook/);
  assert.match(hook, /-- "diagrams\/"/);
  assert.match(hook, /project-flow-hub-sync\.failed/);
});

test("refuses to overwrite external hooks or accept an escaping cover", async () => {
  const external = await fixture();
  await writeFile(external.hook, "#!/bin/sh\necho external\n", "utf8");
  const externalResult = install(external);
  assert.notEqual(externalResult.status, 0);
  assert.equal(await readFile(external.hook, "utf8"), "#!/bin/sh\necho external\n");

  const escaping = await fixture();
  const escapingResult = install(escaping, "-CoverSource", "../secret.png");
  assert.notEqual(escapingResult.status, 0);
  assert.match(escapingResult.stderr, /must stay inside/);
});
