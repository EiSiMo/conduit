import 'dart:io' show Platform;

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/native_sheet_bridge.dart';

import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/services/direct_audio_client.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/settings_service.dart';

import '../../../core/utils/tts_voice_utils.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/adaptive_selection_sheet.dart';
import '../../chat/providers/remote_speech_providers.dart';
import '../../chat/providers/text_to_speech_provider.dart';
import '../../chat/services/voice_input_service.dart';
import '../widgets/adaptive_segmented_selector.dart';
import '../widgets/customization_tile.dart';
import '../widgets/settings_page_scaffold.dart';
import '../../../shared/widgets/utility_components.dart';
import '../widgets/stt_language_picker.dart';

bool shouldShowDeviceSttLanguageSetting(
  TargetPlatform platform,
  SttPreference preference,
) {
  return platform == TargetPlatform.android &&
      preference == SttPreference.deviceOnly;
}

class AudioSettingsPage extends ConsumerWidget {
  const AudioSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    final l10n = AppLocalizations.of(context)!;

    return UtilityPageScaffold.settings(
      title: l10n.audioSettingsTitle,
      children: [
        _buildSttSection(context, ref, settings),
        settingsSectionGap,
        _buildTtsSection(context, ref, settings),
      ],
    );
  }

  Widget _buildSttSection(
    BuildContext context,
    WidgetRef ref,
    AppSettings settings,
  ) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final localSupport = ref.watch(localVoiceRecognitionAvailableProvider);
    final localAvailable = localSupport.asData?.value ?? false;
    final localLoading = localSupport.isLoading;
    final serverAvailable = ref.watch(serverVoiceRecognitionAvailableProvider);
    final directAvailable = ref.watch(directVoiceRecognitionAvailableProvider);
    final notifier = ref.read(appSettingsProvider.notifier);
    final isDirect = settings.sttPreference == SttPreference.direct;
    final isRemote = settings.sttPreference != SttPreference.deviceOnly;

    final warnings = <String>[
      if (settings.sttPreference == SttPreference.deviceOnly &&
          !localAvailable &&
          !localLoading)
        l10n.sttDeviceUnavailableWarning,
      if (settings.sttPreference == SttPreference.serverOnly &&
          !serverAvailable)
        l10n.sttServerUnavailableWarning,
      if (isDirect && !directAvailable) l10n.directAudioUnavailableWarning,
      if (isDirect &&
          directAvailable &&
          ref.watch(activeSpeechTranscriberProvider) == null)
        l10n.directAudioSelectModelWarning,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InsetGroupedSection(
          title: l10n.sttSettings,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AdaptiveSegmentedSelector<SttPreference>(
                value: settings.sttPreference,
                onChanged: notifier.setSttPreference,
                options: [
                  (
                    value: SttPreference.deviceOnly,
                    label: l10n.sttEngineDevice,
                    cupertinoIcon: CupertinoIcons.device_phone_portrait,
                    materialIcon: Icons.phone_android,
                    enabled: localAvailable || localLoading,
                  ),
                  (
                    value: SttPreference.serverOnly,
                    label: l10n.sttEngineServer,
                    cupertinoIcon: CupertinoIcons.cloud,
                    materialIcon: Icons.cloud,
                    enabled: serverAvailable,
                  ),
                  (
                    value: SttPreference.direct,
                    label: l10n.sttEngineDirect,
                    cupertinoIcon: CupertinoIcons.link,
                    materialIcon: Icons.link,
                    enabled: directAvailable,
                  ),
                ],
              ),
              if (localLoading) ...[
                const SizedBox(height: Spacing.sm),
                const LinearProgressIndicator(minHeight: 3),
              ],
              const SizedBox(height: Spacing.sm),
              Text(switch (settings.sttPreference) {
                SttPreference.deviceOnly => l10n.sttEngineDeviceDescription,
                SttPreference.serverOnly => l10n.sttEngineServerDescription,
                SttPreference.direct => l10n.sttEngineDirectDescription,
              }, style: theme.bodySmall?.copyWith(color: theme.textSecondary)),
              for (final warning in warnings) ...[
                const SizedBox(height: Spacing.xs),
                Text(
                  warning,
                  style: theme.bodySmall?.copyWith(
                    color: theme.error,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (shouldShowDeviceSttLanguageSetting(
          defaultTargetPlatform,
          settings.sttPreference,
        )) ...[
          const SizedBox(height: Spacing.sm),
          CustomizationTile(
            key: const Key('device-stt-language-tile'),
            leading: SettingsIconBadge(
              icon: Icons.language,
              color: theme.buttonPrimary,
            ),
            title: l10n.sttDeviceLanguage,
            subtitle: deviceSttLanguageSubtitle(l10n, settings),
            onTap: () =>
                showDeviceSttLanguagePickerSheet(context, ref, settings),
          ),
        ],
        if (isDirect && directAvailable) ...[
          const SizedBox(height: Spacing.sm),
          _buildDirectModelTile(
            context,
            ref,
            kind: DirectAudioModelKind.transcription,
            profileId: settings.sttDirectProfileId,
            modelId: settings.sttDirectModelId,
          ),
        ],
        if (isRemote) ...[
          const SizedBox(height: Spacing.sm),
          CustomizationTile(
            leading: SettingsIconBadge(
              icon: UiUtils.platformIcon(
                ios: CupertinoIcons.globe,
                android: Icons.language,
              ),
              color: theme.buttonPrimary,
            ),
            title: l10n.sttTranscriptionLanguage,
            subtitle: sttLanguageSubtitle(l10n, settings),
            onTap: () => showSttLanguagePickerSheet(context, ref, settings),
          ),
          const SizedBox(height: Spacing.sm),
          InsetGroupedSection(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.sttSilenceDuration,
                  style: theme.bodyMedium?.copyWith(
                    color: theme.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: Spacing.xs),
                Text(
                  l10n.sttSilenceDurationDescription,
                  style: theme.bodySmall?.copyWith(color: theme.textSecondary),
                ),
                const SizedBox(height: Spacing.md),
                Row(
                  children: [
                    Expanded(
                      child: AdaptiveSlider(
                        value: settings.voiceSilenceDuration.toDouble(),
                        min: SettingsService.minVoiceSilenceDurationMs
                            .toDouble(),
                        max: SettingsService.maxVoiceSilenceDurationMs
                            .toDouble(),
                        divisions:
                            (SettingsService.maxVoiceSilenceDurationMs -
                                SettingsService.minVoiceSilenceDurationMs) ~/
                            100,
                        onChanged: (value) {
                          notifier.setVoiceSilenceDuration(value.round());
                        },
                      ),
                    ),
                    const SizedBox(width: Spacing.sm),
                    Text(
                      '${(settings.voiceSilenceDuration / 1000).toStringAsFixed(1)}s',
                      style: theme.bodyMedium?.copyWith(
                        color: theme.buttonPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: Spacing.sm),
        CustomizationTile(
          leading: SettingsIconBadge(
            icon: UiUtils.platformIcon(
              ios: CupertinoIcons.waveform,
              android: Icons.record_voice_over,
            ),
            color: theme.buttonPrimary,
          ),
          title: l10n.voiceBargeIn,
          subtitle: l10n.voiceBargeInDescription,
          trailing: AdaptiveSwitch(
            value: settings.voiceBargeInEnabled,
            onChanged: notifier.setVoiceBargeInEnabled,
          ),
          showChevron: false,
          onTap: () =>
              notifier.setVoiceBargeInEnabled(!settings.voiceBargeInEnabled),
        ),
      ],
    );
  }

  Widget _buildTtsSection(
    BuildContext context,
    WidgetRef ref,
    AppSettings settings,
  ) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final ttsService = ref.watch(textToSpeechServiceProvider);
    final deviceAvailable =
        ttsService.deviceEngineAvailable || !ttsService.isInitialized;
    // The service reports the active remote backend, which is the direct
    // one while direct is selected, so ask for the server itself here.
    final serverAvailable = ref.watch(apiServiceProvider) != null;
    final directAvailable = ref.watch(directAudioProfilesProvider).isNotEmpty;
    final isDirect = settings.ttsEngine == TtsEngine.direct;

    final warnings = <String>[
      if (settings.ttsEngine == TtsEngine.device && !deviceAvailable)
        l10n.ttsDeviceUnavailableWarning,
      if (settings.ttsEngine == TtsEngine.server && !serverAvailable)
        l10n.ttsServerUnavailableWarning,
      if (isDirect && !directAvailable) l10n.directAudioUnavailableWarning,
      if (isDirect &&
          directAvailable &&
          ref.watch(activeSpeechSynthesizerProvider) == null)
        l10n.directAudioSelectModelWarning,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InsetGroupedSection(
          title: l10n.ttsSettings,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AdaptiveSegmentedSelector<TtsEngine>(
                value: settings.ttsEngine,
                onChanged: (engine) async {
                  final notifier = ref.read(appSettingsProvider.notifier);
                  await notifier.setTtsEngineSelection(engine);
                },
                options: [
                  (
                    value: TtsEngine.device,
                    label: l10n.ttsEngineDevice,
                    cupertinoIcon: CupertinoIcons.device_phone_portrait,
                    materialIcon: Icons.phone_android,
                    enabled: deviceAvailable,
                  ),
                  (
                    value: TtsEngine.server,
                    label: l10n.ttsEngineServer,
                    cupertinoIcon: CupertinoIcons.cloud,
                    materialIcon: Icons.cloud,
                    enabled: serverAvailable,
                  ),
                  (
                    value: TtsEngine.direct,
                    label: l10n.ttsEngineDirect,
                    cupertinoIcon: CupertinoIcons.link,
                    materialIcon: Icons.link,
                    enabled: directAvailable,
                  ),
                ],
              ),
              const SizedBox(height: Spacing.sm),
              Text(switch (settings.ttsEngine) {
                TtsEngine.device => l10n.ttsEngineDeviceDescription,
                TtsEngine.server => l10n.ttsEngineServerDescription,
                TtsEngine.direct => l10n.ttsEngineDirectDescription,
              }, style: theme.bodySmall?.copyWith(color: theme.textSecondary)),
              for (final warning in warnings) ...[
                const SizedBox(height: Spacing.xs),
                Text(
                  warning,
                  style: theme.bodySmall?.copyWith(
                    color: theme.error,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (isDirect && directAvailable) ...[
          const SizedBox(height: Spacing.sm),
          _buildDirectModelTile(
            context,
            ref,
            kind: DirectAudioModelKind.speech,
            profileId: settings.ttsDirectProfileId,
            modelId: settings.ttsDirectModelId,
          ),
        ],
        if (!isDirect || settings.ttsDirectModelId != null) ...[
          const SizedBox(height: Spacing.sm),
          CustomizationTile(
            leading: SettingsIconBadge(
              icon: UiUtils.platformIcon(
                ios: CupertinoIcons.speaker_3,
                android: Icons.record_voice_over,
              ),
              color: theme.buttonPrimary,
            ),
            title: l10n.ttsVoice,
            subtitle: _voiceSubtitle(l10n, settings),
            onTap: () => isDirect
                ? _showDirectVoicePickerSheet(context, ref, settings)
                : _showVoicePickerSheet(context, ref, settings),
          ),
        ],
        if (settings.ttsEngine == TtsEngine.device) ...[
          const SizedBox(height: Spacing.sm),
          InsetGroupedSection(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.ttsSpeechRate,
                  style: theme.bodyMedium?.copyWith(
                    color: theme.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Row(
                  children: [
                    Expanded(
                      child: AdaptiveSlider(
                        value: settings.ttsSpeechRate,
                        min: 0.25,
                        max: 2.0,
                        divisions: 35,
                        onChanged: (value) {
                          ref
                              .read(appSettingsProvider.notifier)
                              .setTtsSpeechRate(value);
                        },
                      ),
                    ),
                    const SizedBox(width: Spacing.sm),
                    Text(
                      '${(settings.ttsSpeechRate * 100).round()}%',
                      style: theme.bodyMedium?.copyWith(
                        color: theme.buttonPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: Spacing.sm),
        CustomizationTile(
          leading: SettingsIconBadge(
            icon: UiUtils.platformIcon(
              ios: CupertinoIcons.play_fill,
              android: Icons.play_arrow,
            ),
            color: theme.buttonPrimary,
          ),
          title: l10n.ttsPreview,
          subtitle: l10n.ttsPreviewText,
          onTap: () => _previewTtsVoice(context, ref),
        ),
      ],
    );
  }

  String _voiceSubtitle(AppLocalizations l10n, AppSettings settings) {
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

  Future<void> _showVoicePickerSheet(
    BuildContext context,
    WidgetRef ref,
    AppSettings settings,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final ttsService = ref.read(textToSpeechServiceProvider);

    await ttsService.updateSettings(engine: settings.ttsEngine);
    final voices = await ttsService.getAvailableVoices();
    if (!context.mounted) {
      return;
    }
    if (voices.isEmpty) {
      UiUtils.showMessage(context, l10n.ttsNoVoicesAvailable);
      return;
    }

    final notifier = ref.read(appSettingsProvider.notifier);
    final voiceOptions = buildTtsVoiceOptions(l10n, settings.ttsEngine, voices);
    final selectedOptionId = selectedTtsVoiceOptionId(settings, voices);
    if (Platform.isIOS) {
      try {
        final selectedId = await NativeSheetBridge.instance
            .presentOptionsSelector(
              title: l10n.ttsSelectVoice,
              selectedOptionId: selectedOptionId,
              options: [
                NativeSheetOptionConfig(
                  id: ttsSystemDefaultVoiceId,
                  label: l10n.ttsSystemDefault,
                ),
                for (final option in voiceOptions)
                  NativeSheetOptionConfig(
                    id: option.id,
                    label: option.label,
                    subtitle: option.subtitle,
                  ),
              ],
              rethrowErrors: true,
            );
        if (selectedId == null) {
          return;
        }
        if (selectedId == ttsSystemDefaultVoiceId) {
          if (settings.ttsEngine == TtsEngine.server) {
            await notifier.setTtsServerVoiceSelection(null, null);
          } else {
            await notifier.setTtsDeviceVoiceSelection(null, null);
          }
          return;
        }
        final selectedVoice = findTtsVoiceOption(
          l10n,
          settings.ttsEngine,
          voices,
          selectedId,
        );
        if (selectedVoice == null) {
          return;
        }
        if (settings.ttsEngine == TtsEngine.server) {
          await notifier.setTtsServerVoiceSelection(
            selectedVoice.id,
            selectedVoice.label,
          );
        } else {
          await notifier.setTtsDeviceVoiceSelection(
            selectedVoice.id,
            selectedVoice.label,
          );
        }
        return;
      } catch (_) {}
      if (!context.mounted) {
        return;
      }
    }

    await showAdaptiveSelectionSheet<void>(
      context: context,
      builder: (sheetContext) {
        return AdaptiveSelectionSheet(
          title: l10n.ttsSelectVoice,
          itemCount: voiceOptions.length + 1,
          initialChildSize: 0.68,
          minChildSize: 0.42,
          maxChildSize: 0.9,
          itemBuilder: (context, index) {
            if (index == 0) {
              return AdaptiveSelectionTile(
                title: l10n.ttsSystemDefault,
                selected: selectedOptionId == ttsSystemDefaultVoiceId,
                onTap: () async {
                  if (settings.ttsEngine == TtsEngine.server) {
                    await notifier.setTtsServerVoiceSelection(null, null);
                  } else {
                    await notifier.setTtsDeviceVoiceSelection(null, null);
                  }
                  if (!sheetContext.mounted) return;
                  Navigator.of(sheetContext).pop();
                },
              );
            }

            final option = voiceOptions[index - 1];
            return AdaptiveSelectionTile(
              title: option.label,
              subtitle: option.subtitle,
              selected: option.id == selectedOptionId,
              onTap: () async {
                if (settings.ttsEngine == TtsEngine.server) {
                  await notifier.setTtsServerVoiceSelection(
                    option.id,
                    option.label,
                  );
                } else {
                  await notifier.setTtsDeviceVoiceSelection(
                    option.id,
                    option.label,
                  );
                }
                if (!sheetContext.mounted) return;
                Navigator.of(sheetContext).pop();
              },
            );
          },
        );
      },
    );
  }

  Widget _buildDirectModelTile(
    BuildContext context,
    WidgetRef ref, {
    required DirectAudioModelKind kind,
    required String? profileId,
    required String? modelId,
  }) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final profiles = ref.watch(directAudioProfilesProvider);
    final profile = profiles.where((p) => p.id == profileId).firstOrNull;
    final subtitle = profile == null || modelId == null
        ? l10n.directAudioModelNotSelected
        : profiles.length > 1
        ? '${profile.name} · $modelId'
        : modelId;
    return CustomizationTile(
      leading: SettingsIconBadge(
        icon: UiUtils.platformIcon(
          ios: CupertinoIcons.cube_box,
          android: Icons.memory,
        ),
        color: theme.buttonPrimary,
      ),
      title: l10n.directAudioModel,
      subtitle: subtitle,
      onTap: () => _showDirectModelPickerSheet(context, ref, kind),
    );
  }

  Future<void> _showDirectModelPickerSheet(
    BuildContext context,
    WidgetRef ref,
    DirectAudioModelKind kind,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final profiles = ref.read(directAudioProfilesProvider);
    final entries =
        <({DirectConnectionProfile profile, DirectAudioModel model})>[];
    try {
      for (final profile in profiles) {
        final models = await ref.read(
          directAudioModelsProvider((profileId: profile.id, kind: kind)).future,
        );
        entries.addAll(models.map((model) => (profile: profile, model: model)));
      }
    } catch (_) {
      if (context.mounted) UiUtils.showMessage(context, l10n.errorMessage);
      return;
    }
    if (!context.mounted) return;
    if (entries.isEmpty) {
      UiUtils.showMessage(context, l10n.directAudioNoModels);
      return;
    }

    final settings = ref.read(appSettingsProvider);
    final notifier = ref.read(appSettingsProvider.notifier);
    final isSpeech = kind == DirectAudioModelKind.speech;
    final selectedProfileId = isSpeech
        ? settings.ttsDirectProfileId
        : settings.sttDirectProfileId;
    final selectedModelId = isSpeech
        ? settings.ttsDirectModelId
        : settings.sttDirectModelId;

    await showAdaptiveSelectionSheet<void>(
      context: context,
      builder: (sheetContext) {
        return AdaptiveSelectionSheet(
          title: l10n.directAudioSelectModel,
          itemCount: entries.length,
          initialChildSize: 0.68,
          minChildSize: 0.42,
          maxChildSize: 0.9,
          itemBuilder: (context, index) {
            final entry = entries[index];
            final model = entry.model;
            return AdaptiveSelectionTile(
              title: model.name,
              subtitle: profiles.length > 1
                  ? '${entry.profile.name} · ${model.id}'
                  : model.id,
              selected:
                  entry.profile.id == selectedProfileId &&
                  model.id == selectedModelId,
              onTap: () async {
                if (isSpeech) {
                  // Keep the voice when the new model offers it too;
                  // otherwise start from the model's first voice because
                  // most providers require one.
                  final current = settings.ttsDirectVoice;
                  final voice = model.voices.contains(current)
                      ? current
                      : model.voices.firstOrNull;
                  await notifier.setTtsDirectModel(
                    entry.profile.id,
                    model.id,
                    voice: voice,
                  );
                } else {
                  await notifier.setSttDirectModel(entry.profile.id, model.id);
                }
                if (!sheetContext.mounted) return;
                Navigator.of(sheetContext).pop();
              },
            );
          },
        );
      },
    );
  }

  Future<void> _showDirectVoicePickerSheet(
    BuildContext context,
    WidgetRef ref,
    AppSettings settings,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final profileId = settings.ttsDirectProfileId;
    final modelId = settings.ttsDirectModelId;
    if (profileId == null || modelId == null) return;

    final List<String> voices;
    try {
      final models = await ref.read(
        directAudioModelsProvider((
          profileId: profileId,
          kind: DirectAudioModelKind.speech,
        )).future,
      );
      voices =
          models.where((model) => model.id == modelId).firstOrNull?.voices ??
          const <String>[];
    } catch (_) {
      if (context.mounted) UiUtils.showMessage(context, l10n.errorMessage);
      return;
    }
    if (!context.mounted) return;
    if (voices.isEmpty) {
      UiUtils.showMessage(context, l10n.ttsNoVoicesAvailable);
      return;
    }

    final notifier = ref.read(appSettingsProvider.notifier);
    await showAdaptiveSelectionSheet<void>(
      context: context,
      builder: (sheetContext) {
        return AdaptiveSelectionSheet(
          title: l10n.ttsSelectVoice,
          itemCount: voices.length,
          initialChildSize: 0.68,
          minChildSize: 0.42,
          maxChildSize: 0.9,
          itemBuilder: (context, index) {
            final voice = voices[index];
            return AdaptiveSelectionTile(
              title: voice,
              selected: voice == settings.ttsDirectVoice,
              onTap: () async {
                await notifier.setTtsDirectVoice(voice);
                if (!sheetContext.mounted) return;
                Navigator.of(sheetContext).pop();
              },
            );
          },
        );
      },
    );
  }

  Future<void> _previewTtsVoice(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;

    try {
      final controller = ref.read(textToSpeechControllerProvider.notifier);
      final state = ref.read(textToSpeechControllerProvider);
      if (state.isSpeaking || state.isBusy) {
        await controller.stop();
        return;
      }

      await controller.toggleForMessage(
        messageId: 'tts_preview',
        text: l10n.ttsPreviewText,
      );
    } catch (_) {
      if (!context.mounted) {
        return;
      }
      UiUtils.showMessage(context, l10n.errorMessage);
    }
  }
}
