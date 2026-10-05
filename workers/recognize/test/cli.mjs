#!/usr/bin/env node
// 网易云听歌识曲 CLI 验证工具
//
// 用法: node cli.mjs <音频文件> [时长秒=3] [起始偏移秒=0]
//
// 流程: 任意音频 → ffmpeg 转 8kHz 单声道 float32 PCM → afp.wasm 算指纹
//       → GET interface.music.163.com/api/music/audio/match → 打印结果
//
// 指纹库 vendored 于 ../src/vendor/（来源见 ../README.md）

import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';

// 与 Worker 相同的实例化路径：预编译 afp.wasm，经 __AFP_OPTS.instantiateWasm 注入
const wasmModule = await WebAssembly.compile(
  readFileSync(new URL('../src/vendor/afp.wasm', import.meta.url)),
);
globalThis.__AFP_OPTS = {
  instantiateWasm(imports, successCallback) {
    WebAssembly.instantiate(wasmModule, imports).then(successCallback);
    return {};
  },
};
const require = createRequire(import.meta.url);
const { GenerateFP } = require('../src/vendor/afp.js');

const [file, durationArg, offsetArg] = process.argv.slice(2);
if (!file) {
  console.error('用法: node cli.mjs <音频文件> [时长秒=3] [起始偏移秒=0]');
  process.exit(1);
}
const duration = Number(durationArg ?? 3);
const offset = Number(offsetArg ?? 0);

// 8kHz / 单声道 / float32 原生 PCM（AFP.wasm 只接受该格式）
const raw = execFileSync('ffmpeg', [
  '-v', 'error',
  ...(offset > 0 ? ['-ss', String(offset)] : []),
  '-i', file,
  '-t', String(duration),
  '-ar', '8000', '-ac', '1', '-f', 'f32le', '-',
], { maxBuffer: 64 * 1024 * 1024 });

const pcm = new Float32Array(raw.buffer, raw.byteOffset, raw.length / 4);
console.log(`[cli] PCM: ${pcm.length} samples (${(pcm.length / 8000).toFixed(2)}s @8kHz)`);

const audioFP = await GenerateFP(pcm);
console.log(`[cli] audioFP: ${audioFP.length} chars`);

const url = 'https://interface.music.163.com/api/music/audio/match?' +
  new URLSearchParams({
    sessionId: '0123456789abcdef',
    algorithmCode: 'shazam_v2',
    duration: String(duration),
    rawdata: audioFP,
    times: '1',
    decrypt: '1',
  });

const res = await fetch(url);
const body = await res.json();

if (!body?.data?.result?.length) {
  console.log('[cli] 未识别到结果:', JSON.stringify(body).slice(0, 500));
  process.exit(2);
}
for (const item of body.data.result) {
  const s = item.song;
  console.log(
    `[识别] ${s.name} - ${s.artists?.map(a => a.name).join('/') ?? '?'} ` +
    `《${s.album?.name ?? '?'}》 (songId=${s.id}, 偏移 ${(item.startTime / 1000).toFixed(1)}s, score=${item.score ?? '?'})`,
  );
}
