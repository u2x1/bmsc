/// 本地音乐导入的纯函数工具（不依赖 Flutter，便于单元测试）。
library;

/// 清理文件名中的路径分隔符与各平台非法字符。
String sanitizeFileName(String name) {
  final cleaned =
      name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_').trim();
  return cleaned.isEmpty ? '_' : cleaned;
}

/// 在目标目录中生成不冲突的文件名：
/// `a.mp3` → 冲突时 `a_1.mp3` → `a_2.mp3` ……
/// [exists] 判断候选文件名（不含目录）是否已被占用。
String uniqueFileName(String fileName, bool Function(String candidate) exists) {
  if (!exists(fileName)) return fileName;
  final dot = fileName.lastIndexOf('.');
  final stem = dot > 0 ? fileName.substring(0, dot) : fileName;
  final ext = dot > 0 ? fileName.substring(dot) : '';
  for (var i = 1; i < 1000; i++) {
    final candidate = '${stem}_$i$ext';
    if (!exists(candidate)) return candidate;
  }
  // 极端兜底：时间戳保证唯一
  return '${stem}_${DateTime.now().millisecondsSinceEpoch}$ext';
}

/// 去掉扩展名的文件名（元数据标题缺失时的回退标题）。
String titleFromFileName(String fileName) {
  final dot = fileName.lastIndexOf('.');
  final stem = dot > 0 ? fileName.substring(0, dot) : fileName;
  return stem.isEmpty ? fileName : stem;
}

/// 按图片 MIME 推断封面文件扩展名。
String coverExtensionForMime(String mime) {
  switch (mime.toLowerCase()) {
    case 'image/jpeg':
    case 'image/jpg':
      return '.jpg';
    case 'image/png':
      return '.png';
    case 'image/gif':
      return '.gif';
    case 'image/webp':
      return '.webp';
    default:
      return '.img';
  }
}
