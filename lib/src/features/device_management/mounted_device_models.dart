import '../../generated/management_v1.dart';

/// What this Owner's Host says about one device it holds.
///
/// Three facts, from three authorities, deliberately not collapsed into one:
/// Hub says whether the Claim still stands, Kernel says whether the device is
/// mounted, and the mount says which Companion it answers as. A device whose
/// Claim was revoked but whose mount survives is a real, reachable state — a
/// removal that finished its first half — and folding it into "fine" is how
/// the one screen that could offer the retry stopped being able to say so.
enum MountedDeviceState {
  /// The Claim stands and a Companion answers through this device.
  ready,

  /// The Claim stands; nothing answers through it yet.
  awaitingCompanion,

  /// Platform access is gone and the Host still lists it. The device is
  /// already off; what is left to retry is the unmount.
  accessRevoked,
}

class MountedDevice {
  const MountedDevice({
    required this.deviceId,
    required this.label,
    required this.detail,
    required this.state,
    required this.attachedCompanionId,
    required this.attachedCompanionName,
    required this.revision,
    required this.updatedAt,
    required this.online,
    required this.onlineReason,
    required this.claimState,
    required this.claimGeneration,
    required this.trustEpoch,
    required this.ownerDomainGeneration,
    required this.manifestId,
  });

  /// Built from the Host's own answer.
  ///
  /// The label, the detail line and the state used to be derived here, three
  /// facts at a time, from a Claim and a mount this app had to reason about
  /// together. The Host composes and phrases them now — it is the side that can
  /// see both halves — and what is left here is the enum a screen switches on.
  factory MountedDevice.fromView(DeviceView view) => MountedDevice(
        deviceId: view.deviceId,
        label: view.label,
        detail: (view.kind ?? '').isNotEmpty && view.kind != view.label
            ? view.kind!
            : view.deviceId,
        state: switch (view.state) {
          'ready' => MountedDeviceState.ready,
          'awaiting_companion' => MountedDeviceState.awaitingCompanion,
          'access_revoked' => MountedDeviceState.accessRevoked,
          // A state this version has never heard of is shown as needing
          // attention rather than as fine: the Host knows something this app
          // does not, and "fine" is the one guess that costs someone a device.
          _ => MountedDeviceState.accessRevoked,
        },
        attachedCompanionId: view.answersAsCompanionId,
        attachedCompanionName: view.answersAsCompanionName ?? '',
        revision: view.revision,
        updatedAt: DateTime.tryParse(view.updatedAt)?.toUtc(),
        online: view.online ?? 'unknown',
        onlineReason: view.onlineReason ?? '',
        claimState: view.claimState,
        claimGeneration: view.claimGeneration,
        trustEpoch: view.trustEpoch,
        ownerDomainGeneration: view.ownerDomainGeneration,
        manifestId: view.manifestId ?? '',
      );

  final String deviceId;

  /// How to name it on screen. The Host never invents one: it is what the
  /// Manifest calls this kind of thing, or the tail of the identifier.
  final String label;

  /// The line under the name — the kind when it adds something, otherwise the
  /// identifier, which is what someone reads out when asking for help.
  final String detail;
  final MountedDeviceState state;
  final String? attachedCompanionId;

  /// What that Eidolon is called. Empty when the Host could not say, which is
  /// not the same as nothing answering through this device.
  final String attachedCompanionName;

  /// Echoed back on every change so a stale screen cannot win a race.
  final int revision;
  final DateTime? updatedAt;

  /// Always `unknown` today. Nothing on the Host observes presence, and this
  /// app must not read an active Claim or a live mount as "switched on".
  final String online;
  final String onlineReason;

  /// The canonical facts, kept for the technical corner of a screen: they are
  /// what a person will be asked for when something is wrong.
  final String claimState;
  final int claimGeneration;
  final int trustEpoch;
  final int ownerDomainGeneration;
  final String manifestId;
}

class MountedDeviceInventory {
  const MountedDeviceInventory({required this.devices, this.coverage = ''});

  factory MountedDeviceInventory.fromView(DevicesView view) =>
      MountedDeviceInventory(
        devices: view.devices.map(MountedDevice.fromView).toList(growable: false),
        coverage: view.coverage ?? '',
      );

  final List<MountedDevice> devices;

  /// What this list does not cover, in the Host's own words. Shown rather than
  /// paraphrased: a short list must not be allowed to imply a quiet house.
  final String coverage;
}
