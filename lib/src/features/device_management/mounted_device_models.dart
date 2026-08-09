enum MountedDeviceAdmissionState { mounted, ready, inactive }

class MountedDeviceMount {
  const MountedDeviceMount({
    required this.active,
    required this.revision,
    required this.attachedCompanionId,
    required this.updatedAt,
  });

  factory MountedDeviceMount.fromJson(Map<String, dynamic> value) {
    final rawState = value['state'];
    final revision = value['revision'];
    final companionId = value['attached_companion_id'];
    final rawUpdatedAt = value['updated_at'];
    if (value.length != 4 ||
        (rawState != 'active' && rawState != 'inactive') ||
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
      active: rawState == 'active',
      revision: revision,
      attachedCompanionId: companionId as String?,
      updatedAt: updatedAt,
    );
  }

  final bool active;
  final int revision;
  final String? attachedCompanionId;
  final DateTime updatedAt;
}

class MountedDevice {
  const MountedDevice({
    required this.deviceId,
    required this.admissionState,
    required this.mount,
  });

  factory MountedDevice.fromJson(Map<String, dynamic> value) {
    final deviceId = value['device_id'];
    final rawState = value['admission_state'];
    final rawMount = value['mount'];
    if (value.length != 3 ||
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
      'inactive' => MountedDeviceAdmissionState.inactive,
      _ => throw const FormatException('Local API 返回了未知的设备状态'),
    };
    final mount = MountedDeviceMount.fromJson(
      Map<String, dynamic>.from(rawMount),
    );
    if ((state == MountedDeviceAdmissionState.inactive) == mount.active) {
      throw const FormatException('设备状态与挂载状态不一致');
    }
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
      admissionState: state,
      mount: mount,
    );
  }

  final String deviceId;
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
