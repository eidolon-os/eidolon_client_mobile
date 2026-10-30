import 'dart:typed_data';
import '../../generated/management_v1.dart';
import '../host_setup/host_product_session.dart';

class VoicePreviewRepository {
  VoicePreviewRepository(this._session);
  final HostProductSession _session;

  Future<VoicePreviewStatus> request(VoicePreviewRequest request) =>
      _session.executeManagement((client, uri, token) => client
          .requestVoicePreview(uri, accessToken: token, request: request));
  Future<Uint8List> audio(String key) =>
      _session.executeManagement((client, uri, token) =>
          client.fetchVoicePreviewAudio(uri, accessToken: token, key: key));
}
