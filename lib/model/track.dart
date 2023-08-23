class Track {
  Track({
    required this.code,
    required this.message,
    required this.ttl,
    required this.data,
  });
  late final int code;
  late final String message;
  late final int ttl;
  late final Data data;

  Track.fromJson(Map<String, dynamic> json) {
    code = json['code'];
    message = json['message'];
    ttl = json['ttl'];
    data = Data.fromJson(json['data']);
  }
}

class Data {
  Data({
    required this.from,
    required this.result,
    required this.message,
    required this.quality,
    required this.format,
    required this.timelength,
    required this.acceptFormat,
    required this.acceptDescription,
    required this.acceptQuality,
    required this.videoCodecid,
    required this.seekParam,
    required this.seekType,
    required this.dash,
    required this.lastPlayTime,
    required this.lastPlayCid,
  });
  late final String from;
  late final String result;
  late final String message;
  late final int quality;
  late final String format;
  late final int timelength;
  late final String acceptFormat;
  late final List<String> acceptDescription;
  late final List<int> acceptQuality;
  late final int videoCodecid;
  late final String seekParam;
  late final String seekType;
  late final Dash dash;
  late final int lastPlayTime;
  late final int lastPlayCid;

  Data.fromJson(Map<String, dynamic> json) {
    from = json['from'];
    result = json['result'];
    message = json['message'];
    quality = json['quality'];
    format = json['format'];
    timelength = json['timelength'];
    acceptFormat = json['accept_format'];
    acceptDescription =
        List.castFrom<dynamic, String>(json['accept_description']);
    acceptQuality = List.castFrom<dynamic, int>(json['accept_quality']);
    videoCodecid = json['video_codecid'];
    seekParam = json['seek_param'];
    seekType = json['seek_type'];
    dash = Dash.fromJson(json['dash']);
    lastPlayTime = json['last_play_time'];
    lastPlayCid = json['last_play_cid'];
  }
}

class Dash {
  Dash({
    required this.duration,
    required this.minBufferTime,
    required this.video,
    required this.audio,
  });
  late final int duration;
  late final double minBufferTime;
  late final List<Video> video;
  late final List<Audio> audio;

  Dash.fromJson(Map<String, dynamic> json) {
    duration = json['duration'];
    minBufferTime = json['min_buffer_time'];
    video = List.from(json['video']).map((e) => Video.fromJson(e)).toList();
    audio = List.from(json['audio']).map((e) => Audio.fromJson(e)).toList();
  }
}

class Video {
  Video({
    required this.id,
    required this.baseUrl,
    required this.backupUrl,
    required this.bandwidth,
    required this.mimeType,
    required this.codecs,
    required this.width,
    required this.height,
    required this.frameRate,
    required this.sar,
    required this.startWithSap,
    required this.codecid,
  });
  late final int id;
  late final String baseUrl;
  late final List<String> backupUrl;
  late final int bandwidth;
  late final String mimeType;
  late final String codecs;
  late final int width;
  late final int height;
  late final String frameRate;
  late final String sar;
  late final int startWithSap;
  late final int codecid;

  Video.fromJson(Map<String, dynamic> json) {
    id = json['id'];
    baseUrl = json['base_url'];
    backupUrl = List.castFrom<dynamic, String>(json['backup_url']);
    bandwidth = json['bandwidth'];
    mimeType = json['mime_type'];
    codecs = json['codecs'];
    width = json['width'];
    height = json['height'];
    frameRate = json['frame_rate'];
    sar = json['sar'];
    startWithSap = json['start_with_sap'];
    codecid = json['codecid'];
  }
}

class Audio {
  Audio({
    required this.id,
    required this.baseUrl,
    required this.backupUrl,
    required this.bandwidth,
    required this.mimeType,
    required this.codecs,
    required this.width,
    required this.height,
    required this.frameRate,
    required this.sar,
    required this.startWithSap,
    required this.codecid,
  });
  late final int id;
  late final String baseUrl;
  late final List<String> backupUrl;
  late final int bandwidth;
  late final String mimeType;
  late final String codecs;
  late final int width;
  late final int height;
  late final String frameRate;
  late final String sar;
  late final int startWithSap;
  late final int codecid;

  Audio.fromJson(Map<String, dynamic> json) {
    id = json['id'];
    baseUrl = json['base_url'];
    backupUrl = List.castFrom<dynamic, String>(json['backup_url']);
    bandwidth = json['bandwidth'];
    mimeType = json['mime_type'];
    codecs = json['codecs'];
    width = json['width'];
    height = json['height'];
    frameRate = json['frame_rate'];
    sar = json['sar'];
    startWithSap = json['start_with_sap'];
    codecid = json['codecid'];
  }
}
