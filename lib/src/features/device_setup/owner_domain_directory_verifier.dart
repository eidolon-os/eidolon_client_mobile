import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';

import '../../platform/app_preferences.dart';
import '../../protocol/canonical_json.dart';
import 'device_setup_models.dart';
import 'device_setup_ports.dart';

abstract interface class OwnerDomainSignatureVerifierPort {
  Future<void> verify({
    required DeviceOnboardingTarget target,
    required String canonicalSigningDocument,
  });
}

/// Single-writer Owner directory acceptance boundary.
///
/// Dart owns revision policy and durable accepted state. Android is only the
/// X.509/P-256 Adapter. Neither discovery nor endpoint TLS can substitute for
/// this acceptance act.
class PlatformOwnerDomainDirectoryVerifier
    implements OwnerDomainDirectoryVerifier {
  PlatformOwnerDomainDirectoryVerifier({
    AppPreferences? preferences,
    OwnerDomainSignatureVerifierPort? signatureVerifier,
  })  : _preferences = preferences ?? PlatformAppPreferences(),
        _signatureVerifier =
            signatureVerifier ?? const _PlatformSignatureVerifier();

  static const _preferenceKey = 'eidolon.owner-domain-directories.v1';
  static const _documentVersion = '1';

  final AppPreferences _preferences;
  final OwnerDomainSignatureVerifierPort _signatureVerifier;

  @override
  Future<void> verify(DeviceOnboardingTarget target) async {
    final canonical = canonicalOwnerDomainDescriptorSigningJson(target);
    _validateWindow(target);
    await _signatureVerifier.verify(
      target: target,
      canonicalSigningDocument: canonical,
    );
    return PreferenceWrites.run(
        _preferences, _preferenceKey, () => _acceptVerified(target, canonical));
  }

  void _validateWindow(DeviceOnboardingTarget target) {
    final descriptor = target.ownerDomainDescriptor;
    final now = DateTime.now().toUtc();
    final issuedAt = DateTime.parse(descriptor.issuedAt).toUtc();
    final expiresAt = DateTime.parse(descriptor.expiresAt).toUtc();
    if (now.isBefore(issuedAt) || !now.isBefore(expiresAt)) {
      throw const FormatException(
        'Owner Domain directory is outside its validity window',
      );
    }
  }

  Future<void> _acceptVerified(
    DeviceOnboardingTarget target,
    String canonical,
  ) async {
    final descriptor = target.ownerDomainDescriptor;
    final fingerprint =
        await _fingerprint('$canonical\n${descriptor.signature}');
    final document =
        _decodeState(await _preferences.readString(_preferenceKey));
    final owners = Map<String, dynamic>.from(document['owners']! as Map);
    final currentRaw = owners[target.ownerDomainId];
    if (currentRaw != null) {
      if (currentRaw is! Map ||
          (currentRaw['owner_domain_generation'] != null &&
              currentRaw['owner_domain_generation'] is! int) ||
          currentRaw['directory_revision'] is! int ||
          currentRaw['fingerprint'] is! String) {
        throw const FormatException('Owner Domain directory state is corrupt');
      }
      final current = Map<String, dynamic>.from(currentRaw);
      // Pre-generation state can only represent generation 1: the field did
      // not exist before any higher generation could be issued.
      final currentGeneration =
          (current['owner_domain_generation'] as int?) ?? 1;
      final currentRevision = current['directory_revision']! as int;
      final currentFingerprint = current['fingerprint']! as String;
      if (descriptor.ownerDomainGeneration < currentGeneration) {
        throw const FormatException('Owner Domain generation rollback');
      }
      if (descriptor.ownerDomainGeneration == currentGeneration) {
        if (descriptor.directoryRevision < currentRevision) {
          throw const FormatException(
            'Owner Domain directory revision rollback',
          );
        }
        if (descriptor.directoryRevision == currentRevision) {
          if (fingerprint != currentFingerprint) {
            throw const FormatException(
              'Owner Domain directory revision was reused with different content',
            );
          }
          return;
        }
      }
    }
    owners[target.ownerDomainId] = {
      'owner_domain_generation': descriptor.ownerDomainGeneration,
      'directory_revision': descriptor.directoryRevision,
      'fingerprint': fingerprint,
    };
    await _preferences.writeString(
      _preferenceKey,
      jsonEncode({
        'contract_version': _documentVersion,
        'owners': owners,
      }),
    );
  }

  Map<String, dynamic> _decodeState(String? raw) {
    if (raw == null || raw.isEmpty) {
      return {
        'contract_version': _documentVersion,
        'owners': <String, dynamic>{},
      };
    }
    try {
      final document = jsonDecode(raw);
      if (document is! Map ||
          document['contract_version'] != _documentVersion ||
          document['owners'] is! Map) {
        throw const FormatException('Owner Domain directory state is corrupt');
      }
      return Map<String, dynamic>.from(document);
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('Owner Domain directory state is corrupt');
    }
  }

  Future<String> _fingerprint(String value) async {
    final digest = await Sha256().hash(utf8.encode(value));
    final hex = digest.bytes
        .map((item) => item.toRadixString(16).padLeft(2, '0'))
        .join();
    return 'sha256:$hex';
  }
}

class _PlatformSignatureVerifier implements OwnerDomainSignatureVerifierPort {
  const _PlatformSignatureVerifier();

  static const _channel = MethodChannel('live.eidolon.mobile/platform');

  @override
  Future<void> verify({
    required DeviceOnboardingTarget target,
    required String canonicalSigningDocument,
  }) async {
    final descriptor = target.ownerDomainDescriptor;
    try {
      final verified = await _channel.invokeMethod<bool>(
        'verifyOwnerDomainDescriptor',
        {
          'ownerDomainId': target.ownerDomainId,
          'ownerRootCertificate': target.ownerRootCertificate,
          'authoritySigningCertificate': target.authoritySigningCertificate,
          'signingKeyId': descriptor.signingKeyId,
          'trustRootRefs': descriptor.trustRootRefs,
          'signature': descriptor.signature,
          'canonicalSigningDocument': canonicalSigningDocument,
        },
      );
      if (verified != true) {
        throw const FormatException(
          'Owner Domain directory signature was rejected',
        );
      }
    } on PlatformException catch (error) {
      throw FormatException(
        'Owner Domain directory trust verification failed: ${error.message}',
      );
    }
  }
}

String canonicalOwnerDomainDescriptorSigningJson(
  DeviceOnboardingTarget target,
) {
  final document = Map<String, dynamic>.from(
    target.ownerDomainDescriptor.toJson(),
  )..remove('signature');
  return canonicalJsonEncode(document);
}
