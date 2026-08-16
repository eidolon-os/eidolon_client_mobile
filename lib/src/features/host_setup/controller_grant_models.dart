/// The phones a Host lets manage it, as the Host reports them.
///
/// A household holds more than one phone, and the Host has always been able to
/// say which ones hold it, admit another and withdraw one. This is that answer
/// read strictly: a shape the Host is not supposed to send is refused rather
/// than shown, because everything here is about who has authority.
class ControllerGrant {
  const ControllerGrant({
    required this.controllerId,
    required this.displayName,
    required this.platform,
    required this.role,
    required this.createdAt,
  });

  factory ControllerGrant.fromJson(Map<String, dynamic> value) {
    final controllerId = value['controller_id'];
    final displayName = value['display_name'];
    final platform = value['platform'];
    final role = value['role'];
    final createdAt = value['created_at'];
    if (controllerId is! String ||
        controllerId.isEmpty ||
        displayName is! String ||
        platform is! String ||
        role is! String ||
        createdAt is! String) {
      throw const FormatException('主机返回了无法识别的管理手机记录');
    }
    final claimedAt = DateTime.tryParse(createdAt);
    if (claimedAt == null) {
      throw const FormatException('管理手机记录缺少可解析的时间');
    }
    return ControllerGrant(
      controllerId: controllerId,
      displayName: displayName,
      platform: platform,
      role: role,
      createdAt: claimedAt.toUtc(),
    );
  }

  final String controllerId;
  final String displayName;
  final String platform;
  final String role;
  final DateTime createdAt;
}

/// The window in which one more phone may claim this Host.
///
/// Opened by a phone that already holds it, so the Host is never left deciding
/// on its own who may join. The code is one-time and expires.
class ControllerInvitation {
  const ControllerInvitation({
    required this.setupCode,
    required this.expiresAt,
  });

  factory ControllerInvitation.fromJson(Map<String, dynamic> value) {
    final setupCode = value['setup_code'];
    final expiresAt = value['expires_at'];
    if (setupCode is! String || setupCode.isEmpty || expiresAt is! String) {
      throw const FormatException('主机没有返回可用的邀请码');
    }
    final deadline = DateTime.tryParse(expiresAt);
    if (deadline == null) {
      throw const FormatException('邀请码缺少可解析的有效期');
    }
    return ControllerInvitation(
      setupCode: setupCode,
      expiresAt: deadline.toUtc(),
    );
  }

  final String setupCode;
  final DateTime expiresAt;
}
