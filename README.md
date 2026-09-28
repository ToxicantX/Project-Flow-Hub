# Project Flow Hub

项目流程图门户，项目和流程导航由清单生成。旧服务器已停用，默认使用本地 Docker 部署；GitHub Actions 保留测试和构建，远程 SSH 发布默认关闭。

## Docker 部署（推荐）

需要 Docker Desktop 启用 Linux containers。在此仓库目录执行：

```powershell
$env:FLOW_HUB_REVISION = git rev-parse HEAD
docker compose up -d --build
docker compose ps
```

打开 `http://127.0.0.1:8765/`，漫画流程图入口为 `http://127.0.0.1:8765/comic-generation/`。
漫画控制台仍在 `http://127.0.0.1:8199/`，这是两个独立应用，不需要启动 ComfyUI 来查看流程图。

- `portal`：只读 Nginx，仅绑定本机地址，不暴露到局域网。
- `sync`：启动后立即同步，然后每 300 秒复用 `sync-remote-projects.ps1 -Slug comic-generation -NoPush` 从公开 GitHub 导入漫画流程图；不更新视频项目、不推送 Git，仅在容器内维护独立 Git 比较基线，不读取本机工作树或认证信息。
- `site`：独立命名卷，保存所有已发布版本。构建与测试成功后才原子切换 `current`；无变化不重复发布，同步失败保留旧版并在下一轮重试。已有版本不会在容器启动时被镜像旧版覆盖。
- `/health.json`：当前页面版本和项目来源提交；`/sync-status.json`：同步状态、最近成功时间、漫画来源提交与产物哈希。容器健康只代表有可用页面，同步失败需查看后者及日志。

状态与日常操作：

```powershell
Invoke-RestMethod http://127.0.0.1:8765/health.json
Invoke-RestMethod http://127.0.0.1:8765/sync-status.json
docker compose logs --tail 80 sync
docker compose restart sync       # 立即重试同步（保持门户在线）
docker compose down               # 停止容器，保留发布卷
docker compose up -d              # 恢复使用
```

端口冲突时，在启动前设置 `$env:FLOW_HUB_PORT = '8766'`。本机默认网络池已满，Compose 使用
独立网段 `10.87.65.0/24`；迁移后若与现有网络冲突，通过 `FLOW_HUB_SUBNET` 指定空闲私有网段，不要清理其他项目的网络。同步间隔可通过
`FLOW_SYNC_INTERVAL_SECONDS` 设置为 30–86400 秒。Docker Desktop 需启动后才能自动恢复服务。
更新门户程序需拉取最新 Hub 代码并再次执行 `docker compose up -d --build`；流程图变化则自动同步。
初次离线启动仍能查看镜像内的版本，但无法更新远端流程图。

迁移到其他电脑时，克隆仓库并执行上面的 Docker 命令即可；要保留发布历史，需要另行备份和恢复
`project-flow-hub_site` 卷。不要运行 `docker compose down -v`，这会删除发布历史；此卷不存储小说、漫画图片或数据库。
本部署不访问原服务器，不依赖原 DNS，也不挂载 Docker socket、SSH 私钥或 `.env`。

验证 Docker 页面可复用浏览器烟测（需 `npm ci` 和 `npx playwright install chromium`）：

```powershell
$env:FLOW_HUB_BASE_URL = 'http://127.0.0.1:8765/'
npm run test:browser
Remove-Item Env:FLOW_HUB_BASE_URL
```

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

## 可选远程发布（默认关闭）

只有仓库 Actions Variable `ENABLE_REMOTE_DEPLOY=true` 时才会执行 SSH 配置、发布和公网验收。
未设置或为其他值时，仅运行测试、构建和浏览器检查，不连接已停用服务器。
恢复远程发布前必须重新验证部署主机、域名及 SSH 指纹，不复用旧机器的信任记录。

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
