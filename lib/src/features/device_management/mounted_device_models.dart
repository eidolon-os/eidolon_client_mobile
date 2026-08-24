import '../../generated/device_foundation_v1.dart';

/// What this Owner's Host says about one device it holds.
///
/// Three facts, from three authorities, deliberately not collapsed into one:
/// Hub says whether the Claim still stands, Kernel says whether the device is
/// mounted, and the mount says which Companion it answers as. A device whose
/// Claim was revoked but whose mount survives is a real, reachable state — a
/// removal that finished its first half — and folding it into "fine" is how
/// the one screen that could offer the retry stopped being able to say so.
enum MountedDeviceState {
  /// The Claim stands and a Companion answers through this device.
  ready,

  /// The Claim stands; nothing answers through it yet.
  awaitingCompanion,

  /// Platform access is gone and the Host still lists it. The device is
  /// already off; what is left to retry is the unmount.
  accessRevoked,
}

class MountedDeviceMount {
  const MountedDeviceMount({
    required this.revision,
    required this.attachedCompanionId,
    required this.updatedAt,
  });

  factory MountedDeviceMount.fromJson(Map<String, dynamic> value) {
    final revision = value['revision'];
    final companionId = value['attached_companion_id'];
    final rawUpdatedAt = value['updated_at'];
    if (value.length != 3 ||
        revision is! int ||
        revision < 1 ||
        (companionId != null &&
            (companionId is! String ||
                companionId.isEmpty ||
                companionId.length > 64)) ||
        rawUpdatedAt is! String) {
      throw const FormatException('Local API 返回了无效的设备挂载状态');
    }
    final updatedAt = DateTime.tryParse(rawUpdatedAt);
    if (updatedAt == null || !updatedAt.isUtc) {
      throw const FormatException('设备挂载时间缺少时区');
    }
    return MountedDeviceMount(
      revision: revision,
      attachedCompanionId: companionId as String?,
      updatedAt: updatedAt,
    );
  }

  final int revision;
  final String? attachedCompanionId;
  final DateTime updatedAt;
}

class MountedDevice {
  const MountedDevice({required this.claim, required this.mount});

  factory MountedDevice.fromJson(Map<String, dynamic> value) {
    final rawClaim = value['claim'];
    final rawMount = value['mount'];
    if (value.length != 2 || rawClaim is! Map || rawMount is! Map) {
      throw const FormatException('Local API 返回了无效的设备');
    }
    return MountedDevice(
      claim: ClaimRecordV1.fromJson(Map<String, dynamic>.from(rawClaim)),
      mount: MountedDeviceMount.fromJson(Map<String, dynamic>.from(rawMount)),
    );
  }

  /// Hub's own Claim record, kept whole rather than copied field by field: the
  /// generation and trust epoch inside it are what a later removal has to name,
  /// and re-deriving them is how a stale one gets sent.
  final ClaimRecordV1 claim;
  final MountedDeviceMount mount;

  DeviceRefV1 get deviceRef => DeviceRefV1.fromJson(
        Map<String, dynamic>.from(claim.json['device_ref']! as Map),
      );

  String get deviceId => deviceRef.deviceInstanceId;

  /// What kind of thing this is, as the accepted Manifest names it. Nobody has
  /// named devices yet, and an identifier is not a name.
  String get deviceKind {
    final manifest = claim.json['manifest_ref'];
    final value = manifest is Map ? manifest['manifest_id'] : null;
    return value is String ? value.trim() : '';
  }

  MountedDeviceState get state {
    if (claim.json['state'] != ClaimStateV1.active.wireValue) {
      return MountedDeviceState.accessRevoked;
    }
    return mount.attachedCompanionId == null
        ? MountedDeviceState.awaitingCompanion
        : MountedDeviceState.ready;
  }

  String get _shortId => deviceId.length <= 16
      ? deviceId
      : '…${deviceId.substring(deviceId.length - 12)}';

  /// The line under the name: what kind of thing it is, or the tail of its
  /// identifier when the kind would only repeat the line above.
  String get detail =>
      deviceKind.isNotEmpty && deviceKind != label ? deviceKind : _shortId;

  /// How this device should be named on screen: what it is, and failing that
  /// the tail of its identifier, so there is something to read out when asking
  /// for help — and never invented into a name.
  String get label => deviceKind.isNotEmpty ? deviceKind : _shortId;
}

class MountedDeviceInventory {
  const MountedDeviceInventory({required this.devices});

  factory MountedDeviceInventory.fromJson(Map<String, dynamic> value) {
    final rawDevices = value['devices'];
    if (value.length != 3 ||
        value['contract_version'] != '1' ||
        value['coverage'] !=
            'active-kernel-mounts-with-owner-scoped-hub-claims' ||
        rawDevices is! List ||
        rawDevices.length > 100) {
      throw const FormatException('Local API 返回了无效的设备列表');
    }
    final devices = rawDevices.map((item) {
      if (item is! Map) {
        throw const FormatException('Local API 设备列表包含无效条目');
      }
      return MountedDevice.fromJson(Map<String, dynamic>.from(item));
    }).toList(growable: false);
    if (devices.map((item) => item.deviceId).toSet().length != devices.length) {
      throw const FormatException('Local API 设备列表包含重复设备');
    }
    return MountedDeviceInventory(devices: devices);
  }

  final List<MountedDevice> devices;
}
