import 'dart:typed_data';

/// WAV 文件头关键信息
class WavInfo {
  final int sampleRate;
  final int channels;
  final int bitsPerSample;
  final int dataOffset;
  final int dataLength;

  const WavInfo({
    required this.sampleRate,
    required this.channels,
    required this.bitsPerSample,
    required this.dataOffset,
    required this.dataLength,
  });
}

/// 解析 WAV 文件头（RIFF/fmt/data chunk），非法文件抛 [FormatException]。
WavInfo parseWavHeader(Uint8List bytes) {
  if (bytes.length < 44 ||
      String.fromCharCodes(bytes.sublist(0, 4)) != 'RIFF' ||
      String.fromCharCodes(bytes.sublist(8, 12)) != 'WAVE') {
    throw const FormatException('not a RIFF/WAVE file');
  }
  final view = ByteData.sublistView(bytes);
  var offset = 12;
  int? sampleRate, channels, bitsPerSample, dataOffset, dataLength;
  while (offset + 8 <= bytes.length) {
    final id = String.fromCharCodes(bytes.sublist(offset, offset + 4));
    final size = view.getUint32(offset + 4, Endian.little);
    if (id == 'fmt ' && offset + 16 <= bytes.length) {
      channels = view.getUint16(offset + 10, Endian.little);
      sampleRate = view.getUint32(offset + 12, Endian.little);
      bitsPerSample = view.getUint16(offset + 22, Endian.little);
    } else if (id == 'data') {
      dataOffset = offset + 8;
      dataLength = size;
      break;
    }
    offset += 8 + size + (size.isOdd ? 1 : 0);
  }
  if (sampleRate == null || dataOffset == null) {
    throw const FormatException('missing fmt or data chunk');
  }
  return WavInfo(
    sampleRate: sampleRate,
    channels: channels!,
    bitsPerSample: bitsPerSample!,
    dataOffset: dataOffset,
    dataLength: dataLength!,
  );
}

/// 16bit PCM 单声道线性重采样（任意源采样率 → 8kHz，识曲指纹只接受 8kHz）。
/// [pcm] 为 s16le 字节流。
Uint8List resampleS16To8k(Uint8List pcm, int srcRate) =>
    resampleS16(pcm, srcRate, 8000);

/// 16bit PCM 单声道线性重采样（任意源/目标采样率）。[pcm] 为 s16le 字节流。
Uint8List resampleS16(Uint8List pcm, int srcRate, int dstRate) {
  if (srcRate == dstRate) return pcm;
  final view = ByteData.sublistView(pcm);
  final srcSamples = pcm.length >> 1;
  if (srcSamples == 0) return Uint8List(0);
  final dstSamples = (srcSamples * dstRate / srcRate).round();
  final out = ByteData(dstSamples * 2);
  final ratio = srcRate / dstRate;
  for (var i = 0; i < dstSamples; i++) {
    final pos = i * ratio;
    final i0 = pos.floor();
    final i1 = (i0 + 1).clamp(0, srcSamples - 1);
    final frac = pos - i0;
    final s0 = view.getInt16(i0 * 2, Endian.little);
    final s1 = view.getInt16(i1 * 2, Endian.little);
    out.setInt16(i * 2, (s0 + (s1 - s0) * frac).round(), Endian.little);
  }
  return out.buffer.asUint8List();
}

/// 写入标准 44 字节头的 16bit 单声道 WAV
Uint8List writeWavS16(Uint8List pcm, int sampleRate) {
  final out = ByteData(44 + pcm.length);
  void writeStr(int offset, String s) {
    for (var i = 0; i < s.length; i++) {
      out.setUint8(offset + i, s.codeUnitAt(i));
    }
  }

  writeStr(0, 'RIFF');
  out.setUint32(4, 36 + pcm.length, Endian.little);
  writeStr(8, 'WAVE');
  writeStr(12, 'fmt ');
  out.setUint32(16, 16, Endian.little);
  out.setUint16(20, 1, Endian.little); // PCM
  out.setUint16(22, 1, Endian.little); // mono
  out.setUint32(24, sampleRate, Endian.little);
  out.setUint32(28, sampleRate * 2, Endian.little);
  out.setUint16(32, 2, Endian.little);
  out.setUint16(34, 16, Endian.little);
  writeStr(36, 'data');
  out.setUint32(40, pcm.length, Endian.little);
  out.buffer.asUint8List().setRange(44, 44 + pcm.length, pcm);
  return out.buffer.asUint8List();
}
