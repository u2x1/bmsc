class PlayStat {
  final String bvid;
  final int lastPlayed;
  final int totalPlayTime;
  final int playCount;

  /// 最近播放的分 P（cid）——「最近在听」点击时定位续播用；
  /// 旧数据/未知时为 null（从 P1 开始）
  final int? lastCid;

  // Optional fields from meta table join
  final String? title;
  final String? artist;
  final String? artUri;
  final int? duration;

  /// 本地音乐曲目的沙盒文件路径（bvid 为 `local_<id>` 时由
  /// local_music 联查得到）；非本地曲目为 null
  final String? localFilePath;

  PlayStat({
    required this.bvid,
    required this.lastPlayed,
    required this.totalPlayTime,
    required this.playCount,
    this.lastCid,
    this.title,
    this.artist,
    this.artUri,
    this.duration,
    this.localFilePath,
  });

  /// 是否为本地音乐曲目（play_stat.bvid 以 `local_` 前缀存储）
  bool get isLocal => localFilePath != null || bvid.startsWith('local_');

  factory PlayStat.fromJson(Map<String, dynamic> json) {
    return PlayStat(
      bvid: json['bvid'] as String,
      lastPlayed: json['last_played'] as int,
      totalPlayTime: json['total_play_time'] as int,
      playCount: json['play_count'] as int,
      lastCid: json['last_cid'] as int?,
      title: json['title'] as String?,
      artist: json['artist'] as String?,
      artUri: json['artUri'] as String?,
      duration: json['duration'] as int?,
      localFilePath: json['local_file'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'bvid': bvid,
      'last_played': lastPlayed,
      'total_play_time': totalPlayTime,
      'play_count': playCount,
      // Only include the meta fields if they're not null
      if (title != null) 'title': title,
      if (artist != null) 'artist': artist,
      if (artUri != null) 'artUri': artUri,
      if (duration != null) 'duration': duration,
    };
  }

  Map<String, dynamic> toDbJson() {
    return {
      'bvid': bvid,
      'last_played': lastPlayed,
      'total_play_time': totalPlayTime,
      'play_count': playCount,
      if (lastCid != null) 'last_cid': lastCid,
    };
  }

  @override
  String toString() {
    return 'PlayStat{bvid: $bvid, title: $title, playCount: $playCount, lastPlayed: $lastPlayed}';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is PlayStat && other.bvid == bvid;
  }

  @override
  int get hashCode => bvid.hashCode;
}
