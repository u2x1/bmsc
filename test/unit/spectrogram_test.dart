import 'dart:math';
import 'dart:typed_data';

import 'package:bmsc/util/spectrogram.dart';
import 'package:test/test.dart';

/// 生成 s16le 正弦波 PCM
Uint8List sinePcm(double freq, int sampleRate, double seconds,
    {int amplitude = 12000}) {
  final n = (sampleRate * seconds).round();
  final out = ByteData(n * 2);
  for (var i = 0; i < n; i++) {
    out.setInt16(i * 2, (amplitude * sin(2 * pi * freq * i / sampleRate)).round(),
        Endian.little);
  }
  return out.buffer.asUint8List();
}

void main() {
  group('computeSpectrogram', () {
    test('1kHz 正弦的能量集中在 1kHz 所在行', () {
      final spec = computeSpectrogram(sinePcm(1000, 48000, 1.0), 48000);
      expect(spec.cols, greaterThan(10));
      expect(spec.rows, 64);
      // 全局最大值所在行
      var bestRow = 0;
      var bestVal = -1.0;
      for (var r = 0; r < spec.rows; r++) {
        final v = spec.at(spec.cols ~/ 2, r);
        if (v > bestVal) {
          bestVal = v;
          bestRow = r;
        }
      }
      // 对数频率轴（40Hz~8kHz）：1kHz 对应行 r = ln(1000/40)/ln(8000/40)*63 ≈ 38.2
      expect(bestRow, inInclusiveRange(35, 41));
      expect(bestVal, greaterThan(0.8));
    });

    test('1kHz 正弦：1kHz 行显著强于 4kHz 行', () {
      final spec = computeSpectrogram(sinePcm(1000, 48000, 0.5), 48000);
      double rowMax(int targetRow) => List.generate(spec.cols,
          (c) => spec.at(c, targetRow)).reduce(max);
      expect(rowMax(38), greaterThan(rowMax(58) + 0.5));
    });

    test('静音输入输出全零', () {
      final spec =
          computeSpectrogram(Uint8List(48000 * 2), 48000); // 1s 全零
      for (var c = 0; c < spec.cols; c++) {
        for (var r = 0; r < spec.rows; r++) {
          expect(spec.at(c, r), 0);
        }
      }
    });

    test('空输入不抛异常', () {
      final spec = computeSpectrogram(Uint8List(0), 48000);
      expect(spec.cols, 1);
      expect(spec.mags.length, spec.rows);
    });

    test('列数与时长匹配（7s @48kHz，fftSize 2048）', () {
      final spec = computeSpectrogram(sinePcm(500, 48000, 7.0), 48000);
      // (7*48000-1)~/2048+1 = 165（末帧不足 fftSize 的补零帧）
      expect(spec.cols, 165);
    });
  });
}
