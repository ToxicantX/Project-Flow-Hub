# Project Flow Hub

`draw.wsxcant.me` 的项目流程图门户。项目和流程导航由清单生成，推送 `main` 后由 GitHub Actions 通过专用 SSH 用户原子发布。

## 本地使用

```powershell
npm test
npm run build
python -m http.server 4173 --directory dist
```

打开 `http://127.0.0.1:4173/`。

## 接入项目

项目元数据和流程清单保存在源仓库的 `diagrams/project-flow.json`。可从
`projects/_template/project-flow.json` 复制模板，并让每个流程条目指向一份已通过 Archify
验证和交付的 HTML 与 JSON 规格。项目封面也必须位于 `diagrams/` 内。

首次接入执行：

```powershell
.\scripts\onboard-project.ps1 `
  -SourceRepository E:\workspace\ComfyUIProjects\Movie-Generation
```

脚本读取源清单、导入对应产物、运行 Hub 测试和构建，并按源仓库的 Git 状态选择同步模式。
`slug`、流程 `id` 和目标文件路径必须唯一；绝对路径和越过 `diagrams/` 或项目目录的路径会被拒绝。

### 本地仓库提交后自动同步

`source.mode` 为 `local`，或源仓库还没有远端默认分支时，接入脚本会安装受管的
`post-commit` hook。只有提交包含 `diagrams/` 变化时才会触发；同步使用临时 Git worktree，
不会改写 Hub 当前工作目录。导入、测试和构建通过后才提交并推送 Hub。

同步失败不会撤销源仓库提交，但会留下 `.git/project-flow-hub-sync.failed`。修复后可重新提交，
或手动执行：

```powershell
.\scripts\sync-project.ps1 `
  -Slug movie-generation `
  -SourceDirectory E:\workspace\ComfyUIProjects\Movie-Generation\diagrams
```

### 远端仓库定时同步

当公开 GitHub 仓库已有远端默认分支时，将源清单的 `source.mode` 设为 `remote`。Hub 的
`sync-remote-projects.yml` 每 5 分钟拉取一次所有远端项目；检测到产物变化后记录来源提交和
产物哈希，测试并提交 Hub，再触发唯一的部署工作流。正常同步存在最多约 5 分钟的发现延迟。

可在 Hub 中只验证某个远端项目而不提交：

```powershell
.\scripts\sync-remote-projects.ps1 -Slug comic-generation -NoPush
```

远端链路完成一次端到端验证后，才删除该源仓库原有的本地同步 hook。

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
