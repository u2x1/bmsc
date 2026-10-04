/**
 * BMSC 后端（Cloudflare Workers）
 * 路由：
 *   POST /      应用内反馈 → 自动创建 GitHub Issue
 *   POST /ping  匿名使用统计心跳（每日一次）
 *   GET  /stats 统计面板（需 token，HTML；?format=json 返回 JSON）
 *
 * 环境变量：
 *   GITHUB_TOKEN   (secret, 反馈必填) 可在目标仓库创建 issue 的 GitHub PAT
 *   GITHUB_REPO    (var,    可选)     目标仓库，默认 u2x1/bmsc
 *   FEEDBACK_TOKEN (secret, 可选)     设置后反馈请求头 X-Feedback-Token 须匹配
 *   STATS_TOKEN    (secret, 统计必填) /stats 访问令牌（?token= 或 X-Stats-Token）
 *   DB             (D1 绑定)          统计数据库，见 schema.sql
 */

const MAX_BODY_BYTES = 100 * 1024;
const MAX_CONTENT_LEN = 4000;
const MAX_CONTACT_LEN = 200;
const MAX_LOGS_LEN = 30000;
const MAX_META_FIELD_LEN = 200;
const META_KEYS = ['version', 'buildNumber', 'platform', 'osVersion'];

export default {
  async fetch(request, env) {
    try {
      const path = new URL(request.url).pathname;
      if (path === '/ping') return await handlePing(request, env);
      if (path === '/stats') return await handleStats(request, env);
      return await handleFeedback(request, env);
    } catch (err) {
      return jsonResponse({ ok: false, error: `internal error: ${err}` }, 500);
    }
  },
};

// ---------- 使用统计 ----------

async function handlePing(request, env) {
  if (request.method !== 'POST') {
    return jsonResponse({ ok: false, error: 'method not allowed' }, 405);
  }
  let body;
  try {
    body = await request.json();
  } catch {
    return jsonResponse({ ok: false, error: 'invalid json body' }, 400);
  }
  // 匿名安装 ID 只允许 hex，防注入与垃圾数据
  const id = clampString(body.id, 64);
  if (!/^[0-9a-f]{16,64}$/.test(id)) {
    return jsonResponse({ ok: false, error: 'invalid id' }, 400);
  }
  // version/platform 会渲染进 HTML 面板，剥掉 HTML 特殊字符
  const version = clampString(body.version, 50).replace(/[<>&"']/g, '');
  const platform = clampString(body.platform, 50).replace(/[<>&"']/g, '');
  if (!env.DB) {
    return jsonResponse({ ok: false, error: 'stats not configured' }, 500);
  }
  const day = new Date().toISOString().slice(0, 10); // UTC 日
  await env.DB.prepare(
    'INSERT OR IGNORE INTO pings (id, day, version, platform) VALUES (?, ?, ?, ?)',
  )
    .bind(id, day, version, platform)
    .run();
  return jsonResponse({ ok: true });
}

async function handleStats(request, env) {
  const url = new URL(request.url);
  const token =
    url.searchParams.get('token') || request.headers.get('X-Stats-Token');
  if (!env.STATS_TOKEN || token !== env.STATS_TOKEN) {
    return jsonResponse({ ok: false, error: 'unauthorized' }, 401);
  }
  if (!env.DB) {
    return jsonResponse({ ok: false, error: 'stats not configured' }, 500);
  }
  const [total, dau, newUsers, versions, platforms] = await Promise.all([
    env.DB.prepare('SELECT COUNT(DISTINCT id) AS n FROM pings').first(),
    env.DB.prepare(
      'SELECT day, COUNT(*) AS n FROM pings GROUP BY day ORDER BY day DESC LIMIT 30',
    ).all(),
    env.DB.prepare(
      'SELECT first_day, COUNT(*) AS n FROM (SELECT MIN(day) AS first_day FROM pings GROUP BY id) GROUP BY first_day ORDER BY first_day DESC LIMIT 30',
    ).all(),
    env.DB.prepare(
      'SELECT version, COUNT(DISTINCT id) AS n FROM pings GROUP BY version ORDER BY n DESC LIMIT 20',
    ).all(),
    env.DB.prepare(
      'SELECT platform, COUNT(DISTINCT id) AS n FROM pings GROUP BY platform ORDER BY n DESC',
    ).all(),
  ]);
  const data = {
    totalUsers: total?.n ?? 0,
    dau: dau.results ?? [],
    newUsers: newUsers.results ?? [],
    versions: versions.results ?? [],
    platforms: platforms.results ?? [],
  };
  if (url.searchParams.get('format') === 'json') {
    return jsonResponse({ ok: true, ...data });
  }
  return new Response(renderStatsHtml(data), {
    headers: { 'Content-Type': 'text/html; charset=utf-8' },
  });
}

function renderStatsHtml({ totalUsers, dau, newUsers, versions, platforms }) {
  const esc = (s) =>
    String(s).replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
  const table = (title, rows, cols) => `
<h2>${title}</h2>
<table><tr>${cols.map((c) => `<th>${c}</th>`).join('')}</tr>
${rows.map((r) => `<tr>${r.map((v) => `<td>${esc(v)}</td>`).join('')}</tr>`).join('')}</table>`;
  return `<!doctype html>
<html lang="zh-CN"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>BMSC 使用统计</title>
<style>
body{font-family:system-ui,-apple-system,sans-serif;max-width:720px;margin:2rem auto;padding:0 1rem;background:#121212;color:#eee}
table{border-collapse:collapse;width:100%;margin-bottom:1rem}
th,td{border:1px solid #444;padding:6px 10px;text-align:left;font-size:14px}
th{background:#1e1e1e}
h1{font-size:1.4rem}h2{font-size:1.05rem;margin-top:2rem;color:#9ecfff}
.total{font-size:2.4rem;font-weight:700}
.total small{font-size:0.9rem;font-weight:400;color:#aaa}
</style></head><body>
<h1>BMSC 使用统计</h1>
<div class="total">${esc(totalUsers)} <small>累计用户</small></div>
${table('近 30 天日活（DAU）', dau.map((r) => [r.day, r.n]), ['日期', '活跃用户'])}
${table('近 30 天新增用户', newUsers.map((r) => [r.first_day, r.n]), ['日期', '新增用户'])}
${table('版本分布', versions.map((r) => [r.version || '(未知)', r.n]), ['版本', '用户数'])}
${table('平台分布', platforms.map((r) => [r.platform || '(未知)', r.n]), ['平台', '用户数'])}
</body></html>`;
}

// ---------- 应用内反馈 ----------

async function handleFeedback(request, env) {
  if (request.method !== 'POST') {
    return jsonResponse({ ok: false, error: 'method not allowed' }, 405);
  }

  if (env.FEEDBACK_TOKEN) {
    const token = request.headers.get('X-Feedback-Token');
    if (token !== env.FEEDBACK_TOKEN) {
      return jsonResponse({ ok: false, error: 'unauthorized' }, 401);
    }
  }

  const bodyBytes = Number(request.headers.get('content-length') || 0);
  if (bodyBytes > MAX_BODY_BYTES) {
    return jsonResponse({ ok: false, error: 'payload too large' }, 413);
  }

  let body;
  try {
    body = await request.json();
  } catch {
    return jsonResponse({ ok: false, error: 'invalid json body' }, 400);
  }

  const content = clampString(body.content, MAX_CONTENT_LEN).trim();
  if (!content) {
    return jsonResponse({ ok: false, error: 'content is required' }, 400);
  }
  const contact = clampString(body.contact, MAX_CONTACT_LEN).trim();
  const logs = sanitizeSensitive(clampString(body.logs, MAX_LOGS_LEN));
  const meta = sanitizeMeta(body.meta);

  if (!env.GITHUB_TOKEN) {
    return jsonResponse({ ok: false, error: 'server misconfigured' }, 500);
  }
  const repo = env.GITHUB_REPO || 'u2x1/bmsc';

  const issue = {
    title: buildTitle(content),
    body: buildIssueBody({ content, contact, logs, meta }),
    labels: ['app-feedback'],
  };

  let result = await createIssue(repo, issue, env.GITHUB_TOKEN);
  // 仓库缺少 app-feedback 标签时 GitHub 返回 422，去掉标签重试一次
  if (result.status === 422) {
    result = await createIssue(repo, { ...issue, labels: [] }, env.GITHUB_TOKEN);
  }
  if (result.status >= 200 && result.status < 300 && result.data?.html_url) {
    return jsonResponse({ ok: true, url: result.data.html_url });
  }
  return jsonResponse(
    { ok: false, error: `github api error (${result.status})` },
    502,
  );
}

async function createIssue(repo, issue, token) {
  const resp = await fetch(`https://api.github.com/repos/${repo}/issues`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
      // GitHub API 强制要求 User-Agent
      'User-Agent': 'bmsc-feedback-worker',
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(issue),
  });
  let data = null;
  try {
    data = await resp.json();
  } catch {
    // 非 JSON 响应（如网关错误页），仅保留状态码
  }
  return { status: resp.status, data };
}

function buildTitle(content) {
  const firstLine =
    content
      .split('\n')
      .map((l) => l.trim())
      .find((l) => l) || '问题反馈';
  const trimmed = firstLine.length > 50 ? `${firstLine.slice(0, 50)}…` : firstLine;
  return `[App反馈] ${trimmed}`;
}

function buildIssueBody({ content, contact, logs, meta }) {
  const parts = [
    '## 问题描述',
    '',
    content,
    '',
    '## 联系方式',
    '',
    contact || '未填写',
    '',
    '## 设备信息',
    '',
    '| 项目 | 值 |',
    '| --- | --- |',
    `| 应用版本 | ${meta.version || '未知'} (${meta.buildNumber || '-'}) |`,
    `| 平台 | ${meta.platform || '未知'} |`,
    `| 系统版本 | ${meta.osVersion || '未知'} |`,
  ];
  if (logs) {
    parts.push(
      '',
      '<details>',
      '<summary>应用日志</summary>',
      '',
      '```text',
      // 防止日志中的 ``` 提前闭合代码块
      logs.replace(/```/g, "'''"),
      '```',
      '',
      '</details>',
    );
  }
  parts.push('', '---', '> 此 issue 由应用内反馈通道自动创建');
  return parts.join('\n');
}

/** bilibili 凭据 / Bearer token 打码，与 App 端 FeedbackPayload.sanitize 规则一致 */
function sanitizeSensitive(text) {
  return text
    .replace(
      /(^|[^A-Za-z0-9_])((?:SESSDATA|bili_jct|DedeUserID(?:__ckMd5)?|ac_time_value|bili_ticket|access_key|access_token|refresh_token|csrf|sid)("?\s*[=:]\s*"?))[^\s;&"']+/gi,
      '$1$2***',
    )
    .replace(/(^|[^A-Za-z0-9_])(Bearer\s+)[A-Za-z0-9\-._~+/]+=*/gi, '$1$2***');
}

function sanitizeMeta(meta) {
  const out = {};
  if (!meta || typeof meta !== 'object') return out;
  for (const key of META_KEYS) {
    const value = meta[key];
    if (typeof value === 'string' && value) {
      // 防 markdown 表格注入
      out[key] = value
        .slice(0, MAX_META_FIELD_LEN)
        .replace(/[|\r\n]/g, ' ')
        .trim();
    } else if (typeof value === 'number') {
      out[key] = String(value);
    }
  }
  return out;
}

function clampString(value, max) {
  if (typeof value !== 'string') return '';
  return value.length > max ? value.slice(0, max) : value;
}

function jsonResponse(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { 'Content-Type': 'application/json; charset=utf-8' },
  });
}
