import 'package:flutter/material.dart';

import '../host_setup/host_product_controller.dart';
import 'device_admission_page.dart';
import 'host_controller_device_admission.dart';

/// Open the Owner's approval queue, from wherever a decision is being waited on.
///
/// One entry point because there are now two callers with the same need and
/// they must reach the same queue: the device list, and the conversation screen
/// of a phone waiting for its own proposal to be approved. That second caller
/// is why this exists — the phone waiting was the Controller entitled to
/// decide, and the only thing the screen offered it was a refresh button.
Future<void> openDeviceAdmissionQueue(
  BuildContext context,
  HostProductController controller,
) async {
  final target = await controller.fetchDeviceOnboardingTarget();
  final owner = controller.workspace?.owner;
  final connection = controller.connection;
  if (!context.mounted || owner == null || connection == null) return;
  await Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => DeviceAdmissionPage(
        ownerDomainId: target.ownerDomainId,
        ownerDomainGeneration:
            target.ownerDomainDescriptor.ownerDomainGeneration,
        businessOwnerId: owner.ownerId,
        controllerId: connection.controllerId,
        loadRecovery: HostControllerDeviceAdmission(controller).listRecovery,
        onDecide: ({required requestId, required projection}) =>
            controller.decideEnrollment(
          requestId: requestId,
          projection: projection,
          initialCompanionId:
              controller.workspace?.workspace?.primaryCompanionId,
        ),
      ),
    ),
  );
}
