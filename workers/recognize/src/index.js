// 网易云听歌识曲 Worker
//
// POST /recognize?duration=3
//   body: 8kHz 单声道 s16le PCM（duration 秒，通常 3 秒 = 48KB）
//   → afp.wasm 计算音频指纹 → 网易 /api/music/audio/match → 归一化 JSON
//
// 指纹库 vendored 于 src/vendor/（来源见 README.md）。
// 可选鉴权：wrangler secret put RECOGNIZE_TOKEN 后，请求需带 X-Token 头。

import afpWasmModule from './vendor/afp.wasm';
import afpModule from './vendor/afp.js';

// Workers 禁止运行时 WebAssembly.compile/instantiate(bytes)，wasm 只能顶层 import。
// 通过 __AFP_OPTS.instantiateWasm 让 afp.js 复用该已编译 Module（见 vendor/afp.js 补丁）。
globalThis.__AFP_OPTS = {
  instantiateWasm(imports, successCallback) {
    WebAssembly.instantiate(afpWasmModule, imports)
      .then(successCallback)
      .catch((e) => console.error('[recognize] instantiate failed:', e && e.stack || e));
    return {};
  },
};
const GenerateFP = afpModule.GenerateFP ?? afpModule.default?.GenerateFP;

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, X-Token',
};

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json; charset=utf-8', ...CORS_HEADERS },
  });
}

export default {
  async fetch(request, env) {
    if (request.method === 'OPTIONS') {
      return new Response(null, { headers: CORS_HEADERS });
    }
    const url = new URL(request.url);
    if (url.pathname === '/health') {
      return json({ ok: true });
    }
    if (url.pathname !== '/recognize' || request.method !== 'POST') {
      return json({ error: 'not found' }, 404);
    }
    if (env.RECOGNIZE_TOKEN) {
      if (request.headers.get('X-Token') !== env.RECOGNIZE_TOKEN) {
        return json({ error: 'unauthorized' }, 401);
      }
    }

    // 按客户端 IP 限流（见 wrangler.toml [[ratelimits]]）
    if (env.RATE_LIMITER) {
      const ip = request.headers.get('CF-Connecting-IP') ?? 'unknown';
      const { success } = await env.RATE_LIMITER.limit({ key: ip });
      if (!success) {
        return json({ error: 'rate limit exceeded (10 req/min per IP)' }, 429);
      }
    }

    const duration = Math.min(Math.max(Number(url.searchParams.get('duration')) || 3, 1), 15);
    const raw = new Uint8Array(await request.arrayBuffer());
    const samples = raw.length >> 1;
    if (samples < 8000 || raw.length % 2 !== 0) {
      return json({ error: 'expect s16le mono PCM @8kHz, >= 1s' }, 400);
    }

    // s16le → float32
    const pcm = new Float32Array(samples);
    const view = new DataView(raw.buffer, raw.byteOffset, raw.length);
    for (let i = 0; i < samples; i++) {
      pcm[i] = view.getInt16(i * 2, true) / 32768;
    }

    let audioFP;
    try {
      audioFP = await GenerateFP(pcm);
    } catch (e) {
      return json({ error: `fingerprint failed: ${e}` }, 500);
    }

    const api = 'https://interface.music.163.com/api/music/audio/match?' +
      new URLSearchParams({
        sessionId: '0123456789abcdef',
        algorithmCode: 'shazam_v2',
        duration: String(duration),
        rawdata: audioFP,
        times: '1',
        decrypt: '1',
      });
    let body;
    try {
      const res = await fetch(api);
      body = await res.json();
    } catch (e) {
      return json({ error: `upstream failed: ${e}` }, 502);
    }

    const result = body?.data?.result ?? [];
    return json({
      code: body?.code ?? 500,
      results: result.map((item) => ({
        songId: item.song?.id,
        name: item.song?.name,
        artists: (item.song?.artists ?? []).map((a) => a.name),
        album: item.song?.album?.name,
        startTimeMs: item.startTime,
      })),
    });
  },
};
