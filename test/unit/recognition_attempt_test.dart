import 'package:bmsc/model/recognition_attempt.dart';
import 'package:test/test.dart';

void main() {
  group('RecognizedSong', () {
    test('json 往返', () {
      const s = RecognizedSong(
          songId: 42, name: '歌', artists: ['甲', '乙'], album: '专', startTimeMs: 1500);
      final r = RecognizedSong.fromJson(s.toJson());
      expect(r.songId, 42);
      expect(r.name, '歌');
      expect(r.artists, ['甲', '乙']);
      expect(r.album, '专');
      expect(r.startTimeMs, 1500);
    });

    test('空歌手显示未知歌手', () {
      const s = RecognizedSong(name: 'x', artists: [], startTimeMs: 0);
      expect(s.artistText, '未知歌手');
    });
  });

  group('RecognitionAttempt', () {
    test('新格式 json 往返', () {
      const a = RecognitionAttempt(
        at: 123,
        status: RecognitionStatus.ok,
        songs: [RecognizedSong(name: '歌', artists: ['甲'], startTimeMs: 100)],
        clip: 'clip_1.wav',
        durSec: 6.9,
      );
      final r = RecognitionAttempt.fromStoredJson(a.toJson());
      expect(r.at, 123);
      expect(r.status, RecognitionStatus.ok);
      expect(r.songs.single.name, '歌');
      expect(r.clip, 'clip_1.wav');
      expect(r.durSec, 6.9);
    });

    test('statusTitle 按状态', () {
      const m = RecognitionAttempt(at: 1, status: RecognitionStatus.noMatch);
      expect(m.statusTitle, '未识别到歌曲');
      const s = RecognitionAttempt(at: 1, status: RecognitionStatus.silent);
      expect(s.statusTitle, '录音为静音');
      const e = RecognitionAttempt(at: 1, status: RecognitionStatus.error);
      expect(e.statusTitle, '识别失败');
    });

    test('旧格式（单曲成功条目）迁移', () {
      final r = RecognitionAttempt.fromStoredJson({
        'name': '老歌',
        'artists': ['老歌手'],
        'album': '老专辑',
        'startTimeMs': 3620,
        'songId': 716083,
        'at': 1791182109045,
      });
      expect(r.status, RecognitionStatus.ok);
      expect(r.at, 1791182109045);
      expect(r.songs.single.name, '老歌');
      expect(r.songs.single.songId, 716083);
      expect(r.clip, isNull);
    });

    test('未知 status 兜底为 error', () {
      final r = RecognitionAttempt.fromStoredJson({'at': 1, 'status': '???'});
      expect(r.status, RecognitionStatus.error);
    });
  });

  group('RecognitionOutcome.toAttempt', () {
    test('clipPath 只保留文件名', () {
      const o = RecognitionOutcome(
          status: RecognitionStatus.silent,
          message: '静音',
          clipPath: '/data/xxx/recognition_clips/clip_99.wav',
          durationSec: 7.0);
      final a = o.toAttempt(555);
      expect(a.at, 555);
      expect(a.status, RecognitionStatus.silent);
      expect(a.clip, 'clip_99.wav');
      expect(a.message, '静音');
      expect(a.durSec, 7.0);
    });
  });
}
