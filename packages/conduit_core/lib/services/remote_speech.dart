import 'dart:typed_data';

/// Transcribes recorded speech on a remote backend (Open WebUI or a direct
/// connection).
abstract interface class SpeechTranscriber {
  /// Returns the provider's JSON response; callers read the text from it.
  Future<Map<String, dynamic>> transcribeSpeech({
    required Uint8List audioBytes,
    String? fileName,
    String? mimeType,
    String? language,
  });
}

/// Synthesizes speech on a remote backend (Open WebUI or a direct
/// connection).
abstract interface class SpeechSynthesizer {
  Future<({Uint8List bytes, String mimeType})> generateSpeech({
    required String text,
    String? voice,
    double? speed,
  });
}
