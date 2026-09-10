import 'package:flutter/material.dart';
import 'host_registry.dart';

class HostIdentitySummary extends StatelessWidget {
  const HostIdentitySummary(
      {super.key,
      required this.host,
      required this.status,
      this.showAddress = true,
      this.compact = false,
      this.currentAddress});
  final ManagedHost host;
  final String status;
  final bool showAddress;
  final bool compact;
  final String? currentAddress;

  @override
  Widget build(BuildContext context) {
    final info = host.machineInfo;
    final address = Uri.tryParse(host.lastKnownBaseUrl ?? '')?.host;
    final hardware = <String>[
      if (info?.model?.isNotEmpty == true) info!.model!,
      if (info?.cpuModel?.isNotEmpty == true && info!.cpuModel != info.model)
        info.cpuModel!,
      if ((info?.cpuCores ?? 0) > 0) '${info!.cpuCores} 核',
      if ((info?.memoryBytes ?? 0) > 0)
        '${(info!.memoryBytes! / (1024 * 1024 * 1024)).toStringAsFixed(0)} GiB 内存',
    ];
    final last = host.lastConnectedAt?.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(hardware.isEmpty ? '机型待主机提供' : hardware.join(' · ')),
        if (!compact && info?.operatingSystem?.isNotEmpty == true)
          Text(info!.operatingSystem!),
        if (!compact && info?.hostname.isNotEmpty == true)
          Text('系统主机名：${info!.hostname}'),
        if (!compact &&
            !host.hasCustomDisplayName &&
            host.readableName != host.displayName)
          Text('设备标识：${host.displayName}'),
        if (showAddress)
          Text(currentAddress != null
              ? 'Host IP：$currentAddress'
              : address?.isNotEmpty == true
                  ? '上次连接地址：$address'
                  : 'IP 尚未确认'),
        const SizedBox(height: 6),
        Text(status, style: Theme.of(context).textTheme.labelMedium),
        if (last != null)
          Text(
              '最近连接：${last.year}-${two(last.month)}-${two(last.day)} ${two(last.hour)}:${two(last.minute)}',
              style: Theme.of(context).textTheme.bodySmall),
      ]),
    );
  }
}
