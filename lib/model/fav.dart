class FavResult {
  FavResult({
    required this.count,
    required this.list,
  });
  late final int count;
  late final List<Fav> list;

  FavResult.fromJson(Map<String, dynamic> json) {
    count = json['count'];
    list = List.from(json['list']).map((e) => Fav.fromJson(e)).toList();
  }
}

class Fav {
  Fav({
    required this.id,
    required this.title,
    this.favState = 0,
    required this.mediaCount,
    this.cover,
  });
  late final int id;
  late final String title;
  int favState = 0;
  late final int mediaCount;

  /// 收藏夹自身封面（列表 API 返回，通常是夹内第一个视频的封面），
  /// 用作主页网格拼贴的最后兜底
  String? cover;

  Fav.fromJson(Map<String, dynamic> json) {
    id = json['id'];
    title = json['title'];
    favState = json['fav_state'];
    mediaCount = json['media_count'];
    cover = json['cover'] as String?;
  }
}
