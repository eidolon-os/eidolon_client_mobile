import '../../generated/management_v1.dart';
import '../../management/management_client.dart';
import '../host_setup/host_product_session.dart';

/// Everything the tool screens ask the Host, as one port.
///
/// Which tools exist, what each is called and what it needs are the Host's
/// catalog; the screens never keep a list of their own. A change carries only
/// what changed and the revision it was made against.
abstract interface class ToolPolicies {
  /// Every tool this Host has, with the Owner's switch and each Companion's.
  Future<ToolsOverviewView> overview();

  /// The Owner's switches. A null value puts a tool back on its default.
  Future<ToolsOverviewView> change(ToolPolicyChange change);

  Future<CompanionToolsView> companion(String companionId);

  /// One Companion's switches, and its 「允许操控身体」.
  Future<CompanionToolsView> changeCompanion(
      String companionId, ToolPolicyChange change);

  /// Which tools a conversation on this device could use now, and why not
  /// the others.
  Future<DeviceToolsView> device(String deviceId);
}

/// Uses the existing authenticated Host session, never a page-owned credential.
class HostToolPolicies implements ToolPolicies {
  HostToolPolicies(this._session);
  final HostProductSession _session;

  @override
  Future<ToolsOverviewView> overview() => _session.executeManagement(
      (client, uri, token) => client.fetchTools(uri, accessToken: token));

  @override
  Future<ToolsOverviewView> change(ToolPolicyChange change) =>
      _session.executeManagement((client, uri, token) =>
          client.changeTools(uri, accessToken: token, change: change));

  @override
  Future<CompanionToolsView> companion(String companionId) =>
      _session.executeManagement((client, uri, token) =>
          client.fetchCompanionTools(uri,
              accessToken: token, companionId: companionId));

  @override
  Future<CompanionToolsView> changeCompanion(
          String companionId, ToolPolicyChange change) =>
      _session.executeManagement((client, uri, token) =>
          client.changeCompanionTools(uri,
              accessToken: token, companionId: companionId, change: change));

  @override
  Future<DeviceToolsView> device(String deviceId) =>
      _session.executeManagement((client, uri, token) =>
          client.fetchDeviceTools(uri, accessToken: token, deviceId: deviceId));
}

/// Whether to offer the tool switches at all: the row on the Host card, the
/// 「它能做的事」 row on an Eidolon's page, and the section on a device's page.
///
/// A named rule, like [hostCan] beside it, so the three entries cannot come to
/// disagree. Only on the Host's own word: a context that was never read cannot
/// tell a Host that has the switches from one too old to have heard of them,
/// and the second would open each entry onto a page that cannot load. The
/// context is read as the Host connects, before any of these is reached.
bool hostOffersToolSwitches(ManagementContextView? context) =>
    context != null && hostCan(context, 'tools.govern');

/// The kinds of tool whose use depends on what a device's channel offers.
const deviceDependentKinds = {'channel', 'device', 'agent_device'};

/// Reasons about the device itself, rather than about anybody's switches or
/// about what the Host has configured.
const _deviceFactPrefixes = [
  'channel_not_ready',
  'device_not_declared:',
  'output_not_allowed:',
  'input_not_allowed:',
  'motion_profile_mismatch',
  'device_restricted',
];

bool _isDeviceFact(String reason) =>
    _deviceFactPrefixes.any((prefix) => reason.startsWith(prefix));

/// Whether this device is somewhere [row]'s tool can run, whoever's switch is
/// off: 「它的设备里有 2 台支持」 is about the devices, not the switches.
bool deviceSupports(DeviceToolRowView row) => !row.reasons.any(_isDeviceFact);

/// Where a person can go to remove a reason a tool cannot be used.
enum ToolReasonAction {
  /// What the device may hear and present.
  outputs,

  /// The Eidolon's own switches, 「允许操控身体」 among them.
  companion,

  /// The Owner's switches.
  overview,
}

/// The one place that changes [reason], or null when nothing on this phone
/// can: a device that lacks the part, a Host missing a service.
ToolReasonAction? toolReasonAction(String reason) {
  if (reason.startsWith('output_not_allowed:') ||
      reason.startsWith('input_not_allowed:')) {
    return ToolReasonAction.outputs;
  }
  return switch (reason) {
    'companion_off' || 'body_control_off' => ToolReasonAction.companion,
    'global_off' => ToolReasonAction.overview,
    _ => null,
  };
}
