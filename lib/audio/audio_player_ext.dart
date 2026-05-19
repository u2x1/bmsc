import 'package:just_audio/just_audio.dart';

extension AudioPlayerExt on AudioPlayer {
  Future<void> seekToNextRegardlessOfLoopMode() async {
    if (loopMode == LoopMode.one) {
      if (effectiveIndices.isEmpty) return;
      int targetIndex = ((currentIndex ?? 0) + 1) % effectiveIndices.length;
      await seek(Duration.zero, index: targetIndex);
    } else {
      await seekToNext();
    }
  }

  Future<void> seekToPreviousRegardlessOfLoopMode() async {
    if (loopMode == LoopMode.one) {
      if (effectiveIndices.isEmpty) return;
      int targetIndex = ((currentIndex ?? 0) - 1 + effectiveIndices.length) %
          effectiveIndices.length;
      await seek(Duration.zero, index: targetIndex);
    } else {
      await seekToPrevious();
    }
  }
}
