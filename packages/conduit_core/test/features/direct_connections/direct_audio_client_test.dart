import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/models/direct_completion.dart';
import 'package:conduit_core/features/direct_connections/services/direct_audio_client.dart';
import 'package:conduit_core/features/direct_connections/services/direct_http_client.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

void main() {
  late _RecordingAdapter adapter;
  late DirectHttpClientPool pool;
  late DirectAudioClient client;

  setUp(() {
    adapter = _RecordingAdapter();
    pool = DirectHttpClientPool(
      dioFactory: (_) =>
          Dio(BaseOptions(baseUrl: '$kOpenRouterApiBaseUrl/'))
            ..httpClientAdapter = adapter,
    );
    client = DirectAudioClient(clientPool: pool);
  });

  tearDown(() => pool.dispose());

  group('supportsDirectAudio', () {
    test('accepts enabled OpenRouter profiles only', () {
      check(supportsDirectAudio(_profile())).isTrue();
      check(supportsDirectAudio(_profile(enabled: false))).isFalse();
      check(supportsDirectAudio(_profile(baseUrl: 'https://api.openai.com/v1')))
          .isFalse();
    });
  });

  group('listModels', () {
    test('filters by output modality and reads the voices', () async {
      adapter.respondJson({
        'data': [
          {
            'id': 'openai/gpt-4o-mini-tts',
            'name': 'GPT-4o mini TTS',
            'supported_voices': ['alloy', ' ', 'nova'],
          },
          {'id': 'hexgrad/kokoro-82m', 'supported_voices': null},
          {'id': 'openai/gpt-4o-mini-tts'},
        ],
      });

      final models = await client.listModels(
        _profile(),
        DirectAudioModelKind.speech,
      );

      final request = adapter.requests.single;
      check(request.path).equals('models');
      check(request.queryParameters)
          .deepEquals({'output_modalities': 'speech'});
      check(models.map((m) => m.id).toList())
          .deepEquals(['openai/gpt-4o-mini-tts', 'hexgrad/kokoro-82m']);
      check(models.first.name).equals('GPT-4o mini TTS');
      check(models.first.voices).deepEquals(['alloy', 'nova']);
      check(models.last.name).equals('hexgrad/kokoro-82m');
      check(models.last.voices).isEmpty();
    });

    test('asks for transcription models', () async {
      adapter.respondJson({'data': <Object>[]});

      await client.listModels(_profile(), DirectAudioModelKind.transcription);

      check(adapter.requests.single.queryParameters)
          .deepEquals({'output_modalities': 'transcription'});
    });

    test('never calls a non-OpenRouter provider', () async {
      final models = await client.listModels(
        _profile(baseUrl: 'https://api.openai.com/v1'),
        DirectAudioModelKind.speech,
      );

      check(models).isEmpty();
      check(adapter.requests).isEmpty();
    });
  });

  test('transcribe posts the model and audio as multipart', () async {
    adapter.respondJson({'text': 'hello'});

    final result = await client.transcribe(
      _profile(),
      modelId: 'openai/whisper-1',
      audioBytes: Uint8List.fromList([1, 2, 3]),
      fileName: 'voice.wav',
      mimeType: 'audio/wav',
      language: 'de',
    );

    final request = adapter.requests.single;
    check(request.method).equals('POST');
    check(request.path).equals('audio/transcriptions');
    final form = request.data as FormData;
    check(Map.fromEntries(form.fields))
        .deepEquals({'model': 'openai/whisper-1', 'language': 'de'});
    check(form.files.single.key).equals('file');
    check(form.files.single.value.filename).equals('voice.wav');
    check(result).deepEquals({'text': 'hello'});
  });

  test('synthesize requests mp3 with the given voice', () async {
    adapter.respondBytes([9, 8, 7], contentType: 'audio/mpeg');

    final result = await client.synthesize(
      _profile(),
      modelId: 'openai/gpt-4o-mini-tts',
      text: 'Hi',
      voice: 'nova',
    );

    final request = adapter.requests.single;
    check(request.path).equals('audio/speech');
    check(request.data as Map<String, dynamic>).deepEquals({
      'model': 'openai/gpt-4o-mini-tts',
      'input': 'Hi',
      'voice': 'nova',
      'response_format': 'mp3',
    });
    check(result.bytes).deepEquals([9, 8, 7]);
    check(result.mimeType).equals('audio/mpeg');
  });

  test('synthesizer sends its own voice instead of the server voice', () async {
    adapter.respondBytes([1], contentType: 'application/octet-stream');
    final synthesizer = DirectSpeechSynthesizer(
      client: client,
      profile: _profile(),
      modelId: 'openai/gpt-4o-mini-tts',
      voice: 'alloy',
    );

    final result = await synthesizer.generateSpeech(
      text: 'Hi',
      voice: 'open-webui-default',
    );

    final body = adapter.requests.single.data as Map<String, dynamic>;
    check(body['voice']).equals('alloy');
    check(result.mimeType).equals('audio/mpeg');
  });

  test('falls back to PCM wrapped as WAV for PCM-only models', () async {
    String? format(RequestOptions r) =>
        (r.data as Map<String, dynamic>)['response_format'] as String?;
    adapter
      ..respondJson({
        'error': {'message': 'Gemini TTS only supports response_format="pcm".'},
      }, statusCode: 400)
      ..respondBytes([1, 0, 2, 0], contentType: 'audio/pcm')
      ..respondBytes([3, 0], contentType: 'audio/pcm;rate=16000');

    final first = await client.synthesize(
      _profile(),
      modelId: 'google/gemini-3.8-flash-tts',
      text: 'Hi',
      voice: 'Kore',
    );
    final second = await client.synthesize(
      _profile(),
      modelId: 'google/gemini-3.8-flash-tts',
      text: 'again',
      voice: 'Kore',
    );

    check(adapter.requests.map(format).toList())
        .deepEquals(['mp3', 'pcm', 'pcm']);
    check(first.mimeType).equals('audio/wav');
    check(first.bytes.length).equals(44 + 4);
    check(String.fromCharCodes(first.bytes.sublist(0, 4))).equals('RIFF');
    final header = ByteData.sublistView(first.bytes);
    check(header.getUint32(24, Endian.little)).equals(24000);
    check(header.getUint32(40, Endian.little)).equals(4);
    check(ByteData.sublistView(second.bytes).getUint32(24, Endian.little))
        .equals(16000);
  });

  test('surfaces the provider error message', () async {
    adapter.respondJson({
      'error': {'message': 'Model not found'},
    }, statusCode: 404);

    await expectLater(
      client.synthesize(_profile(), modelId: 'missing', text: 'Hi'),
      throwsA(
        isA<DirectProviderException>().having(
          (e) => e.message,
          'message',
          contains('Model not found'),
        ),
      ),
    );
  });
}

DirectConnectionProfile _profile({
  String baseUrl = kOpenRouterApiBaseUrl,
  bool enabled = true,
}) => DirectConnectionProfile(
  id: 'openrouter',
  name: 'OpenRouter',
  adapterKey: kOpenAiCompatibleAdapterKey,
  baseUrl: baseUrl,
  enabled: enabled,
  apiKey: 'sk-or-test',
);

final class _RecordingAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  final _responses = <ResponseBody Function()>[];

  void respondJson(Object body, {int statusCode = 200}) {
    _responses.add(
      () => ResponseBody.fromString(
        jsonEncode(body),
        statusCode,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      ),
    );
  }

  void respondBytes(List<int> bytes, {required String contentType}) {
    _responses.add(
      () => ResponseBody.fromBytes(
        bytes,
        200,
        headers: {
          Headers.contentTypeHeader: [contentType],
        },
      ),
    );
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return _responses.removeAt(0)();
  }

  @override
  void close({bool force = false}) {}
}
