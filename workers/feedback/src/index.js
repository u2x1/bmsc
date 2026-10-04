/**
 * BMSC 应用内反馈接收端（Cloudflare Workers）
 * 流程：校验请求 → 脱敏 → 组装 Issue → 调用 GitHub API 创建
 *
 * 环境变量：
 *   GITHUB_TOKEN   (secret, 必填) 可在目标仓库创建 issue 的 GitHub PAT
 *   GITHUB_REPO    (var,    可选) 目标仓库，默认 u2x1/bmsc
 *   FEEDBACK_TOKEN (secret, 可选) 设置后要求请求头 X-Feedback-Token 匹配
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
      return await handle(request, env);
    } catch (err) {
      return jsonResponse({ ok: false, error: `internal error: ${err}` }, 500);
    }
  },
};

async function handle(request, env) {
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

/** bilibili 凭据 / Bearer token 打码，与 App 端 FeedbackService.sanitize 规则一致 */
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
