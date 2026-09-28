import { execFileSync, spawn, spawnSync } from "node:child_process";
import { access, readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { publishRelease, writeSyncStatus } from "./local-release.mjs";

const gitIdentity = ["-c", "user.name=flow-hub-local", "-c", "user.email=flow-hub-local@localhost"];

function runSyncScript(root, slug) {
  return new Promise((resolve, reject) => {
    const child = spawn("pwsh", ["-NoProfile", "-File", "scripts/sync-remote-projects.ps1", "-Slug", slug, "-NoPush"], {
      cwd: root, stdio: "inherit", detached: true,
      env: { ...process.env, GIT_TERMINAL_PROMPT: "0", GIT_CONFIG_COUNT: "2",
        GIT_CONFIG_KEY_0: "http.lowSpeedLimit", GIT_CONFIG_VALUE_0: "1024",
        GIT_CONFIG_KEY_1: "http.lowSpeedTime", GIT_CONFIG_VALUE_1: "60" }
    });
    // Bound the whole process group, including Git and test subprocesses.
    const timeout = setTimeout(() => {
      try { process.kill(-child.pid, "SIGKILL"); }
      catch (error) { if (error.code !== "ESRCH") reject(error); }
    }, 600_000);
    child.on("error", (error) => { clearTimeout(timeout); reject(error); });
    child.on("close", (code) => {
      clearTimeout(timeout);
      if (code === 0) resolve();
      else reject(new Error(`Synchronization exited with code ${code}`));
    });
  });
}

async function readStatus(siteDir) {
  try {
    return JSON.parse(await readFile(path.join(siteDir, "sync-status.json"), "utf8"));
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
    return {};
  }
}

export async function seedSite({ root, siteDir }) {
  try {
    await access(path.join(siteDir, "current", "health.json"));
    return null;
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
    return publishRelease({ sourceDir: path.join(root, "dist"), siteDir });
  }
}

export async function syncOnce({ root, siteDir, slug, synchronize = () => runSyncScript(root, slug) }) {
  if (!/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(slug)) throw new Error("Invalid synchronization slug");
  const previous = await readStatus(siteDir);
  const lastAttemptAt = new Date().toISOString();
  await writeSyncStatus(siteDir, { ...previous, slug, state: "syncing", lastAttemptAt });
  try {
    await synchronize();
    const manifest = JSON.parse(await readFile(path.join(root, "projects", slug, "project.json"), "utf8"));
    const result = await publishRelease({ sourceDir: path.join(root, "dist"), siteDir });
    await writeSyncStatus(siteDir, {
      slug, state: "ok", lastAttemptAt, lastSuccessAt: new Date().toISOString(),
      result: result.changed ? "published" : "unchanged", release: result.release,
      revision: result.health.revision, sourceCommit: manifest.provenance?.commit,
      artifactHash: manifest.provenance?.artifactHash
    });
    return result;
  } catch (error) {
    await writeSyncStatus(siteDir, { ...previous, slug, state: "error", lastAttemptAt, result: "sync_failed" });
    throw error;
  }
}

async function main() {
  const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
  const siteDir = process.env.FLOW_SITE_DIR || "/site";
  const slug = process.env.FLOW_SYNC_SLUG || "comic-generation";
  const interval = Number(process.env.FLOW_SYNC_INTERVAL_SECONDS || "300");
  if (!Number.isInteger(interval) || interval < 30 || interval > 86400) {
    throw new Error("FLOW_SYNC_INTERVAL_SECONDS must be between 30 and 86400");
  }
  await seedSite({ root, siteDir });
  execFileSync("git", ["init", "--quiet"], { cwd: root });
  if (spawnSync("git", ["rev-parse", "--verify", "HEAD"], { cwd: root }).status !== 0) {
    execFileSync("git", ["add", "--", "projects"], { cwd: root });
    execFileSync("git", [...gitIdentity, "commit", "--quiet", "-m", "Image baseline"], { cwd: root });
  }
  while (true) {
    try {
      const result = await syncOnce({ root, siteDir, slug });
      execFileSync("git", ["add", "--", `projects/${slug}`], { cwd: root });
      const diff = spawnSync("git", ["diff", "--cached", "--quiet"], { cwd: root });
      if (diff.status === 1) {
        execFileSync("git", [...gitIdentity, "commit", "--quiet", "-m", "Validated local synchronization"], { cwd: root });
      } else if (diff.status !== 0) {
        throw new Error("Unable to inspect local synchronization baseline");
      }
      console.log(`${new Date().toISOString()} ${slug}: ${result.changed ? "published" : "unchanged"} ${result.release}`);
    } catch {
      console.error(`${new Date().toISOString()} ${slug}: sync failed; keeping last published release, retry in ${interval}s`);
    }
    await new Promise((resolve) => setTimeout(resolve, interval * 1000));
  }
}

const entry = process.argv[1] ? pathToFileURL(path.resolve(process.argv[1])).href : "";
if (import.meta.url === entry) await main();
