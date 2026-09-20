import 'dart:convert';

import '../generated/management_v1.dart';
import 'management_client.dart' show CreatedCompanion;
import '../platform/app_preferences.dart';

/// A submitted request, not a live reference to a form or the current catalogue.
class CompanionCreationSubmission {
  CompanionCreationSubmission(
      String operationId,
      String name,
      PersonaAuthoring? persona,
      ConversationPreferences? preferences,
      PersonaPreset? sourcePreset)
      : this._fromJson({
          'version': 1,
          'operation_id': operationId,
          'name': name,
          'persona': persona?.toJson(),
          'preferences': preferences?.toJson(),
          'source_preset': sourcePreset?.toJson(),
        });

  CompanionCreationSubmission._fromJson(Map<String, dynamic> value)
      : operationId = value['operation_id'] as String,
        name = value['name'] as String,
        persona = value['persona'] == null
            ? null
            : PersonaAuthoring.fromJson(
                Map<String, dynamic>.from(value['persona'] as Map)),
        preferences = value['preferences'] == null
            ? null
            : ConversationPreferences.fromJson(
                Map<String, dynamic>.from(value['preferences'] as Map)),
        sourcePreset = value['source_preset'] == null
            ? null
            : PersonaPreset.fromJson(
                Map<String, dynamic>.from(value['source_preset'] as Map));

  factory CompanionCreationSubmission.decode(String raw) {
    final value = jsonDecode(raw);
    if (value is! Map<String, dynamic> ||
        value['version'] != 1 ||
        value.length != 6 ||
        !value.keys.toSet().containsAll(const {
          'version',
          'operation_id',
          'name',
          'persona',
          'preferences',
          'source_preset',
        }) ||
        value['operation_id'] is! String ||
        (value['operation_id'] as String).isEmpty ||
        value['name'] is! String ||
        (value['name'] as String).trim().isEmpty) {
      throw const FormatException('Invalid companion creation checkpoint');
    }
    final submission = CompanionCreationSubmission._fromJson(value)
      ..uncertain = true;
    if (jsonEncode(_canonical(value)) !=
        jsonEncode(_canonical(jsonDecode(submission.encode())))) {
      throw const FormatException(
          'Creation checkpoint would lose fields in this App version');
    }
    return submission;
  }

  final String operationId;
  final String name;
  final PersonaAuthoring? persona;
  final ConversationPreferences? preferences;
  final PersonaPreset? sourcePreset;
  bool uncertain = false;

  String encode() => jsonEncode({
        'version': 1,
        'operation_id': operationId,
        'name': name,
        'persona': persona?.toJson(),
        'preferences': preferences?.toJson(),
        'source_preset': sourcePreset?.toJson(),
      });
}

/// One unresolved creation per Host/controller/Owner. Do not silently discard
/// corrupt or old state: losing an operation id could duplicate a companion.
/// Holds private authored content locally; never credentials or memory history.
class CompanionCreationCheckpointStore {
  CompanionCreationCheckpointStore({
    required String hostId,
    required String controllerId,
    required String ownerId,
    AppPreferences? preferences,
  })  : _preferences = preferences ?? PlatformAppPreferences(),
        _key =
            'eidolon.companion-creation.v1.${base64Url.encode(utf8.encode(jsonEncode([
              hostId,
              controllerId,
              ownerId
            ])))}' {
    if ([hostId, controllerId, ownerId].any((value) => value.isEmpty)) {
      throw ArgumentError(
          'Creation recovery requires Host, controller and Owner');
    }
  }

  final AppPreferences _preferences;
  final String _key;

  // A device can await this creation while the user resumes it from the roster.
  // Retain a receipt only for explicitly watched operations, until that device acknowledges it.
  String _receiptKey(String operationId) =>
      '$_key.result.${base64Url.encode(utf8.encode(operationId))}';
  Future<void> watch(String operationId) =>
      PreferenceWrites.run(_preferences, _key, () async {
        final key = _receiptKey(operationId);
        if (await _preferences.readString(key) == null) {
          await _preferences.writeString(key, '{}');
        }
      });
  Future<void> complete(String operationId, CreatedCompanion result) =>
      PreferenceWrites.run(_preferences, _key, () async {
        final key = _receiptKey(operationId);
        final watched = await _preferences.readString(key);
        if (watched == null || watched.isEmpty) return;
        await _preferences.writeString(
            key,
            jsonEncode({
              'companion_id': result.companionId,
              'display_name': result.displayName,
              'created': result.created,
              'memory_ready': result.memoryReady
            }));
      });
  Future<CreatedCompanion?> result(String operationId) async {
    final raw = await _preferences.readString(_receiptKey(operationId));
    if (raw == null || raw.isEmpty || raw == '{}') return null;
    final j = jsonDecode(raw) as Map<String, dynamic>;
    return CreatedCompanion(
        companionId: j['companion_id'] as String,
        displayName: j['display_name'] as String,
        created: j['created'] as bool,
        memoryReady: j['memory_ready'] as bool);
  }

  Future<void> acknowledge(String operationId) => PreferenceWrites.run(
      _preferences,
      _key,
      () => _preferences.writeString(_receiptKey(operationId), ''));

  Future<CompanionCreationSubmission?> load() async {
    final raw = await _preferences.readString(_key);
    return raw == null || raw.isEmpty
        ? null
        : CompanionCreationSubmission.decode(raw);
  }

  Future<void> save(CompanionCreationSubmission submission) =>
      PreferenceWrites.run(_preferences, _key, () async {
        final pending = await load();
        if (pending != null && pending.encode() != submission.encode()) {
          throw StateError('Another companion creation is still unresolved');
        }
        await _preferences.writeString(_key, submission.encode());
      });

  Future<void> clear(String operationId) =>
      PreferenceWrites.run(_preferences, _key, () async {
        final pending = await load();
        if (pending == null) return;
        if (pending.operationId != operationId) {
          throw StateError('Cannot clear another creation operation');
        }
        await _preferences.writeString(_key, '');
      });
}

// Compare semantic content independently of JSON object key order. Older or
// newer fields must never disappear when a saved request is reconstructed.
Object? _canonical(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _canonical(value[key])};
  }
  if (value is List) return value.map(_canonical).toList();
  return value;
}
