import 'dart:math';
import 'dart:typed_data';

/// 音频频谱图数据（列=时间帧，行=频率带，行 0 为最低频，值域 0..1）
class Spectrogram {
  final int cols;
  final int rows;

  /// 长度 cols*rows，按列优先存储：mags[col * rows + row]
  final Float32List mags;

  const Spectrogram({required this.cols, required this.rows, required this.mags});

  double at(int col, int row) => mags[col * rows + row];
}

/// 从 s16le 单声道 PCM 计算频谱图（纯 Dart，无 Flutter 依赖）。
///
/// 频率轴对数分布（[minFreq]~[maxFreq]，超出奈奎斯特自动截断），
/// 幅度映射：dB ∈ [minDb, maxDb] → [0, 1]。
Spectrogram computeSpectrogram(
  Uint8List s16le,
  int sampleRate, {
  int fftSize = 2048,
  int rows = 64,
  double minFreq = 40,
  double maxFreq = 8000,
  double minDb = -75,
  double maxDb = -25,
}) {
  assert(fftSize > 0 && (fftSize & (fftSize - 1)) == 0, 'fftSize 须为 2 的幂');
  final view = ByteData.sublistView(s16le);
  final total = s16le.length >> 1;
  final cols = total == 0 ? 1 : (total - 1) ~/ fftSize + 1;
  final mags = Float32List(cols * rows);

  // Hann 窗
  final win = Float64List(fftSize);
  for (var i = 0; i < fftSize; i++) {
    win[i] = 0.5 * (1 - cos(2 * pi * i / (fftSize - 1)));
  }
  // 对数频率轴：行 r → FFT bin
  final maxBinFreq = min(maxFreq, sampleRate / 2);
  final nyquistBin = fftSize ~/ 2 - 1;
  int binOf(int r) {
    final f = minFreq * pow(maxBinFreq / minFreq, r / (rows - 1));
    return (f / sampleRate * fftSize).round().clamp(1, nyquistBin);
  }

  final re = Float64List(fftSize);
  final im = Float64List(fftSize);
  const ln10 = 2.302585092994046;
  for (var c = 0; c < cols; c++) {
    final start = c * fftSize;
    for (var i = 0; i < fftSize; i++) {
      final idx = start + i;
      re[i] =
          idx < total ? view.getInt16(idx * 2, Endian.little) * win[i] : 0.0;
      im[i] = 0;
    }
    _fft(re, im);
    for (var r = 0; r < rows; r++) {
      final b = binOf(r);
      final m =
          sqrt(re[b] * re[b] + im[b] * im[b]) / (fftSize / 2) / 32768;
      final db = 20 * log(m + 1e-9) / ln10;
      mags[c * rows + r] =
          ((db - minDb) / (maxDb - minDb)).clamp(0.0, 1.0);
    }
  }
  return Spectrogram(cols: cols, rows: rows, mags: mags);
}

/// 迭代基-2 FFT（原地，re/im 长度须为 2 的幂）
void _fft(Float64List re, Float64List im) {
  final n = re.length;
  for (var i = 1, j = 0; i < n; i++) {
    var bit = n >> 1;
    for (; j & bit != 0; bit >>= 1) {
      j ^= bit;
    }
    j ^= bit;
    if (i < j) {
      final t = re[i];
      re[i] = re[j];
      re[j] = t;
      final u = im[i];
      im[i] = im[j];
      im[j] = u;
    }
  }
  for (var len = 2; len <= n; len <<= 1) {
    final ang = -2 * pi / len;
    final wRe = cos(ang);
    final wIm = sin(ang);
    final half = len >> 1;
    for (var i = 0; i < n; i += len) {
      var cRe = 1.0, cIm = 0.0;
      for (var j = 0; j < half; j++) {
        final k = i + j + half;
        final vRe = re[k] * cRe - im[k] * cIm;
        final vIm = re[k] * cIm + im[k] * cRe;
        re[k] = re[i + j] - vRe;
        im[k] = im[i + j] - vIm;
        re[i + j] += vRe;
        im[i + j] += vIm;
        final nRe = cRe * wRe - cIm * wIm;
        cIm = cRe * wIm + cIm * wRe;
        cRe = nRe;
      }
    }
  }
}
