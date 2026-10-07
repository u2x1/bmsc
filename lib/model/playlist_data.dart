class PlaylistData {
  final String id;
  final String title;
  final String artist;
  final String artUri;
  final String audioUri;
  final String bvid;
  final int aid;
  final int cid;
  final bool multi;
  final int mid;
  final bool cached;
  final String rawTitle;
  final int duration;
  final bool dummy;

  /// dummy 占位源内部分 P 数（meta 缓存值；随机播放权重用，见
  /// AnchoredShuffleOrder.weightOfIndex）。非 dummy / 未知为 null
  final int? parts;

  /// 是否为本地音乐曲目（用户导入的设备文件，与 B 站源体系无关）
  final bool local;

  /// 本地曲目的沙盒文件绝对路径（local = true 时有效）
  final String filePath;

  /// 专辑名（本地曲目元数据；B 站源为空串）
  final String album;
  PlaylistData({
    required this.id,
    required this.title,
    required this.artist,
    required this.artUri,
    required this.audioUri,
    required this.bvid,
    required this.aid,
    required this.cid,
    required this.multi,
    required this.mid,
    required this.cached,
    required this.rawTitle,
    required this.duration,
    required this.dummy,
    this.parts,
    this.local = false,
    this.filePath = '',
    this.album = '',
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'artist': artist,
        'artUri': artUri,
        'audioUri': audioUri,
        'bvid': bvid,
        'aid': aid,
        'cid': cid,
        'multi': multi,
        'mid': mid,
        'cached': cached,
        'raw_title': rawTitle,
        'duration': duration,
        'dummy': dummy,
        'parts': parts,
        'local': local,
        'filePath': filePath,
        'album': album,
      };

  factory PlaylistData.fromJson(Map<String, dynamic> json) => PlaylistData(
        id: json['id'],
        title: json['title'],
        artist: json['artist'],
        artUri: json['artUri'],
        audioUri: json['audioUri'],
        bvid: json['bvid'],
        aid: json['aid'],
        cid: json['cid'],
        multi: json['multi'],
        mid: json['mid'],
        cached: json['cached'],
        rawTitle: json['raw_title'],
        duration: json['duration'],
        dummy: json['dummy'],
        parts: json['parts'],
        local: json['local'] ?? false,
        filePath: json['filePath'] ?? '',
        album: json['album'] ?? '',
      );
}
