import 'dart:typed_data';

import 'package:bmsc/util/wav.dart';
import 'package:test/test.dart';

/// 构造最小合法 WAV 文件（16bit 单声道）
Uint8List makeWav({required int sampleRate, required List<int> samples}) {
  final dataLen = samples.length * 2;
  final byteRate = sampleRate * 2;
  final out = ByteData(44 + dataLen);
  void writeStr(int offset, String s) {
    for (var i = 0; i < s.length; i++) {
      out.setUint8(offset + i, s.codeUnitAt(i));
    }
  }

  writeStr(0, 'RIFF');
  out.setUint32(4, 36 + dataLen, Endian.little);
  writeStr(8, 'WAVE');
  writeStr(12, 'fmt ');
  out.setUint32(16, 16, Endian.little);
  out.setUint16(20, 1, Endian.little); // PCM
  out.setUint16(22, 1, Endian.little); // mono
  out.setUint32(24, sampleRate, Endian.little);
  out.setUint32(28, byteRate, Endian.little);
  out.setUint16(32, 2, Endian.little);
  out.setUint16(34, 16, Endian.little);
  writeStr(36, 'data');
  out.setUint32(40, dataLen, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    out.setInt16(44 + i * 2, samples[i], Endian.little);
  }
  return out.buffer.asUint8List();
}

void main() {
  group('parseWavHeader', () {
    test('解析标准 8kHz 16bit 单声道 WAV', () {
      final wav = makeWav(sampleRate: 8000, samples: [1, -1, 32767, -32768]);
      final info = parseWavHeader(wav);
      expect(info.sampleRate, 8000);
      expect(info.channels, 1);
      expect(info.bitsPerSample, 16);
      expect(info.dataOffset, 44);
      expect(info.dataLength, 8);
    });

    test('非法文件抛 FormatException', () {
      expect(() => parseWavHeader(Uint8List.fromList([0, 1, 2, 3])),
          throwsFormatException);
      expect(
          () => parseWavHeader(
              Uint8List.fromList('NOT_A_WAVE_FILE_AT_ALL__________'.codeUnits)),
          throwsFormatException);
    });
  });

  group('resampleS16To8k', () {
    test('8kHz 输入原样返回', () {
      final pcm = Uint8List.fromList([1, 0, 2, 0]);
      expect(resampleS16To8k(pcm, 8000), same(pcm));
    });

    test('44.1kHz → 8kHz 采样点数与时长正确', () {
      // 1 秒 44.1kHz = 44100 采样点 → 8000 采样点
      final samples = List.generate(44100, (i) => i % 200 - 100);
      final pcm = ByteData(samples.length * 2);
      for (var i = 0; i < samples.length; i++) {
        pcm.setInt16(i * 2, samples[i], Endian.little);
      }
      final out = resampleS16To8k(pcm.buffer.asUint8List(), 44100);
      expect(out.length, 8000 * 2);
    });

    test('16kHz → 8kHz 每两点插值取点（直流信号值不变）', () {
      // 恒定幅值信号重采样后应保持幅值
      final samples = List.filled(1600, 1000);
      final pcm = ByteData(samples.length * 2);
      for (var i = 0; i < samples.length; i++) {
        pcm.setInt16(i * 2, samples[i], Endian.little);
      }
      final out = resampleS16To8k(pcm.buffer.asUint8List(), 16000);
      expect(out.length, 800 * 2);
      final view = ByteData.sublistView(out);
      for (var i = 0; i < 800; i++) {
        expect(view.getInt16(i * 2, Endian.little), 1000);
      }
    });

    test('空输入返回空', () {
      expect(resampleS16To8k(Uint8List(0), 44100), isEmpty);
    });

    test('resampleS16 通用：48k→16k 直流信号值不变', () {
      final samples = List.filled(4800, 1000);
      final pcm = ByteData(samples.length * 2);
      for (var i = 0; i < samples.length; i++) {
        pcm.setInt16(i * 2, samples[i], Endian.little);
      }
      final out = resampleS16(pcm.buffer.asUint8List(), 48000, 16000);
      expect(out.length, 1600 * 2);
      final view = ByteData.sublistView(out);
      for (var i = 0; i < 1600; i++) {
        expect(view.getInt16(i * 2, Endian.little), 1000);
      }
    });
  });

  group('writeWavS16', () {
    test('写入后可被 parseWavHeader 完整解析（往返一致）', () {
      final samples = [1, -1, 32767, -32768, 100, -100];
      final pcm = ByteData(samples.length * 2);
      for (var i = 0; i < samples.length; i++) {
        pcm.setInt16(i * 2, samples[i], Endian.little);
      }
      final wav = writeWavS16(pcm.buffer.asUint8List(), 16000);
      final info = parseWavHeader(wav);
      expect(info.sampleRate, 16000);
      expect(info.channels, 1);
      expect(info.bitsPerSample, 16);
      expect(info.dataOffset, 44);
      expect(info.dataLength, samples.length * 2);
      final view = ByteData.sublistView(wav);
      for (var i = 0; i < samples.length; i++) {
        expect(view.getInt16(44 + i * 2, Endian.little), samples[i]);
      }
    });
  });
}
