/// 本地音乐曲目（用户导入的设备音频文件）。
///
/// 文件统一复制到应用沙盒 `local_music/` 目录管理（iOS 安全作用域
/// URL 与 Android file_picker 缓存路径都是临时的，必须复制；
/// 桌面平台保持一致行为）。DB 记录以内容哈希去重。
class LocalTrack {
  /// DB 自增主键
  final int id;

  /// 沙盒内的音频文件绝对路径
  final String filePath;

  /// 标题（元数据缺失时回退为去扩展名的文件名）
  final String title;

  /// 艺术家（元数据缺失时为「未知艺术家」）
  final String artist;

  /// 专辑（可能为空串）
  final String album;

  /// 时长（秒），元数据缺失为 0
  final int duration;

  /// 文件大小（字节）
  final int fileSize;

  /// 内嵌封面落盘后的绝对路径；无封面为 null
  final String? coverPath;

  /// 导入时间（毫秒时间戳）
  final int createdAt;

  const LocalTrack({
    required this.id,
    required this.filePath,
    required this.title,
    required this.artist,
    required this.album,
    required this.duration,
    required this.fileSize,
    this.coverPath,
    required this.createdAt,
  });

  Map<String, dynamic> toDbJson() => {
        'id': id,
        'filePath': filePath,
        'title': title,
        'artist': artist,
        'album': album,
        'duration': duration,
        'fileSize': fileSize,
        'coverPath': coverPath,
        'createdAt': createdAt,
      };

  factory LocalTrack.fromJson(Map<String, dynamic> json) => LocalTrack(
        id: json['id'] as int,
        filePath: json['filePath'] as String,
        title: json['title'] as String,
        artist: json['artist'] as String? ?? '',
        album: json['album'] as String? ?? '',
        duration: json['duration'] as int? ?? 0,
        fileSize: json['fileSize'] as int? ?? 0,
        coverPath: json['coverPath'] as String?,
        createdAt: json['createdAt'] as int? ?? 0,
      );

  @override
  String toString() => 'LocalTrack($id, $title - $artist, $filePath)';
}
