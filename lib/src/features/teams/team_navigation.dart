import '../../generated/management_v1.dart';
import '../voice_preview/voice_preview_panel.dart';
import 'package:flutter/material.dart';
import '../host_setup/host_product_controller.dart';
import 'team_management_page.dart';
import 'team_run_page.dart';

/// Both product entrances use the same saved assets and Host-owned controllers.
Future<void> openTeamManagement(
        BuildContext context,
        HostProductController controller,
        Future<void> Function() openDevices) =>
    Navigator.of(context).push<void>(MaterialPageRoute(
        builder: (_) => TeamManagementPage(
              voicePreview: VoicePreviewPanel(
                  request: controller.voicePreview.request,
                  audio: controller.voicePreview.audio),
              load: (after) => controller.teams.list(after: after),
              openRun: (team) => _openTeamRun(context, controller, team),
              save: controller.teams.save,
              remove: controller.teams.delete,
              loadDevices: () async {
                await controller.refreshDevices();
                if (controller.devicesError != null ||
                    controller.devices == null) {
                  throw StateError('Device inventory unavailable');
                }
                return controller.devices!.devices;
              },
              openDevices: openDevices,
            )));

Future<void> _openTeamRun(BuildContext context,
        HostProductController controller, TeamRevision team) =>
    Navigator.of(context).push<void>(MaterialPageRoute(
        builder: (_) => TeamRunPage(
            team: team,
            controller: controller.teamRun(team.teamId),
            loadRuns: () => controller.teams.runs(team.teamId),
            reloadTeam: () => controller.teams.get(team.teamId),
            loadConflicts: () => controller.teams.conflicts(team.teamId),
            openConflict: (id) async {
              final other = await controller.teams.get(id);
              if (context.mounted) {
                await _openTeamRun(context, controller, other);
              }
            })));
