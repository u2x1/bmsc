/// 断点续传的响应决策（纯逻辑，便于离线测试引用）。
///
/// 带 `Range: bytes=N-` 请求后，服务器有三种回复：
/// - 206 Partial Content：支持续传，流从 N 起 → 续写
/// - 200 OK：忽略 Range 返回全量 → 必须删临时文件从头写，否则文件损坏
/// - 416 Range Not Satisfiable：本地已有全部数据 → 跳过下载直接收尾
library;

enum DownloadRangeMode {
  /// 从本地已有偏移处续写（服务器响应 206）。
  resume,

  /// 临时文件无效或不存在，从头写（200 忽略 Range，或全新下载）。
  restart,

  /// 本地临时文件已完整（416），跳过下载直接收尾。
  finalize,
}

class DownloadRangePlan {
  const DownloadRangePlan({
    required this.mode,
    required this.totalBytes,
  });

  final DownloadRangeMode mode;

  /// 文件总字节数；-1 表示服务器未提供（此时不展示进度）。
  final int totalBytes;
}

/// 计算 Range 请求的响应处理方案。
///
/// [startBytes] 本地临时文件已有的字节数（0 表示全新下载）。
/// [statusCode] 响应状态码（dio 层已保证非 2xx/416 直接抛错）。
/// [contentRange] 响应 Content-Range 头，形如 `bytes 100-999/1000`。
/// [contentLength] 响应 Content-Length 头。
DownloadRangePlan resolveDownloadRangePlan({
  required int startBytes,
  required int? statusCode,
  required String? contentRange,
  required String? contentLength,
}) {
  final total = int.tryParse(contentLength ?? '') ?? -1;

  // 416：本地已有数据覆盖整个文件（上次死在改名/落库前），直接收尾
  if (startBytes > 0 && statusCode == 416) {
    return DownloadRangePlan(
        mode: DownloadRangeMode.finalize, totalBytes: startBytes);
  }

  // 206：真正续传；总长优先取 Content-Range 尾段（比 200 时的
  // Content-Length + 偏移可靠）
  if (startBytes > 0 && statusCode == 206) {
    final fromRange = contentRange != null
        ? int.tryParse(contentRange.split('/').last)
        : null;
    return DownloadRangePlan(
      mode: DownloadRangeMode.resume,
      totalBytes: fromRange ?? total + startBytes,
    );
  }

  // 其余（200 全量、无法解析的状态码等）：临时文件作废，从头写；
  // 总长即 Content-Length（绝不能再加偏移，否则进度超 100%）
  return DownloadRangePlan(mode: DownloadRangeMode.restart, totalBytes: total);
}
