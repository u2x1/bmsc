import 'package:bmsc/api/bilibili.dart';
import 'package:test/test.dart';

import '../helpers/fake_http_adapter.dart';

void main() {
  test('getCollectionMetas 单次请求返回全部并过滤失效项', () async {
    final adapter = FakeHttpAdapter();
    final api = BilibiliAPI(enableConnectivity: false);
    api.noNetwork = false;
    api.dio.httpClientAdapter = adapter;
    addTearDown(() => api.dio.close(force: true));

    adapter.onPath('/x/space/fav/season/list', {
      'body': {
        'code': 0,
        'message': 'OK',
        'data': {
          'media_count': 5,
          'has_more': true,
          'medias': [
            _media(1, 'BVseason0001', '第一首'),
            _media(2, 'BVseason0002', '第二首'),
            _media(3, 'BVseason0003', '第三首'),
            _media(4, '', '空 BV'),
            _media(5, 'BVseason0005', '已失效视频'),
          ],
        },
      },
    });

    final metas = await api.getCollectionMetas(1519400);

    expect(metas, isNotNull);
    expect(metas!.map((x) => x.bvid),
        ['BVseason0001', 'BVseason0002', 'BVseason0003']);
    expect(metas.map((x) => x.aid), [1, 2, 3]);
    expect(adapter.requests, hasLength(1));
    final request = adapter.requests.single;
    expect(request.uri.path, '/x/space/fav/season/list');
    expect(request.queryParameters['season_id'], 1519400);
    expect(request.queryParameters['pn'], 1);
  });
}

Map<String, dynamic> _media(int id, String bvid, String title) => {
      'id': id,
      'bvid': bvid,
      'title': title,
      'upper': {'mid': 327901592, 'name': 'UP 主'},
      'duration': 123,
      'cover': 'https://example.test/cover$id.jpg',
    };
