enum MountedDeviceAdmissionState { mounted, ready }

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
  const MountedDevice({
    required this.deviceId,
    required this.displayName,
    required this.deviceKind,
    required this.admissionState,
    required this.mount,
  });

  factory MountedDevice.fromJson(Map<String, dynamic> value) {
    final deviceId = value['device_id'];
    final rawState = value['admission_state'];
    final rawMount = value['mount'];
    final rawName = value['display_name'];
    final rawKind = value['device_kind'];
    // Three fields on a Host that predates saying what a device is, five on
    // one that says it. An App is routinely newer than the Host beside it.
    if (value.length < 3 ||
        value.length > 5 ||
        (rawName != null && rawName is! String) ||
        (rawKind != null && rawKind is! String) ||
        deviceId is! String ||
        deviceId.isEmpty ||
        deviceId.length > 128 ||
        rawState is! String ||
        rawMount is! Map) {
      throw const FormatException('Local API 返回了无效的设备');
    }
    final state = switch (rawState) {
      'mounted' => MountedDeviceAdmissionState.mounted,
      'ready' => MountedDeviceAdmissionState.ready,
      _ => throw const FormatException('Local API 返回了未知的设备状态'),
    };
    final mount = MountedDeviceMount.fromJson(
      Map<String, dynamic>.from(rawMount),
    );
    if (state == MountedDeviceAdmissionState.ready &&
        mount.attachedCompanionId == null) {
      throw const FormatException('Ready 设备没有关联 Companion');
    }
    if (state == MountedDeviceAdmissionState.mounted &&
        mount.attachedCompanionId != null) {
      throw const FormatException('Mounted 设备包含了已完成的 Companion 关联');
    }
    return MountedDevice(
      deviceId: deviceId,
      displayName: (rawName as String?)?.trim() ?? '',
      deviceKind: (rawKind as String?)?.trim() ?? '',
      admissionState: state,
      mount: mount,
    );
  }

  final String deviceId;

  /// What this device is called, or empty when the Host could not say. Empty
  /// stays empty: an identifier is what someone falls back to when nobody
  /// will tell them what a thing is, not a substitute for its name.
  final String displayName;

  /// What kind of thing it is — esp32-box3, a phone. Useful exactly when the
  /// name is missing or when two devices share one.
  final String deviceKind;

  /// How this device should be named on screen: what it is called, and
  /// failing that what it is, and failing that the tail of its identifier so
  /// there is at least something to read out when asking for help.
  String get label {
    if (displayName.isNotEmpty) return displayName;
    if (deviceKind.isNotEmpty) return deviceKind;
    return deviceId.length <= 16
        ? deviceId
        : '…${deviceId.substring(deviceId.length - 12)}';
  }

  final MountedDeviceAdmissionState admissionState;
  final MountedDeviceMount mount;
}

class MountedDeviceInventory {
  const MountedDeviceInventory({required this.devices});

  factory MountedDeviceInventory.fromJson(Map<String, dynamic> value) {
    final rawDevices = value['devices'];
    if (value.length != 3 ||
        value['contract_version'] != '1' ||
        value['coverage'] != 'mounted-devices' ||
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
