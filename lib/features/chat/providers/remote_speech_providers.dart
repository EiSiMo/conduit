import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/direct_connections/services/direct_audio_client.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/remote_speech.dart';
import 'package:conduit_core/services/settings_service.dart';

final directAudioClientProvider = Provider<DirectAudioClient>((ref) {
  return DirectAudioClient(clientPool: ref.watch(directHttpClientPoolProvider));
});

/// Enabled direct connections that can serve speech-to-text and
/// text-to-speech (currently OpenRouter only).
final directAudioProfilesProvider = Provider<List<DirectConnectionProfile>>((
  ref,
) {
  final profiles =
      ref.watch(effectiveDirectConnectionProfilesProvider).value ??
      const <DirectConnectionProfile>[];
  return profiles.where(supportsDirectAudio).toList(growable: false);
});

/// Speech or transcription models of one direct connection. Kept apart from
/// the chat model registry so audio models never show up in the chat picker.
final directAudioModelsProvider = FutureProvider.autoDispose
    .family<
      List<DirectAudioModel>,
      ({String profileId, DirectAudioModelKind kind})
    >((ref, key) async {
      final profile = _findProfile(
        ref.watch(directAudioProfilesProvider),
        key.profileId,
      );
      if (profile == null) return const <DirectAudioModel>[];
      return ref.watch(directAudioClientProvider).listModels(profile, key.kind);
    });

/// The transcriber for the selected STT preference: the Open WebUI API for
/// the server (and device fallback) path, or the chosen direct model.
final activeSpeechTranscriberProvider = Provider<SpeechTranscriber?>((ref) {
  final selection = ref.watch(
    appSettingsProvider.select(
      (s) => (
        preference: s.sttPreference,
        profileId: s.sttDirectProfileId,
        modelId: s.sttDirectModelId,
      ),
    ),
  );
  if (selection.preference != SttPreference.direct) {
    return ref.watch(apiServiceProvider);
  }
  final profile = _findProfile(
    ref.watch(directAudioProfilesProvider),
    selection.profileId,
  );
  final modelId = selection.modelId;
  if (profile == null || modelId == null || modelId.isEmpty) return null;
  return DirectSpeechTranscriber(
    client: ref.watch(directAudioClientProvider),
    profile: profile,
    modelId: modelId,
  );
});

/// The synthesizer for the selected TTS engine: the Open WebUI API for the
/// server (and device fallback) path, or the chosen direct model and voice.
final activeSpeechSynthesizerProvider = Provider<SpeechSynthesizer?>((ref) {
  final selection = ref.watch(
    appSettingsProvider.select(
      (s) => (
        engine: s.ttsEngine,
        profileId: s.ttsDirectProfileId,
        modelId: s.ttsDirectModelId,
        voice: s.ttsDirectVoice,
      ),
    ),
  );
  if (selection.engine != TtsEngine.direct) {
    return ref.watch(apiServiceProvider);
  }
  final profile = _findProfile(
    ref.watch(directAudioProfilesProvider),
    selection.profileId,
  );
  final modelId = selection.modelId;
  if (profile == null || modelId == null || modelId.isEmpty) return null;
  return DirectSpeechSynthesizer(
    client: ref.watch(directAudioClientProvider),
    profile: profile,
    modelId: modelId,
    voice: selection.voice,
  );
});

DirectConnectionProfile? _findProfile(
  List<DirectConnectionProfile> profiles,
  String? id,
) {
  if (id == null) return null;
  for (final profile in profiles) {
    if (profile.id == id) return profile;
  }
  return null;
}
