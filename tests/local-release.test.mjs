import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, readlink, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { publishRelease } from "../scripts/local-release.mjs";
import { seedSite, syncOnce } from "../scripts/local-sync.mjs";

const dockerOnly = { skip: process.platform === "win32" ? "Atomic directory symlink replacement is verified in Linux Docker" : false };

async function fixture(t) {
  const root = await mkdtemp(path.join(os.tmpdir(), "flow-local-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const sourceDir = path.join(root, "dist");
  const siteDir = path.join(root, "site");
  await mkdir(path.join(sourceDir, "demo"), { recursive: true });
  await mkdir(path.join(root, "projects", "demo"), { recursive: true });
  await writeFile(path.join(root, "projects", "demo", "project.json"), JSON.stringify({
    provenance: { commit: "a".repeat(40), artifactHash: "b".repeat(64) }
  }));
  await writeFile(path.join(sourceDir, "health.json"), JSON.stringify({
    status: "ok", projects: 1, projectSlugs: ["demo"], revision: "abc123"
  }));
  await writeFile(path.join(sourceDir, "demo", "index.html"), "project");
  await writeFile(path.join(sourceDir, "index.html"), "first");
  return { root, sourceDir, siteDir };
}

test("rejects incomplete releases before creating a published version", async (t) => {
  const context = await fixture(t);
  await rm(path.join(context.sourceDir, "demo", "index.html"));
  await assert.rejects(() => publishRelease(context), /ENOENT/);
  await assert.rejects(() => readFile(path.join(context.siteDir, "current", "health.json")), /ENOENT/);
});

test("atomically switches releases, keeps the previous version and skips unchanged output", dockerOnly, async (t) => {
  const context = await fixture(t);
  const first = await publishRelease(context);
  assert.equal(first.changed, true);
  const firstLink = await readlink(path.join(context.siteDir, "current"));
  assert.equal((await publishRelease(context)).changed, false);
  assert.equal(await readlink(path.join(context.siteDir, "current")), firstLink);
  await writeFile(path.join(context.sourceDir, "index.html"), "second");
  const second = await publishRelease(context);
  assert.equal(second.changed, true);
  assert.notEqual(first.release, second.release);
  assert.equal(await readFile(path.join(context.siteDir, "current", "index.html"), "utf8"), "second");
  assert.equal(await readFile(path.join(context.siteDir, firstLink, "index.html"), "utf8"), "first");
  await writeFile(path.join(context.sourceDir, "index.html"), "first");
  assert.equal((await publishRelease(context)).release, first.release);
});

test("invalid candidate leaves the current release untouched", dockerOnly, async (t) => {
  const context = await fixture(t);
  await publishRelease(context);
  const link = await readlink(path.join(context.siteDir, "current"));
  await writeFile(path.join(context.sourceDir, "health.json"), '{"status":"error"}');
  await assert.rejects(() => publishRelease(context), /health is invalid/);
  assert.equal(await readlink(path.join(context.siteDir, "current")), link);
  assert.equal(await readFile(path.join(context.siteDir, "current", "index.html"), "utf8"), "first");
});

test("restart preserves a newer published version instead of seeding old image output", dockerOnly, async (t) => {
  const context = await fixture(t);
  await seedSite(context);
  await writeFile(path.join(context.sourceDir, "index.html"), "newer");
  await publishRelease(context);
  await writeFile(path.join(context.sourceDir, "index.html"), "old-image");
  assert.equal(await seedSite(context), null);
  assert.equal(await readFile(path.join(context.siteDir, "current", "index.html"), "utf8"), "newer");
});

test("sync failure keeps the release and last success, exposes a redacted status, then recovers", dockerOnly, async (t) => {
  const context = await fixture(t);
  await seedSite(context);
  const options = { ...context, slug: "demo", synchronize: async () => {} };
  const first = await syncOnce(options);
  assert.equal(first.changed, false);
  const statusFile = path.join(context.siteDir, "sync-status.json");
  const previous = JSON.parse(await readFile(statusFile, "utf8"));
  assert.equal(previous.sourceCommit, "a".repeat(40));
  assert.equal(previous.artifactHash, "b".repeat(64));
  const link = await readlink(path.join(context.siteDir, "current"));
  await assert.rejects(() => syncOnce({ ...options, synchronize: async () => { throw new Error("private diagnostic"); } }));
  const failedText = await readFile(statusFile, "utf8");
  const failed = JSON.parse(failedText);
  assert.equal(failed.state, "error");
  assert.equal(failed.lastSuccessAt, previous.lastSuccessAt);
  assert.doesNotMatch(failedText, /private diagnostic/);
  assert.equal(await readlink(path.join(context.siteDir, "current")), link);
  await writeFile(path.join(context.sourceDir, "index.html"), "recovered");
  assert.equal((await syncOnce(options)).changed, true);
  assert.equal(JSON.parse(await readFile(statusFile, "utf8")).state, "ok");
});
