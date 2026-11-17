import '../../generated/management_v1.dart';
import '../../management/management_client.dart';
import '../host_setup/failure_sentences.dart';
import 'tool_policies.dart';

/// The words the tool screens say about tools.
///
/// A tool's own name and sentence come from the Host's catalog, so a tool a
/// package added yesterday is named without an App release. What is here is
/// the short, fixed vocabulary around them: groups, reasons, requirements.

/// The groups in the order the screens show them. The two body groups sit
/// together, so 「允许操控身体」 can stand above both.
const toolGroupOrder = [
  'general',
  'music',
  'vision',
  'motion',
  'device_settings',
  'collaboration',
];

/// Where any group this build has not heard of is shown.
const otherToolGroup = 'other';

/// Where every tool the system reserves is shown, last and folded.
const systemToolGroup = 'system';

/// The groups 「允许操控身体」 governs on an Eidolon's page.
const bodyToolGroups = {'motion', 'device_settings'};

String toolGroupLabel(String code) => switch (code) {
      'general' => '通用',
      'music' => '音乐',
      'motion' => '身体动作',
      'vision' => '视觉',
      'device_settings' => '设备设置',
      'collaboration' => '后台协作',
      'system' => '系统',
      _ => '其他',
    };

/// [rows] as the screens group them: the known groups in [toolGroupOrder],
/// then any group this build has not heard of under 其他, then everything the
/// system reserves under 系统. Rows keep the Host's order inside a group.
List<(String, List<T>)> toolSections<T>(
  Iterable<T> rows, {
  required String Function(T row) group,
  required bool Function(T row) reserved,
}) {
  String sectionOf(T row) {
    if (reserved(row)) return systemToolGroup;
    final code = group(row);
    if (code == systemToolGroup || toolGroupOrder.contains(code)) return code;
    return otherToolGroup;
  }

  final bySection = <String, List<T>>{};
  for (final row in rows) {
    bySection.putIfAbsent(sectionOf(row), () => []).add(row);
  }
  return [
    for (final code in [...toolGroupOrder, otherToolGroup, systemToolGroup])
      if (bySection[code] case final members?) (code, members),
  ];
}

/// Why a tool is locked, said where its switch would be.
String toolReservedText(ToolReservation reservation) =>
    switch (reservation.reason) {
      'interactive_session' => '系统保留：语音对话中不开放',
      _ => '系统保留',
    };

/// Said beside a switch the Owner's own switch has overruled.
const toolGlobalOffText = '已在工具总览中关闭';

/// Said beside a switch 「允许操控身体」 has overruled.
const toolBodyControlOffText = '已关闭操控身体';

/// When a change takes effect (§3.6): turning off reaches a conversation
/// already going from its next turn; turning on waits for the next one.
const toolTurnedOffNotice = '已关闭，正在进行的对话从下一句起生效';
const toolTurnedOnNotice = '已开启，下一次对话起生效';

String toolChangeNotice(bool enabled) =>
    enabled ? toolTurnedOnNotice : toolTurnedOffNotice;

/// Said when 恢复默认 left the switch where it already was.
const toolRestoredNotice = '已恢复默认';

/// 「N/M 个伙伴在用」 under a tool on the overview.
String toolUsageLine(ToolOverviewRowView row) {
  final using = row.companions.where((c) => c.effective).length;
  return row.companions.isEmpty
      ? '还没有伙伴'
      : '$using/${row.companions.length} 个伙伴在用';
}

/// The sentence under 「它能做的事」 on an Eidolon's page.
String companionToolsLine(CompanionToolsView view) {
  final offered = view.tools.where((row) => row.reserved == null).toList();
  final usable = offered.where((row) => row.effective).length;
  if (usable == offered.length) return '${offered.length} 个工具都能用';
  return '能用 $usable 个，${offered.length - usable} 个用不了';
}

/// Under a tool that needs a device: how many of this Eidolon's devices can
/// run it. [supported] is null while that is not known.
String toolDeviceSupportLine({required int devices, int? supported}) {
  if (devices == 0) return '需要设备支持 · 它还没有设备';
  if (supported == null) return '需要设备支持';
  return '需要设备支持 · 它的设备里有 $supported 台支持';
}

/// An output as a requirement: 「需要设备允许动作」.
String _outputName(String output) => switch (output) {
      'speech' => '说话',
      'dialogue_text' => '显示对话文字',
      'expression' => '表情',
      'audio_cue' => '提示音',
      'motion' => '动作',
      _ => '「$output」',
    };

/// An output as something a device was not allowed to do: 「没允许做动作」.
String _outputAct(String output) => switch (output) {
      'speech' => '说话',
      'dialogue_text' => '显示对话文字',
      'expression' => '做表情',
      'audio_cue' => '发提示音',
      'motion' => '做动作',
      _ => '「$output」',
    };

String _hostFeature(String? feature) => switch (feature) {
      'music' => '音乐服务',
      'vision_model' => '视觉模型',
      'face_recognition' => '人脸识别',
      _ => '这项功能需要的服务',
    };

/// What the Host must have before the tool can run anywhere.
///
/// A static requirement, not a reason: whether the Host has it is only known
/// to the voice worker when a conversation starts.
String toolHostRequirementText(String feature) =>
    '需要主机已配置${_hostFeature(feature)}';

/// What a tool needs, one sentence each, in the order a person would check.
List<String> toolRequirementLines(ToolRequirements requires) => [
      for (final output in requires.outputs ?? const <String>[])
        '需要设备允许${_outputName(output)}',
      if (requires.inputs?['camera'] == 'capture') '需要摄像头设为可拍照',
      if (requires.motionProfile != null)
        '需要设备的身体做得了这种动作'
      else if (requires.deviceContracts?.isNotEmpty ?? false)
        '需要设备支持',
      if (requires.hostFeature case final feature?)
        toolHostRequirementText(feature),
    ];

/// Why a tool cannot be used on a device, from the Host's reason code.
String toolReasonText(String code) {
  final split = code.indexOf(':');
  final kind = split < 0 ? code : code.substring(0, split);
  final detail = split < 0 ? null : code.substring(split + 1);
  return switch (kind) {
    'reserved' => '系统保留：语音对话中不开放',
    'global_off' => toolGlobalOffText,
    'companion_off' => '这个伙伴关掉了它',
    'body_control_off' => toolBodyControlOffText,
    'no_companion' => '还没有伙伴通过这台设备应答',
    'channel_not_ready' => '这台设备还不能开始对话',
    'device_not_declared' =>
      detail == 'camera.capture' ? '这台设备没有可拍照的摄像头' : '这台设备没有这项能力',
    'output_not_allowed' => '这台设备没允许${_outputAct(detail ?? '')}',
    'input_not_allowed' => '这台设备的摄像头没有设为可拍照',
    'motion_profile_mismatch' => '这台设备的身体做不了这种动作',
    'host_not_configured' => '主机还没配置${_hostFeature(detail)}',
    'device_restricted' => '在这台设备上被禁止了',
    _ => '暂时用不了',
  };
}

/// The button beside a reason that this phone can remove.
String toolReasonActionLabel(ToolReasonAction action) => switch (action) {
      ToolReasonAction.outputs => '去设置',
      ToolReasonAction.companion => '去伙伴页',
      ToolReasonAction.overview => '去总览',
    };

/// Said after rereading because somebody else changed the switches first.
const toolsChangedElsewhere = '工具开关刚被改过，已经重新读取';
const companionToolsChangedElsewhere = '这个伙伴的能力刚被改过，已经重新读取';

/// What went wrong with a change, in words a person can act on.
String toolFailure(Object error) {
  if (error is! ManagementRequestException) return failureSentence(error);
  return switch (error.code) {
    'unknown_tool' => '主机上已经没有这个工具了',
    'reserved_tool' => '系统保留的工具不能更改',
    _ => refusalText(error, subject: '工具设置'),
  };
}

/// What to say about a change that did not land: [changedElsewhere] when
/// somebody else changed the switches first, so the screen read them again.
String toolRefusal(Object error, {required String changedElsewhere}) =>
    error is ManagementRequestException && error.someoneElseChangedIt
        ? changedElsewhere
        : toolFailure(error);

/// Whether a refusal means the screen is out of date and should read again.
bool toolScreenIsStale(Object error) =>
    error is ManagementRequestException &&
    (error.someoneElseChangedIt || error.code == 'unknown_tool');
