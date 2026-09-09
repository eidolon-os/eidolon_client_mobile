import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../generated/device_foundation_v1.dart';
import '../../platform/app_preferences.dart';
import '../device_setup/device_setup_models.dart';
import '../device_setup/device_setup_ports.dart';
import '../device_setup/owner_domain_directory_verifier.dart';
import '../host_setup/pinned_http_client.dart';

/// Public trust material installed at commissioning, independent of Controller
/// credentials. Host ids only select a remembered Owner; they are not anchors.
class DeviceOwnerDirectory {
  DeviceOwnerDirectory(
      {AppPreferences? preferences,
      OwnerDomainDirectoryVerifier? verifier,
      http.Client Function(DeviceOnboardingTarget)? transport})
      : _preferences = preferences ?? PlatformAppPreferences(),
        _verifier = verifier ?? PlatformOwnerDomainDirectoryVerifier(),
        _transport = transport ??
            ((t) => PlatformPinnedHttpClient.ownerDomain(
                ownerRootCertificate: t.ownerRootCertificate,
                addressHints: t.addressHints));

  final AppPreferences _preferences;
  final OwnerDomainDirectoryVerifier _verifier;
  final http.Client Function(DeviceOnboardingTarget) _transport;
  static const _key = 'eidolon.device-owner-directory.v1';
  final Map<String, DeviceOnboardingTarget> _targets = {};
  final Map<String, int> _routes = {};
  int _sequence = 0;

  Future<void> _save(String hostId, DeviceOnboardingTarget target) {
    return PreferenceWrites.run(_preferences, _key, () async {
      final raw = await _preferences.readString(_key);
      final saved = raw == null || raw.isEmpty
          ? <String, dynamic>{}
          : Map<String, dynamic>.from(jsonDecode(raw) as Map);
      saved[hostId] = _wire(target);
      await _preferences.writeString(_key, jsonEncode(saved));
    });
  }

  DeviceOnboardingTarget _currentDescriptor(DeviceOnboardingTarget candidate) {
    final current = _targets[candidate.ownerDomainId];
    if (current == null ||
        current.ownerRootCertificate != candidate.ownerRootCertificate) {
      return candidate;
    }
    final a = current.ownerDomainDescriptor;
    final b = candidate.ownerDomainDescriptor;
    if (a.ownerDomainGeneration > b.ownerDomainGeneration ||
        (a.ownerDomainGeneration == b.ownerDomainGeneration &&
            a.directoryRevision > b.directoryRevision)) {
      return candidate.hostAddress == null
          ? current
          : current.reachedAt(candidate.hostAddress!);
    }
    return candidate;
  }

  Future<DeviceOnboardingTarget> open(
      {required String hostId,
      required Future<DeviceOnboardingTarget> Function() bootstrap}) async {
    final attempt = ++_sequence;
    final raw = await _preferences.readString(_key);
    final saved = raw == null || raw.isEmpty
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(jsonDecode(raw) as Map);
    final value = saved[hostId];
    var target = value == null
        ? await bootstrap()
        : DeviceOnboardingTarget.fromJson(
            Map<String, dynamic>.from(value as Map));
    if (value is Map && value['last_reached_address'] is String) {
      target = target.reachedAt(value['last_reached_address'] as String);
    }
    final previousRoute = _routes[target.ownerDomainId] ?? 0;
    if (attempt > previousRoute) _routes[target.ownerDomainId] = attempt;
    if (value != null) {
      // Startup may continue on installed trust after three seconds, but the
      // locator result must not be discarded when Controller setup takes longer.
      // A later verified result updates the same directory used by Device reads.
      target = await _refreshFromHost(hostId, bootstrap, target, attempt)
          .timeout(const Duration(seconds: 3), onTimeout: () => target);
    }
    target = _currentDescriptor(target);
    if (value == null) {
      await _verifier.verify(target);
      await _save(hostId, target);
    }
    if (_routes[target.ownerDomainId] == attempt) {
      _targets[target.ownerDomainId] = target;
    }
    return load(target.ownerDomainId);
  }

  Future<DeviceOnboardingTarget> _refreshFromHost(
      String hostId,
      Future<DeviceOnboardingTarget> Function() bootstrap,
      DeviceOnboardingTarget installed,
      int attempt) async {
    final DeviceOnboardingTarget candidate;
    try {
      candidate = await bootstrap();
    } catch (_) {
      // Optional management location cannot revoke installed Device trust.
      return installed;
    }
    if (candidate.ownerDomainId != installed.ownerDomainId ||
        candidate.ownerRootCertificate != installed.ownerRootCertificate) {
      throw const FormatException('主机目录与本机已安装的 Owner 信任不一致');
    }
    if (_routes[installed.ownerDomainId] != attempt) {
      return _targets[installed.ownerDomainId] ?? installed;
    }
    try {
      await _verifier.verify(candidate);
    } on FormatException {
      return installed;
    }
    final target =
        candidate.hostAddress == null && installed.hostAddress != null
            ? candidate.reachedAt(installed.hostAddress!)
            : candidate;
    await _save(hostId, target);
    if (_routes[target.ownerDomainId] == attempt) {
      _targets[target.ownerDomainId] = target;
    }

    return target;
  }

  Future<DeviceOnboardingTarget> load(String ownerDomainId) async {
    final installed = _targets[ownerDomainId];
    if (installed == null) throw StateError('尚未安装此 Owner 的可信目录');
    DeviceOnboardingTarget target = installed;
    final expires = DateTime.parse(target.ownerDomainDescriptor.expiresAt);
    if (expires.difference(DateTime.now()) < const Duration(minutes: 5)) {
      final client = _transport(target);
      try {
        final response = await client
            .get(Uri.parse(target.ownerDomainDescriptor.descriptorUri))
            .timeout(const Duration(seconds: 15));
        if (response.statusCode != 200) {
          throw StateError('无法更新 Owner 目录（HTTP ${response.statusCode}）');
        }
        final descriptor = OwnerDomainDescriptorV1.fromJson(
            jsonDecode(utf8.decode(response.bodyBytes))
                as Map<String, dynamic>);
        if (descriptor.ownerDomainId != ownerDomainId) {
          throw const FormatException('Owner directory identity mismatch');
        }
        final next = DeviceOnboardingTarget(
            ownerDomainId: ownerDomainId,
            ownerDomainDescriptor: descriptor,
            ownerRootCertificate: target.ownerRootCertificate,
            authoritySigningCertificate: target.authoritySigningCertificate,
            hostAddress: target.hostAddress);
        final accepted = _currentDescriptor(next);
        await _verifier.verify(accepted);
        final latest = _targets[ownerDomainId]!;
        target = latest.hostAddress == null
            ? accepted
            : accepted.reachedAt(latest.hostAddress!);
        _targets[ownerDomainId] = target;
        await PreferenceWrites.run(_preferences, _key, () async {
          final raw = await _preferences.readString(_key);
          final saved = raw == null
              ? <String, dynamic>{}
              : Map<String, dynamic>.from(jsonDecode(raw) as Map);
          for (final key in saved.keys.toList()) {
            final entry = saved[key] as Map;
            if (entry['owner_domain_id'] == ownerDomainId) {
              // Host address hints are per Host, not part of Owner trust.
              saved[key] = {
                ..._wire(target),
                if (entry['last_reached_address'] != null)
                  'last_reached_address': entry['last_reached_address']
              };
            }
          }
          await _preferences.writeString(_key, jsonEncode(saved));
        });
      } catch (_) {
        if (!DateTime.now().isBefore(expires)) rethrow;
        // Refresh is opportunistic while the installed descriptor is valid.
        // Never use it past expiry; the final verifier remains authoritative.
      } finally {
        client.close();
      }
    }
    // Revalidate expiry, signatures and anti-rollback even for cached content.
    await _verifier.verify(target);
    return target;
  }

  Map<String, Object?> _wire(DeviceOnboardingTarget t) => {
        'operation': 'local.device-onboarding-target',
        'contract_version': '1',
        if (t.hostAddress != null) 'last_reached_address': t.hostAddress,
        'owner_domain_id': t.ownerDomainId,
        'owner_domain_descriptor': t.ownerDomainDescriptor.toJson(),
        'owner_root_certificate': t.ownerRootCertificate,
        'authority_signing_certificate': t.authoritySigningCertificate,
      };
}
