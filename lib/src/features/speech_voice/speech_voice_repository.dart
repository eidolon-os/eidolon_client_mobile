import 'dart:typed_data';

import '../../generated/management_v1.dart';
import '../host_setup/host_product_session.dart';

/// Everything the voice screens ask the Host, as one port.
///
/// The screens never see a provider: a voice is an opaque `voice_key`, and
/// whether the Host can design or clone is a flag on the catalog.
abstract interface class SpeechVoices {
  Future<SpeechVoiceCatalogView> catalog();

  /// Ask the Host to look again; it answers with what it has if it looked
  /// recently.
  Future<SpeechVoiceCatalogView> refresh();

  /// A short sample of a voice as WAV bytes.
  Future<Uint8List> preview(String voiceKey, {int sample = 1});

  Future<CompanionSpeechVoiceView> companionVoice(String companionId);

  /// Null puts the Companion back on the Host's own voice.
  Future<CompanionSpeechVoiceView> choose(
      String companionId, String? voiceKey, int expectedRevision);

  Future<List<OwnerVoiceView>> ownerVoices();
  Future<OwnerVoiceView> ownerVoice(String voiceAssetId);
  Future<OwnerVoiceView> design(VoiceDesignBody body);

  /// Measure a recording or an audio file; the window it returns is what a
  /// clone is made from.
  Future<ReferenceCheckView> check(Uint8List audio, {int? startMs});
  Future<OwnerVoiceView> clone(VoiceCloneBody body);
  Future<OwnerVoiceView> change(String voiceAssetId, OwnerVoiceChange change);
  Future<void> delete(OwnerVoiceView voice);
}

/// Uses the existing authenticated Host session, never a page-owned credential.
class HostSpeechVoices implements SpeechVoices {
  HostSpeechVoices(this._session);
  final HostProductSession _session;

  /// Samples are the same bytes every time for a voice, so a person scrolling
  /// back up the list does not wait for the Host twice. Bounded: a long list
  /// of auditions must not grow without end.
  static const _keptPreviews = 24;
  final _previews = <String, Uint8List>{}; // insertion-ordered: oldest first

  @override
  Future<SpeechVoiceCatalogView> catalog() =>
      _session.executeManagement((client, uri, token) =>
          client.fetchSpeechVoices(uri, accessToken: token));

  @override
  Future<SpeechVoiceCatalogView> refresh() =>
      _session.executeManagement((client, uri, token) =>
          client.refreshSpeechVoices(uri, accessToken: token));

  @override
  Future<Uint8List> preview(String voiceKey, {int sample = 1}) async {
    final key = '$voiceKey#$sample';
    final kept = _previews.remove(key);
    if (kept != null) return _previews[key] = kept;
    final audio = await _session.executeManagement((client, uri, token) =>
        client.fetchVoicePreview(uri,
            accessToken: token, voiceKey: voiceKey, sample: sample));
    _previews[key] = audio;
    if (_previews.length > _keptPreviews) {
      _previews.remove(_previews.keys.first);
    }
    return audio;
  }

  @override
  Future<CompanionSpeechVoiceView> companionVoice(String companionId) =>
      _session.executeManagement((client, uri, token) =>
          client.fetchCompanionSpeechVoice(uri,
              accessToken: token, companionId: companionId));

  @override
  Future<CompanionSpeechVoiceView> choose(
          String companionId, String? voiceKey, int expectedRevision) =>
      _session.executeManagement((client, uri, token) =>
          client.chooseCompanionSpeechVoice(uri,
              accessToken: token,
              companionId: companionId,
              choice: SpeechVoiceChoice(
                  voiceKey: voiceKey, expectedRevision: expectedRevision)));

  @override
  Future<List<OwnerVoiceView>> ownerVoices() async =>
      (await _session.executeManagement((client, uri, token) =>
              client.fetchOwnerVoices(uri, accessToken: token)))
          .voices;

  @override
  Future<OwnerVoiceView> ownerVoice(String voiceAssetId) =>
      _session.executeManagement((client, uri, token) => client.fetchOwnerVoice(
          uri,
          accessToken: token,
          voiceAssetId: voiceAssetId));

  @override
  Future<OwnerVoiceView> design(VoiceDesignBody body) =>
      _session.executeManagement((client, uri, token) =>
          client.designOwnerVoice(uri, accessToken: token, body: body));

  @override
  Future<ReferenceCheckView> check(Uint8List audio, {int? startMs}) =>
      _session.executeManagement((client, uri, token) =>
          client.checkVoiceReference(uri,
              accessToken: token, audio: audio, startMs: startMs));

  @override
  Future<OwnerVoiceView> clone(VoiceCloneBody body) =>
      _session.executeManagement((client, uri, token) =>
          client.cloneOwnerVoice(uri, accessToken: token, body: body));

  @override
  Future<OwnerVoiceView> change(String voiceAssetId, OwnerVoiceChange change) =>
      _session.executeManagement((client, uri, token) =>
          client.changeOwnerVoice(uri,
              accessToken: token, voiceAssetId: voiceAssetId, change: change));

  @override
  Future<void> delete(OwnerVoiceView voice) async {
    await _session.executeManagement((client, uri, token) =>
        client.deleteOwnerVoice(uri,
            accessToken: token, voiceAssetId: voice.voiceAssetId));
    _previews.removeWhere((key, _) => key.startsWith('${voice.voiceKey}#'));
  }
}
