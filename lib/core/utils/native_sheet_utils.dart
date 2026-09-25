import 'dart:convert';

import 'package:intl/intl.dart';

import '../../l10n/app_localizations.dart';
import '../../shared/utils/locale_display_formatters.dart';

import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/server_memory.dart';
import 'package:conduit_core/models/socket_health.dart';

import '../services/native_sheet_bridge.dart';

import 'package:conduit_core/features/direct_connections/services/direct_audio_client.dart';
import 'package:conduit_core/services/settings_service.dart';

import 'tts_voice_utils.dart';

String nativeQuickActionsTitle(AppLocalizations l10n) {
  return l10n.quickActionsDescription;
}

String nativeSettingsTitle(AppLocalizations _) => 'Settings';

String nativeProfileTitle(AppLocalizations _) => 'Profile';

String nativeAppearanceTitle(AppLocalizations l10n) => l10n.settingsAppearance;

String nativeChatsTitle(AppLocalizations _) => 'Chats';

String nativeAiMemoryTitle(AppLocalizations _) => 'AI and Memory';

String nativeDataConnectionTitle(AppLocalizations l10n) =>
    l10n.settingsDataAndConnection;

String? resolveNativeSheetModelName(List<Model> models, String? modelId) {
  if (modelId == null || modelId.isEmpty) return null;
  for (final model in models) {
    if (model.id == modelId) return model.name;
  }
  return modelId;
}

String nativeSheetPreviewText(AppLocalizations l10n, String? value) {
  if (value == null || value.trim().isEmpty) return l10n.notSet;
  final text = value.trim();
  if (text.length > 88) return '${text.substring(0, 85)}...';
  return text;
}

String truncateNativeSheetMemory(String content) {
  final normalized = content.trim().replaceAll('\n', ' ');
  if (normalized.length <= 72) return normalized;
  return '${normalized.substring(0, 69)}...';
}

String nativeSheetMemoryUpdatedSubtitle(
  AppLocalizations l10n,
  ServerMemory memory,
) {
  final formatted = DateFormat.yMMMd().add_jm().format(memory.updatedAt);
  return l10n.memoryUpdatedAt(formatted);
}

NativeSheetItemConfig buildNativeLoadingItem(
  AppLocalizations l10n, {
  String id = 'loading',
  String? title,
  String sfSymbol = 'ellipsis.circle',
}) {
  return NativeSheetItemConfig(
    id: id,
    title: title ?? l10n.loadingShort,
    sfSymbol: sfSymbol,
    kind: NativeSheetItemKind.info,
  );
}

NativeSheetDetailConfig buildNativeLoadingDetail({
  required AppLocalizations l10n,
  required String id,
  required String title,
  String? subtitle,
}) {
  return NativeSheetDetailConfig(
    id: id,
    title: title,
    subtitle: subtitle,
    items: [buildNativeLoadingItem(l10n, id: '$id-loading')],
  );
}

class NativeAudioSheetParts {
  const NativeAudioSheetParts({
    required this.mainSections,
    required this.voicePickerDetail,
  });

  final List<NativeSheetSectionConfig> mainSections;
  final NativeSheetDetailConfig voicePickerDetail;
}

/// Option id for a direct audio model in the native pickers.
String encodeNativeDirectAudioModelId(String profileId, String modelId) =>
    jsonEncode([profileId, modelId]);

/// Reverses [encodeNativeDirectAudioModelId].
({String profileId, String modelId})? decodeNativeDirectAudioModelId(
  Object? value,
) {
  if (value is! String) return null;
  try {
    final decoded = jsonDecode(value);
    if (decoded is List &&
        decoded.length == 2 &&
        decoded[0] is String &&
        decoded[1] is String) {
      return (profileId: decoded[0] as String, modelId: decoded[1] as String);
    }
  } on FormatException {
    return null;
  }
  return null;
}

/// A direct audio model with the connection that serves it.
typedef NativeDirectAudioModel = ({
  String profileId,
  String profileName,
  DirectAudioModel model,
});

NativeAudioSheetParts buildNativeAudioSheetParts(
  AppLocalizations l10n,
  AppSettings appSettings, {
  List<Map<String, dynamic>> ttsVoices = const <Map<String, dynamic>>[],
  bool directAudioAvailable = false,
  List<NativeDirectAudioModel> sttDirectModels =
      const <NativeDirectAudioModel>[],
  List<NativeDirectAudioModel> ttsDirectModels =
      const <NativeDirectAudioModel>[],
}) {
  final sttDirect = appSettings.sttPreference == SttPreference.direct;
  final ttsDirect = appSettings.ttsEngine == TtsEngine.direct;
  final sttSegment = NativeSheetItemConfig(
    id: 'stt-engine',
    title: l10n.sttSettings,
    subtitle: switch (appSettings.sttPreference) {
      SttPreference.deviceOnly => l10n.sttEngineDeviceDescription,
      SttPreference.serverOnly => l10n.sttEngineServerDescription,
      SttPreference.direct => l10n.sttEngineDirectDescription,
    },
    sfSymbol: 'mic',
    kind: NativeSheetItemKind.segment,
    value: appSettings.sttPreference.name,
    options: [
      NativeSheetOptionConfig(id: 'deviceOnly', label: l10n.sttEngineDevice),
      NativeSheetOptionConfig(id: 'serverOnly', label: l10n.sttEngineServer),
      if (directAudioAvailable || sttDirect)
        NativeSheetOptionConfig(
          id: SttPreference.direct.name,
          label: l10n.sttEngineDirect,
        ),
    ],
  );

  NativeSheetItemConfig directModelPicker({
    required String id,
    required String? profileId,
    required String? modelId,
    required List<NativeDirectAudioModel> models,
  }) {
    final showProfile = models.map((m) => m.profileId).toSet().length > 1;
    return NativeSheetItemConfig(
      id: id,
      title: l10n.directAudioModel,
      subtitle: modelId ?? l10n.directAudioModelNotSelected,
      sfSymbol: 'cube',
      kind: NativeSheetItemKind.searchablePicker,
      value: profileId == null || modelId == null
          ? ''
          : encodeNativeDirectAudioModelId(profileId, modelId),
      options: [
        for (final entry in models)
          NativeSheetOptionConfig(
            id: encodeNativeDirectAudioModelId(entry.profileId, entry.model.id),
            label: entry.model.name,
            subtitle: showProfile
                ? '${entry.profileName} · ${entry.model.id}'
                : entry.model.id,
          ),
      ],
    );
  }

  final silenceDivisions =
      ((SettingsService.maxVoiceSilenceDurationMs -
                  SettingsService.minVoiceSilenceDurationMs) ~/
              100)
          .clamp(1, 1000)
          .toInt();

  final silenceSlider = NativeSheetItemConfig(
    id: 'stt-silence-duration',
    title: l10n.sttSilenceDuration,
    subtitle: l10n.sttSilenceDurationDescription,
    sfSymbol: 'timer',
    kind: NativeSheetItemKind.slider,
    value: appSettings.voiceSilenceDuration.toDouble(),
    min: SettingsService.minVoiceSilenceDurationMs.toDouble(),
    max: SettingsService.maxVoiceSilenceDurationMs.toDouble(),
    divisions: silenceDivisions,
  );

  final sttLanguageField = NativeSheetItemConfig(
    id: 'stt-language-code',
    title: l10n.sttTranscriptionLanguage,
    subtitle: appSettings.sttLanguageCode ?? l10n.sttTranscriptionLanguageAuto,
    sfSymbol: 'globe',
    kind: NativeSheetItemKind.textField,
    value: appSettings.sttLanguageCode ?? '',
    placeholder: l10n.sttTranscriptionLanguagePlaceholder,
  );

  final ttsSegment = NativeSheetItemConfig(
    id: 'tts-engine',
    title: l10n.ttsSettings,
    subtitle: switch (appSettings.ttsEngine) {
      TtsEngine.device => l10n.ttsEngineDeviceDescription,
      TtsEngine.server => l10n.ttsEngineServerDescription,
      TtsEngine.direct => l10n.ttsEngineDirectDescription,
    },
    sfSymbol: 'speaker.wave.2',
    kind: NativeSheetItemKind.segment,
    value: appSettings.ttsEngine.name,
    options: [
      NativeSheetOptionConfig(id: 'device', label: l10n.ttsEngineDevice),
      NativeSheetOptionConfig(id: 'server', label: l10n.ttsEngineServer),
      if (directAudioAvailable || ttsDirect)
        NativeSheetOptionConfig(
          id: TtsEngine.direct.name,
          label: l10n.ttsEngineDirect,
        ),
    ],
  );

  final voiceOptions = buildTtsVoiceOptions(
    l10n,
    appSettings.ttsEngine,
    ttsVoices,
  );
  final selectedVoiceId = selectedTtsVoiceOptionId(appSettings, ttsVoices);

  final voicePickerNav = NativeSheetItemConfig(
    id: 'tts-voice-picker',
    title: l10n.ttsVoice,
    subtitle: _nativeVoiceSubtitle(l10n, appSettings),
    sfSymbol: 'person.wave.2',
    kind: NativeSheetItemKind.searchablePicker,
    value: selectedVoiceId,
    options: [
      // Direct providers mostly require an explicit voice.
      if (!ttsDirect)
        NativeSheetOptionConfig(
          id: ttsSystemDefaultVoiceId,
          label: l10n.ttsSystemDefault,
        ),
      for (final option in voiceOptions)
        NativeSheetOptionConfig(
          id: option.id,
          label: option.label,
          subtitle: option.subtitle,
          sfSymbol: 'person.wave.2',
        ),
    ],
  );

  final speechRateSlider = NativeSheetItemConfig(
    id: 'tts-speech-rate',
    title: l10n.ttsSpeechRate,
    sfSymbol: 'gauge.with.dots.needle.67percent',
    kind: NativeSheetItemKind.slider,
    value: appSettings.ttsSpeechRate,
    min: 0.25,
    max: 2.0,
    divisions: 35,
  );

  final previewNav = NativeSheetItemConfig(
    id: 'tts-preview',
    title: l10n.ttsPreview,
    subtitle: l10n.ttsPreviewText,
    sfSymbol: 'play.circle',
    value: l10n.ttsPreviewText,
  );

  final sttItems = <NativeSheetItemConfig>[
    sttSegment,
    if (sttDirect)
      directModelPicker(
        id: 'stt-direct-model',
        profileId: appSettings.sttDirectProfileId,
        modelId: appSettings.sttDirectModelId,
        models: sttDirectModels,
      ),
    if (appSettings.sttPreference != SttPreference.deviceOnly) ...[
      sttLanguageField,
      silenceSlider,
    ],
    NativeSheetItemConfig(
      id: 'voice-barge-in',
      title: l10n.voiceBargeIn,
      subtitle: l10n.voiceBargeInDescription,
      sfSymbol: 'waveform',
      kind: NativeSheetItemKind.toggle,
      value: appSettings.voiceBargeInEnabled,
    ),
  ];

  final ttsItems = <NativeSheetItemConfig>[
    ttsSegment,
    if (ttsDirect)
      directModelPicker(
        id: 'tts-direct-model',
        profileId: appSettings.ttsDirectProfileId,
        modelId: appSettings.ttsDirectModelId,
        models: ttsDirectModels,
      ),
    if (!ttsDirect || appSettings.ttsDirectModelId != null) voicePickerNav,
    if (appSettings.ttsEngine == TtsEngine.device) speechRateSlider,
    previewNav,
  ];

  final voicePickerDetail = NativeSheetDetailConfig(
    id: 'tts-voice-picker',
    title: l10n.ttsSelectVoice,
    subtitle: l10n.ttsVoice,
    items: const [],
  );

  return NativeAudioSheetParts(
    mainSections: [
      NativeSheetSectionConfig(items: sttItems),
      NativeSheetSectionConfig(items: ttsItems),
    ],
    voicePickerDetail: voicePickerDetail,
  );
}

String _nativeVoiceSubtitle(AppLocalizations l10n, AppSettings settings) {
  if (settings.ttsEngine == TtsEngine.direct) {
    return settings.ttsDirectVoice ?? l10n.ttsSystemDefault;
  }
  if (settings.ttsEngine == TtsEngine.server) {
    final voice =
        settings.ttsServerVoiceName ??
        settings.ttsServerVoiceId ??
        l10n.ttsSystemDefault;
    return formatTtsVoiceDisplayName(voice);
  }
  final voice =
      settings.ttsVoiceName ?? settings.ttsVoice ?? l10n.ttsSystemDefault;
  return formatTtsVoiceDisplayName(voice);
}

NativeSheetDetailConfig buildNativePasswordDetail(
  AppLocalizations l10n, {
  required bool passwordChangeEnabled,
  String? subtitle,
}) {
  final items = passwordChangeEnabled
      ? [
          NativeSheetItemConfig(
            id: 'current-password',
            title: l10n.currentPassword,
            subtitle: l10n.passwordHint,
            sfSymbol: 'lock',
            kind: NativeSheetItemKind.secureTextField,
            placeholder: l10n.currentPassword,
          ),
          NativeSheetItemConfig(
            id: 'new-password',
            title: l10n.newPassword,
            subtitle: l10n.passwordHint,
            sfSymbol: 'key',
            kind: NativeSheetItemKind.secureTextField,
            placeholder: l10n.newPassword,
          ),
          NativeSheetItemConfig(
            id: 'confirm-password',
            title: l10n.confirmNewPassword,
            subtitle: l10n.passwordHint,
            sfSymbol: 'checkmark.shield',
            kind: NativeSheetItemKind.secureTextField,
            placeholder: l10n.confirmNewPassword,
          ),
        ]
      : [
          NativeSheetItemConfig(
            id: 'password-unavailable',
            title: l10n.changePasswordTitle,
            subtitle: l10n.passwordChangeUnavailable,
            sfSymbol: 'lock.slash',
            kind: NativeSheetItemKind.info,
          ),
        ];
  return NativeSheetDetailConfig(
    id: 'password',
    title: l10n.changePasswordTitle,
    subtitle: passwordChangeEnabled ? subtitle : null,
    items: items,
  );
}

List<NativeSheetOptionConfig> buildNativeDefaultModelOptions(
  AppLocalizations l10n,
  List<Model> models,
) {
  return [
    NativeSheetOptionConfig(id: 'auto-select', label: l10n.autoSelect),
    for (final model in models)
      NativeSheetOptionConfig(id: model.id, label: model.name),
  ];
}

NativeSheetDetailConfig buildNativeDefaultModelDetail(
  AppLocalizations l10n, {
  required List<Model> models,
  required String? selectedModelId,
  String? subtitle,
}) {
  return NativeSheetDetailConfig(
    id: 'default-model',
    title: l10n.defaultModel,
    subtitle: subtitle ?? l10n.autoSelectDescription,
    items: [
      NativeSheetItemConfig(
        id: 'default-model',
        title: l10n.defaultModel,
        subtitle: l10n.autoSelectDescription,
        sfSymbol: 'wand.and.stars',
        kind: NativeSheetItemKind.dropdown,
        value: selectedModelId ?? 'auto-select',
        options: buildNativeDefaultModelOptions(l10n, models),
      ),
    ],
  );
}

NativeSheetItemConfig? buildNativeOpenRouterImageGenerationModelItem(
  AppLocalizations l10n, {
  required List<Model> models,
  required String? selectedModelId,
}) {
  final isAvailable = models.any(
    (model) =>
        model.capabilities?['openrouter'] == true &&
        model.capabilities?['image_generation'] == true,
  );
  if (!isAvailable) return null;

  return NativeSheetItemConfig(
    id: 'default-image-generation-model',
    title: l10n.defaultImageGenerationModel,
    subtitle: selectedModelId ?? l10n.openRouterDefaultImageGenerationModel,
    sfSymbol: 'photo.on.rectangle',
  );
}

NativeSheetDetailConfig buildNativeOpenRouterImageGenerationModelDetail(
  AppLocalizations l10n, {
  required String value,
}) {
  return NativeSheetDetailConfig(
    id: 'default-image-generation-model',
    title: l10n.defaultImageGenerationModel,
    subtitle: l10n.defaultImageGenerationModelDescription,
    items: [
      NativeSheetItemConfig(
        id: 'default-image-generation-model',
        title: l10n.defaultImageGenerationModel,
        subtitle: l10n.defaultImageGenerationModelDescription,
        sfSymbol: 'photo.on.rectangle',
        kind: NativeSheetItemKind.textField,
        value: value,
        placeholder: 'openai/gpt-5-image',
      ),
    ],
  );
}

NativeSheetDetailConfig buildNativeSystemPromptDetail(
  AppLocalizations l10n, {
  required String value,
  String? subtitle,
}) {
  return NativeSheetDetailConfig(
    id: 'system-prompt',
    title: l10n.yourSystemPrompt,
    subtitle: subtitle ?? l10n.yourSystemPromptDescription,
    items: [
      NativeSheetItemConfig(
        id: 'system-prompt',
        title: l10n.yourSystemPrompt,
        subtitle: l10n.enterSystemPrompt,
        sfSymbol: 'text.bubble',
        kind: NativeSheetItemKind.multilineTextField,
        value: value,
        placeholder: l10n.enterSystemPrompt,
      ),
    ],
  );
}

NativeSheetDetailConfig buildNativeMemoryAddDetail(AppLocalizations l10n) {
  return NativeSheetDetailConfig(
    id: 'memory-add',
    title: l10n.addMemory,
    subtitle: l10n.memoryEditorDescription,
    items: [
      NativeSheetItemConfig(
        id: 'memory-add-content',
        title: l10n.addMemory,
        sfSymbol: 'plus.circle',
        kind: NativeSheetItemKind.multilineTextField,
        value: '',
        placeholder: l10n.memoryHint,
      ),
    ],
  );
}

List<NativeSheetDetailConfig> buildNativeMemoryEditDetails(
  AppLocalizations l10n,
  List<ServerMemory> memories,
) {
  return [
    for (final memory in memories)
      NativeSheetDetailConfig(
        id: 'memory-edit:${Uri.encodeComponent(memory.id)}',
        title: l10n.editMemory,
        subtitle: l10n.memoryEditorDescription,
        items: [
          NativeSheetItemConfig(
            id: 'memory-save:${Uri.encodeComponent(memory.id)}',
            title: l10n.editMemory,
            sfSymbol: 'quote.bubble',
            kind: NativeSheetItemKind.multilineTextField,
            value: memory.content,
            placeholder: l10n.memoryHint,
          ),
          NativeSheetItemConfig(
            id: 'memory-delete:${Uri.encodeComponent(memory.id)}',
            title: l10n.deleteMemory,
            subtitle: l10n.deleteMemoryConfirm,
            sfSymbol: 'trash',
            destructive: true,
          ),
        ],
      ),
  ];
}

List<NativeSheetDetailConfig> buildNativeModelPromptLoadingDetails(
  AppLocalizations l10n,
  List<Model> models,
) {
  return [
    for (final model in models)
      NativeSheetDetailConfig(
        id: 'model-prompt:${Uri.encodeComponent(model.id)}',
        title: l10n.modelSystemPromptTitle(model.name),
        items: [
          buildNativeLoadingItem(
            l10n,
            id: 'model-prompt-loading:${Uri.encodeComponent(model.id)}',
          ),
        ],
      ),
  ];
}

String nativeLanguageLabel(AppLocalizations l10n, String code) {
  switch (code) {
    case 'system':
      return l10n.system;
    case 'en':
      return l10n.english;
    case 'cs':
      return l10n.czech;
    case 'sk':
      return l10n.slovak;
    case 'pl':
      return l10n.polish;
    case 'de':
      return l10n.deutsch;
    case 'fr':
      return l10n.francais;
    case 'it':
      return l10n.italiano;
    case 'es':
      return l10n.espanol;
    case 'nl':
      return l10n.nederlands;
    case 'ru':
      return l10n.russian;
    case 'zh':
      return l10n.chineseSimplified;
    case 'ko':
      return l10n.korean;
    case 'ja':
      return l10n.japanese;
    case 'zh-Hant':
      return l10n.chineseTraditional;
    default:
      final normalized = code.replaceAll('_', '-').toLowerCase();
      if (normalized == 'zh-hant') return l10n.chineseTraditional;
      if (normalized == 'zh') return l10n.chineseSimplified;
      if (normalized == 'ko') return l10n.korean;
      if (normalized == 'ja') return l10n.japanese;
      if (normalized == 'cs') return l10n.czech;
      if (normalized == 'sk') return l10n.slovak;
      if (normalized == 'pl') return l10n.polish;
      return l10n.system;
  }
}

List<NativeSheetOptionConfig> nativeLanguageDropdownOptions(
  AppLocalizations l10n,
) {
  return [
    NativeSheetOptionConfig(id: 'system', label: l10n.system),
    NativeSheetOptionConfig(id: 'en', label: l10n.english),
    NativeSheetOptionConfig(id: 'cs', label: l10n.czech),
    NativeSheetOptionConfig(id: 'sk', label: l10n.slovak),
    NativeSheetOptionConfig(id: 'pl', label: l10n.polish),
    NativeSheetOptionConfig(id: 'de', label: l10n.deutsch),
    NativeSheetOptionConfig(id: 'es', label: l10n.espanol),
    NativeSheetOptionConfig(id: 'fr', label: l10n.francais),
    NativeSheetOptionConfig(id: 'it', label: l10n.italiano),
    NativeSheetOptionConfig(id: 'nl', label: l10n.nederlands),
    NativeSheetOptionConfig(id: 'ru', label: l10n.russian),
    NativeSheetOptionConfig(id: 'zh', label: l10n.chineseSimplified),
    NativeSheetOptionConfig(id: 'zh-Hant', label: l10n.chineseTraditional),
    NativeSheetOptionConfig(id: 'ko', label: l10n.korean),
    NativeSheetOptionConfig(id: 'ja', label: l10n.japanese),
  ];
}

String nativeSocketHealthSummary(AppLocalizations l10n, SocketHealth? health) {
  if (health == null) return l10n.socketNotConnected;
  if (!health.isConnected) return l10n.socketDisconnected;
  final transport = _nativeSocketTransportLabel(l10n, health.transport);
  if (health.hasLatencyInfo) {
    return '$transport · ${health.latencyMs}ms';
  }
  return transport;
}

List<NativeSheetItemConfig> nativeSocketHealthItems(
  AppLocalizations l10n,
  SocketHealth? health,
) {
  if (health == null) {
    return [
      NativeSheetItemConfig(
        id: 'socket-health-null',
        title: l10n.socketNotConnected,
        sfSymbol: 'cloud.fill',
        kind: NativeSheetItemKind.info,
      ),
    ];
  }
  final transportLabel = _nativeSocketTransportLabel(l10n, health.transport);
  final items = <NativeSheetItemConfig>[
    NativeSheetItemConfig(
      id: 'socket-connected',
      title: health.isConnected
          ? l10n.socketConnected
          : l10n.socketDisconnected,
      subtitle: transportLabel,
      sfSymbol: health.isConnected
          ? 'checkmark.circle.fill'
          : 'xmark.circle.fill',
      kind: NativeSheetItemKind.info,
    ),
  ];
  if (health.isConnected && health.hasLatencyInfo) {
    items.add(
      NativeSheetItemConfig(
        id: 'socket-latency',
        title: l10n.socketLatencyLabel,
        subtitle:
            '${health.latencyMs}ms · ${_nativeSocketQualityLabel(l10n, health.quality)}',
        sfSymbol: 'gauge.with.dots.needle.67percent',
        kind: NativeSheetItemKind.info,
      ),
    );
  }
  items.add(
    NativeSheetItemConfig(
      id: 'socket-reconnects',
      title: l10n.socketReconnectsLabel,
      subtitle: '${health.reconnectCount}',
      sfSymbol: 'arrow.clockwise',
      kind: NativeSheetItemKind.info,
    ),
  );
  if (health.lastHeartbeat != null) {
    items.add(
      NativeSheetItemConfig(
        id: 'socket-heartbeat',
        title: l10n.socketLastHeartbeat(
          _nativeFormatHeartbeatRelative(l10n, health.lastHeartbeat!),
        ),
        sfSymbol: 'heart.fill',
        kind: NativeSheetItemKind.info,
      ),
    );
  }
  return items;
}

String _nativeSocketTransportLabel(AppLocalizations l10n, String transport) {
  switch (transport) {
    case 'websocket':
      return l10n.socketTransportWebSocket;
    case 'polling':
      return l10n.socketTransportPolling;
    default:
      return l10n.socketTransportUnknown;
  }
}

String _nativeSocketQualityLabel(AppLocalizations l10n, String quality) {
  switch (quality) {
    case 'excellent':
      return l10n.socketQualityExcellent;
    case 'good':
      return l10n.socketQualityGood;
    case 'fair':
      return l10n.socketQualityFair;
    case 'poor':
      return l10n.socketQualityPoor;
    default:
      return '—';
  }
}

String _nativeFormatHeartbeatRelative(
  AppLocalizations l10n,
  DateTime lastHeartbeat,
) => LocaleDisplayFormatters.relativeTime(
  l10n,
  lastHeartbeat,
  fallbackToDate: false,
);
