import 'dart:async';

import 'package:bmsc/audio/clip_player.dart';
import 'package:bmsc/model/recognition_attempt.dart';
import 'package:bmsc/screen/search_screen.dart';
import 'package:bmsc/service/overlay_recognition.dart';
import 'package:bmsc/service/recognition_service.dart';
import 'package:bmsc/service/shared_preferences_service.dart';
import 'package:bmsc/util/spectrogram.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 听歌识曲：录制几秒环境音 → workers/recognize（网易云识曲）→ 结果可回链 B 站搜索。
/// 录音过程可视化：波纹扩散 + 倒计时进度环 + 实时电平声纹；上传时展示本次录音的频谱图。
/// 每次识别（成功/未中/静音/失败）入「识别历史」，附 16kHz 试听片段，可回放/单条删除。
class RecognitionScreen extends StatefulWidget {
  const RecognitionScreen({super.key});

  @override
  State<RecognitionScreen> createState() => _RecognitionScreenState();
}

enum _Phase { idle, recording, uploading, done }

class _RecognitionScreenState extends State<RecognitionScreen>
    with TickerProviderStateMixin {
  // 7 秒：实际产出 ~6.9s，duration 向下取整报 6，避开上游 duration=5 毒值
  // 与 ~7.9s 死档（见 RecognitionService._upload 注释与 workers/recognize README）
  static const _recordSeconds = 7;

  final _service = RecognitionService();
  final _clipPlayer = ClipPlayer();
  _Phase _phase = _Phase.idle;
  List<RecognizedSong> _results = [];
  List<RecognitionAttempt> _history = [];
  String? _error;
  int _countdown = _recordSeconds;
  Timer? _timer;
  StreamSubscription<dynamic>? _ampSub;

  /// 实时电平（0..1），滚动显示最近 60 个采样
  final List<double> _levels = [];
  Spectrogram? _spectrogram;

  late final AnimationController _pulse;
  late final AnimationController _ripple;
  late final AnimationController _ring;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
      lowerBound: 0.9,
      upperBound: 1.15,
    );
    _ripple = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    );
    _ring = AnimationController(
      vsync: this,
      duration: const Duration(seconds: _recordSeconds),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkConsent());
    _loadHistory();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _ampSub?.cancel();
    _pulse.dispose();
    _ripple.dispose();
    _ring.dispose();
    _clipPlayer.dispose();
    unawaited(_service.cancelRecording());
    _service.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    final h = await SharedPreferencesService.getRecognitionHistory();
    if (mounted) setState(() => _history = h);
  }

  /// 使用告知 v2：录音片段会保存在本机识别历史供回放（相比 v1「不保存」
  /// 范围变大，需重新征得同意）；不同意则不进入功能
  Future<void> _checkConsent() async {
    if (await SharedPreferencesService.getRecognitionConsent()) return;
    if (!mounted) return;
    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('听歌识曲'),
        content: const Text(
            '识别时将录制约 $_recordSeconds 秒环境音，经 BMSC 自建中转（Cloudflare）调用网易云音乐识曲接口。\n\n'
            '录音片段会保存在本机「识别历史」中供回放（可单条删除或随时清空），'
            '除本次识别上传外不会用于其他用途。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('同意并开始'),
          ),
        ],
      ),
    );
    if (accepted == true) {
      await SharedPreferencesService.setRecognitionConsent(true);
    }
    if (!mounted) return;
    if (accepted != true) Navigator.pop(context);
  }

  Future<void> _start() async {
    if (!await _service.ensureMicPermission()) {
      setState(() {
        _error = '未获得麦克风权限，请在系统设置中允许后重试';
        _phase = _Phase.done;
      });
      return;
    }
    setState(() {
      _phase = _Phase.recording;
      _countdown = _recordSeconds;
      _error = null;
      _spectrogram = null;
      _levels.clear();
    });
    try {
      await _service.startRecording();
    } catch (e) {
      setState(() {
        _phase = _Phase.done;
        _error = '无法开始录音：$e';
      });
      return;
    }
    _pulse.repeat(reverse: true);
    _ripple.repeat();
    _ring.forward(from: 0);
    _ampSub = _service.watchAmplitude().listen((a) {
      if (!mounted) return;
      // dBFS（-40..0）归一化到 0..1
      setState(() {
        _levels.add(((a.current + 40) / 40).clamp(0.0, 1.0));
        if (_levels.length > 60) _levels.removeAt(0);
      });
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_countdown <= 1) {
        timer.cancel();
        _finish();
      } else {
        setState(() => _countdown--);
      }
    });
  }

  Future<void> _finish() async {
    // 连点/重复触发守卫（按钮在 setState 重建前有极短可点窗口）
    if (_phase != _Phase.recording) return;
    _timer?.cancel();
    _ampSub?.cancel();
    _ampSub = null;
    _pulse.stop();
    _ripple.stop();
    _ring.stop();
    setState(() => _phase = _Phase.uploading);
    final outcome = await _service.stopAndRecognize(
      onCaptured: (pcm, sampleRate) {
        final spec = computeSpectrogram(pcm, sampleRate);
        if (mounted) setState(() => _spectrogram = spec);
      },
    );
    if (!mounted) return;
    setState(() {
      _phase = _Phase.done;
      _results = outcome.songs;
      _error = switch (outcome.status) {
        RecognitionStatus.ok => null,
        RecognitionStatus.noMatch => '未识别到歌曲，请靠近音源重试',
        RecognitionStatus.silent ||
        RecognitionStatus.error =>
          outcome.message ?? '识别失败',
      };
    });
    // 成功/未中/静音/失败均入史（附试听片段）
    unawaited(_saveAttempt(outcome));
  }

  Future<void> _saveAttempt(RecognitionOutcome outcome) async {
    await SharedPreferencesService.addRecognitionHistory(
        outcome.toAttempt(DateTime.now().millisecondsSinceEpoch));
    await _loadHistory();
  }

  Future<void> _deleteAttempt(RecognitionAttempt a) async {
    await SharedPreferencesService.removeRecognitionHistory(a.at);
    if (mounted) setState(() => _history.removeWhere((e) => e.at == a.at));
  }

  Future<void> _confirmClearHistory() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空识别历史？'),
        content: const Text('将同时删除全部录音片段。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await SharedPreferencesService.clearRecognitionHistory();
      if (mounted) setState(() => _history = []);
    }
  }

  /// 开启悬浮窗识曲（Android）：检查/申请悬浮窗权限 → 启动气泡服务
  Future<void> _enableOverlay() async {
    final overlay = OverlayRecognitionService.instance;
    final messenger = ScaffoldMessenger.of(context);
    if (!await overlay.isSupported()) {
      messenger.showSnackBar(
        const SnackBar(content: Text('悬浮窗识曲目前仅支持 Android')),
      );
      return;
    }
    if (!await overlay.isGranted()) {
      await overlay.requestPermission();
      messenger.showSnackBar(
        const SnackBar(content: Text('请授予「显示在其他应用上层」权限后重试')),
      );
      return;
    }
    await overlay.show();
    messenger.showSnackBar(
      const SnackBar(content: Text('悬浮窗已开启：点气泡即可在任意界面识曲')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('听歌识曲'),
        actions: [
          IconButton(
            tooltip: '悬浮窗识曲',
            icon: const Icon(Icons.picture_in_picture_alt_outlined),
            onPressed: _enableOverlay,
          ),
        ],
      ),
      body: SafeArea(
        child: switch (_phase) {
          _Phase.idle || _Phase.done => _buildIdle(theme),
          _Phase.recording => _buildRecording(theme),
          _Phase.uploading => _buildUploading(theme),
        },
      ),
    );
  }

  Widget _buildIdle(ThemeData theme) {
    return Column(
      children: [
        const SizedBox(height: 32),
        Center(
          child: IconButton.filled(
            iconSize: 56,
            padding: const EdgeInsets.all(28),
            onPressed: _start,
            icon: const Icon(Icons.mic),
            tooltip: '开始识别',
          ),
        ),
        const SizedBox(height: 12),
        Text('轻触开始识别（约 $_recordSeconds 秒）',
            style: theme.textTheme.bodyMedium),
        if (_error != null) ...[
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(_error!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.error)),
          ),
        ],
        const SizedBox(height: 8),
        Expanded(child: _buildResults(theme)),
      ],
    );
  }

  /// 录音中：波纹扩散 + 倒计时进度环 + 实时电平声纹
  Widget _buildRecording(ThemeData theme) {
    final cs = theme.colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AnimatedBuilder(
            animation: Listenable.merge([_ripple, _ring]),
            builder: (context, _) => CustomPaint(
              painter: _RipplePainter(progress: _ripple.value, color: cs.primary),
              child: SizedBox(
                width: 240,
                height: 240,
                child: Center(
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      SizedBox(
                        width: 132,
                        height: 132,
                        child: CircularProgressIndicator(
                          value: _ring.value,
                          strokeWidth: 3,
                          color: cs.primary,
                          backgroundColor: cs.surfaceContainerHighest,
                        ),
                      ),
                      ScaleTransition(
                        scale: _pulse,
                        child: IconButton.filled(
                          iconSize: 56,
                          padding: const EdgeInsets.all(28),
                          onPressed: _finish,
                          icon: const Icon(Icons.graphic_eq),
                          tooltip: '提前完成',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          SizedBox(
            width: 280,
            height: 56,
            child: CustomPaint(
                painter: _LevelBarsPainter(levels: _levels, color: cs.primary)),
          ),
          const SizedBox(height: 12),
          Text('正在聆听… $_countdown 秒（点按提前完成）',
              style: theme.textTheme.bodyLarge),
        ],
      ),
    );
  }

  /// 识别中：展示本次录音的真实频谱图
  Widget _buildUploading(ThemeData theme) {
    final spec = _spectrogram;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (spec != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  height: 200,
                  width: double.infinity,
                  child: CustomPaint(painter: _SpectrogramPainter(spec)),
                ),
              ),
            )
          else
            const SizedBox(
                height: 200, child: Center(child: CircularProgressIndicator())),
          const SizedBox(height: 24),
          Text('识别中…', style: theme.textTheme.bodyLarge),
          if (spec != null) ...[
            const SizedBox(height: 8),
            Text('上方为本次录音的频谱图',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline)),
          ],
        ],
      ),
    );
  }

  Widget _buildResults(ThemeData theme) {
    final children = <Widget>[];
    if (_results.isNotEmpty) {
      children.add(_sectionHeader(theme, '本次识别'));
      children.addAll(_results.map(_resultTile));
    }
    if (_history.isNotEmpty) {
      children.add(Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 4, 0),
        child: Row(
          children: [
            Text('识别历史', style: theme.textTheme.titleSmall),
            const Spacer(),
            IconButton(
              tooltip: '清空',
              icon: const Icon(Icons.delete_outline, size: 20),
              onPressed: _confirmClearHistory,
            ),
          ],
        ),
      ));
      children.addAll(_history.map(_attemptTile));
    }
    if (children.isEmpty) return const SizedBox.shrink();
    return ListView(children: children);
  }

  Widget _sectionHeader(ThemeData theme, String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Text(text, style: theme.textTheme.titleSmall),
    );
  }

  Widget _resultTile(RecognizedSong song) {
    final offset = (song.startTimeMs / 1000).toStringAsFixed(1);
    return ListTile(
      leading: const Icon(Icons.music_note),
      title: Text(song.name),
      subtitle: Text(
          '${song.artistText}${song.album != null ? ' · ${song.album}' : ''} · 片段位于 ${offset}s'),
      trailing: IconButton(
        tooltip: '复制歌名',
        icon: const Icon(Icons.copy_outlined),
        onPressed: () {
          Clipboard.setData(ClipboardData(text: song.searchKeyword));
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已复制'), duration: Duration(seconds: 1)),
          );
        },
      ),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute<Widget>(
          builder: (_) => SearchScreen(initialKeyword: song.searchKeyword),
        ),
      ),
    );
  }

  /// 历史条目：可回放片段（暂停主播放器）、单条删除、成功条目可回链搜索
  Widget _attemptTile(RecognitionAttempt a) {
    final song = a.songs.isNotEmpty ? a.songs.first : null;
    return AnimatedBuilder(
      animation: _clipPlayer,
      builder: (context, _) {
        final playing = a.clip != null && _clipPlayer.playingId == a.clip;
        return ListTile(
          leading: a.clip != null
              ? IconButton(
                  tooltip: playing ? '停止' : '回放录音片段',
                  icon: Icon(playing
                      ? Icons.stop_circle_outlined
                      : Icons.play_circle_outline),
                  onPressed: () => _toggleClip(a),
                )
              : Icon(_statusIcon(a.status)),
          title: Text(a.statusTitle),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(song != null
                  ? '${song.artistText}${song.album != null ? ' · ${song.album}' : ''} · ${_fmtTime(a.at)}'
                  : '${a.message ?? ''} · ${_fmtTime(a.at)}'),
              if (playing)
                StreamBuilder<Duration>(
                  stream: _clipPlayer.positionStream,
                  builder: (context, snap) {
                    final d = _clipPlayer.duration;
                    final v = d != null && d.inMilliseconds > 0
                        ? (snap.data?.inMilliseconds ?? 0) / d.inMilliseconds
                        : 0.0;
                    return Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: LinearProgressIndicator(
                          value: v.clamp(0.0, 1.0), minHeight: 2),
                    );
                  },
                ),
            ],
          ),
          trailing: IconButton(
            tooltip: '删除',
            icon: const Icon(Icons.delete_outline, size: 20),
            onPressed: () => _deleteAttempt(a),
          ),
          onTap: song != null
              ? () => Navigator.push(
                    context,
                    MaterialPageRoute<Widget>(
                      builder: (_) =>
                          SearchScreen(initialKeyword: song.searchKeyword),
                    ),
                  )
              : null,
        );
      },
    );
  }

  Future<void> _toggleClip(RecognitionAttempt a) async {
    final path = await SharedPreferencesService.recognitionClipPath(a.clip);
    if (path == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('片段文件已不存在')),
        );
      }
      return;
    }
    await _clipPlayer.toggle(a.clip!, path);
  }

  static IconData _statusIcon(RecognitionStatus s) => switch (s) {
        RecognitionStatus.ok => Icons.music_note,
        RecognitionStatus.noMatch => Icons.music_off_outlined,
        RecognitionStatus.silent => Icons.mic_off_outlined,
        RecognitionStatus.error => Icons.error_outline,
      };

  static String _fmtTime(int ms) {
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    final hm =
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    final sameDay =
        t.year == now.year && t.month == now.month && t.day == now.day;
    return sameDay ? hm : '${t.month}月${t.day}日 $hm';
  }
}

/// Shazam 风格三层错峰扩散波纹
class _RipplePainter extends CustomPainter {
  _RipplePainter({required this.progress, required this.color});

  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    const minR = 66.0;
    final maxR = size.shortestSide / 2;
    final paint = Paint()..style = PaintingStyle.stroke;
    for (var i = 0; i < 3; i++) {
      final phase = (progress + i / 3) % 1.0;
      paint
        ..color = color.withValues(alpha: (1 - phase) * 0.45)
        ..strokeWidth = 2.5 - phase * 1.5;
      canvas.drawCircle(center, minR + (maxR - minR) * phase, paint);
    }
  }

  @override
  bool shouldRepaint(_RipplePainter old) =>
      old.progress != progress || old.color != color;
}

/// 实时电平声纹（滚动条形图，右新左旧，越新越亮）
class _LevelBarsPainter extends CustomPainter {
  _LevelBarsPainter({required this.levels, required this.color});

  final List<double> levels;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const barW = 4.0, gap = 2.0;
    final maxBars = (size.width / (barW + gap)).floor();
    final start = levels.length > maxBars ? levels.length - maxBars : 0;
    final count = levels.length - start;
    if (count <= 0) return;
    final baseline = size.height / 2;
    final paint = Paint();
    for (var i = 0; i < count; i++) {
      final level = levels[start + i];
      final h = (level * (size.height - 6)).clamp(2.0, size.height);
      paint.color = color.withValues(alpha: 0.3 + 0.7 * (i + 1) / count);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(i * (barW + gap), baseline - h / 2, barW, h),
          const Radius.circular(2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_LevelBarsPainter old) => true;
}

/// 频谱图渲染（inferno 风格色表：黑→紫→品红→橙→黄）
class _SpectrogramPainter extends CustomPainter {
  _SpectrogramPainter(this.spec);

  final Spectrogram spec;

  static final List<Color> _lut = _buildLut();

  static List<Color> _buildLut() {
    const stops = [
      Color(0xFF000000),
      Color(0xFF3B0F4F),
      Color(0xFF9C1C5B),
      Color(0xFFE8601C),
      Color(0xFFF7D13D),
    ];
    return List.generate(256, (i) {
      final t = i / 255 * (stops.length - 1);
      final seg = t.floor().clamp(0, stops.length - 2);
      return Color.lerp(stops[seg], stops[seg + 1], t - seg)!;
    });
  }

  @override
  void paint(Canvas canvas, Size size) {
    final cw = size.width / spec.cols;
    final ch = size.height / spec.rows;
    final paint = Paint();
    for (var c = 0; c < spec.cols; c++) {
      for (var r = 0; r < spec.rows; r++) {
        paint.color = _lut[(spec.at(c, r) * 255).round()];
        canvas.drawRect(
          Rect.fromLTWH(c * cw, size.height - (r + 1) * ch,
              cw.ceilToDouble(), ch.ceilToDouble()),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_SpectrogramPainter old) => old.spec != spec;
}
