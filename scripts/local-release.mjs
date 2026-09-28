import { createHash, randomUUID } from "node:crypto";
import { cp, mkdir, readFile, readdir, readlink, rename, rm, symlink, writeFile } from "node:fs/promises";
import path from "node:path";

async function fingerprint(directory, hash = createHash("sha256"), prefix = "") {
  const entries = await readdir(directory, { withFileTypes: true });
  for (const entry of entries.sort((a, b) => a.name.localeCompare(b.name))) {
    const relative = `${prefix}${entry.name}`;
    const file = path.join(directory, entry.name);
    if (entry.isDirectory()) {
      await fingerprint(file, hash, `${relative}/`);
    } else if (entry.isFile()) {
      const content = await readFile(file);
      hash.update(JSON.stringify([relative, content.length]));
      hash.update(content);
    } else {
      throw new Error(`Release contains a non-regular file: ${relative}`);
    }
  }
  return hash;
}

export async function publishRelease({ sourceDir, siteDir }) {
  const health = JSON.parse(await readFile(path.join(sourceDir, "health.json"), "utf8"));
  if (health.status !== "ok" || !health.projects || !Array.isArray(health.projectSlugs) ||
      health.projectSlugs.length !== health.projects || !health.revision) {
    throw new Error("Release health is invalid");
  }
  await readFile(path.join(sourceDir, "index.html"));
  for (const slug of health.projectSlugs) {
    if (!/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(slug)) throw new Error("Release project slug is invalid");
    await readFile(path.join(sourceDir, slug, "index.html"));
  }
  const release = (await fingerprint(sourceDir)).digest("hex");
  const target = `releases/${release}`;
  const current = path.join(siteDir, "current");
  const existing = await readlink(current).catch((error) => {
    if (error.code !== "ENOENT") throw error;
    return null;
  });
  if (existing === target) return { changed: false, release, health };

  await mkdir(path.join(siteDir, "releases"), { recursive: true });
  const token = randomUUID();
  const staging = path.join(siteDir, "releases", `.staging-${token}`);
  const link = path.join(siteDir, `.current-${token}`);
  try {
    await cp(sourceDir, staging, { recursive: true });
    const releaseDir = path.join(siteDir, target);
    try {
      await rename(staging, releaseDir);
    } catch (error) {
      if (!["EEXIST", "ENOTEMPTY"].includes(error.code)) throw error;
    }
    // Linux rename replaces the symlink atomically; Nginx never serves staging.
    await symlink(target, link, "dir");
    await rename(link, current);
    return { changed: true, release, health };
  } finally {
    await rm(staging, { recursive: true, force: true });
    await rm(link, { force: true });
  }
}

export async function writeSyncStatus(siteDir, status) {
  const staging = path.join(siteDir, `.status-${randomUUID()}`);
  try {
    await writeFile(staging, `${JSON.stringify(status)}\n`, "utf8");
    await rename(staging, path.join(siteDir, "sync-status.json"));
  } finally {
    await rm(staging, { force: true });
  }
}
