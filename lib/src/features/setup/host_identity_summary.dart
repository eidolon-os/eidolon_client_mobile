import 'package:flutter/material.dart';

import '../../generated/management_v1.dart';
import '../../theme/eidolon_theme.dart';
import '../../theme/neon_components.dart';
import 'host_registry.dart';

/// Read a Host status line as one of the shared tones.
///
/// The status arrives as prose because it is written once and shown in several
/// places; the colour is derived here so a single sentence cannot disagree
/// with itself between the list and the detail page.
NeonTone hostStatusTone(String status) {
  if (status.contains('正在')) return NeonTone.accent;
  if (status.contains('无法') || status.contains('失败') || status.contains('不可')) {
    return NeonTone.warn;
  }
  if (status.contains('可连接') ||
      status.contains('已连接') ||
      status.contains('已安全连接')) {
    return NeonTone.ok;
  }
  return NeonTone.idle;
}

bool hostStatusBusy(String status) => status.contains('正在');

class HostIdentitySummary extends StatelessWidget {
  const HostIdentitySummary(
      {super.key,
      required this.host,
      required this.status,
      this.showAddress = true,
      this.compact = false,
      this.showStatus = true,
      this.currentAddress,
      this.release});
  final ManagedHost host;
  final String status;
  final bool showAddress;
  final bool compact;

  /// What the Host answered about its release this time. Null means it was
  /// not asked or did not answer, and then there is no line rather than a
  /// guess; a null `releaseId` inside is the Host saying it has no release.
  final HostReleaseView? release;

  /// The Host list draws the pill up in the card header next to the name, so
  /// it asks the summary to leave the status out rather than printing it twice.
  final bool showStatus;
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

    // Identifiers and addresses are instrument values, not prose: they go into
    // one monospaced block behind an accent rule so the eye can skip them.
    final readout = <String>[
      if (!compact && info?.hostname.isNotEmpty == true)
        '系统主机名：${info!.hostname}',
      if (!compact &&
          !host.hasCustomDisplayName &&
          host.readableName != host.displayName)
        '设备标识：${host.displayName}',
      if (release != null)
        'Release 版本：${release!.releaseId ?? '无（源码运行）'}',
      if (showAddress)
        currentAddress != null
            ? 'Host IP：$currentAddress'
            : address?.isNotEmpty == true
                ? '上次连接地址：$address'
                : 'IP 尚未确认',
    ];

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(
        hardware.isEmpty ? '机型待主机提供' : hardware.join(' · '),
        style: const TextStyle(
            fontSize: 13.5,
            height: 1.5,
            color: Neon.ink,
            fontWeight: FontWeight.w500),
      ),
      if (!compact && info?.operatingSystem?.isNotEmpty == true)
        Text(info!.operatingSystem!,
            style: const TextStyle(
                fontSize: 12.5, height: 1.5, color: Neon.inkFaint)),
      if (readout.isNotEmpty) ...[
        const SizedBox(height: Neon.s3),
        MetaReadout(readout),
      ],
      if (showStatus) ...[
        const SizedBox(height: Neon.s3),
        Align(
          alignment: Alignment.centerLeft,
          child: StatusPill(status,
              tone: hostStatusTone(status), busy: hostStatusBusy(status)),
        ),
      ],
      if (last != null) ...[
        const SizedBox(height: Neon.s2),
        Text(
            '最近连接：${last.year}-${two(last.month)}-${two(last.day)} ${two(last.hour)}:${two(last.minute)}',
            style: Neon.mono(size: 11, color: Neon.inkFaint)),
      ],
    ]);
  }
}
