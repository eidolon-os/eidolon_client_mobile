/// Asking the Authority what this Body's configuration is right now.
///
/// One call, `configuration:pull`, and it answers two things a phone cannot
/// know on its own: whether its Claim still stands, and which channel — if any
/// — it may currently talk through. Both are the Authority's to say. A device
/// that inferred either from a local record would keep speaking after a
/// revocation and keep silent after a channel arrived.
///
/// ## Why the Claim state comes back at all
///
/// Because this is the edge where a device learns it was revoked. Nothing else
/// tells it: revocation happens at the Host, between the Owner and the
/// Authority, and the phone finds out the next time it asks. So `revoked` here
/// is not an error — it is the answer, and the caller's job is to stop being a
/// Body rather than to retry.
///
/// ## The signing document is a third hand-written copy
///
/// The Authority builds it in `hub/device_control/application.py` and the
/// firmware builds the same bytes in
/// `eidolon-client-esp32/main/eidolon/hub_onboarding_protocol.cc`; neither is
/// written down in `eidolon_sdk/contracts`. The ordering and escaping here come
/// from the one canonicaliser this app owns, which RFC 8785's own vector pins,
/// so what is unpinned is the member set — and
/// `test/device_control_client_test.dart` states it so a change has to be typed
/// twice. The proper fix is a golden, and it is a contracts change.
library;

import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../../protocol/canonical_json.dart';
import '../../protocol/livekit_session_binding.dart';
import '../../models/hub_models.dart';

/// The operation the Authority verifies this device's signature against.
const deviceControlConfigurationOperation = 'device-control.configuration';

/// What the Authority currently says about this Body.
class DeviceConfiguration {
  const DeviceConfiguration({
    required this.claimStands,
    required this.session,
  });

  /// Whether the Claim is still active.
  ///
  /// False means revoked, which is an answer rather than a failure — and the
  /// one thing a phone must never learn from its own records.
  final bool claimStands;

  /// The room this device may join, when the Authority delivered one.
  ///
  /// Null with [claimStands] true is the ordinary case while a channel is being
  /// provisioned, and also the case where provisioning refused. Those look the
  /// same on this edge on purpose: the Authority returns no channels either
  /// way, and a client that guessed which one it was would be inventing a
  /// reason.
  final RoomConfig? session;
}

/// Raised when the Authority refuses or answers unreadably.
class DeviceControlRefusal implements Exception {
  const DeviceControlRefusal({
    required this.detail,
    required this.status,
    required this.retryable,
  });

  final String detail;
  final int status;

  /// Whether asking again can change the answer on its own.
  final bool retryable;

  @override
  String toString() => 'DeviceControlRefusal($status): $detail';
}

/// The device-facing half of Device Control.
class DeviceControlClient {
  DeviceControlClient({
    required this.authority,
    required http.Client transport,
    this.timeout = const Duration(seconds: 20),
    Random? random,
  })  : _transport = transport,
        _random = random ?? Random.secure();

  /// The `device-control` authority endpoint from the signed directory.
  final Uri authority;

  final http.Client _transport;
  final Duration timeout;
  final Random _random;

  static const _path = '/api/device-control/v1/configuration:pull';

  /// Ask what this Body's configuration is, proving it is that Body.
  ///
  /// [sign] receives the canonical bytes and returns ES256 `r || s` base64url —
  /// the operational key's signature, made on the platform where that key
  /// lives. Passed as a function rather than a key for the obvious reason: the
  /// key never comes here.
  Future<DeviceConfiguration> pullConfiguration({
    required Map<String, Object?> deviceRef,
    required String operationalPublicKey,
    required Future<String> Function(String canonicalDocument) sign,
  }) async {
    final nonce = _nonce();
    final signature = await sign(
      canonicalJsonEncode(<String, Object?>{
        'device_ref': deviceRef,
        'nonce': nonce,
        'operation_type': deviceControlConfigurationOperation,
      }),
    );
    final response = await _transport
        .post(
          authority.resolveUri(Uri.parse(_path)),
          headers: const {
            'accept': 'application/json',
            'content-type': 'application/json',
          },
          body: jsonEncode(<String, Object?>{
            'device_ref': deviceRef,
            'nonce': nonce,
            'public_key_spki': operationalPublicKey,
            'device_signature': signature,
          }),
        )
        .timeout(timeout);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw DeviceControlRefusal(
        detail: _detailOf(response),
        status: response.statusCode,
        // 409 is a stale generation and 403 is a rejected proof: both are
        // answers about this device, and asking again with the same facts
        // produces the same answer. Only a server-side fault is worth a retry.
        retryable: response.statusCode >= 500,
      );
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw DeviceControlRefusal(
        detail: 'Device Control answered with a body that is not JSON',
        status: response.statusCode,
        retryable: false,
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw DeviceControlRefusal(
        detail: 'Device Control answered with something that is not an object',
        status: response.statusCode,
        retryable: false,
      );
    }
    if (decoded['nonce'] != nonce) {
      // The nonce comes back so a device can tell this answer from a replayed
      // one. Checked rather than trusted: an answer about an older ask could
      // report a Claim that has since been revoked.
      throw DeviceControlRefusal(
        detail: 'Device Control answered a different request',
        status: response.statusCode,
        retryable: false,
      );
    }

    final lifecycle = decoded['lifecycle_state'];
    if (lifecycle != 'approved' && lifecycle != 'revoked') {
      throw DeviceControlRefusal(
        detail: 'Device Control reported a lifecycle state this build does '
            'not know: $lifecycle',
        status: response.statusCode,
        retryable: false,
      );
    }
    if (lifecycle == 'revoked') {
      return const DeviceConfiguration(claimStands: false, session: null);
    }

    final channels = decoded['channels'];
    if (channels is! List || channels.isEmpty) {
      return const DeviceConfiguration(claimStands: true, session: null);
    }
    final channel = channels.first;
    if (channel is! Map<String, dynamic>) {
      throw DeviceControlRefusal(
        detail: 'Device Control delivered a channel this build cannot read',
        status: response.statusCode,
        retryable: false,
      );
    }
    return DeviceConfiguration(
      claimStands: true,
      session: liveKitSessionFromBinding(
        bindingFormat: channel['binding_format'] as String? ?? '',
        opaqueBinding: channel['opaque_binding'] as String? ?? '',
      ),
    );
  }

  /// A fresh nonce, in the shape the contract accepts.
  ///
  /// 32 random bytes as unpadded base64url — 43 characters, inside the
  /// contract's 16..128, and drawn from a secure source because its whole job
  /// is to make one answer belong to one ask.
  String _nonce() {
    final bytes = List<int>.generate(32, (_) => _random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  String _detailOf(http.Response response) {
    try {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      if (body is Map<String, dynamic> && body['detail'] is String) {
        return body['detail'] as String;
      }
    } on FormatException {
      // Fall through to the status. A refusal this app cannot read is still a
      // refusal, and saying so beats quoting bytes at a person.
    }
    return 'Device Control refused with HTTP ${response.statusCode}';
  }
}
