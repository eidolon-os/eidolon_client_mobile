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
  int _trustRevision = 0;
  bool _changingTrust = false;

  Future<void> _changeTrust(Future<void> Function() action) async {
    if (_changingTrust) throw StateError('Owner 信任正在更新，请稍后重试');
    _changingTrust = true;
    _trustRevision++;
    _authorityRoutes.invalidate();
    try {
      await action();
    } finally {
      _changingTrust = false;
    }
  }

  void _checkRevision(int revision) {
    if (_changingTrust || revision != _trustRevision) {
      throw StateError('Owner 信任已更新，请重试');
    }
  }

  /// All Owner APIs resolve locations at send time through the same transport.
  http.Client transport(DeviceOnboardingTarget target) => _transport(target);

  /// Give up everything this phone learned from one Host's Owner Domain.
  ///
  /// Both halves go, and they have to go together: the saved onboarding target
  /// is what names the domain, and the accepted-generation record is what
  /// refuses an older one. Dropping the first and keeping the second leaves a
  /// record nothing can name and nothing can clear — which is how removing a
  /// Host and adding it back still walked into the refusal it was meant to
  /// escape.
  Future<void> forgetHost(String hostId) => _changeTrust(() async {
        final saved = await _readSaved();
        final target = saved[hostId];
        final ownerDomainId =
            target is Map ? target['owner_domain_id'] as String? : null;
        await PreferenceWrites.run(_preferences, _key, () async {
          final current = await _readSaved();
          if (current.remove(hostId) == null) return;
          await _preferences.writeString(_key, jsonEncode(current));
        });
        if (ownerDomainId == null) return;
        // Only when this phone keeps no other Host in that domain: the record is
        // about the domain, not about one machine that speaks for it.
        final remaining = await _readSaved();
        final otherHosts = remaining.entries.where((entry) =>
            entry.value is Map &&
            entry.value['owner_domain_id'] == ownerDomainId);
        if (otherHosts.isEmpty) {
          _targets.remove(ownerDomainId);
          _hosts.remove(ownerDomainId);
          _selections.remove(ownerDomainId);
          await _verifier.forget(ownerDomainId);
        } else if (_hosts[ownerDomainId] == hostId) {
          _hosts[ownerDomainId] = otherHosts.first.key;
        }
      });

  /// Validate the actual offered directory, without substituting a cached one.
  Future<void> verify(DeviceOnboardingTarget target) async {
    final saved = await _readSaved();
    final installed = [
      if (_targets[target.ownerDomainId] case final current?) _wire(current),
      ...saved.values.whereType<Map>(),
    ];
    for (final entry in installed) {
      if (entry['owner_domain_id'] == target.ownerDomainId &&
          entry['owner_root_certificate'] != target.ownerRootCertificate) {
        throw const FormatException('不能替换此设备已安装的 Owner 信任');
      }
    }
    await _verifier.verify(target);
  }

  /// Accept, once, that this domain's lineage was re-established.
  ///
  /// Separate from [forgetHost] on purpose: giving up a Host throws away the
  /// pairing too, which is a heavy price for a record that is merely stale.
  /// This installs the exact directory the person confirmed, and exists because the
  /// Host cannot yet prove a legitimate reset on its own — until it can, the
  /// person who knows what happened to that machine is the evidence.
  Future<void> realignOwnerDomain(DeviceOnboardingTarget target) =>
      _changeTrust(() async {
        // Recheck signatures, expiry and the installed root before clearing anything.
        // Only the generation refusal is overridden by the person's confirmation.
        try {
          await verify(target);
        } on OwnerDomainGenerationRollback {
          await _verifier.forget(target.ownerDomainId);
          await _verifier.verify(target);
        }
        await PreferenceWrites.run(_preferences, _key, () async {
          final saved = await _readSaved();
          for (final hostId in saved.keys.toList()) {
            if (saved[hostId]['owner_domain_id'] == target.ownerDomainId) {
              saved[hostId] = _wire(target);
            }
          }
          await _preferences.writeString(_key, jsonEncode(saved));
          _targets[target.ownerDomainId] = target;
        });
      });

  /// What this phone would refuse a lower generation than, for this Host.
  Future<String?> ownerDomainOf(String hostId) async {
    final target = (await _readSaved())[hostId];
    return target is Map ? target['owner_domain_id'] as String? : null;
  }

  Future<Map<String, dynamic>> _readSaved() async {
    final raw = await _preferences.readString(_key);
    if (raw == null || raw.isEmpty) return <String, dynamic>{};
    final decoded = jsonDecode(raw);
    return decoded is Map
        ? Map<String, dynamic>.from(decoded)
        : <String, dynamic>{};
  }

  Future<void> close() => _authorityRoutes.close();

  Future<void> _save(
      String hostId, DeviceOnboardingTarget target, int revision) {
    return PreferenceWrites.run(_preferences, _key, () async {
      final raw = await _preferences.readString(_key);
      final saved = raw == null || raw.isEmpty
          ? <String, dynamic>{}
          : Map<String, dynamic>.from(jsonDecode(raw) as Map);
      _checkRevision(revision);
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
    final revision = _trustRevision;
    _checkRevision(revision);
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
    _checkRevision(revision);
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
    _checkRevision(revision);
    if (attempt > (_selections[target.ownerDomainId] ?? 0)) {
      _selections[target.ownerDomainId] = attempt;
      _hosts[target.ownerDomainId] = hostId;
      _targets[target.ownerDomainId] = target;
    }
    final accepted = await load(target.ownerDomainId, refresh: value != null);
    _checkRevision(revision);
    await _save(hostId, accepted, revision);
    return accepted;
  }

  Future<DeviceOnboardingTarget> load(String ownerDomainId,
      {bool refresh = false}) async {
    final revision = _trustRevision;
    _checkRevision(revision);
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
        _checkRevision(revision);
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
        _checkRevision(revision);
        target = _currentDescriptor(accepted);
        _targets[ownerDomainId] = target;
        await PreferenceWrites.run(_preferences, _key, () async {
          _checkRevision(revision);
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
        _checkRevision(revision);
        if (!DateTime.now().isBefore(expires)) rethrow;
        // Refresh is opportunistic while the installed descriptor is valid.
        // Never use it past expiry; the final verifier remains authoritative.
      } finally {
        client.close();
      }
    }
    // Revalidate expiry, signatures and anti-rollback even for cached content.
    target = _currentDescriptor(target);
    _checkRevision(revision);
    await _verifier.verify(target);
    _checkRevision(revision);
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
