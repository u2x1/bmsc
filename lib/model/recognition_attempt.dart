/// 听歌识曲数据模型（纯 Dart，无 Flutter/插件依赖，可单测）。
library;

/// 单条识曲结果（workers/recognize 返回格式）
class RecognizedSong {
  final int? songId;
  final String name;
  final List<String> artists;
  final String? album;

  /// 采样片段在原曲中的起始位置（毫秒）
  final int startTimeMs;

  const RecognizedSong({
    this.songId,
    required this.name,
    required this.artists,
    this.album,
    required this.startTimeMs,
  });

  factory RecognizedSong.fromJson(Map<String, dynamic> json) => RecognizedSong(
        songId: json['songId'] as int?,
        name: json['name'] as String? ?? '',
        artists:
            (json['artists'] as List?)?.map((e) => e.toString()).toList() ??
                const [],
        album: json['album'] as String?,
        startTimeMs: json['startTimeMs'] as int? ?? 0,
      );

  Map<String, dynamic> toJson() => {
        if (songId != null) 'songId': songId,
        'name': name,
        'artists': artists,
        if (album != null) 'album': album,
        'startTimeMs': startTimeMs,
      };

  String get artistText => artists.isEmpty ? '未知歌手' : artists.join('/');
  String get searchKeyword => '$name $artistText';
}

enum RecognitionStatus { ok, noMatch, silent, error }

/// 一次识别尝试的结果（stopAndRecognize 返回；不再以异常表达业务失败）
class RecognitionOutcome {
  final RecognitionStatus status;
  final List<RecognizedSong> songs;

  /// silent / error 时的用户可读说明
  final String? message;

  /// 16kHz 试听片段完整路径（写入失败为 null）
  final String? clipPath;

  final double durationSec;

  const RecognitionOutcome({
    required this.status,
    this.songs = const [],
    this.message,
    this.clipPath,
    this.durationSec = 0,
  });

  RecognitionAttempt toAttempt(int at) => RecognitionAttempt(
        at: at,
        status: status,
        songs: songs,
        message: message,
        clip: clipPath?.split('/').last,
        durSec: durationSec,
      );
}

/// 识别历史条目（成功/未中/静音/失败均入史，附 16kHz 试听片段）
class RecognitionAttempt {
  /// 毫秒时间戳（兼作删除键）
  final int at;
  final RecognitionStatus status;
  final List<RecognizedSong> songs;
  final String? message;

  /// 片段文件名（documents/recognition_clips/ 下；旧条目或写入失败为 null）
  final String? clip;
  final double durSec;

  const RecognitionAttempt({
    required this.at,
    required this.status,
    this.songs = const [],
    this.message,
    this.clip,
    this.durSec = 0,
  });

  Map<String, dynamic> toJson() => {
        'at': at,
        'status': status.name,
        'songs': songs.map((s) => s.toJson()).toList(),
        if (message != null) 'message': message,
        if (clip != null) 'clip': clip,
        'durSec': durSec,
      };

  /// 兼容旧格式（{name, artists, album, startTimeMs, songId, at} 单曲成功条目）
  factory RecognitionAttempt.fromStoredJson(Map<String, dynamic> json) {
    if (json['status'] == null) {
      return RecognitionAttempt(
        at: json['at'] as int? ?? 0,
        status: RecognitionStatus.ok,
        songs: [RecognizedSong.fromJson(json)],
      );
    }
    return RecognitionAttempt(
      at: json['at'] as int? ?? 0,
      status: RecognitionStatus.values.asNameMap()[json['status']] ??
          RecognitionStatus.error,
      songs: ((json['songs'] as List?) ?? const [])
          .map((e) => RecognizedSong.fromJson(
              (e as Map).map((k, v) => MapEntry(k.toString(), v))))
          .toList(),
      message: json['message'] as String?,
      clip: json['clip'] as String?,
      durSec: (json['durSec'] as num?)?.toDouble() ?? 0,
    );
  }

  String get statusTitle => switch (status) {
        RecognitionStatus.ok => songs.isEmpty ? '识别成功' : songs.first.name,
        RecognitionStatus.noMatch => '未识别到歌曲',
        RecognitionStatus.silent => '录音为静音',
        RecognitionStatus.error => '识别失败',
      };
}
