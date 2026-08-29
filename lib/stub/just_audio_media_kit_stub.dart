import 'package:just_audio/just_audio.dart';

class JustAudioMediaKit {
  static void ensureInitialized() {
    // No-op on web
  }
}

class MediaKitPlayer extends AudioPlayer {
  MediaKitPlayer() : super();
}
