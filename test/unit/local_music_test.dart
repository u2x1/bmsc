import 'package:bmsc/model/local_track.dart';
import 'package:bmsc/model/playlist_data.dart';
import 'package:bmsc/util/local_file_names.dart';
import 'package:test/test.dart';

/// 本地音乐测试：导入文件名处理、曲库模型、播放列表持久化模型。
void main() {
  group('文件名工具', () {
    test('sanitizeFileName 清理路径分隔符与非法字符', () {
      expect(sanitizeFileName('a/b\\c:d*e?f"g<h>i|j.mp3'), 'a_b_c_d_e_f_g_h_i_j.mp3');
      expect(sanitizeFileName('正常 名字.mp3'), '正常 名字.mp3');
      expect(sanitizeFileName('   '), '_');
    });

    test('uniqueFileName 冲突时追加序号', () {
      final taken = <String>{'a.mp3', 'a_1.mp3'};
      bool exists(String name) => taken.contains(name);
      expect(uniqueFileName('b.mp3', exists), 'b.mp3');
      expect(uniqueFileName('a.mp3', exists), 'a_2.mp3');
      // 无扩展名文件
      final taken2 = <String>{'noext'};
      expect(uniqueFileName('noext', taken2.contains), 'noext_1');
    });

    test('titleFromFileName 去扩展名', () {
      expect(titleFromFileName('歌名.mp3'), '歌名');
      expect(titleFromFileName('a.b.c.flac'), 'a.b.c');
      expect(titleFromFileName('noext'), 'noext');
      expect(titleFromFileName('.hidden'), '.hidden');
    });

    test('coverExtensionForMime 按 MIME 推断扩展名', () {
      expect(coverExtensionForMime('image/jpeg'), '.jpg');
      expect(coverExtensionForMime('image/png'), '.png');
      expect(coverExtensionForMime('image/webp'), '.webp');
      expect(coverExtensionForMime('unknown'), '.img');
    });
  });

  group('LocalTrack 模型', () {
    test('DB json 序列化往返', () {
      const track = LocalTrack(
        id: 7,
        filePath: '/data/local_music/a.mp3',
        title: '标题',
        artist: '艺术家',
        album: '专辑',
        duration: 233,
        fileSize: 1024,
        coverPath: '/data/local_music/covers/h.jpg',
        createdAt: 1700000000000,
      );
      final restored = LocalTrack.fromJson(track.toDbJson());
      expect(restored.id, 7);
      expect(restored.filePath, track.filePath);
      expect(restored.title, '标题');
      expect(restored.artist, '艺术家');
      expect(restored.album, '专辑');
      expect(restored.duration, 233);
      expect(restored.fileSize, 1024);
      expect(restored.coverPath, track.coverPath);
      expect(restored.createdAt, track.createdAt);
    });

    test('可空字段兼容（旧数据/缺省）', () {
      final track = LocalTrack.fromJson({
        'id': 1,
        'filePath': '/x.mp3',
        'title': 't',
      });
      expect(track.artist, '');
      expect(track.album, '');
      expect(track.duration, 0);
      expect(track.coverPath, isNull);
    });
  });

  group('PlaylistData 本地曲目持久化', () {
    PlaylistData makeLocal() => PlaylistData(
          id: 'local_3',
          title: '本地歌',
          artist: '歌手',
          artUri: 'file:///covers/h.jpg',
          audioUri: 'file:///music/a.mp3',
          bvid: '',
          aid: 0,
          cid: 0,
          multi: false,
          mid: 0,
          cached: false,
          rawTitle: '',
          duration: 100,
          dummy: false,
          local: true,
          filePath: '/music/a.mp3',
          album: '专辑A',
        );

    test('local 字段序列化往返', () {
      final restored = PlaylistData.fromJson(makeLocal().toJson());
      expect(restored.local, isTrue);
      expect(restored.filePath, '/music/a.mp3');
      expect(restored.album, '专辑A');
    });

    test('旧版本 json（无 local 字段）反序列化为 B 站源', () {
      final json = makeLocal().toJson()
        ..remove('local')
        ..remove('filePath')
        ..remove('album');
      final restored = PlaylistData.fromJson(json);
      expect(restored.local, isFalse);
      expect(restored.filePath, '');
      expect(restored.album, '');
    });
  });
}
