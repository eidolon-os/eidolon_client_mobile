import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class LocalApiEndpoint {
  const LocalApiEndpoint({
    required this.instanceName,
    required this.baseUrl,
    required this.ipAddress,
    required this.contractVersion,
  });

  factory LocalApiEndpoint.fromMap(Map<Object?, Object?> value) {
    final instanceName = value['instanceName'];
    final baseUrl = value['baseUrl'];
    final ipAddress = value['ipAddress'];
    final contractVersion = value['contractVersion'];
    final uri = baseUrl is String ? Uri.tryParse(baseUrl) : null;
    final parsedAddress =
        ipAddress is String ? InternetAddress.tryParse(ipAddress) : null;
    if (instanceName is! String ||
        instanceName.isEmpty ||
        baseUrl is! String ||
        uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        parsedAddress == null ||
        contractVersion != '1') {
      throw const FormatException('发现了无效的 Eidolon Local API 服务');
    }
    return LocalApiEndpoint(
      instanceName: instanceName,
      baseUrl: baseUrl,
      ipAddress: parsedAddress.address,
      contractVersion: contractVersion as String,
    );
  }

  final String instanceName;
  final String baseUrl;
  final String ipAddress;
  final String contractVersion;
}

abstract interface class LocalApiDiscovery {
  Future<List<LocalApiEndpoint>> discover({Duration timeout});
}

class PlatformLocalApiDiscovery implements LocalApiDiscovery {
  PlatformLocalApiDiscovery({MethodChannel? channel})
      : _channel =
            channel ?? const MethodChannel('live.eidolon.mobile/platform');

  final MethodChannel _channel;

  @override
  Future<List<LocalApiEndpoint>> discover({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      throw PlatformException(
        code: 'UNSUPPORTED_PLATFORM',
        message: 'Local API discovery currently requires Android',
      );
    }
    final raw = await _channel.invokeListMethod<Object?>('discoverLocalApis', {
      'timeoutMs': timeout.inMilliseconds,
    });
    return (raw ?? const <Object?>[])
        .map(
          (item) => LocalApiEndpoint.fromMap(
            Map<Object?, Object?>.from(item! as Map),
          ),
        )
        .toList(growable: false);
  }
}
