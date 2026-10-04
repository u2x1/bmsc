-- 使用统计表：每个匿名安装 ID 每天一行（INSERT OR IGNORE 天然按日去重）
CREATE TABLE IF NOT EXISTS pings (
  id TEXT NOT NULL,        -- 匿名安装 ID（App 端随机生成的 hex）
  day TEXT NOT NULL,       -- 心跳日期（UTC，YYYY-MM-DD）
  version TEXT NOT NULL DEFAULT '',
  platform TEXT NOT NULL DEFAULT '',
  PRIMARY KEY (id, day)
);
