# Project Flow Hub

`draw.wsxcant.me` 的项目流程图门户。项目和流程导航由清单生成，推送 `main` 后由 GitHub Actions 通过专用 SSH 用户原子发布。

## 本地使用

```powershell
npm test
npm run build
python -m http.server 4173 --directory dist
```

打开 `http://127.0.0.1:4173/`。

## 添加项目

1. 在 `projects/<slug>/project.json` 新建项目清单。
2. 将 Archify 已交付的 HTML 和对应 JSON 规格放入 `projects/<slug>/flows/`。
3. 设置一张项目封面；可以使用 Archify `visual-check` 产生的截图。
4. 运行 `npm test` 和 `npm run build`。
5. 提交并推送 `main`，GitHub Actions 自动发布。

项目清单中的 `slug`、流程 `id` 必须唯一。流程文件必须位于本项目目录，构建器拒绝绝对路径和 `..` 路径。

## 同步已有 Archify 项目

先维护目标项目的 `project.json`，然后执行：

```powershell
.\scripts\import-archify.ps1 `
  -Slug movie-generation `
  -SourceDirectory E:\workspace\ComfyUIProjects\Movie-Generation\diagrams `
  -CoverSource 00-full-pipeline-overview.visual-check.1440x900.dark.png
```

脚本只复制清单列出的 HTML、JSON 规格和封面，不修改源项目。

### 本地仓库提交后自动同步

源仓库尚未接入 GitHub Actions 时，可以安装本地 `post-commit` hook：

```powershell
.\scripts\install-local-hook.ps1 `
  -SourceRepository E:\workspace\ComfyUIProjects\Movie-Generation `
  -Slug movie-generation `
  -CoverSource 00-full-pipeline-overview.visual-check.1440x900.dark.png
```

只有提交包含 `diagrams/` 变化时才会触发。同步过程使用临时 Git worktree，不修改 Hub 的当前工作目录；导入、测试和构建通过后才提交并推送 Hub，随后触发正式站点自动发布。

同步失败不会撤销已经完成的源仓库提交，但会留下 `.git/project-flow-hub-sync.failed`，并在提交输出中报告错误；修复后可重新提交，或手动执行 `sync-project.ps1`。

当源仓库已有远端默认分支后，建议迁移为 GitHub 跨仓库触发。迁移前保留本地 hook，避免流程图更新漏同步。

## 自动发布

GitHub 仓库需要以下 Actions Secrets：

- `DEPLOY_HOST`
- `DEPLOY_USER`
- `DEPLOY_SSH_KEY`
- `DEPLOY_KNOWN_HOSTS`

工作流将 `dist/` 上传到服务器的独立 release 目录，通过软链接切换版本，并在切换后检查 `/health.json`。构建、上传或健康检查失败时不会把未验证目录保留为线上版本。

SSH 私钥只保存在 GitHub Actions Secrets；仓库和 Notion 中不保存凭据。

服务器首次接入时，由管理员生成独立部署密钥并执行一次：

```bash
sudo bash scripts/bootstrap-server.sh /tmp/project-flow-hub.pub
```

脚本创建低权限 `flowdeploy` 用户与 `/var/www/draw.wsxcant.me/managed`，并让现有 `current` 通过受控的二级软链接继续指向当前版本。它不会把 root SSH 私钥交给 GitHub。
