class HistoryResult {
  HistoryResult({
    required this.cursor,
    required this.tab,
    required this.list,
  });
  late final Cursor cursor;
  late final List<Tab> tab;
  late final List<HistoryData> list;

  HistoryResult.fromJson(Map<String, dynamic> json) {
    cursor = Cursor.fromJson(json['cursor']);
    tab = (json['tab'] as List?)?.map((e) => Tab.fromJson(e)).toList() ?? [];
    list = (json['list'] as List?)
            ?.map((e) => HistoryData.fromJson(e as Map<String, dynamic>))
            .toList() ??
        [];
  }
}

class Cursor {
  Cursor({
    required this.max,
    required this.viewAt,
    required this.business,
    required this.ps,
  });
  late final int max;
  late final int viewAt;
  late final String business;
  late final int ps;

  Cursor.fromJson(Map<String, dynamic> json) {
    max = json['max'];
    viewAt = json['view_at'];
    business = json['business'];
    ps = json['ps'];
  }
}

class Tab {
  Tab({
    required this.type,
    required this.name,
  });
  late final String type;
  late final String name;

  Tab.fromJson(Map<String, dynamic> json) {
    type = json['type'];
    name = json['name'];
  }
}

class HistoryData {
  HistoryData({
    required this.title,
    required this.longTitle,
    required this.cover,
    required this.uri,
    required this.history,
    required this.videos,
    required this.authorName,
    required this.authorFace,
    required this.authorMid,
    required this.viewAt,
    required this.progress,
    required this.badge,
    required this.showTitle,
    required this.duration,
    required this.current,
    required this.total,
    required this.newDesc,
    required this.isFinish,
    required this.isFav,
    required this.kid,
    required this.tagName,
    required this.liveStatus,
  });
  late final String title;
  late final String longTitle;
  late final String cover;
  late final String uri;
  late final History history;
  late final int videos;
  late final String authorName;
  late final String authorFace;
  late final int authorMid;
  late final int viewAt;
  late final int progress;
  late final String badge;
  late final String showTitle;
  late final int duration;
  late final String current;
  late final int total;
  late final String newDesc;
  late final int isFinish;
  late final int isFav;
  late final int kid;
  late final String tagName;
  late final int liveStatus;

  HistoryData.fromJson(Map<String, dynamic> json) {
    title = json['title'] ?? '';
    longTitle = json['long_title'] ?? '';
    cover = json['cover'] ?? '';
    uri = json['uri'] ?? '';
    history = json['history'] != null
        ? History.fromJson(json['history'])
        : History(
            oid: 0,
            epid: 0,
            bvid: '',
            page: 0,
            cid: 0,
            part: '',
            business: '',
            dt: 0);
    videos = json['videos'] ?? 0;
    authorName = json['author_name'] ?? '';
    authorFace = json['author_face'] ?? '';
    authorMid = json['author_mid'] ?? 0;
    viewAt = json['view_at'] ?? 0;
    progress = json['progress'] ?? 0;
    badge = json['badge'] ?? '';
    showTitle = json['show_title'] ?? '';
    duration = json['duration'] ?? 0;
    current = json['current'] ?? '';
    total = json['total'] ?? 0;
    newDesc = json['new_desc'] ?? '';
    isFinish = json['is_finish'] ?? 0;
    isFav = json['is_fav'] ?? 0;
    kid = json['kid'] ?? 0;
    tagName = json['tag_name'] ?? '';
    liveStatus = json['live_status'] ?? 0;
  }
}

class History {
  History({
    required this.oid,
    required this.epid,
    required this.bvid,
    required this.page,
    required this.cid,
    required this.part,
    required this.business,
    required this.dt,
  });
  late final int oid;
  late final int epid;
  late final String bvid;
  late final int page;
  late final int cid;
  late final String part;
  late final String business;
  late final int dt;

  History.fromJson(Map<String, dynamic> json) {
    oid = json['oid'];
    epid = json['epid'];
    bvid = json['bvid'];
    page = json['page'];
    cid = json['cid'];
    part = json['part'];
    business = json['business'];
    dt = json['dt'];
  }
}
