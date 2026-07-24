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

/// Whether to render the live talking-head video right now.
///
/// The avatar worker publishes its track for the whole session — a frozen frame
/// between turns — so track presence alone is NOT the signal. We show the live
/// video only while the agent is *speaking*; otherwise the stage renders the
/// local idle representation (placeholder now; a looping idle clip later). The
/// track stays subscribed at idle, so the switch to video is an instant flip.
bool shouldShowAvatarVideo({
  required bool hasVideoTrack,
  required AgentTurnState turn,
}) =>
    hasVideoTrack && turn == AgentTurnState.speaking;
