/// Language-native mirror of the Mission Control Local API vocabulary.
///
/// The source of truth is `eidolon_sdk/eidolon_sdk/biz/contracts/mission_control.py`
/// and the JSON Schemas beside it in `eidolon_sdk/contracts/local_api/v1/`. This
/// file exists because Mobile does not import that package, and the SDK's
/// cross-repository mirror tests assert the two agree — the same arrangement the
/// device wire contract already uses.
///
/// Pure constants. Drift here is silent in the worst way: a request is made, a
/// payload parses, and a value simply never matches anything.
library;

const missionControlContractVersion = '1';
const missionControlSnapshotCoverage = 'owner-runtime';

/// Every projection block carries its own health. "Read it, it was empty" and
/// "could not read it" must never share a shape.
const laneStateOk = 'ok';
const laneStateDegraded = 'degraded';
const laneStateUnavailable = 'unavailable';
const laneStates = <String>{
  laneStateOk,
  laneStateDegraded,
  laneStateUnavailable
};

/// Device presence. `unknown` is neither online nor offline: it is nobody having
/// answered.
const presenceOnline = 'online';
const presenceOffline = 'offline';
const presenceDegraded = 'degraded';
const presenceUnknown = 'unknown';
const presenceStates = <String>{
  presenceOnline,
  presenceOffline,
  presenceDegraded,
  presenceUnknown,
};

/// Which authority answered for a presence. The Data authority is never one of
/// them — a lifecycle status is not a presence.
const presenceSourceBlackboard = 'runtime_blackboard';
const presenceSourceHub = 'hub';
const presenceSourceNone = 'none';
const presenceSources = <String>{
  presenceSourceBlackboard,
  presenceSourceHub,
  presenceSourceNone,
};

// The Companion lifecycle vocabulary is deliberately NOT here. It belongs to
// the Companion authority, not to Mission Control, and it is consumed by the
// management surface as well — see `companion_contract.dart`. Upstream made the
// same move: the SDK's `mission_control` module imports it from its own
// `companion` module rather than restating it.

const roleKinds = <String>{'guard', 'persona', 'unbound'};

const activityKinds = <String>{
  'voice_turn',
  'guard_event',
  'device_command',
  'device_event',
  'background_job',
};

const hopNodeTypes = <String>{
  'device',
  'companion',
  'service',
  'memory',
  'tool',
  'provider',
};
const hopDirections = <String>{'in', 'out', 'internal'};

/// Turn stages in request order. Controlled because three surfaces point at the
/// same instant with it: the asset moon, the backplane wavefront and the route
/// strip. An unknown key is compatible — nothing lights for it.
const stageKeys = <String>[
  'input',
  'speech',
  'duck',
  'eot',
  'commit',
  'memory_recall',
  'agent_turn',
  'brain',
  'response',
  'tools',
  'playback',
  'tts',
  'memory_write',
];

const serviceTiers = <String>{'service', 'middleware', 'external'};

/// Shared with the audit envelope. A projection of an audit event does not get
/// its own words for what happened.
const outcomes = <String>{'success', 'failure', 'denied', 'deferred'};
const severities = <String>{'info', 'warn', 'error', 'critical'};
const privacyClasses = <String>{'safe', 'sensitive', 'restricted'};

/// No `mock` on the wire. Staged data exists only inside this app, and is
/// labelled there.
const eventOrigins = <String>{'live', 'polling', 'replay'};

/// The stream cursor: the audit index's own total order on this Host.
const cursorField = 'ingest_seq';

/// Sent when a submitted cursor can no longer be honoured. The client drops its
/// cursor and re-reads a snapshot; it must never silently resume from now.
const streamResetEvent = 'stream.reset';
