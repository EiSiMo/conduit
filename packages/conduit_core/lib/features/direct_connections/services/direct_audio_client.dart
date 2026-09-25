import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:http_parser/http_parser.dart';

import 'package:conduit_core/features/direct_connections/models/direct_completion.dart';
import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/services/direct_adapter_helpers.dart';
import 'package:conduit_core/features/direct_connections/services/direct_http_client.dart';
import 'package:conduit_core/services/remote_speech.dart';
import 'package:conduit_core/utils/debug_logger.dart';

/// Which audio endpoint a direct audio model serves.
enum DirectAudioModelKind {
  /// Text to speech, served by `audio/speech`.
  speech('speech'),

  /// Speech to text, served by `audio/transcriptions`.
  transcription('transcription');

  const DirectAudioModelKind(this.outputModality);

  /// The OpenRouter `output_modalities` filter value for this kind.
  final String outputModality;
}

/// A speech or transcription model offered by a direct connection.
final class DirectAudioModel {
  const DirectAudioModel({
    required this.id,
    required this.name,
    this.voices = const <String>[],
  });

  final String id;
  final String name;

  /// Voices the provider advertises for a speech model. Empty for
  /// transcription models and for speech models without a published list.
  final List<String> voices;
}

/// Whether [profile] can serve direct speech-to-text and text-to-speech.
///
/// Only OpenRouter publishes which models serve the audio endpoints (and
/// their voices), so other OpenAI-compatible providers are not offered yet.
bool supportsDirectAudio(DirectConnectionProfile profile) =>
    profile.enabled && profile.isOpenRouter;

/// Talks to a direct connection's OpenAI-compatible audio endpoints.
///
/// Requests go through [DirectHttpClientPool], so the profile's base URL,
/// credentials, custom headers and TLS policy apply exactly as for chat.
final class DirectAudioClient {
  DirectAudioClient({DirectHttpClientPool? clientPool})
    : _clientPool = clientPool ?? DirectHttpClientPool(),
      _ownsClientPool = clientPool == null;

  static const int _maxSpeechBytes = 32 * 1024 * 1024;

  final DirectHttpClientPool _clientPool;
  final bool _ownsClientPool;
  final Set<String> _pcmOnlyModels = <String>{};

  void dispose() {
    if (_ownsClientPool) _clientPool.dispose();
  }

  /// Lists the models of [kind] that [profile] offers.
  ///
  /// OpenRouter leaves audio models out of the plain model list, so they are
  /// requested explicitly through the `output_modalities` filter.
  Future<List<DirectAudioModel>> listModels(
    DirectConnectionProfile profile,
    DirectAudioModelKind kind,
  ) async {
    if (!supportsDirectAudio(profile)) return const <DirectAudioModel>[];
    final raw = await _request<Object?>(profile, 'audio-models-failed', (
      dio,
    ) async {
      final response = await dio.get<ResponseBody>(
        'models',
        queryParameters: {'output_modalities': kind.outputModality},
        options: Options(responseType: ResponseType.stream),
      );
      return decodeDirectJsonValue(response.data!);
    });
    final data = raw is Map ? raw['data'] : raw;
    if (data is! List) {
      throw const FormatException('Model list is missing.');
    }

    final models = <DirectAudioModel>[];
    final seen = <String>{};
    for (final item in data) {
      if (item is! Map) continue;
      final id = item['id']?.toString().trim();
      if (id == null || id.isEmpty || !seen.add(id)) continue;
      final name = item['name']?.toString().trim();
      final voices = item['supported_voices'];
      models.add(
        DirectAudioModel(
          id: id,
          name: (name == null || name.isEmpty) ? id : name,
          voices: voices is List
              ? voices
                    .map((voice) => voice.toString().trim())
                    .where((voice) => voice.isNotEmpty)
                    .toList(growable: false)
              : const <String>[],
        ),
      );
    }
    models.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return models;
  }

  Future<Map<String, dynamic>> transcribe(
    DirectConnectionProfile profile, {
    required String modelId,
    required Uint8List audioBytes,
    String? fileName,
    String? mimeType,
    String? language,
  }) async {
    if (audioBytes.isEmpty) {
      throw ArgumentError('audioBytes cannot be empty for transcription');
    }
    final resolvedName = (fileName ?? '').trim().isEmpty
        ? 'audio.wav'
        : fileName!.trim();
    final resolvedMimeType = (mimeType ?? '').trim().isEmpty
        ? 'audio/wav'
        : mimeType!.trim();
    final trimmedLanguage = language?.trim();

    return _request(profile, 'transcription-failed', (dio) async {
      final response = await dio.post<ResponseBody>(
        'audio/transcriptions',
        data: FormData.fromMap({
          'model': modelId,
          'file': MultipartFile.fromBytes(
            audioBytes,
            filename: resolvedName,
            contentType: MediaType.parse(resolvedMimeType),
          ),
          if (trimmedLanguage != null && trimmedLanguage.isNotEmpty)
            'language': trimmedLanguage,
        }),
        options: Options(responseType: ResponseType.stream),
      );
      return decodeDirectJsonBody(response.data!);
    });
  }

  Future<({Uint8List bytes, String mimeType})> synthesize(
    DirectConnectionProfile profile, {
    required String modelId,
    required String text,
    String? voice,
    double? speed,
  }) async {
    if (!_pcmOnlyModels.contains(modelId)) {
      try {
        return await _synthesize(
          profile,
          modelId: modelId,
          text: text,
          voice: voice,
          speed: speed,
          format: 'mp3',
        );
      } on DirectProviderException catch (error) {
        // Some models (e.g. Gemini TTS) reject mp3 and only stream raw PCM.
        // Remember that so later chunks skip the failing round trip.
        if (error.statusCode != 400 ||
            !error.message.toLowerCase().contains('pcm')) {
          rethrow;
        }
        _pcmOnlyModels.add(modelId);
      }
    }
    return _synthesize(
      profile,
      modelId: modelId,
      text: text,
      voice: voice,
      speed: speed,
      format: 'pcm',
    );
  }

  Future<({Uint8List bytes, String mimeType})> _synthesize(
    DirectConnectionProfile profile, {
    required String modelId,
    required String text,
    required String? voice,
    required double? speed,
    required String format,
  }) {
    final trimmedVoice = voice?.trim();
    return _request(profile, 'speech-failed', (dio) async {
      final response = await dio.post<ResponseBody>(
        'audio/speech',
        data: {
          'model': modelId,
          'input': text,
          if (trimmedVoice != null && trimmedVoice.isNotEmpty)
            'voice': trimmedVoice,
          'speed': ?speed,
          // OpenRouter defaults to raw PCM, which the players cannot decode
          // without a container, so mp3 is preferred where supported.
          'response_format': format,
        },
        options: Options(responseType: ResponseType.stream),
      );
      final builder = BytesBuilder(copy: false);
      await for (final chunk in directStreamingResponseBytes(
        response.data!,
        maxBytes: _maxSpeechBytes,
      )) {
        builder.add(chunk);
      }
      final bytes = builder.takeBytes();
      final rawContentType = response.headers.value(Headers.contentTypeHeader);
      final contentType = rawContentType?.split(';').first.trim().toLowerCase();

      if (format == 'pcm' && !_isWav(bytes)) {
        final sampleRate = _pcmSampleRate(rawContentType);
        DebugLogger.log(
          'speech-pcm',
          scope: 'direct-connections/audio',
          data: {
            'contentType': rawContentType,
            'bytes': bytes.length,
            'sampleRate': sampleRate,
          },
        );
        return (
          bytes: wrapPcm16AsWav(bytes, sampleRate: sampleRate),
          mimeType: 'audio/wav',
        );
      }
      return (
        bytes: bytes,
        mimeType: (contentType == null || !contentType.startsWith('audio/'))
            ? 'audio/mpeg'
            : contentType,
      );
    });
  }

  static bool _isWav(Uint8List bytes) =>
      bytes.length >= 12 &&
      bytes[0] == 0x52 && // R
      bytes[1] == 0x49 && // I
      bytes[2] == 0x46 && // F
      bytes[3] == 0x46 && // F
      bytes[8] == 0x57 && // W
      bytes[9] == 0x41 && // A
      bytes[10] == 0x56 && // V
      bytes[11] == 0x45; // E

  /// Reads `rate=`/`sample_rate=` from a content type such as
  /// `audio/pcm;rate=24000`. OpenRouter documents no rate, and its speech
  /// providers stream 24 kHz 16-bit mono PCM, so that is the fallback.
  static int _pcmSampleRate(String? contentType) {
    final match = RegExp(
      r'(?:sample_)?rate=(\d+)',
      caseSensitive: false,
    ).firstMatch(contentType ?? '');
    final rate = match == null ? null : int.tryParse(match.group(1)!);
    return (rate != null && rate > 0) ? rate : 24000;
  }

  Future<T> _request<T>(
    DirectConnectionProfile profile,
    String logEvent,
    Future<T> Function(Dio dio) run,
  ) async {
    final lease = _clientPool.acquire(profile);
    try {
      return await run(lease.dio);
    } catch (error) {
      final sensitiveValues = directProfileSensitiveValues(profile);
      final normalized = await normalizeDirectProviderErrorWithBody(
        error,
        sensitiveValues: sensitiveValues,
      );
      DebugLogger.error(
        logEvent,
        scope: 'direct-connections/audio',
        error: sanitizeDirectProviderErrorMessage(
          normalized.message,
          sensitiveValues: sensitiveValues,
        ),
      );
      throw normalized;
    } finally {
      lease.release();
    }
  }
}

/// [SpeechTranscriber] bound to one direct connection and model.
final class DirectSpeechTranscriber implements SpeechTranscriber {
  const DirectSpeechTranscriber({
    required DirectAudioClient client,
    required this.profile,
    required this.modelId,
  }) : _client = client;

  final DirectAudioClient _client;
  final DirectConnectionProfile profile;
  final String modelId;

  @override
  Future<Map<String, dynamic>> transcribeSpeech({
    required Uint8List audioBytes,
    String? fileName,
    String? mimeType,
    String? language,
  }) {
    return _client.transcribe(
      profile,
      modelId: modelId,
      audioBytes: audioBytes,
      fileName: fileName,
      mimeType: mimeType,
      language: language,
    );
  }
}

/// [SpeechSynthesizer] bound to one direct connection, model and voice.
///
/// The voice is part of the direct selection because voices are
/// model-specific. The `voice` passed per call is the Open WebUI voice (or
/// its server default) and is ignored so it never reaches the provider.
final class DirectSpeechSynthesizer implements SpeechSynthesizer {
  const DirectSpeechSynthesizer({
    required DirectAudioClient client,
    required this.profile,
    required this.modelId,
    this.voice,
  }) : _client = client;

  final DirectAudioClient _client;
  final DirectConnectionProfile profile;
  final String modelId;
  final String? voice;

  @override
  Future<({Uint8List bytes, String mimeType})> generateSpeech({
    required String text,
    String? voice,
    double? speed,
  }) {
    return _client.synthesize(
      profile,
      modelId: modelId,
      text: text,
      voice: this.voice,
      speed: speed,
    );
  }
}

/// Wraps raw little-endian 16-bit mono PCM in a WAV container so the audio
/// players can decode it.
Uint8List wrapPcm16AsWav(Uint8List pcm, {required int sampleRate}) {
  const channels = 1;
  const bitsPerSample = 16;
  final header = ByteData(44);
  void ascii(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      header.setUint8(offset + i, value.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  header.setUint32(4, 36 + pcm.length, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little); // PCM
  header.setUint16(22, channels, Endian.little);
  header.setUint32(24, sampleRate, Endian.little);
  header.setUint32(
    28,
    sampleRate * channels * bitsPerSample ~/ 8,
    Endian.little,
  );
  header.setUint16(32, channels * bitsPerSample ~/ 8, Endian.little);
  header.setUint16(34, bitsPerSample, Endian.little);
  ascii(36, 'data');
  header.setUint32(40, pcm.length, Endian.little);
  return (BytesBuilder(copy: false)
        ..add(header.buffer.asUint8List())
        ..add(pcm))
      .takeBytes();
}
