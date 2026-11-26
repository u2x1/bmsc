import 'package:bmsc/api/bilibili.dart';
import 'package:bmsc/service/shared_preferences_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:test/test.dart';

import '../helpers/fake_http_adapter.dart';

void main() {
  late BilibiliAPI api;
  late FakeHttpAdapter adapter;

  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
  });

  setUp(() async {
    adapter = FakeHttpAdapter();
    api = BilibiliAPI(enableConnectivity: false);
    api.noNetwork = false;
    api.dio.httpClientAdapter = adapter;
    final prefs = await SharedPreferencesService.instance;
    await prefs.remove('raw_wbi_key');
    await prefs.remove('img_sub_key_last_update');
    await SharedPreferencesService.setBuvid3(_testBuvid3);
    await SharedPreferencesService.setBuvid4(_testBuvid4);
  });

  tearDown(() {
    api.dio.close(force: true);
  });

  test('视频搜索使用 WBI 签名并解析结果', () async {
    adapter.onPath('/x/web-interface/nav', _navRoute(_wbiKey1));
    adapter.onPath('/x/web-interface/wbi/search/type', _searchRoute());

    final result = await api.search('周杰伦', 1);

    expect(result, isNotNull);
    expect(result!.page, 1);
    expect(result.result.single.bvid, 'BVsearch0001');
    final request = adapter.requests
        .singleWhere((r) => r.uri.path == '/x/web-interface/wbi/search/type');
    expect(request.queryParameters['keyword'], '周杰伦');
    expect(request.queryParameters['search_type'], 'video');
    expect(request.queryParameters['page'], '1');
    expect(request.queryParameters['w_rid'], isNotEmpty);
  });

  test('搜索返回 v_voucher 时刷新身份与 WBI key 并重试', () async {
    adapter.onPathSequence('/x/web-interface/nav', [
      _navRoute(_wbiKey1),
      _navRoute(_wbiKey2),
    ]);
    adapter.onPath('/x/frontend/finger/spi', _fingerSpiRoute());
    adapter.onPathSequence('/x/web-interface/wbi/search/type', [
      _vVoucherRoute(),
      _searchRoute(),
    ]);

    final result = await api.search('周杰伦', 1);

    expect(result, isNotNull);
    expect(result!.result, hasLength(1));
    int count(String path) =>
        adapter.requests.where((r) => r.uri.path == path).length;
    expect(count('/x/web-interface/wbi/search/type'), 2);
    expect(count('/x/web-interface/nav'), 2);
    expect(count('/x/frontend/finger/spi'), 1);
  });

  test('连续 v_voucher 时回退综合搜索并保留页码', () async {
    adapter.onPathSequence('/x/web-interface/nav', [
      _navRoute(_wbiKey1),
      _navRoute(_wbiKey2),
    ]);
    adapter.onPath('/x/frontend/finger/spi', _fingerSpiRoute());
    adapter.onPathSequence('/x/web-interface/wbi/search/type', [
      _vVoucherRoute(),
      _vVoucherRoute(),
    ]);
    adapter.onPath('/x/web-interface/search/all/v2', _searchAllRoute());

    final result = await api.search('周杰伦', 2);

    expect(result, isNotNull);
    expect(result!.page, 2);
    expect(result.result.single.bvid, 'BVsearch0001');
    final fallback = adapter.requests
        .singleWhere((r) => r.uri.path == '/x/web-interface/search/all/v2');
    expect(fallback.queryParameters['page'], 2);
  });

  test('综合搜索视频块混入直播间条目时跳过而非整页失败（#23）', () async {
    adapter.onPathSequence('/x/web-interface/nav', [
      _navRoute(_wbiKey1),
      _navRoute(_wbiKey2),
    ]);
    adapter.onPath('/x/frontend/finger/spi', _fingerSpiRoute());
    adapter.onPathSequence('/x/web-interface/wbi/search/type', [
      _vVoucherRoute(),
      _vVoucherRoute(),
    ]);
    final route = _searchAllRoute();
    final block = (route['body']['data']['result'] as List).single as Map;
    final video = Map<String, dynamic>.from((block['data'] as List).single);
    // 真实响应（搜 y/a）：直播间条目无 bvid/aid，play 为 null
    block['data'] = [
      {
        'type': 'live_room',
        'uname': '主播',
        'uid': 2,
        'roomid': 3,
        'title': '直播中',
        'play': null,
      },
      {...video, 'type': 'video'},
      {...video, 'type': 'video', 'bvid': 'BVbroken', 'aid': null},
    ];
    adapter.onPath('/x/web-interface/search/all/v2', route);

    final result = await api.search('y', 1);

    expect(result, isNotNull);
    expect(result!.result.map((r) => r.bvid), ['BVsearch0001']);
  });
}

const _wbiKey1 =
    '7cd084941338484aae1ad9425b84077c4932caff0ff746eab6f01bf08b70ac45';
const _wbiKey2 =
    'ea1db124af3c7062474693fa704f4ff8ea1db124af3c7062474693fa704f4ff8';
const _testBuvid3 = 'D9656DA8-9BEF-F464-5B72-C4849AFD336379044infoc';
const _testBuvid4 =
    'F6E0FD4B-520C-1902-4F7B-E461D8D1F5AB79044-024072309-666onEZSnlHVPjoRp4kDYg==';

Map<String, dynamic> _fingerSpiRoute() => {
      'body': {
        'code': 0,
        'message': 'ok',
        'data': {'b_3': _testBuvid3, 'b_4': _testBuvid4},
      },
    };

Map<String, dynamic> _navRoute(String key) => {
      'body': {
        'code': 0,
        'message': '0',
        'data': {
          'wbi_img': {
            'img_url': 'https://i0.hdslb.com/bfs/wbi/$key.png',
            'sub_url': 'https://i0.hdslb.com/bfs/wbi/${key}sub.png',
          },
        },
      },
    };

Map<String, dynamic> _vVoucherRoute() => {
      'body': {
        'code': 0,
        'message': '0',
        'data': {'v_voucher': 'voucher_test'},
      },
    };

Map<String, dynamic> _searchRoute() => {
      'body': {
        'code': 0,
        'message': 'OK',
        'data': {
          'seid': '1',
          'page': 1,
          'pagesize': 20,
          'numResults': 1,
          'numPages': 1,
          'suggest_keyword': '',
          'rqt_type': 'video',
          'egg_hit': 0,
          'result': [
            {
              'author': 'UP 主',
              'mid': 1,
              'typeid': '1',
              'typename': '音乐',
              'aid': 1,
              'bvid': 'BVsearch0001',
              'title': '搜索结果',
              'pic': 'https://example.test/cover.jpg',
              'play': 1,
              'duration': '1:00',
            },
          ],
          'show_column': 0,
        },
      },
    };

Map<String, dynamic> _searchAllRoute() {
  final route = _searchRoute();
  final data = Map<String, dynamic>.from(route['body']['data'] as Map);
  final videos = data['result'] as List;
  data['page'] = 2;
  data['result'] = [
    {'result_type': 'video', 'data': videos},
  ];
  return {
    'body': {'code': 0, 'message': 'OK', 'data': data},
  };
}
