import '../host_setup/host_product_controller.dart';
import '../host_setup/local_api_client.dart';
import '../../generated/device_foundation_v1.dart';
import 'device_setup_coordinator.dart';
import 'device_setup_models.dart';
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
  Future<CommissioningVoucher> issueCommissioningVoucher({
    required String operationalSpkiSha256,
  }) => _controller.issueCommissioningVoucher(
        operationalSpkiSha256: operationalSpkiSha256,
      );

  @override
  Future<EnrollmentProposalPageV1> listRecovery({
    AdmissionListCursorV1? after,
  }) =>
      _controller.listEnrollmentRecovery(after: after);

  @override
  Future<EnrollmentRecoveryProjectionV1> recover({
    required String enrollmentId,
  }) async {
    try {
      return await _controller.recoverEnrollment(enrollmentId: enrollmentId);
    } on LocalApiRequestException catch (error) {
      throw enrollmentRecoveryRefusal(error) ?? error;
    }
  }

  @override
  Future<EnrollmentRecoveryProjectionV1> decide({
    required String requestId,
    required EnrollmentRecoveryProjectionV1 projection,
    String? initialCompanionId,
  }) =>
      _controller.decideEnrollment(
        requestId: requestId,
        projection: projection,
        initialCompanionId: initialCompanionId,
      );
}


/// Grade a refused Enrollment recovery, or return null to let it through.
///
/// 404 here is not an outage. The Host is answering that this Enrollment is not
/// one of its own — the usual causes being that the Host was reinstalled, or
/// the Enrollment removed — and asking again will return 404 forever. Left
/// ungraded it reached the coordinator's catch-all as
/// `admission_unavailable, retryable: true`, so the screen printed
/// 「可安全重试」 directly above the Host's own 「主机上已经没有这台设备了」.
///
/// Everything else stays ungraded on purpose: a 503 or a dropped connection is
/// exactly the transient the retry exists for.
DeviceSetupException? enrollmentRecoveryRefusal(LocalApiRequestException error) {
  if (error.statusCode != 404) return null;
  return DeviceSetupException(
    code: 'enrollment_gone',
    message: error.toString(),
  );
}
