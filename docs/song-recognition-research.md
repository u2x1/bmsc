# 听歌识曲能力调研

> 调研时间：2026-10。目标：评估为 BMSC 增加「听歌识曲」（识别当前播放的 B 站视频 BGM / 本地音频 / 环境音）的可行方案。

## 0. 项目现状与切入点

BMSC 已有的相关基础设施：

- **音频缓存文件可直接利用**：`LazyAudioSource`（lib/audio/lazy_audio_source.dart）播放时会把 B 站音频流（dash m4s / fMP4 AAC，moov 前置）缓存为本地文件，下载中为 `.part`。文件头部 ~1–2MB 即可被服务端 ffmpeg 解码，无需 App 本地解码。
- **本地音乐有真实文件路径**：`LocalMusicService` 导入的文件保存在沙盒内。
- **NetEase API 已接入**：`lib/api/netease/` 已实现 weapi/eapi 加解密（搜索、歌单、歌词），识曲结果可回链网易云。
- **已有 Cloudflare Worker 后端**：`workers/feedback`（bmsc-api.u2x1.work）承载反馈与匿名统计，密钥用 `wrangler secret` 管理——天然适合做识别 API 的密钥托管/转发代理，避免在开源 App 内硬编码 key。
- **隐私合规矩阵已有先例**：2.0.0 起匿名统计默认开、可关（设置 → 隐私）。识曲涉及音频片段上传第三方，需要同级的告知与开关。
- 目前无任何识曲相关代码。

两个使用场景：

| 场景 | 音频来源 | 价值 |
| --- | --- | --- |
| A. 识别当前播放 | 播放缓存文件 / 本地文件（压缩音频直接可用） | B 站用户高频需求（"BGM 是什么"），无需麦克风 |
| B. 识别环境音 | 麦克风录音（需权限） | 经典 Shazam 场景 |

## 1. 候选方案

### 1.1 ACRCloud（商业，推荐度 ★★★★★）

- 曲库 >1.5 亿首，**华语 / ACG 覆盖业内最好**（网易云、QQ 音乐的识曲均由其支撑），对"带人声/混杂音的视频 BGM"抗噪最强；另支持哼唱识别、自定义曲库 bucket。
- 接入：纯 HTTP 识别 API——`POST https://identify-{region}.acrcloud.com/v1/identify`，multipart 上传 ≤5MB 音频片段（或预计算指纹），HMAC-SHA1 签名。Flutter 用现有 dio 即可，**不需要原生 SDK**。
- Flutter 生态有非官方插件（`acr_cloud_sdk`、`flutter_acrcloud` 等），但都是麦克风录音路径，质量一般；自封装 HTTP API 更可控。
- 成本：14 天免费试用；之后付费（第三方口径约 $6/1000 次，准确价格需登录控制台查看，B2B 报价）。无永久免费档。
- 文档：https://docs.acrcloud.com/reference/identification-api/identification-api

### 1.2 AudD（商业，推荐度 ★★★★）

- 曲库 >1.6 亿首（神经网络指纹）。集成最简单：`POST https://api.audd.io/`，支持 `url=` / 文件上传 / base64，token 鉴权无签名；返回 artist/title/album/timecode，可加 `return=apple_music,spotify,deezer,musicbrainz`。
- 标准端点文件上限 10MB（分析前 ~12 秒）；超长文件/流另有 enterprise 与 streams 端点。
- 成本：注册送 300 次（总量）；之后 $5/1000 次，量大 $2/1000。个人用户自测够用，App 级分发需付费或用户自带 token。
- 文档：https://docs.audd.io/

### 1.3 ShazamKit（Apple 官方，推荐度 ★★★）

- iOS/iPadOS/macOS/tvOS/watchOS **原生免费**，识别质量顶级；自定义曲库（Custom Catalog）可端上匹配任意音频。
- 有官方 Android SDK（`com.shazam.shazamkit`），但匹配 Shazam 曲库需要 developer token——需 $99/年的 Apple Developer Program 创建 Media ID + 私钥签名。**Windows / Linux 无解**。
- Flutter 插件（`flutter_shazam_kit`、`pp_shazam_kit`）基本只包 iOS、维护弱；Android 需自写平台通道。
- 结论：可作为 iOS/macOS 端的零成本增强，不适合做唯一方案。

### 1.4 网易云音乐识曲（逆向接口，免费，推荐度 ★★★ / 风险高）

- 接口（来源：NeteaseCloudMusicApi `/audio/match` 模块 + `public/audio_match_demo`）：
  `GET https://interface.music.163.com/api/music/audio/match?sessionId=xxx&algorithmCode=shazam_v2&duration=3&rawdata=<urlencoded audioFP>&times=1&decrypt=1`
  demo 未传登录 cookie 即可用，返回歌曲列表及在原曲中的起始偏移。
- 难点在客户端指纹：**8kHz 单声道 PCM ≈3s → afp.wasm（Emscripten，接口 `ExtractQueryFP`）→ base64**。WASM 内符号显示其为网易 C++ AFPClient（FFT + PeakExtractor + AES，`hyai_1.2.0_client`）。
- **维护现状（2026-10 核实）**：
  - 原仓 Binaryify/NeteaseCloudMusicApi 2024 年因版权原因删库停更；指纹源码仓 mos9527/ncm-afp 已 404。
  - **仍在维护的 fork：`NeteaseCloudMusicApiEnhanced/api-enhanced`**（"全网最全"增强版，最近提交 2026-10-03，v4.41.0），完整保留 `module/audio_match.js` 与 `public/audio_match_demo/`（afp.js 58KB + afp.wasm.js 308KB 构建产物完好）。npm 包 `NeteaseCloudMusicApi@4.32.0` 也仍可下载到同样文件。
  - 注意：被维护的是 API 封装层；**指纹 WASM 的源码无人维护**，若网易升级算法（algorithmCode/hyai 版本变化）没有上游可修——但失效时可从网易官方 Chrome 扩展「云音乐听歌识曲」（Chrome Web Store 仍在架）重新提取。
- 接口本身被网易官方 Chrome 扩展使用，相对稳定，无需登录。
- **已实现并实测（2026-10-04）**：`workers/recognize/` 已把该链路移植为 Cloudflare Worker（App 传 8kHz PCM → Worker 内 afp.wasm 算指纹 → 网易接口），用 B 站真实视频音频验证识别正确（详见该目录 README，含 4 处 Workers 适配补丁）。PCM 重采样可用 record 插件（麦克风场景）直接产出 8kHz WAV；「当前播放」场景则需先把 m4s 解码为 PCM（移动端需平台通道 MediaCodec/AVAssetReader 或引入 ffmpeg，成本上升）。
- ⚠️ 风险：非官方接口，随时可能失效或加风控（网易识曲已知存在黑名单机制）。本项目已有 weapi/eapi 依赖，风险性质相同，识曲接口只是叠加。

### 1.5 其他免费/开源路径（不推荐做主力）

| 方案 | 问题 |
| --- | --- |
| shazamio / 逆向 Shazam API | 违反 ToS、随时被封；指纹算法需客户端实现，Flutter 无移植 |
| AcoustID + Chromaprint | 免费、社区曲库，但华语/ACG 覆盖差；Chromaprint 面向"文件级近似匹配"，麦克风/混音场景远弱于 Shazam 系 landmark 算法；指纹计算需 fpcalc（C 库）全平台 FFI 打包。适合本地文件元数据补全，不适合实时识曲 |
| 自建指纹引擎（Olaf / dejavu / audfprint / Panako） | 算法成熟（Olaf 为 C 实现可嵌入式/WASM），但曲库要自己拥有——识别任意商业音乐需千万级曲目音频，版权与存储均不现实。仅适合"匹配自有内容"（如本地库/收藏夹内匹配） |
| 多模态大模型（Gemini / Qwen-Audio） | 延迟大、成本高、非热门曲目不可靠，不适合做识曲主力 |

## 2. 推荐架构

### Phase 1：识别当前播放（核心价值，全平台）

```
播放页「识曲」按钮
  → 取 LazyAudioSource 缓存文件（或本地音乐文件）头部 ~1.5MB
  → POST 到自有 Worker（bmsc-api.u2x1.work/recognize，密钥存 wrangler secret）
  → Worker 转发 ACRCloud（优先，华语/ACG 强）或 AudD
  → 返回 曲名/歌手/专辑/timecode
  → App 内展示结果卡片，支持：B 站搜索（现有）、网易云匹配（现有 weapi）、存识曲历史（sqflite）
```

- 全程纯 HTTP + 文件切片，无原生依赖，Android/iOS/macOS/Windows/Linux 行为一致。
- 密钥模式建议双轨：默认走 Worker（配额/限流可控）；设置页允许**用户填自己的 AudD/ACRCloud key（BYOK）**——开源分发最可持续的模式（AudD 注册即送 300 次，个人够用）。
- 隐私：首次使用弹告知（音频片段将上传第三方识别服务），设置页可关；README 声明同步更新。

### Phase 2：麦克风识曲

- 加 `record` 插件录 5–10s（WAV/PCM），复用同一条 Worker 通道；iOS 加 `NSMicrophoneUsageDescription`，Android 加 `RECORD_AUDIO`（permission_handler 已在用）。
- 若 Phase 1 已完成，增量很小。

### Phase 3（可选，免费后端）：网易云识曲 ✅ 已端到端落地（麦克风路径）

- 服务端：`workers/recognize/` 已部署 `https://bmsc-recognize.u2x1.work/recognize`（含每 IP 10 次/60s 限流），真实 B 站音频实测识别正确，单次 300~500ms。
- App 侧（麦克风场景，已实现）：`lib/service/recognition_service.dart`（record 录 8kHz WAV → `lib/util/wav.dart` 校验/重采样 → 上传）+ `lib/screen/recognition_screen.dart`（录音/识别/结果回链 B 站搜索），主页 AppBar 入口，首次使用隐私告知（`recognition_consent`），Android/iOS/macOS 权限已配置。
- 待做：「识别当前播放」场景需解决压缩音频→PCM 解码（平台通道 MediaCodec/AVAssetReader，或 ffmpeg/miniaudio FFI），工作量明显增加。
- 该路径为非官方接口，须接受失效风险并在 UI 标注「实验性」。

### Phase 4（可选，体验增强）：ShazamKit 原生

- iOS/macOS 用 pp_shazam_kit 或自写通道，麦克风识曲零成本、质量最好；Android 需 $99/年开发者账号签名 token，视意愿。

## 3. 成本粗算（供决策）

以 DAU 1000、人均 1 次识曲/天计：约 3 万次/月。

- 项目方全包：AudD ≈ $60–150/月，ACRCloud 量级相当——个人开源项目难以为继。
- BYOK + Worker 限额兜底：成本可控，推荐。
- 网易云路径：免费，但有失效/风控风险。

## 4. 主要风险

1. **合规**：向第三方上传音频片段需明确用户告知与开关；README「不收集数据」声明要修订。
2. **密钥泄露**：任何内置在开源 App 里的 key 都会被薅，必须走 Worker 或 BYOK。
3. **非官方接口**（网易云、shazamio）：随时失效，有删库前科；只能做增强不能做依赖。
4. **识别率实测**：ACRCloud 与 AudD 对 B 站典型音频（带解说的游戏视频、翻唱、remix、ACG）差异需用真实样本 A/B 后再定默认后端。

## 5. 参考链接

- ACRCloud Identification API: https://docs.acrcloud.com/reference/identification-api/identification-api
- AudD API Docs: https://docs.audd.io/
- ShazamKit（含 Android）: https://developer.apple.com/shazamkit
- NeteaseCloudMusicApi `/audio/match`：`NeteaseCloudMusicApiEnhanced/api-enhanced`（活跃维护 fork，`module/audio_match.js` + `public/audio_match_demo/`）；npm 包 `NeteaseCloudMusicApi@4.32.0` 亦可获取
- AcoustID: https://acoustid.org ；Olaf: https://github.com/JorenSix/Olaf
