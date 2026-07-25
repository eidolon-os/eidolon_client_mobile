import '../models/client_ui_state.dart';

/// Identity prefix of the digital-human avatar worker participant. The channel
/// spawns it as ``avatar-<room>`` (see channel ``avatar_identity_for``) and it
/// publishes the talking-head video track. Kept in sync with the web client's
/// ``AVATAR_IDENTITY_PREFIX``.
const avatarIdentityPrefix = 'avatar-';

/// Whether a subscribed track's publisher is the avatar worker. We target only
/// its track so a stray video publisher can't hijack the stage.
bool isAvatarIdentity(String identity) =>
    identity.startsWith(avatarIdentityPrefix);

/// Signed path of the companion idle-loop clip on hub (device-scoped; hub
/// resolves device → companion). Kept as a constant so the signed path matches
/// exactly what the server verifies.
const companionIdlePath = '/api/avatar/idle/video';

/// Absolute idle-clip URL derived from the hub register URL's origin, or null if
/// the register URL can't be parsed. The device plays this looping as its idle
/// placeholder (client-side idle, mirroring the web client's fetch from admin).
String? companionIdleUrl(String registerUrl) {
  final uri = Uri.tryParse(registerUrl);
  if (uri == null || uri.host.isEmpty) return null;
  return Uri(
    scheme: uri.scheme,
    host: uri.host,
    port: uri.port,
    path: companionIdlePath,
  ).toString();
}

/// Whether the live avatar should remain on stage.
///
/// The worker intentionally keeps its track alive and freezes the last frame
/// between turns. Therefore a subscribed track remains the correct resting face
/// while listening/idle; switching it out based on turn state makes the avatar
/// disappear exactly when the user starts speaking.
bool isAvatarVideoActive({
  required bool hasVideoTrack,
  required AgentTurnState turn,
}) =>
    hasVideoTrack;
