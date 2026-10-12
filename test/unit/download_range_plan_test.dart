import 'package:bmsc/util/download_range_plan.dart';
import 'package:test/test.dart';

/// 断点续传决策表测试（离线、确定性）。
/// 覆盖历史 bug：200 忽略 Range 时 append 半截文件导致损坏、
/// totalBytes 误加偏移导致进度超 100%。
void main() {
  group('全新下载（startBytes == 0）', () {
    test('200 正常：从头写，总长取 Content-Length', () {
      final plan = resolveDownloadRangePlan(
        startBytes: 0,
        statusCode: 200,
        contentRange: null,
        contentLength: '1000',
      );
      expect(plan.mode, DownloadRangeMode.restart);
      expect(plan.totalBytes, 1000);
    });

    test('200 无 Content-Length：总长未知（-1），进度隐藏', () {
      final plan = resolveDownloadRangePlan(
        startBytes: 0,
        statusCode: 200,
        contentRange: null,
        contentLength: null,
      );
      expect(plan.mode, DownloadRangeMode.restart);
      expect(plan.totalBytes, -1);
    });

    test('非 2xx 状态码防御性视为从头写', () {
      final plan = resolveDownloadRangePlan(
        startBytes: 0,
        statusCode: null,
        contentRange: null,
        contentLength: '500',
      );
      expect(plan.mode, DownloadRangeMode.restart);
      expect(plan.totalBytes, 500);
    });
  });

  group('续传（startBytes > 0）', () {
    test('206 带 Content-Range：续写，总长取 Range 尾段', () {
      final plan = resolveDownloadRangePlan(
        startBytes: 100,
        statusCode: 206,
        contentRange: 'bytes 100-999/1000',
        contentLength: '900',
      );
      expect(plan.mode, DownloadRangeMode.resume);
      expect(plan.totalBytes, 1000);
    });

    test('206 缺 Content-Range：总长回退 Content-Length + 偏移', () {
      final plan = resolveDownloadRangePlan(
        startBytes: 100,
        statusCode: 206,
        contentRange: null,
        contentLength: '900',
      );
      expect(plan.mode, DownloadRangeMode.resume);
      expect(plan.totalBytes, 1000);
    });

    test('206 且 Content-Range 无法解析：同样回退', () {
      final plan = resolveDownloadRangePlan(
        startBytes: 100,
        statusCode: 206,
        contentRange: 'bytes */*',
        contentLength: '900',
      );
      expect(plan.mode, DownloadRangeMode.resume);
      expect(plan.totalBytes, 1000);
    });

    test('200 忽略 Range：临时文件作废从头写，总长不得再加偏移', () {
      final plan = resolveDownloadRangePlan(
        startBytes: 100,
        statusCode: 200,
        contentRange: null,
        contentLength: '1000',
      );
      expect(plan.mode, DownloadRangeMode.restart);
      expect(plan.totalBytes, 1000); // 不是 1100（历史 bug：进度超 100%）
    });

    test('416：临时文件已完整，直接收尾', () {
      final plan = resolveDownloadRangePlan(
        startBytes: 1000,
        statusCode: 416,
        contentRange: null,
        contentLength: null,
      );
      expect(plan.mode, DownloadRangeMode.finalize);
      expect(plan.totalBytes, 1000);
    });

    test('startBytes 为 0 时 416 不视为完成（防御）', () {
      final plan = resolveDownloadRangePlan(
        startBytes: 0,
        statusCode: 416,
        contentRange: null,
        contentLength: null,
      );
      expect(plan.mode, DownloadRangeMode.restart);
    });
  });
}
