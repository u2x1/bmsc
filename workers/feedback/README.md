# BMSC 后端（Cloudflare Workers）

两个功能：

1. **应用内反馈**（`POST /`）：接收 App 反馈表单，自动在 GitHub 仓库创建
   Issue。GitHub PAT 只保存在 Worker 密钥中，不随 App 分发，用户无需
   GitHub 账号即可反馈。
2. **匿名使用统计**（`POST /ping` + `GET /stats`）：接收 App 每日心跳
   （匿名 ID + 版本 + 平台），存入 D1；`/stats` 提供带 token 的数据面板。

## 当前部署

- 生产端点：`https://bmsc-api.u2x1.work`（自定义域名；`*.workers.dev` 在国内
  被 DNS 污染不可达，故 `wrangler.toml` 中 `workers_dev = false`）
- 目标仓库：`u2x1/bmsc`，Issue 带 `app-feedback` 标签（标签不存在时自动降级无标签）
- 统计面板：`https://bmsc-api.u2x1.work/stats?token=<STATS_TOKEN>`
  （JSON：`&format=json`）；数据在 D1 `bmsc-stats` 库 `pings` 表

## 部署

```bash
cd workers/feedback

# 1. 登录 Cloudflare（首次）
npx wrangler login

# 2. 设置 GitHub PAT（必填）
#    可用 fine-grained PAT：仅授权目标仓库的 Issues: Read and write
npx wrangler secret put GITHUB_TOKEN

# 3. 设置统计面板访问令牌（统计功能必填）
openssl rand -hex 24 | npx wrangler secret put STATS_TOKEN

# 4. 创建统计数据库并建表
npx wrangler d1 create bmsc-stats   # 输出 database_id，填入 wrangler.toml
npx wrangler d1 execute bmsc-stats --remote --file=schema.sql

# 5. （可选）设置反馈防滥用令牌，App 需携带相同值
npx wrangler secret put FEEDBACK_TOKEN

# 6. 部署
npx wrangler deploy
```

部署成功后 wrangler 会输出 Worker URL（形如
`https://bmsc-feedback.<account>.workers.dev`），将其配置到 App：

- 直接改 `lib/service/feedback_service.dart` 中 `endpoint` 的默认值，或
- 构建时注入：`flutter build --dart-define=FEEDBACK_ENDPOINT=<URL>`
  （若设置了 FEEDBACK_TOKEN，同样用 `--dart-define=FEEDBACK_TOKEN=...` 注入）

## 使用统计协议

`POST /ping`：

```json
{ "id": "32位hex匿名安装ID", "version": "2.0.0", "platform": "android" }
```

- `id` 仅接受 16..64 位 hex；每天每 ID 一行（`INSERT OR IGNORE` 按 UTC 日去重）
- 不记录 IP；version/platform 剥除 HTML 特殊字符后入库（面板渲染安全）
- `GET /stats` 需 `STATS_TOKEN`（query `?token=` 或头 `X-Stats-Token`），
  返回深色 HTML 面板：累计用户、近 30 天 DAU/新增、版本分布、平台分布

## 协议

`POST <endpoint>`，`Content-Type: application/json`：

```json
{
  "content": "问题描述（必填，≤4000 字符）",
  "contact": "联系方式（可选，≤200 字符）",
  "logs": "应用日志（可选，≤30000 字符，两端均会做凭据脱敏）",
  "meta": {
    "version": "1.20.0",
    "buildNumber": "1",
    "platform": "android",
    "osVersion": "..."
  }
}
```

- 响应：`{"ok": true, "url": "<issue 链接>"}`；失败 `{"ok": false, "error": "..."}`
- 若设置了 `FEEDBACK_TOKEN`，请求需携带 `X-Feedback-Token` 头
- 创建的 Issue 带 `app-feedback` 标签；仓库没有该标签时自动降级为无标签
- 本地调试：`npx wrangler dev`

## 可选加固（未实现，按需补充）

- 基于 Cloudflare KV / Rate Limiting 绑定做按 IP 限流
- 接入 Turnstile 人机验证（需 App 端配合）
