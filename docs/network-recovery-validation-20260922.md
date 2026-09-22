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

## BOX-3 hardware acceptance

- Selecting the old record and connecting the current physical BOX-3 rejected
  the identity mismatch before Owner preparation or Wi-Fi submission.
- Selecting the current record preserved identity through preparation and real
  Wi-Fi scanning; cancelling and re-entering also succeeded.
- The first full same-network submission rolled back with
  `OWNER_ROUTE_UNAVAILABLE`. Device-side failure logs were unavailable.
- After a device restart, the 17:51 submission to Manson succeeded: phone and
  serial logs both confirmed committed terminal state, terminal ACK returned
  HTTP 200, and control/voice connections resumed with operational_ready=1.
- The existing device ID, claim generation, activation timestamp, mount revision
  and Companion binding were unchanged. No additional claim was created.
- With user authorization, the obsolete f16e… claim was revoked through the app
  at 2026-09-22 09:53:22 UTC. The current 7daa… claim remained active. Refreshing
  the list showed one BOX-3 and three devices total.

## Remaining acceptance and root-cause limits

Cross-SSID switching has not been tested. The earlier intermittent
`OWNER_ROUTE_UNAVAILABLE` is unresolved: success after restart does not identify
its cause. The earlier StackChan HTTP receive timeout must not be called resolved
solely from unit tests or the firmware TCP_NODELAY mechanism reproduction.

The historical BOX-3 records used different operational keys and independently
issued base identities. Historical qualification notes already reported that
mismatch before this network move; original evidence identifying the first key
change is unavailable. A base-derived hardware reference is not immutable chip
attestation, so merging records by model or name is unsafe. The obsolete claim
was explicitly revoked, not automatically merged or deleted from audit history.
