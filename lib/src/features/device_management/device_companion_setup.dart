import 'dart:convert';
import '../../generated/management_v1.dart';
import '../../platform/app_preferences.dart';
import 'mounted_device_models.dart';

class CompanionSetupException implements Exception {
  const CompanionSetupException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Post-admission setup. Network/claim credentials remain in Device Setup;
/// only owner decisions are journalled here, scoped to Host/controller/Owner/device.
enum CompanionSetupStep {
  creating,
  confirmBinding,
  binding,
  outputs,
  savingOutputs
}

class CompanionSetupIntent {
  const CompanionSetupIntent(
      {required this.step,
      required this.requestId,
      required this.expectedRevision,
      this.companionId,
      this.companionName = '',
      this.description = '',
      this.creationOperationId,
      this.allowed,
      this.inputs,
      this.outputRevision});
  final CompanionSetupStep step;
  final String requestId;
  final int expectedRevision;
  final String? companionId;
  final String companionName;
  final String description;
  final String? creationOperationId;
  final OutputSelection? allowed;
  final InputSelection? inputs;
  final int? outputRevision;

  /// Whether this record still stands for something the phone cannot work out
  /// by asking the Host again.
  ///
  /// The journal exists for one reason: a request may already be with the Host
  /// when the app stops, and the answer has to be reclaimed rather than
  /// guessed. A creation that was never submitted has no such request behind
  /// it — no Companion exists, nothing waits to be acknowledged, and reopening
  /// the picker reconstructs the whole of it. A record like that is not
  /// progress to resume; kept, it outranks the Host's own state and sends
  /// every later visit straight back into creation.
  bool get isRecoverable =>
      step != CompanionSetupStep.creating || creationOperationId != null;

  CompanionSetupIntent at(CompanionSetupStep step,
          {String? companionId,
          String? companionName,
          String? creationOperationId,
          OutputSelection? allowed,
          InputSelection? inputs,
          int? outputRevision}) =>
      CompanionSetupIntent(
          step: step,
          requestId: requestId,
          expectedRevision: expectedRevision,
          companionId: companionId ?? this.companionId,
          companionName: companionName ?? this.companionName,
          description: description,
          creationOperationId: creationOperationId ?? this.creationOperationId,
          allowed: allowed ?? this.allowed,
          inputs: inputs ?? this.inputs,
          outputRevision: outputRevision ?? this.outputRevision);
  Map<String, dynamic> toJson() => {
        'version': 1,
        'step': step.name,
        'request_id': requestId,
        'expected_revision': expectedRevision,
        'companion_id': companionId,
        'companion_name': companionName,
        'description': description,
        'creation_operation_id': creationOperationId,
        'allowed': allowed?.toJson(),
        if (inputs != null) 'inputs': inputs!.toJson(),
        'output_revision': outputRevision
      };
  factory CompanionSetupIntent.decode(String raw) {
    final j = jsonDecode(raw) as Map<String, dynamic>;
    if (j['version'] != 1 ||
        (j.length != 10 && !(j.length == 11 && j.containsKey('inputs'))) ||
        j['request_id'] is! String ||
        (j['request_id'] as String).isEmpty ||
        j['expected_revision'] is! int ||
        (j['expected_revision'] as int) < 0) {
      throw const FormatException('无法读取设备配置进度，请保留数据并更新应用。');
    }
    final step = CompanionSetupStep.values.byName(j['step'] as String);
    final allowed = j['allowed'] == null
        ? null
        : OutputSelection.fromJson(j['allowed'] as Map<String, dynamic>);
    final outputRevision = j['output_revision'] as int?;
    if (step == CompanionSetupStep.savingOutputs &&
        (allowed == null || outputRevision == null || outputRevision < 0)) {
      throw const FormatException('表达设置恢复记录不完整。');
    }
    return CompanionSetupIntent(
        step: step,
        requestId: j['request_id'] as String,
        expectedRevision: j['expected_revision'] as int,
        companionId: j['companion_id'] as String?,
        creationOperationId: j['creation_operation_id'] as String?,
        companionName: j['companion_name'] as String,
        description: j['description'] as String,
        allowed: allowed,
        inputs: j['inputs'] == null ? null : InputSelection.fromJson(j['inputs'] as Map<String, dynamic>),
        outputRevision: outputRevision);
  }
}

class DeviceCompanionSetupStore {
  DeviceCompanionSetupStore(
      {required String hostId,
      required String controllerId,
      required String ownerId,
      String? deviceId,
      AppPreferences? preferences})
      : _preferences = preferences ?? PlatformAppPreferences(),
        _key =
            'eidolon.companion-device-setup.v1.${base64Url.encode(utf8.encode(jsonEncode([
              hostId,
              controllerId,
              ownerId,
              deviceId
            ])))}' {
    if ([hostId, controllerId, ownerId].any((s) => s.isEmpty) ||
        deviceId == '') {
      throw ArgumentError('Device setup requires its full authority scope');
    }
  }
  final AppPreferences _preferences;
  final String _key;
  Future<CompanionSetupIntent?> load() async {
    final raw = await _preferences.readString(_key);
    return raw == null || raw.isEmpty ? null : CompanionSetupIntent.decode(raw);
  }

  Future<void> save(CompanionSetupIntent intent) =>
      PreferenceWrites.run(_preferences, _key, () async {
        final old = await load();
        if (old != null && old.requestId != intent.requestId) {
          throw CompanionSetupException('这台设备还有未完成的配置，请先继续原操作。');
        }
        await _preferences.writeString(_key, jsonEncode(intent.toJson()));
      });
  Future<void> clear(String requestId) =>
      PreferenceWrites.run(_preferences, _key, () async {
        final old = await load();
        if (old != null && old.requestId != requestId) {
          throw CompanionSetupException('配置进度已变化，请重新打开设备。');
        }
        await _preferences.writeString(_key, '');
      });
}

/// Recovery never trusts a local "success" flag. Read current authority first,
/// then either recognize the result, retry the identical decision, or stop on CAS conflict.
class DeviceCompanionSetup {
  DeviceCompanionSetup(
      {required this.store,
      required this.loadDevice,
      required this.bind,
      required this.setOutputs});
  final DeviceCompanionSetupStore store;
  final Future<MountedDevice> Function() loadDevice;
  final Future<void> Function(CompanionSetupIntent) bind;
  final Future<void> Function(OutputSelection, InputSelection?, int) setOutputs;
  Future<MountedDevice> finishBinding(CompanionSetupIntent intent) async {
    var device = await loadDevice();
    _active(device);
    if (device.attachedCompanionId != intent.companionId) {
      if (device.revision != intent.expectedRevision) {
        throw CompanionSetupException('设备的应答伙伴已在别处更改，请重新选择，不会覆盖新设置。');
      }
      await bind(intent);
      device = await loadDevice();
      if (device.attachedCompanionId != intent.companionId) {
        throw CompanionSetupException('主机尚未确认伙伴绑定，请继续核对。');
      }
    }
    if (device.outputs.decided || intent.companionId == null) {
      await store.clear(intent.requestId);
    } else {
      await store.save(intent.at(CompanionSetupStep.outputs));
    }
    return device;
  }

  Future<MountedDevice> finishOutputs(CompanionSetupIntent intent) async {
    var device = await loadDevice();
    _active(device);
    if (device.attachedCompanionId != intent.companionId) {
      throw CompanionSetupException('应答伙伴已改变，请核对后重新选择表达方式。');
    }
    if (!_matches(device.outputs, intent)) {
      if (device.outputs.revision != intent.outputRevision) {
        throw CompanionSetupException('表达设置已在别处更改，请重新选择，不会覆盖新设置。');
      }
      await setOutputs(intent.allowed!, intent.inputs, intent.outputRevision!);
      device = await loadDevice();
      if (!_matches(device.outputs, intent)) {
        throw CompanionSetupException('主机尚未确认表达设置，请继续核对。');
      }
    }
    await store.clear(intent.requestId);
    return device;
  }

  static bool _matches(DeviceOutputs outputs, CompanionSetupIntent intent) =>
      _same(outputs.allowed, intent.allowed) &&
      (intent.inputs == null || outputs.inputs?.microphone == intent.inputs!.microphone);

  static bool _same(OutputSelection? a, OutputSelection? b) =>
      a != null &&
      b != null &&
      (a.speech ?? false) == (b.speech ?? false) &&
      (a.dialogueText ?? false) == (b.dialogueText ?? false) &&
      (a.expression ?? false) == (b.expression ?? false) &&
      (a.audioCue ?? false) == (b.audioCue ?? false) &&
      (a.motion ?? false) == (b.motion ?? false);
  static void _active(MountedDevice device) {
    if (device.state == MountedDeviceState.accessRevoked) {
      throw CompanionSetupException('设备已停用，请返回设备列表。');
    }
  }
}
