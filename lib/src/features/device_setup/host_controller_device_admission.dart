import '../host_setup/host_product_controller.dart';
import '../../generated/device_foundation_v1.dart';
import 'device_setup_ports.dart';

/// The admission half of device setup, as this Controller performs it.
///
/// The coordinator asks for admission through a port so that setting a device up
/// and approving one stay separable: a device that enrolled on its own — after a
/// reflash, or when nobody was running setup — is recovered through the same
/// authority projection. The companion a device attaches to is
/// the Owner's workspace's, which is the controller's to know and not something
/// the setup flow should be told to pass along.
class HostControllerDeviceAdmission implements DeviceAdmissionPort {
  const HostControllerDeviceAdmission(this._controller);

  final HostProductController _controller;

  @override
  Future<EnrollmentProposalPageV1> listRecovery({
    AdmissionListCursorV1? after,
  }) =>
      _controller.listEnrollmentRecovery(after: after);

  @override
  Future<EnrollmentRecoveryProjectionV1> recover({
    required String enrollmentId,
  }) =>
      _controller.recoverEnrollment(enrollmentId: enrollmentId);

  @override
  Future<EnrollmentRecoveryProjectionV1> decide({
    required String commandId,
    required String correlationId,
    required EnrollmentRecoveryProjectionV1 projection,
    String? initialCompanionId,
  }) =>
      _controller.decideEnrollment(
        commandId: commandId,
        correlationId: correlationId,
        projection: projection,
        initialCompanionId: initialCompanionId,
      );
}
