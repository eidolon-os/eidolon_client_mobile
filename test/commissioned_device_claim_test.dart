import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_models.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/host_product_controller.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/host_product_session.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/pinned_http_client.dart';
import 'package:flutter_test/flutter_test.dart';

const _deviceId = '24:ec:4a:52:f3:54';

PendingDeviceEnrollment _pending(String deviceId) =>
    PendingDeviceEnrollment.fromJson({
      'device_id': deviceId,
      'display_name': 'Box-3',
      'device_kind': 'esp32-box3',
      'enrolled_at': '2026-08-13T04:42:00Z',
    });

DeviceAdmissionProgress _claimed() => DeviceAdmissionProgress(
      requestId: 'device-commissioned-$_deviceId',
      deviceId: _deviceId,
      ownerId: 'owner-1',
      outcome: ActOutcome.done,
      stoppedAfter: 'companion-attached',
      companionId: 'companion-1',
    );

PinnedHttpException _transport(PinnedHttpFailureKind kind) =>
    PinnedHttpException(kind: kind, message: 'no route to the Host');

/// A clock and a sleep that move together, so a 150s policy costs no real time.
class _Fake {
  var now = DateTime.utc(2026, 8, 13, 4, 42);

  DateTime clock() => now;

  Future<void> sleep(Duration duration) async {
    now = now.add(duration);
  }
}

void main() {
  test('waits out the handover instead of reporting the setup as failed',
      () async {
    // The phone has just let go of the device's access point. Android does not
    // hand the home network back in the same breath, so the first calls reach
    // nothing — while the device is already commissioned and on its way to the
    // Host. This is the failure the Owner saw as "配网失败" for a device that
    // had in fact been set up.
    final fake = _Fake();
    var calls = 0;
    var approved = false;

    final progress = await claimWhenBothEndsAreBack(
      deviceId: _deviceId,
      listPending: () async {
        calls += 1;
        if (calls <= 3) throw _transport(PinnedHttpFailureKind.unreachable);
        if (calls == 4) return const <PendingDeviceEnrollment>[];
        return [_pending(_deviceId)];
      },
      approve: () async {
        approved = true;
        return _claimed();
      },
      clock: fake.clock,
      sleep: fake.sleep,
    );

    expect(approved, isTrue);
    expect(progress.outcome, ActOutcome.done);
    expect(calls, 5);
  });

  test('a Host that answered and refused is not waited on', () async {
    // Only the absence of a transport is something to wait for. A refusal is
    // something the Host decided, and sitting on it for two and a half minutes
    // would hide what it said.
    final fake = _Fake();
    var calls = 0;

    await expectLater(
      claimWhenBothEndsAreBack(
        deviceId: _deviceId,
        listPending: () async {
          calls += 1;
          throw _transport(PinnedHttpFailureKind.secureChannel);
        },
        approve: () async => _claimed(),
        clock: fake.clock,
        sleep: fake.sleep,
      ),
      throwsA(isA<PinnedHttpException>()),
    );
    expect(calls, 1);
  });

  test('says which end never came back when the wait runs out', () async {
    final fake = _Fake();

    await expectLater(
      claimWhenBothEndsAreBack(
        deviceId: _deviceId,
        listPending: () async =>
            throw _transport(PinnedHttpFailureKind.unreachable),
        approve: () async => _claimed(),
        clock: fake.clock,
        sleep: fake.sleep,
      ),
      throwsA(
        isA<HostControllerAuthorizationException>().having(
          (HostControllerAuthorizationException error) => error.message,
          'message',
          allOf(contains('联系不上主机'), contains('设备已经配好')),
        ),
      ),
    );

    // The Host answering all along means the device is what never arrived, and
    // the person is told that instead.
    final settled = _Fake();
    await expectLater(
      claimWhenBothEndsAreBack(
        deviceId: _deviceId,
        listPending: () async => const <PendingDeviceEnrollment>[],
        approve: () async => _claimed(),
        clock: settled.clock,
        sleep: settled.sleep,
      ),
      throwsA(
        isA<HostControllerAuthorizationException>().having(
          (HostControllerAuthorizationException error) => error.message,
          'message',
          contains('设备还没有连上主机'),
        ),
      ),
    );
  });

  test('the wait covers both arrivals, not just one of them', () {
    // Device: up to 25s joining the network the firmware was given, then
    // discovery and enrollment. Phone: its own way back onto the home network.
    // Neither is controlled from here, so the budget sits above their sum.
    expect(commissionedClaimTimeout.inSeconds, greaterThanOrEqualTo(120));
  });
}
