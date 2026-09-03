import { cp, mkdir, readFile, readdir, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const slugPattern = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;
const idPattern = /^[a-zA-Z0-9_-]+$/;

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function safeRelativePath(value, field) {
  if (typeof value !== "string" || value.length === 0 || path.isAbsolute(value)) {
    throw new Error(`${field} must be a non-empty relative path`);
  }
  const normalized = value.replaceAll("\\", "/");
  if (normalized.split("/").includes("..")) {
    throw new Error(`${field} cannot leave the project directory`);
  }
  return normalized;
}

async function loadProjects(projectsDir) {
  const entries = await readdir(projectsDir, { withFileTypes: true });
  const projects = [];
  const slugs = new Set();

  for (const entry of entries.filter((item) => item.isDirectory() && !item.name.startsWith("_"))) {
    const projectDir = path.join(projectsDir, entry.name);
    const manifest = JSON.parse(await readFile(path.join(projectDir, "project.json"), "utf8"));
    if (manifest.schemaVersion !== 1) throw new Error(`${entry.name}: unsupported schemaVersion`);
    if (!slugPattern.test(manifest.slug) || manifest.slug !== entry.name) {
      throw new Error(`${entry.name}: slug must match its directory`);
    }
    if (slugs.has(manifest.slug)) throw new Error(`Duplicate project slug: ${manifest.slug}`);
    slugs.add(manifest.slug);
    for (const field of ["name", "title", "description", "status", "updated"]) {
      if (typeof manifest[field] !== "string" || manifest[field].trim() === "") {
        throw new Error(`${manifest.slug}: ${field} is required`);
      }
    }
    manifest.cover = safeRelativePath(manifest.cover, `${manifest.slug}.cover`);
    if (!Array.isArray(manifest.flows) || manifest.flows.length === 0) {
      throw new Error(`${manifest.slug}: flows cannot be empty`);
    }
    const flowIds = new Set();
    for (const flow of manifest.flows) {
      if (!idPattern.test(flow.id) || flowIds.has(flow.id)) {
        throw new Error(`${manifest.slug}: invalid or duplicate flow id ${flow.id}`);
      }
      flowIds.add(flow.id);
      if (typeof flow.title !== "string" || flow.title.trim() === "") {
        throw new Error(`${manifest.slug}.${flow.id}: title is required`);
      }
      flow.file = safeRelativePath(flow.file, `${manifest.slug}.${flow.id}.file`);
      flow.spec = safeRelativePath(flow.spec, `${manifest.slug}.${flow.id}.spec`);
      if (!flow.file.endsWith(".html") || !flow.spec.endsWith(".json")) {
        throw new Error(`${manifest.slug}.${flow.id}: expected HTML file and JSON spec`);
      }
      const html = await readFile(path.join(projectDir, flow.file), "utf8");
      await readFile(path.join(projectDir, flow.spec), "utf8");
      if (!html.includes('name="generator" content="archify')) {
        throw new Error(`${manifest.slug}.${flow.id}: HTML is not an Archify delivery`);
      }
    }
    projects.push({ ...manifest, projectDir });
  }

  if (projects.length === 0) throw new Error("At least one project is required");
  return projects.sort((a, b) => a.name.localeCompare(b.name, "zh-CN"));
}

function homePage(projects) {
  const cards = projects.map((project) => `
    <article class="project-card">
      <a class="project-cover" href="${escapeHtml(project.slug)}/" aria-label="打开 ${escapeHtml(project.title)}">
        <img src="${escapeHtml(project.slug)}/${escapeHtml(project.cover)}" alt="${escapeHtml(project.title)}流程图预览">
      </a>
      <div class="project-body">
        <span class="status">${escapeHtml(project.status)}</span>
        <h2>${escapeHtml(project.title)}</h2>
        <p>${escapeHtml(project.description)}</p>
        <dl class="project-facts">
          <div><dt>${project.flows.length}</dt><dd>流程图</dd></div>
          <div><dt>${escapeHtml(project.updated)}</dt><dd>最后更新</dd></div>
        </dl>
        <a class="primary-action" href="${escapeHtml(project.slug)}/">打开项目流程</a>
      </div>
    </article>`).join("");

  return `<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>项目流程图中心</title>
  <link rel="icon" href="data:,">
  <link rel="stylesheet" href="assets/site.css">
</head>
<body class="hub-page">
  <header class="topbar">
    <a class="brand" href="./"><span class="brand-mark">PX</span><span><strong>项目流程图中心</strong><small>Project Flow Explorer</small></span></a>
    <span class="project-count">${projects.length} 个可用项目</span>
  </header>
  <main class="hub-main">
    <section class="page-heading"><h1>选择项目</h1><p>按项目进入总览、阶段流程、数据边界和重跑链路。</p></section>
    <section class="project-grid" aria-label="项目列表">${cards}</section>
  </main>
</body>
</html>`;
}

function projectPage(project) {
  const browserData = JSON.stringify({
    slug: project.slug,
    title: project.title,
    repository: project.repository || "",
    notion: project.notion || "",
    flows: project.flows.map(({ id, title, file }) => ({ id, title, file }))
  }).replaceAll("<", "\\u003c");

  return `<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${escapeHtml(project.title)} · 流程图工作台</title>
  <link rel="icon" href="data:,">
  <link rel="stylesheet" href="../assets/site.css">
</head>
<body class="project-page">
  <aside class="project-sidebar">
    <a class="back-link" href="../">← 项目列表</a>
    <div class="project-brand"><strong>${escapeHtml(project.title)}</strong><span>${escapeHtml(project.description)}</span></div>
    <nav id="flow-nav" aria-label="流程图列表"></nav>
    <div class="project-links">
      ${project.repository ? `<a href="${escapeHtml(project.repository)}" target="_blank" rel="noreferrer">代码仓库</a>` : ""}
      ${project.notion ? `<a href="${escapeHtml(project.notion)}" target="_blank" rel="noreferrer">项目文档</a>` : ""}
    </div>
  </aside>
  <main class="viewer-main">
    <header class="viewer-header">
      <div class="current-title"><strong id="current-title"></strong><span id="current-file"></span></div>
      <a id="open-current" class="secondary-action" target="_blank" rel="noreferrer">独立打开</a>
    </header>
    <section class="viewer-shell" aria-label="流程图预览"><iframe id="viewer" title="${escapeHtml(project.title)}流程图"></iframe></section>
  </main>
  <script id="project-data" type="application/json">${browserData}</script>
  <script src="../assets/project.js"></script>
</body>
</html>`;
}

export async function buildSite({ root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), ".."), outputDir } = {}) {
  const projectsDir = path.join(root, "projects");
  const distDir = outputDir || path.join(root, "dist");
  const projects = await loadProjects(projectsDir);

  await rm(distDir, { recursive: true, force: true });
  await mkdir(path.join(distDir, "assets"), { recursive: true });
  await cp(path.join(root, "src", "site.css"), path.join(distDir, "assets", "site.css"));
  await cp(path.join(root, "src", "project.js"), path.join(distDir, "assets", "project.js"));

  for (const project of projects) {
    const projectOutput = path.join(distDir, project.slug);
    await mkdir(projectOutput, { recursive: true });
    await cp(path.join(project.projectDir, project.cover), path.join(projectOutput, project.cover));
    for (const flow of project.flows) {
      const outputPath = path.join(projectOutput, flow.file);
      await mkdir(path.dirname(outputPath), { recursive: true });
      await cp(path.join(project.projectDir, flow.file), outputPath);
    }
    await writeFile(path.join(projectOutput, "index.html"), projectPage(project), "utf8");
  }

  await writeFile(path.join(distDir, "index.html"), homePage(projects), "utf8");
  await writeFile(path.join(distDir, "health.json"), `${JSON.stringify({ status: "ok", projects: projects.length })}\n`, "utf8");
  return { projects: projects.length, outputDir: distDir };
}

const entry = process.argv[1] ? pathToFileURL(path.resolve(process.argv[1])).href : "";
if (import.meta.url === entry) {
  const result = await buildSite();
  console.log(`Built ${result.projects} project(s) in ${result.outputDir}`);
}
