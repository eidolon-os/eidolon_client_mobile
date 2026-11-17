import 'package:eidolon_client_mobile/src/features/device_management/mounted_device_models.dart';
import 'package:eidolon_client_mobile/src/features/tools/tool_policies.dart';
import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'package:eidolon_client_mobile/src/management/management_client.dart';

/// The Host's catalog and switches as the tool screens see them, and a fake
/// Host that answers from them and writes every call down.

const companionA = 'companion-a';
const companionB = 'companion-b';

/// Somebody else changed the switches first: Data's 409, relayed by Admin.
const toolPolicyChanged = ManagementRequestException('更改工具开关被拒绝',
    statusCode: 409,
    refusal: Refusal(kind: 'conflict', code: 'tool_policy_changed'));

ToolRequirements requirements({
  List<String> outputs = const [],
  Map<String, String> inputs = const {},
  List<String> contracts = const [],
  String? motionProfile,
  String? hostFeature,
}) =>
    ToolRequirements(
        outputs: outputs,
        inputs: inputs,
        deviceContracts: contracts,
        motionProfile: motionProfile,
        hostFeature: hostFeature);

/// One entry of the catalog, as every view below is built from it.
class CatalogTool {
  const CatalogTool(this.key, this.label, this.group,
      {this.kind = 'brain',
      this.reserved = false,
      this.bodyControl = false,
      this.defaultEnabled = true,
      this.requires});
  final String key, label, group, kind;
  final bool reserved, bodyControl, defaultEnabled;
  final ToolRequirements? requires;

  String get summary => '$label的说明。';
  ToolReservation? get reservation =>
      reserved ? const ToolReservation(reason: 'interactive_session') : null;
  ToolRequirements get needs => requires ?? requirements();
}

/// The Host's order: by group, then key, reserved last — the screens regroup.
final catalog = <CatalogTool>[
  CatalogTool('vision.look', '看一眼', 'vision',
      kind: 'agent_device',
      requires: requirements(
          inputs: {'camera': 'capture'}, contracts: ['camera.capture'])),
  CatalogTool('audio.volume.set', '设定音量', 'device_settings',
      kind: 'device',
      bodyControl: true,
      requires:
          requirements(outputs: ['speech'], contracts: ['audio.volume.set'])),
  const CatalogTool('get_time', '查询时间', 'general'),
  const CatalogTool('get_weather', '查询天气', 'general'),
  CatalogTool('motion.look', '转头看', 'motion',
      kind: 'device',
      bodyControl: true,
      requires: requirements(outputs: ['motion'], contracts: ['motion.look'])),
  CatalogTool('motion.nod', '点头', 'motion',
      kind: 'device',
      bodyControl: true,
      requires: requirements(outputs: ['motion'], contracts: ['motion.nod'])),
  CatalogTool('music.play', '播放音乐', 'music',
      kind: 'channel',
      requires: requirements(outputs: ['speech'], hostFeature: 'music')),
  const CatalogTool('weird.tool', '新来的工具', 'weird'),
  const CatalogTool('delegate_to_coworker', '交给后台去办', 'collaboration',
      reserved: true),
  const CatalogTool('emit_event', '发出系统事件', 'system', reserved: true),
];

/// One layer of switches: overrides over the catalog's defaults.
class Switches {
  Switches({Map<String, bool>? overrides, this.revision = 1})
      : overrides = {...?overrides};
  final Map<String, bool> overrides;
  int revision;

  bool of(CatalogTool tool) => overrides[tool.key] ?? tool.defaultEnabled;

  void apply(Map<String, Object?> changes) {
    for (final MapEntry(:key, :value) in changes.entries) {
      if (value == null) {
        overrides.remove(key);
      } else {
        overrides[key] = value as bool;
      }
    }
  }
}

class CompanionSwitches extends Switches {
  CompanionSwitches(this.name,
      {super.overrides, super.revision, this.allowBodyControl = true});
  final String name;
  bool allowBodyControl;
}

/// Which layer keeps [tool] from a Companion, as the SDK's one rule says.
String? blockedBy(
    CatalogTool tool, Switches owner, CompanionSwitches companion) {
  if (tool.reserved) return 'reserved';
  if (!owner.of(tool)) return 'global';
  if (tool.bodyControl && !companion.allowBodyControl) return 'body_control';
  if (!companion.of(tool)) return 'companion';
  return null;
}

/// A device of the Owner's, answering as [companionId].
MountedDevice mountedDevice(String id,
        {String label = 'esp-box-3',
        String? companionId = companionA,
        String companionName = '小忆'}) =>
    MountedDevice.fromView(DeviceView.fromJson({
      'device_id': id,
      'label': label,
      'kind': label,
      'state': companionId == null ? 'awaiting_companion' : 'ready',
      'answers_as_companion_id': companionId,
      'answers_as_companion_name': companionId == null ? '' : companionName,
      'revision': 4,
      'mount_revision': 7,
      'updated_at': '2026-11-17T08:10:00Z',
      'online': 'unknown',
      'online_reason': '这台主机没有任何东西在观测设备是否开着',
      'claim_state': 'active',
      'claim_generation': 2,
      'trust_epoch': 1,
      'owner_domain_generation': 3,
      'manifest_id': label,
      'manifest_revision': 1,
      'outputs': {
        'capabilities': {'speech': true, 'expression': true, 'motion': true},
        'allowed': {'speech': true},
        'revision': 2,
      },
    }));

DeviceToolRowView deviceRow(String key,
    {List<String> reasons = const [], String? label}) {
  final tool = catalog.where((t) => t.key == key).firstOrNull;
  return DeviceToolRowView(
    key: key,
    label: label ?? tool?.label ?? key,
    summary: tool?.summary ?? '',
    group: tool?.group ?? 'general',
    kind: tool?.kind ?? 'brain',
    available: reasons.isEmpty,
    reasons: reasons,
    requires: tool?.needs ?? requirements(),
  );
}

DeviceToolsView deviceTools(String deviceId,
        {String? companionId = companionA,
        List<DeviceToolRowView> tools = const [],
        DeviceToolRestriction? restriction}) =>
    DeviceToolsView(
        deviceId: deviceId,
        companionId: companionId,
        tools: tools,
        restriction: restriction);

/// A device's own restriction, as the Host answers it: sorted, de-duplicated.
DeviceToolRestriction restriction(int revision, Iterable<String> denied) =>
    DeviceToolRestriction(
        revision: revision, denied: ({...denied}.toList()..sort()));

/// The Host refusing a restriction for a device whose outputs were never
/// decided.
const outputPolicyRequired = ManagementRequestException('更改这台设备的工具限制被拒绝',
    statusCode: 409,
    refusal: Refusal(kind: 'conflict', code: 'output_policy_required'));

const _switchReasons = {
  'global_off',
  'no_companion',
  'companion_off',
  'body_control_off',
};

/// A stale restriction revision: a conflict with no code of its own.
const restrictionChanged = ManagementRequestException('更改这台设备的工具限制被拒绝',
    statusCode: 409, refusal: Refusal(kind: 'conflict'));

/// The Host, as the tool screens see it: answers composed from [tools] and
/// the two layers of switches, every call written down.
class FakeToolPolicies implements ToolPolicies {
  FakeToolPolicies({
    List<CatalogTool>? tools,
    Switches? owner,
    Map<String, CompanionSwitches>? companions,
    Map<String, DeviceToolsView>? devices,
  })  : tools = tools ?? catalog,
        owner = owner ?? Switches(revision: 3),
        companions = companions ??
            {
              companionA: CompanionSwitches('小忆'),
              companionB: CompanionSwitches('阿福'),
            },
        devices = {...?devices};

  final List<CatalogTool> tools;
  final Switches owner;
  final Map<String, CompanionSwitches> companions;
  final Map<String, DeviceToolsView> devices;

  final calls = <String>[];
  final changes = <ToolPolicyChange>[];
  final companionChanges = <(String, ToolPolicyChange)>[];
  final restrictions = <(String, DeviceToolRestrictionRequest)>[];

  /// What the next write does instead of succeeding, when set.
  Object? writeFailure;

  /// What every read of a device does instead of answering, when set.
  Object? deviceFailure;

  int reads(String call) => calls.where((c) => c == call).length;

  ToolsOverviewView get _overview => ToolsOverviewView(
        revision: owner.revision,
        catalogRevision: 'sha256:catalog',
        tools: [
          for (final tool in tools)
            ToolOverviewRowView(
              key: tool.key,
              label: tool.label,
              summary: tool.summary,
              group: tool.group,
              kind: tool.kind,
              sideEffect: false,
              reserved: tool.reservation,
              defaultEnabled: tool.defaultEnabled,
              globalEnabled: owner.of(tool),
              globalOverridden: owner.overrides.containsKey(tool.key),
              requires: tool.needs,
              companions: [
                for (final MapEntry(key: id, value: companion)
                    in companions.entries)
                  ToolCompanionSwitchView(
                    companionId: id,
                    name: companion.name,
                    revision: companion.revision,
                    enabled: companion.of(tool),
                    effective: blockedBy(tool, owner, companion) == null,
                    blockedBy: blockedBy(tool, owner, companion),
                  ),
              ],
            ),
        ],
      );

  CompanionToolsView _companion(String id) {
    final companion = companions[id]!;
    return CompanionToolsView(
      companionId: id,
      revision: companion.revision,
      allowBodyControl: companion.allowBodyControl,
      tools: [
        for (final tool in tools)
          CompanionToolRowView(
            key: tool.key,
            label: tool.label,
            summary: tool.summary,
            group: tool.group,
            kind: tool.kind,
            reserved: tool.reservation,
            defaultEnabled: tool.defaultEnabled,
            globalEnabled: owner.of(tool),
            companionEnabled: companion.of(tool),
            companionOverridden: companion.overrides.containsKey(tool.key),
            effective: blockedBy(tool, owner, companion) == null,
            bodyControl: tool.bodyControl,
            blockedBy: blockedBy(tool, owner, companion),
            requires: tool.needs,
          ),
      ],
    );
  }

  Never _fail(Object failure) {
    writeFailure = null;
    throw failure;
  }

  @override
  Future<ToolsOverviewView> overview() async {
    calls.add('overview');
    return _overview;
  }

  @override
  Future<ToolsOverviewView> change(ToolPolicyChange change) async {
    changes.add(change);
    if (writeFailure case final failure?) _fail(failure);
    owner
      ..apply(change.changes ?? const {})
      ..revision += 1;
    return _overview;
  }

  @override
  Future<CompanionToolsView> companion(String companionId) async {
    calls.add('companion $companionId');
    return _companion(companionId);
  }

  @override
  Future<CompanionToolsView> changeCompanion(
      String companionId, ToolPolicyChange change) async {
    companionChanges.add((companionId, change));
    if (writeFailure case final failure?) _fail(failure);
    final companion = companions[companionId]!
      ..apply(change.changes ?? const {})
      ..revision += 1;
    if (change.allowBodyControl case final allow?) {
      companion.allowBodyControl = allow;
    }
    return _companion(companionId);
  }

  @override
  Future<DeviceToolsView> device(String deviceId) async {
    calls.add('device $deviceId');
    if (deviceFailure case final failure?) throw failure;
    return devices[deviceId] ?? deviceTools(deviceId);
  }

  /// Keeps the new list and marks each tool it denies, the way the Host adds
  /// `device_restricted` after the switch reasons.
  @override
  Future<DeviceToolRestriction> restrict(
      String deviceId, DeviceToolRestrictionRequest request) async {
    restrictions.add((deviceId, request));
    if (writeFailure case final failure?) _fail(failure);
    final view = devices[deviceId] ?? deviceTools(deviceId);
    final answer = restriction(
        (view.restriction?.revision ?? 0) + 1, request.denied ?? const []);
    final denied = answer.denied!.toSet();
    devices[deviceId] = deviceTools(deviceId,
        companionId: view.companionId,
        restriction: answer,
        tools: [
          for (final row in view.tools)
            deviceRow(row.key,
                label: row.label,
                reasons: row.reasons.contains('reserved')
                    ? row.reasons
                    : [
                        ...row.reasons.where(_switchReasons.contains),
                        if (denied.contains(row.key)) 'device_restricted',
                        ...row.reasons.where((reason) =>
                            !_switchReasons.contains(reason) &&
                            reason != 'device_restricted'),
                      ]),
        ]);
    return answer;
  }
}
