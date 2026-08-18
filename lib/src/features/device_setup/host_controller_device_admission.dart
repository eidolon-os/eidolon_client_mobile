import '../host_setup/host_product_controller.dart';
import 'device_setup_models.dart';
import 'device_setup_ports.dart';

/// The admission half of device setup, as this Controller performs it.
///
/// The coordinator asks for admission through a port so that setting a device up
/// and approving one stay separable: a device that enrolled on its own — after a
/// reflash, or when nobody was running setup — is approved from the pending list
/// instead, through the same authority. The companion a device attaches to is
/// the Owner's workspace's, which is the controller's to know and not something
/// the setup flow should be told to pass along.
class HostControllerDeviceAdmission implements DeviceAdmissionPort {
  const HostControllerDeviceAdmission(this._controller);

  final HostProductController _controller;

  @override
  Future<List<PendingDeviceEnrollment>> listPending() =>
      _controller.listPendingDeviceEnrollments();

  @override
  Future<DeviceAdmissionProgress> approve({
    required String requestId,
    required String deviceId,
    String? companionId,
  }) =>
      _controller.approveDeviceEnrollment(
        requestId: requestId,
        deviceId: deviceId,
      );
}
