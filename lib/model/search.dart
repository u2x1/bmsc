class SearchResult {
  SearchResult({
    required this.seid,
    required this.page,
    required this.pagesize,
    required this.numResults,
    required this.numPages,
    required this.suggestKeyword,
    required this.rqtType,
    required this.eggHit,
    required this.result,
    required this.showColumn,
  });
  late final String seid;
  late final int page;
  late final int pagesize;
  late final int numResults;
  late final int numPages;
  late final String suggestKeyword;
  late final String rqtType;
  late final int eggHit;
  late final List<Result> result;
  late final int showColumn;

  SearchResult.fromJson(Map<String, dynamic> json) {
    seid = json['seid'];
    page = json['page'];
    pagesize = json['pagesize'];
    numResults = json['numResults'];
    numPages = json['numPages'];
    suggestKeyword = json['suggest_keyword'];
    rqtType = json['rqt_type'];
    eggHit = json['egg_hit'];
    // 只取视频条目，单条解析失败跳过：综合搜索（search/all）的视频块里
    // 会混入直播间（type=live_room，play 等字段为 null），原先一条解析
    // 失败整页报「加载失败」——搜单字母、正在直播的 UP 主名等关键词
    // 必现（#23）
    result = [
      for (final e in (json['result'] as List<dynamic>?) ?? const [])
        if (e is Map<String, dynamic> &&
            (e['type'] == null || e['type'] == 'video'))
          Result.tryParse(e),
    ].whereType<Result>().toList();
    showColumn = json['show_column'];
  }
}

class Result {
  Result({
    required this.author,
    required this.mid,
    required this.typeid,
    required this.typename,
    required this.aid,
    required this.bvid,
    required this.title,
    required this.pic,
    required this.play,
    required this.duration,
  });
  late final String author;
  late final int mid;
  late final String typeid;
  late final String typename;
  late final int aid;
  late final String bvid;
  late final String title;
  late final String pic;
  late final int play;
  late final String duration;

  static Result? tryParse(Map<String, dynamic> json) {
    try {
      return Result.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  Result.fromJson(Map<String, dynamic> json) {
    author = json['author'];
    mid = json['mid'];
    typeid = json['typeid'];
    typename = json['typename'];
    aid = json['aid'];
    bvid = json['bvid'];
    title = json['title'];
    pic = json['pic'];
    play = json['play'];
    duration = json['duration'];
  }
}
