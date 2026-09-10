import 'package:flutter/material.dart';

import 'development_lan_commissioning.dart';
import 'host_registry.dart';
import 'setup_models.dart';

/// Presentation of evidence already collected by discovery or saved locally.
/// No additional requests, registration writes or connection checks occur here.
class HostDiscoveryDetails extends StatelessWidget {
  const HostDiscoveryDetails({
    super.key,
    required this.status,
    required this.displayName,
    this.known,
    this.lan,
    this.nearby,
    this.endpoint,
  });

  final String status;
  final String displayName;
  final ManagedHost? known;
  final DevelopmentLanHost? lan;
  final NearbyEidolonHost? nearby;
  final CommissioningEndpoint? endpoint;

  @override
  Widget build(BuildContext context) {
    final info = known?.machineInfo;
    final hardware = <String>[
      if (info?.model?.trim().isNotEmpty == true) info!.model!.trim(),
      if (info?.cpuModel?.trim().isNotEmpty == true &&
          info!.cpuModel != info.model)
        info.cpuModel!.trim(),
      if ((info?.cpuCores ?? 0) > 0) '${info!.cpuCores} 核',
      if ((info?.memoryBytes ?? 0) > 0)
        '${(info!.memoryBytes! / (1024 * 1024 * 1024)).toStringAsFixed(0)} GiB 内存',
    ];
    final liveAddress = _address(lan?.localApi.baseUrl);
    final publishedAddresses = (endpoint?.localApiBaseUrls ?? const <String>[])
        .map(_address)
        .whereType<String>()
        .toSet();
    final previousAddress = _address(known?.lastKnownBaseUrl);
    final serviceName = lan?.localApi.instanceName.trim();
    final last = known?.lastConnectedAt?.toLocal();
    final identity = endpoint?.hostId ?? known?.hostId;
    String two(int value) => value.toString().padLeft(2, '0');
    final addresses = <String>[
      if (liveAddress != null)
        '局域网地址：$liveAddress'
      else if (publishedAddresses.isNotEmpty)
        '主机提供地址：${publishedAddresses.join('、')}'
      else if (previousAddress != null)
        '上次连接地址：$previousAddress'
      else
        '局域网地址：暂未获取',
    ];
    final details = <String>[
      if (info?.operatingSystem?.trim().isNotEmpty == true)
        '系统：${info!.operatingSystem!.trim()}',
      if (info?.hostname.trim().isNotEmpty == true)
        '主机名：${info!.hostname.trim()}',
      if (serviceName != null &&
          serviceName.isNotEmpty &&
          serviceName != displayName &&
          serviceName != info?.hostname &&
          serviceName != lan?.localApi.ipAddress)
        '服务名称：$serviceName',
      if (nearby != null && nearby!.name != displayName) '广播名称：${nearby!.name}',
      '发现方式：${[if (lan != null) '局域网', if (nearby != null) '蓝牙'].join(' + ')}'
          '${nearby != null ? ' · 信号 ${nearby!.rssi} dBm' : ''}',
      if (identity != null) 'Host ID：$identity',
      if (identity == null && nearby != null) '蓝牙地址：${nearby!.address}',
      if (last != null)
        '最近连接：${last.year}-${two(last.month)}-${two(last.day)} '
            '${two(last.hour)}:${two(last.minute)}',
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(status, style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          if (hardware.isNotEmpty)
            Text(hardware.join(' · '),
                style: Theme.of(context).textTheme.bodyMedium)
          else if (identity != null)
            Text(known == null ? '机型和系统信息将在添加并连接后显示' : '尚未保存机型信息',
                style: Theme.of(context).textTheme.bodySmall),
          for (final address in addresses) Text(address),
          ExpansionTile(
            title: const Text('识别详情'),
            children: [
              for (final detail in details)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: SelectableText(detail,
                      style: Theme.of(context).textTheme.bodySmall),
                ),
            ],
          ),
          if (info != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('设备资料来自上次连接',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ),
        ],
      ),
    );
  }

  static String? _address(String? value) {
    final uri = Uri.tryParse(value ?? '');
    if (uri == null || uri.host.isEmpty) return null;
    final host = uri.host.contains(':') ? '[${uri.host}]' : uri.host;
    return uri.hasPort ? '$host:${uri.port}' : host;
  }
}
