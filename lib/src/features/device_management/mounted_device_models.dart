import '../../generated/management_v1.dart';

/// What this Owner's Host says about one device it holds.
///
/// Three facts, from three authorities, deliberately not collapsed into one:
/// Hub says whether the Claim still stands, Kernel says whether the device is
/// mounted, and its Body says which Companion answers through it. A device
/// whose Claim was revoked but whose mount survives is a real, reachable state
/// — a removal that finished its first half — and folding it into "fine" is how
/// the one screen that could offer the retry stopped being able to say so.
/// Why a device answers as nobody.
///
/// The three ways it happens leave the same empty assignment behind and are not
/// the same event. A person who cleared a speaker knows why it is silent; a
/// person whose Eidolon was put away is owed the sentence; and a speaker nobody
/// ever pointed anywhere was never quiet in the first place. One word for all
/// three would read as a fault in at least one of them.
enum DeviceQuietBecause {
  /// Nothing to explain: something answers, or nobody has decided yet.
  unstated,

  /// The Owner pointed it at nobody.
  ownerCleared,

  /// The Eidolon it answered as was put away.
  companionPutAway,

  /// The Host let it go on its own.
  hostReleased,
}

enum MountedDeviceState {
  /// The Claim stands and a Companion answers through this device.
  ready,

  /// The Claim stands; nothing answers through it. Why nothing does is
  /// [MountedDevice.quietBecause], and it is a different sentence each way.
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
    required this.quietBecause,
    required this.revision,
    required this.mountRevision,
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
        quietBecause: switch (view.quietBecause) {
          'you_cleared_it' => DeviceQuietBecause.ownerCleared,
          'companion_put_away' => DeviceQuietBecause.companionPutAway,
          'host_released_it' => DeviceQuietBecause.hostReleased,
          // Empty is the ordinary case — something answers, or nobody ever
          // decided — and a word this version has not heard of falls here too:
          // saying nothing is better than inventing a reason.
          _ => DeviceQuietBecause.unstated,
        },
        revision: view.revision,
        mountRevision: view.mountRevision,
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

  /// Why nobody answers through it, when nobody does.
  final DeviceQuietBecause quietBecause;

  /// The *Body's* version, echoed back on every change so a stale screen cannot
  /// win a race. Zero for a device nobody has pointed anywhere yet: that is a
  /// value to send, not one that is missing.
  final int revision;

  /// Whether this device is on the Host, at which version. Never sent back —
  /// it is one of the canonical facts a person is asked for when something is
  /// wrong, and it is a different number from the one above.
  final int mountRevision;
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
