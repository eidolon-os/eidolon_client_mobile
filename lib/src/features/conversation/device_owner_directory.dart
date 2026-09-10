import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../generated/device_foundation_v1.dart';
import '../../platform/app_preferences.dart';
import '../device_setup/device_setup_models.dart';
import '../device_setup/device_setup_ports.dart';
import '../device_setup/owner_domain_directory_verifier.dart';
import '../device_setup/owner_authority_routes.dart';

/// Public trust material installed at commissioning, independent of Controller
/// credentials. Host ids only select a remembered Owner; they are not anchors.
class DeviceOwnerDirectory {
  DeviceOwnerDirectory({
    AppPreferences? preferences,
    OwnerDomainDirectoryVerifier? verifier,
    http.Client Function(DeviceOnboardingTarget)? transport,
    OwnerAuthorityRoutes? routes,
  })  : _preferences = preferences ?? PlatformAppPreferences(),
        _verifier = verifier ?? PlatformOwnerDomainDirectoryVerifier(),
        _authorityRoutes = routes ?? OwnerAuthorityRoutes() {
    _transport = transport ??
        (target) => _authorityRoutes.client(
            target,
            () =>
                _hosts[target.ownerDomainId] ??
                (throw StateError('尚未选择此 Owner 的主机')));
  }

  final AppPreferences _preferences;
  final OwnerDomainDirectoryVerifier _verifier;
  final OwnerAuthorityRoutes _authorityRoutes;
  late final http.Client Function(DeviceOnboardingTarget) _transport;
  static const _key = 'eidolon.device-owner-directory.v1';
  final Map<String, DeviceOnboardingTarget> _targets = {};
  final Map<String, String> _hosts = {};
  final Map<String, int> _selections = {};
  int _sequence = 0;

  /// All Owner APIs resolve locations at send time through the same transport.
  http.Client transport(DeviceOnboardingTarget target) => _transport(target);

  Future<void> close() => _authorityRoutes.close();

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
      return current;
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
    // Persisted trust can be used without a Controller session. The address
    // formerly embedded in this record is not trust and is deliberately ignored.
    target = DeviceOnboardingTarget.fromJson(_wire(target));
    final current = _targets[target.ownerDomainId];
    if (current != null &&
        current.ownerRootCertificate != target.ownerRootCertificate) {
      throw const FormatException('不能替换此设备已安装的 Owner 信任');
    }
    target = _currentDescriptor(target);
    if (value == null) await _verifier.verify(target);
    if (attempt > (_selections[target.ownerDomainId] ?? 0)) {
      _selections[target.ownerDomainId] = attempt;
      _hosts[target.ownerDomainId] = hostId;
      _targets[target.ownerDomainId] = target;
    }
    final accepted = await load(target.ownerDomainId, refresh: value != null);
    await _save(hostId, accepted);
    return accepted;
  }

  Future<DeviceOnboardingTarget> load(String ownerDomainId,
      {bool refresh = false}) async {
    final installed = _targets[ownerDomainId];
    if (installed == null) throw StateError('尚未安装此 Owner 的可信目录');
    DeviceOnboardingTarget target = installed;
    final expires = DateTime.parse(target.ownerDomainDescriptor.expiresAt);
    if (refresh ||
        expires.difference(DateTime.now()) < const Duration(minutes: 5)) {
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
            authoritySigningCertificate: target.authoritySigningCertificate);
        final accepted = _currentDescriptor(next);
        await _verifier.verify(accepted);
        target = _currentDescriptor(accepted);
        _targets[ownerDomainId] = target;
        await PreferenceWrites.run(_preferences, _key, () async {
          final raw = await _preferences.readString(_key);
          final saved = raw == null
              ? <String, dynamic>{}
              : Map<String, dynamic>.from(jsonDecode(raw) as Map);
          for (final key in saved.keys.toList()) {
            final entry = saved[key] as Map;
            if (entry['owner_domain_id'] == ownerDomainId) {
              saved[key] = _wire(target);
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
    target = _currentDescriptor(target);
    await _verifier.verify(target);
    return target;
  }

  Map<String, Object?> _wire(DeviceOnboardingTarget t) => {
        'operation': 'local.device-onboarding-target',
        'contract_version': '1',
        'owner_domain_id': t.ownerDomainId,
        'owner_domain_descriptor': t.ownerDomainDescriptor.toJson(),
        'owner_root_certificate': t.ownerRootCertificate,
        'authority_signing_certificate': t.authoritySigningCertificate,
      };
}
