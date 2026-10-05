# bmsc-recognize

网易云听歌识曲转发 Worker：App 上传 8kHz 单声道 PCM，Worker 在 V8 内运行
afp.wasm 计算音频指纹，调网易识曲接口返回归一化结果。指纹与密钥均不落 App。

## 来源与致谢

- `src/vendor/afp.js`：vendored 自
  [NeteaseCloudMusicApiEnhanced/api-enhanced](https://github.com/NeteaseCloudMusicApiEnhanced/api-enhanced)
  `public/audio_match_demo/`（上游为逆向网易官方 Chrome 扩展「云音乐听歌识曲」的
  [mos9527/ncm-afp](https://github.com/mos9527/ncm-afp)，原仓已删除）。
- `src/vendor/afp.wasm`：从上游 `afp.wasm.js` 内嵌的 base64 解码出的原始
  WebAssembly 模块（Workers 禁止运行时编译 wasm，只能顶层 import 预编译模块）。
- 识曲接口：`https://interface.music.163.com/api/music/audio/match`
  （非官方，可能失效或加风控，见 docs/song-recognition-research.md）。

## vendor 补丁（适配 Cloudflare Workers，共 4 处，均以 `PATCH(bmsc)` 标注）

Workers（workerd）禁止一切运行时字符串代码生成（eval / new Function /
WebAssembly.compile(bytes)），原版 emscripten + embind 胶水依赖这些能力，需修补：

1. **模块实例化注入**：`var o = Object.create(globalThis.__AFP_OPTS ?? Object.prototype)`，
   经 `__AFP_OPTS.instantiateWasm` 复用顶层 import 的 `WebAssembly.Module`。
   必须每次原型继承出新对象——embind 类型表挂在模块实例上，共享会跨实例污染
   （UnboundTypeError）。
2. **embind `createNamedFunction`**：`new Function(...)` 改为匿名闭包
   （函数名仅用于报错信息）。
3. **embind `craftInvokerFunction`**：动态拼代码生成函数调用器改为等价闭包实现
   （参数 toWireType / 返回值 fromWireType / 析构器语义与原生成代码一致）。
4. **删除 readSync 的 `require('./afp.wasm.js')` 回退**：统一走 instantiateWasm。

以上补丁不影响 Node 运行（`test/cli.mjs` 与 Worker 共用同一条实例化路径）。

## API

```
POST /recognize?duration=3
Content-Type: application/octet-stream
（可选）X-Token: <RECOGNIZE_TOKEN>

body: 8kHz 单声道 s16le PCM，时长 1~15 秒（3 秒 = 48KB）

⚠️ duration 参数实测约束（2026-10-05，连续真实音乐矩阵验证）：
- **duration=5 是上游毒值**——任意实际时长报 5 均返回空结果；
- duration 必须与实际 PCM 时长相差 ≤~1 秒，否则同样返回空；
- 实际时长 ~7.9s 为死档（报 7/8 均空，两段内容交叉验证排除内容因素）。
- 已验证可用档位：实际 ~3.9s 报 3、~6.9s 报 6、~9.9s 报 9；实际 5.0~5.9s
  报 6（毒值 5 的重映射，距离 ≤1）。
- App 端配置：录 7 秒（实际 ~6.9s），duration 向下取整、5 重映射为 6。
  见 lib/service/recognition_service.dart `_upload`。

200 → {
  "code": 200,
  "results": [{
    "songId": 2684571841,
    "name": "八方来财（抖音热搜版）",
    "artists": ["北北昼"],
    "album": "合集",
    "startTimeMs": 37500      // 采样片段在原曲中的起始位置
  }]
}
```

`GET /health` 探活。

## 本地调试

```bash
npx wrangler dev            # 或 ../feedback/node_modules/.bin/wrangler dev
curl -X POST --data-binary @seg.pcm \
  'http://127.0.0.1:8788/recognize?duration=3'
```

## 部署

已部署：`https://bmsc-recognize.u2x1.work`（2026-10-04，`wrangler deploy`）。

注意：**`*.u2x1.work` 有泛解析记录，Custom Domain 会与之冲突（CF API 10013）**，
必须用 zone 路由（`bmsc-recognize.u2x1.work/*`, zone_name `u2x1.work`），见 wrangler.toml。

```bash
# 可选：开启简易鉴权（App 需在 X-Token 头携带相同值）
npx wrangler secret put RECOGNIZE_TOKEN
```

## 端到端验证工具

`test/cli.mjs`：不经过 Worker，直接验证 音频→指纹→网易接口 全链路：

```bash
node test/cli.mjs <任意音频文件> [时长秒=3] [起始偏移秒=0]
```

2026-10-04 实测（B 站视频 BV11eZ8Y5EVi 音频流）：偏移 60s/120s 处正确识别出
《八方来财》，开头混剪段识别出 Gangnam Style 及其 remix。
