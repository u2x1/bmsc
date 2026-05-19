class DynamicResult {
  late final bool hasMore;
  late final List<DataItem> items;
  late final String offset;
  late final String updateBaseline;
  late final int updateNum;

  DynamicResult({
    required this.hasMore,
    required this.items,
    required this.offset,
    required this.updateBaseline,
    required this.updateNum,
  });

  DynamicResult.fromJson(Map<String, dynamic> json) {
    final rawItems = (json['items'] as List?) ?? [];
    items = rawItems
        .map((e) {
          try {
            return DataItem.fromJson(e as Map<String, dynamic>);
          } catch (_) {
            return null;
          }
        })
        .whereType<DataItem>()
        .toList();
    hasMore = json['has_more'] ?? false;
    offset = json['offset'] as String? ?? '';
    updateBaseline = json['update_baseline'] as String? ?? '';
    updateNum = json['update_num'] as int? ?? 0;
  }
}

class DataItem {
  late final Modules modules;
  late final bool visible;

  DataItem({
    required this.modules,
    required this.visible,
  });

  DataItem.fromJson(Map<String, dynamic> json) {
    modules = Modules.fromJson(json['modules']);
    visible = json['visible'];
  }
}

class Modules {
  late final ModuleAuthor moduleAuthor;
  late final ModuleDynamic moduleDynamic;
  late final ModuleStat moduleStat;

  Modules({
    required this.moduleAuthor,
    required this.moduleDynamic,
    required this.moduleStat,
  });

  Modules.fromJson(Map<String, dynamic> json) {
    moduleAuthor = ModuleAuthor.fromJson(json['module_author']);
    moduleDynamic = ModuleDynamic.fromJson(json['module_dynamic']);
    moduleStat = ModuleStat.fromJson(json['module_stat']);
  }
}

class ModuleAuthor {
  late final String face;
  late final int mid;
  late final String name;
  late final String pubTime;
  late final int pubTs;

  ModuleAuthor({
    required this.face,
    required this.mid,
    required this.name,
    required this.pubTime,
    required this.pubTs,
  });

  ModuleAuthor.fromJson(Map<String, dynamic> json) {
    face = json['face'];
    mid = json['mid'];
    name = json['name'];
    pubTime = json['pub_time'];
    pubTs = json['pub_ts'];
  }
}

class ModuleDynamic {
  late final DynamicData major;

  ModuleDynamic({
    required this.major,
  });

  ModuleDynamic.fromJson(Map<String, dynamic> json) {
    major = DynamicData.fromJson(json['major']);
  }
}

class DynamicData {
  late final Archive? archive;

  DynamicData({
    this.archive,
  });

  DynamicData.fromJson(Map<String, dynamic> json) {
    archive =
        json['archive'] != null ? Archive.fromJson(json['archive']) : null;
  }
}

class Archive {
  late final String aid;
  late final String bvid;
  late final String cover;
  late final String desc;
  late final int disablePreview;
  late final String durationText;
  late final Stat stat;
  late final String title;
  late final int type;

  Archive({
    required this.aid,
    required this.bvid,
    required this.cover,
    required this.desc,
    required this.disablePreview,
    required this.durationText,
    required this.stat,
    required this.title,
    required this.type,
  });

  Archive.fromJson(Map<String, dynamic> json) {
    aid = json['aid'];
    bvid = json['bvid'];
    cover = json['cover'];
    desc = json['desc'];
    disablePreview = json['disable_preview'];
    durationText = json['duration_text'];
    stat = Stat.fromJson(json['stat']);
    title = json['title'];
    type = json['type'];
  }
}

class Stat {
  late final String danmaku;
  late final String play;

  Stat({
    required this.danmaku,
    required this.play,
  });

  Stat.fromJson(Map<String, dynamic> json) {
    danmaku = json['danmaku'];
    play = json['play'];
  }
}

class ModuleStat {
  late final Comment comment;
  late final Comment forward;
  late final Like like;

  ModuleStat({
    required this.comment,
    required this.forward,
    required this.like,
  });

  ModuleStat.fromJson(Map<String, dynamic> json) {
    comment = Comment.fromJson(json['comment']);
    forward = Comment.fromJson(json['forward']);
    like = Like.fromJson(json['like']);
  }
}

class Comment {
  late final int count;
  late final bool forbidden;

  Comment({
    required this.count,
    required this.forbidden,
  });

  Comment.fromJson(Map<String, dynamic> json) {
    count = json['count'];
    forbidden = json['forbidden'];
  }
}

class Like {
  late final int count;
  late final bool forbidden;
  late final bool status;

  Like({
    required this.count,
    required this.forbidden,
    required this.status,
  });

  Like.fromJson(Map<String, dynamic> json) {
    count = json['count'];
    forbidden = json['forbidden'];
    status = json['status'];
  }
}
