# Network recovery validation — 2026-09-22

## Changes

- Provisioning visits own their network, HTTP calls, cookies and completion
  lifecycle. Failed or closed visits cannot complete a later visit. Wi-Fi scans
  use bounded asynchronous polling; encrypted requests are not replayed.
- An already registered Host discovered over BLE offers the existing
  authenticated Wi-Fi change flow. A failed LAN connection also offers recovery.
  Confirmation must report success before the UI reports that Wi-Fi changed.
- Device details offer network maintenance scoped to the original device ID.
  Identity changes during preparation or between hotspot visits stop before
  network submission. Recovery lists exclude other devices' unfinished work.
- Device registration is displayed separately from connectivity, which is
  currently unobserved. Cancelling provisioning does not open an unrelated device.

## Evidence

- Native provisioning tests: 66 passed during unified provisioning validation.
- Host recovery tests: 78 passed; analysis and APK build passed. A real OPi
  without Wi-Fi was recovered over authenticated BLE. The phone then authenticated
  on the new LAN address and updated the existing Host registration.
- Device recovery tests: 74 distinct related cases passed, including one updated
  wording assertion verified by rerunning its 9-case file. Analysis and APK build
  passed. The final APK was installed and maintenance entry points inspected.

## Remaining acceptance

Device network switching, interruption/retry and identity mismatch still need
hardware acceptance. The earlier StackChan intermittent HTTP receive timeout
must not be called resolved solely from unit tests or the companion firmware's
TCP_NODELAY mechanism reproduction.

The two BOX-3 records have different operational keys and independently issued
base identities. Historical qualification notes already reported an identity
mismatch before this network move; original evidence identifying the first key
change is unavailable. A base-derived hardware reference is not immutable chip
attestation, so merging records by model or name is unsafe. Old-record revocation
is pending explicit approval; no duplicate record has been revoked by this work.
