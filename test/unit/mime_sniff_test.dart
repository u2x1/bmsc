import 'package:bmsc/audio/lazy_audio_source.dart';
import 'package:test/test.dart';

/// MIME 嗅探测试：iOS AVPlayer 不认 application/octet-stream，且 CDN 可能
/// 错标 Content-Type，必须按 URL 扩展名 / 文件头魔数确定真实格式。
void main() {
  group('sniffMimeFromBytes（文件头魔数）', () {
    test('ftyp box（B 站 fMP4 音频）识别为 audio/mp4', () {
      final header = [
        0x00, 0x00, 0x00, 0x18, // size
        0x66, 0x74, 0x79, 0x70, // 'ftyp'
        0x4D, 0x34, 0x41, 0x20, // 'M4A '
      ];
      expect(LazyAudioSource.sniffMimeFromBytes(header), 'audio/mp4');
    });

    test('styp box（DASH 分片开头）识别为 audio/mp4', () {
      final header = [
        0x00, 0x00, 0x00, 0x24,
        0x73, 0x74, 0x79, 0x70, // 'styp'
        0x6D, 0x73, 0x64, 0x68,
      ];
      expect(LazyAudioSource.sniffMimeFromBytes(header), 'audio/mp4');
    });

    test('ID3 标签识别为 audio/mpeg', () {
      final header = [
        0x49, 0x44, 0x33, // 'ID3'
        0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x21, 0x00,
      ];
      expect(LazyAudioSource.sniffMimeFromBytes(header), 'audio/mpeg');
    });

    test('MP3 帧同步字（0xFFEx）识别为 audio/mpeg', () {
      final header = [
        0xFF, 0xFB, 0x90, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00,
      ];
      expect(LazyAudioSource.sniffMimeFromBytes(header), 'audio/mpeg');
    });

    test('OggS 识别为 audio/ogg', () {
      final header = [
        0x4F, 0x67, 0x67, 0x53, // 'OggS'
        0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      ];
      expect(LazyAudioSource.sniffMimeFromBytes(header), 'audio/ogg');
    });

    test('fLaC 识别为 audio/flac', () {
      final header = [
        0x66, 0x4C, 0x61, 0x43, // 'fLaC'
        0x00, 0x00, 0x00, 0x22, 0x12, 0x00, 0x12, 0x00,
      ];
      expect(LazyAudioSource.sniffMimeFromBytes(header), 'audio/flac');
    });

    test('RIFF/WAVE 识别为 audio/wav', () {
      final header = [
        0x52, 0x49, 0x46, 0x46, // 'RIFF'
        0x24, 0x00, 0x00, 0x00,
        0x57, 0x41, 0x56, 0x45, // 'WAVE'
      ];
      expect(LazyAudioSource.sniffMimeFromBytes(header), 'audio/wav');
    });

    test('未知内容返回 null', () {
      final header = List<int>.filled(12, 0x01);
      expect(LazyAudioSource.sniffMimeFromBytes(header), isNull);
    });

    test('不足 12 字节返回 null', () {
      final header = [0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70];
      expect(LazyAudioSource.sniffMimeFromBytes(header), isNull);
    });
  });

  group('sniffMimeFromUri（URL 扩展名）', () {
    test('常见音频扩展名', () {
      expect(
          LazyAudioSource.sniffMimeFromUri(
              Uri.parse('https://upos.example.com/upgcxcode/xx.m4s')),
          'audio/mp4');
      expect(
          LazyAudioSource.sniffMimeFromUri(
              Uri.parse('https://upos.example.com/a.M4A?e=ig')),
          'audio/mp4');
      expect(
          LazyAudioSource.sniffMimeFromUri(
              Uri.parse('https://upos.example.com/a.aac')),
          'audio/aac');
      expect(
          LazyAudioSource.sniffMimeFromUri(
              Uri.parse('https://upos.example.com/a.flac')),
          'audio/flac');
      expect(
          LazyAudioSource.sniffMimeFromUri(
              Uri.parse('https://upos.example.com/a.ogg')),
          'audio/ogg');
      expect(
          LazyAudioSource.sniffMimeFromUri(
              Uri.parse('https://upos.example.com/a.wav')),
          'audio/wav');
    });

    test('B 站无扩展名 CDN URL 返回传入的 fallback', () {
      expect(
          LazyAudioSource.sniffMimeFromUri(
              Uri.parse(
                  'https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/76/48/38054857671/38054857671-1-30280.m4s?e=ig&deadline=1'),
              ''),
          'audio/mp4');
      expect(
          LazyAudioSource.sniffMimeFromUri(
              Uri.parse(
                  'https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/76/48/38054857671/38054857671-1-30280?e=ig&deadline=1'),
              ''),
          '');
      expect(
          LazyAudioSource.sniffMimeFromUri(
              Uri.parse(
                  'https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/noext')),
          'audio/mpeg');
    });
  });

  group('sanitizeMime（响应头清洗）', () {
    test('octet-stream 回退', () {
      expect(LazyAudioSource.sanitizeMime('application/octet-stream'),
          'audio/mpeg');
      expect(
          LazyAudioSource.sanitizeMime('application/octet-stream', ''), '');
    });

    test('空串与无斜杠回退', () {
      expect(LazyAudioSource.sanitizeMime(''), 'audio/mpeg');
      expect(LazyAudioSource.sanitizeMime('text'), 'audio/mpeg');
    });

    test('合法 MIME 原样保留', () {
      expect(LazyAudioSource.sanitizeMime('audio/mp4'), 'audio/mp4');
      expect(LazyAudioSource.sanitizeMime('audio/mpeg; charset=binary'),
          'audio/mpeg; charset=binary');
    });
  });
}
