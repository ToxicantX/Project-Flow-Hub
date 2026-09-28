# 本地 Docker 部署验收

## 范围

旧服务器已停用，部署目标改为本地 Docker。仅新增 Project-Flow-Hub 门户与漫画流程图同步服务，
不迁移、清空或修改漫画小说、媒体和 PostgreSQL；不调整视频项目服务。
原服务器的 DNS、SSH 和公网验收不再是此阶段完成条件，历史记录保留。

## 入口与持久化

- 门户：`http://127.0.0.1:8765/`
- 漫画流程图：`http://127.0.0.1:8765/comic-generation/`
- 漫画控制台：`http://127.0.0.1:8199/`，现有独立容器保持运行。
- 发布卷：`project-flow-hub_site`，保存版本及当前软链接；门户只读挂载。
- 默认独立网段：`10.87.65.0/24`，避开本机已耗尽的默认网络池和现有路由。

## 已验证结果

1. Windows `npm test`：11 项通过；4 项 Linux 原子目录软链接测试明确跳过。
2. Linux 镜像构建与容器内 `npm test`：15/15 通过，无跳过。
3. `npm run build`：通过，保留两个项目；同步仅选择 `comic-generation`。
4. `docker compose up -d --wait`：门户和同步容器健康，端口仅绑定 `127.0.0.1`。
5. 实际同步从公开 GitHub 克隆漫画 `main`，来源提交为
   `0fa6dc542c235ccc92f95c1d9322497b61269599`，与源仓库 `git ls-remote` 一致；产物哈希为
   `b5d844a67b046af9605a42342165c173fa55cab1e2514d81a2e4c35a947296b8`。
6. `FLOW_HUB_BASE_URL=http://127.0.0.1:8765/ npm run test:browser`：现有所有项目/流程导航通过，
   包含 PC 1440×900 和现有移动烟测；本次业务验收以 PC 为准。
7. 独立 Playwright 会话验证漫画页、故事章节聚焦与主题切换；浏览器错误和警告均为 0。
   本地截图位于 `output/playwright/docker-comic-desktop.png` 与 `docker-comic-dark-desktop.png`。
8. 实际故障注入：暂停同步服务，在一次性容器设置不可达代理，让真实 Git 克隆失败。
   验证 `current` 不变、保留最近成功时间、状态显示错误；漫画页面继续返回 HTTP 200。
   恢复同步服务后状态回到 `ok`，无变化不发布。
9. 重启两个服务后自动恢复同步；发布标识保持一致，来源与 HTTP 页面仍可验证。
10. `/comic-generation` 重定向为相对路径 `/comic-generation/`，不再跳到容器内部 `8080` 端口。

## 运维边界

Docker Desktop 必须运行；远端同步依赖公开 GitHub 网络，断网时只能查看已发布版本。
所有发布版本保留在卷中，长期运行应关注磁盘使用，不自动删除历史。
迁移仅查看最新流程时可重新克隆构建；保留发布历史需另外备份卷。
`docker compose down` 保留卷，禁止误用 `down -v`。
旧 SSH 发布仅在 Actions Variable `ENABLE_REMOTE_DEPLOY=true` 时执行，默认只测试和构建。
不将私钥、Token、API Key 或本机 Git 凭据挂载到容器或写入仓库。
