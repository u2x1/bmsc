# BMSC API 测试套件

系统性地验证 B 站 API 层的可用性，分两层：

## 1. 单元测试（离线、确定性、常跑）

不触发任何网络请求，验证签名算法、模型解析、认证层行为。

```bash
dart test test/unit          # 或 flutter test test/unit
```

| 文件 | 覆盖 |
|---|---|
| `bili_sign_test.dart` | TV / Android-HD / Android playurl 三套签名算法（含 Python 复算的参考向量）、percent-encode（对齐 Java URLEncoder）、buvid/deviceId 身份格式、login_session_id |
| `crypto_test.dart` | WBI mixin key 置换表（参考向量）、RSA 密码/设备凭据加密、CSRF 提取 |
| `login_model_test.dart` | 登录响应解析（Set-Cookie + body cookie_info 合并、status=2 风控、-105 重验证、TV poll 外层 code 兜底）、风控/重验证 URL 解析、极验/腾讯验证码结构 |
| `auth_layer_test.dart` | CookieJar 注入与拼装（含"不再携带伪造设备头"断言）、_callAPI 错误路径（412 明确抛错 / 5xx / 非 JSON / data 缺失 / callback 异常 → null 不崩溃）、TV 二维码生成/轮询解析、App playurl -101 失效处理 |
| `feedback_test.dart` | 反馈通道 payload 组装：bilibili 凭据/Bearer token 脱敏、日志尾部截断、content trim 与空字段省略、meta 字段 |
| `changelog_test.dart` | changelog.md 解析：版本分节顺序、多行条目合并、空行剔除、空输入 |

## 2. 集成测试（真实接口、live tag、默认跳过）

对真实 passport/api 接口做**只读**冒烟验证（不发短信、不写数据），跑在真实网络上。

**日常用法（推荐，人工操作最少）：**

```bash
flutter test/test/run_live.sh
```

- **首次**：自动进入扫码模式，终端打印二维码，用哔哩哔哩手机 App 扫一次
- **之后**（SESSDATA 约 180 天有效）：缓存登录态自动复用，**全自动**，无需任何人工介入
- 登录态缓存在 `test/credentials/live_session.json`（已在 .gitignore，含敏感凭据勿提交）
- 扫码登录同时获得 access_token → App playurl 等高画质接口测试自动启用

**高级用法：**

| 环境变量 | 作用 |
|---|---|
| `BMSC_LIVE=1` | 启用 live 测试（不设则全部 skip） |
| `BMSC_LOGIN=1` | 强制走扫码登录（换账号 / 缓存被删） |
| `BMSC_COOKIE="SESSDATA=...; bili_jct=..."` | 手动提供 cookie（CI 或特殊场景，优先级高于缓存文件） |

```bash
BMSC_LIVE=1 flutter test test/integration          # 未登录态
BMSC_LIVE=1 BMSC_COOKIE="..." flutter test test/integration
```

> CI（无终端）自动降级：不扫码、登录态用例记录行为；设 `BMSC_COOKIE` 可跑完整登录态。

覆盖：WBI key 拉取、极验参数结构、TV/Web 二维码生成与轮询、排行榜→详情→分P→UP 主互证、热搜、安全中心预捕获、登录态接口（myinfo/历史/动态/收藏夹）、App playurl。

**注意**：
- 会真实请求 B 站，注意**频率限制与 IP 风控（412）**，不要高频重复跑
- 测试为只读设计；**不要**在测试中添加会写数据的接口（点赞/收藏/发信等）
- 未登录时登录态接口测试自动降级为"记录行为"（不判失败）

## 判定标准（单元测试的断言哲学）

- 签名类：与**参考向量**（Python 复算 BiliPai/Kotlin 算法）逐字节比对，杜绝"自证"
- 健壮性类：B 站任何接口结构变化 → 返回 `null` / 明确异常，**绝不崩溃**
- 认证层：CookieJar 自动注入完整 cookie 组；**伪造设备头（env/app-key/x-bili-aurora-*）不得再出现**

## 工程约束

- 测试不依赖 Flutter binding / 数据库 / 真实 SharedPreferences（`setMockInitialValues` 内存化）
- `BilibiliAPI(enableConnectivity: false)` 跳过 connectivity 插件初始化
- 网络请求一律走 `FakeHttpAdapter`（`test/helpers/fake_http_adapter.dart`）或标记 `@Tags(['live'])`

## 常用命令

```bash
dart test                            # 全部（默认跳过 live）
dart test test/unit/bili_sign_test.dart   # 单个文件
dart test --chain-stack-traces       # 出错时显示完整调用链
dart test --reporter expanded        # 展开输出
```