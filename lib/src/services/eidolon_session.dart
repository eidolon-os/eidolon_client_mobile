import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:livekit_client/livekit_client.dart';

import '../avatar/avatar_stage.dart';
import '../models/hub_models.dart';
import '../protocol/eidolon_protocol.dart';

/// One channel, held for as long as this client is enrolled.
///
/// There used to be two rooms: a control room the client lived in and a voice
/// room it joined to have a conversation. Connecting was therefore how it asked
/// to be heard, and disconnecting was how it stopped — which meant every
/// conversation began by building a room and ended by tearing one down. Now the
/// connection stands still and the client says which it wants.
class EidolonSession {
  Room? _room;
  EventsListener<RoomEvent>? _listener;

  /// The conversation this client is currently asking to have, readable so the
  /// controller can tell a lifecycle packet about *this* conversation from one
  /// about the last. An agent's `session_end` for conversation N can arrive
  /// after this client has opened N+1; acting on it would end the wrong one.
  String? get conversationId => _conversationId;

  /// The conversation this client is currently asking to have, if any.
  ///
  /// Null between conversations. It is not derived from the room or the
  /// channel: both outlive a conversation, which is the whole reason the
  /// contract has a separate correlation key.
  String? _conversationId;
  int _conversationSequence = 0;
  final _random = Random.secure();

  final _dataController = StreamController<SessionData>.broadcast();
  final _stateController = StreamController<SessionState>.broadcast();
  final _videoController = StreamController<VideoTrack?>.broadcast();
  final _presenceController = StreamController<bool>.broadcast();
  int _audioStateSequence = 0;

  Stream<SessionData> get dataEvents => _dataController.stream;
  Stream<SessionState> get stateEvents => _stateController.stream;
  Stream<VideoTrack?> get remoteVideo => _videoController.stream;

  /// Whether anyone is still on the far end of this channel.
  ///
  /// Deliberately its own typed stream rather than another [stateEvents]
  /// string. That stream is about the *channel*, and a channel can be
  /// perfectly connected with nobody in the room — which is exactly the case
  /// a person cannot see. It is also mapped by the controller with a
  /// catch-all that resolves every unrecognised string to `disconnected`, so
  /// an unattended room would have been reported as a dropped channel: a
  /// different fact, with a different remedy, said in the same words.
  Stream<bool> get farEndPresent => _presenceController.stream;

  /// Remote participants that could be answering, avatars excluded.
  ///
  /// The worker that draws a face is not the thing that answers, so an avatar
  /// publisher lingering after the agent died must not make an empty room look
  /// attended. The prefix is this app's existing one, not a new rule.
  bool get _anyoneAnswering =>
      (_room?.remoteParticipants.values ?? const <RemoteParticipant>[])
          .any((participant) => !isAvatarIdentity(participant.identity));

  /// Reports the room's occupancy as it is, with no judgement about whether
  /// the report is actionable.
  ///
  /// Whether an empty room *means* the far end abandoned a conversation is the
  /// controller's decision, and it is made in exactly one place there. This
  /// used to guard on [isConnected] here as well; two guards in two objects
  /// for one question is how a condition comes to be enforced in one of them
  /// and not the other, and the half that lived here could not be reached by
  /// a test without a live LiveKit room.
  void _emitPresence() => _presenceController.add(_anyoneAnswering);

  bool get isConnected => _room?.connectionState == ConnectionState.connected;

  static const _capture = AudioCaptureOptions(
    echoCancellation: true,
    noiseSuppression: true,
    autoGainControl: true,
    voiceIsolation: true,
    typingNoiseDetection: true,
    stopAudioCaptureOnMute: false,
  );

  Future<void> connect(RoomConfig config) async {
    await disconnect();
    if (!config.usable) throw StateError('Channel config is incomplete');
    final room = Room(
      roomOptions: const RoomOptions(
        adaptiveStream: true,
        dynacast: true,
        defaultAudioCaptureOptions: _capture,
      ),
    );
    final listener = room.createListener();
    _wireRoom(listener);
    _room = room;
    _listener = listener;
    room.registerTextStreamHandler(transcriptionTopic,
        (reader, identity) async {
      final payload = await reader.readAll();
      _dataController.add(SessionData(transcriptionTopic, payload));
    });
    // LiveKit Agents may create this stream for session lifecycle data. ESP32
    // deliberately drains it; doing the same prevents backpressure here.
    room.registerTextStreamHandler(agentSessionTopic, (reader, identity) async {
      await reader.readAll();
    });
    _stateController.add(const SessionState('connecting'));
    await room.connect(config.serverUrl, config.token);
    // The microphone stays closed until there is a conversation to speak into.
    // Connecting is no longer a request to be listened to.
    await room.setSpeakerOn(true);
    _stateController.add(const SessionState('connected'));
  }

  /// Ask to be served. The agent, its models and its metered speech services
  /// are what this starts, so it is said explicitly rather than implied by
  /// being connected.
  Future<void> openSession() async {
    // One id per conversation, minted here and kept until it closes — the
    // firmware's shape (`current_conversation_id_`), because `session_open`
    // and `session_close` are statements about the same conversation and the
    // far end correlates them by this value.
    _conversationId ??= _newConversationId();
    await _publishSessionRequest(sessionOpenType);
    await _room?.localParticipant
        ?.setMicrophoneEnabled(true, audioCaptureOptions: _capture);
  }

  /// Say the conversation is over. The channel stays exactly as it is.
  Future<void> closeSession() async {
    try {
      await _room?.localParticipant?.setMicrophoneEnabled(false);
      _videoController.add(null);
      if (_conversationId != null) {
        await _publishSessionRequest(sessionCloseType);
      }
    } finally {
      _conversationId = null;
    }
  }

  /// A conversation id in the shape the contract accepts.
  ///
  /// Device-prefixed, random, and sequenced, the way the firmware builds its
  /// `esp32-…` ids: the prefix says which kind of Body asked, the randomness
  /// keeps two installs apart, and the counter keeps two conversations on one
  /// install apart even inside the same millisecond.
  String _newConversationId() {
    _conversationSequence += 1;
    String block() =>
        _random.nextInt(0x100000000).toRadixString(16).padLeft(8, '0');
    return 'mobile-${block()}-${block()}-'
        '${_conversationSequence.toRadixString(16).padLeft(8, '0')}';
  }

  Future<void> _publishSessionRequest(String type) async {
    final participant = _room?.localParticipant;
    if (participant == null) throw StateError('Channel is not connected');
    final conversationId = _conversationId;
    if (conversationId == null) {
      // Refused here rather than sent. The Provider drops a request it cannot
      // correlate and drops it without a log line, so the failure would arrive
      // as a conversation that never starts — indistinguishable from never
      // having asked for one.
      throw StateError('Session request has no conversation to name');
    }
    await participant.publishData(
      Uint8List.fromList(
        utf8.encode(
          jsonEncode(
            sessionRequestPayload(type: type, conversationId: conversationId),
          ),
        ),
      ),
      reliable: true,
      topic: sessionControlTopic,
    );
  }

  void _wireRoom(EventsListener<RoomEvent> listener) {
    listener
      ..on<DataReceivedEvent>((event) {
        final topic = event.topic ?? '';
        _dataController.add(
          SessionData(topic, utf8.decode(event.data, allowMalformed: true)),
        );
      })
      ..on<TrackSubscribedEvent>((event) {
        // Only the avatar worker's video track drives the stage — never a stray
        // video publisher on the channel.
        if (event.track is VideoTrack &&
            isAvatarIdentity(event.participant.identity)) {
          _videoController.add(event.track as VideoTrack);
        }
      })
      ..on<TrackUnsubscribedEvent>((event) {
        if (event.track is VideoTrack &&
            isAvatarIdentity(event.participant.identity)) {
          _videoController.add(null);
        }
      })
      // Who is in the room is not who is publishing a track. An agent that
      // died cannot publish `session_end` — the channel is already gone — so
      // its absence is the only evidence that arrives, and it arrives here.
      ..on<ParticipantConnectedEvent>((event) => _emitPresence())
      ..on<ParticipantDisconnectedEvent>((event) => _emitPresence())
      ..on<RoomDisconnectedEvent>((event) {
        _conversationId = null;
        _stateController.add(const SessionState('disconnected'));
        _videoController.add(null);
      })
      ..on<RoomReconnectingEvent>((event) {
        _stateController.add(const SessionState('reconnecting'));
      })
      ..on<RoomReconnectedEvent>((event) {
        _stateController.add(const SessionState('connected'));
      });
  }

  Future<void> publishControl(String payload) async {
    final participant = _room?.localParticipant;
    if (participant == null) throw StateError('Channel is not connected');
    await participant.publishData(
      Uint8List.fromList(utf8.encode(payload)),
      reliable: true,
      topic: controlTopic,
    );
  }

  Future<void> publishAudioState({
    required bool muted,
    required bool agentSpeaking,
    bool reliable = false,
  }) async {
    final participant = _room?.localParticipant;
    if (participant == null) return;
    final payload = jsonEncode({
      'schema_v': 1,
      'type': clientAudioStateType,
      'seq': ++_audioStateSequence,
      'input_mode': 'auto',
      'playback_state':
          agentSpeaking ? playbackStateAgentSpeaking : playbackStateIdle,
      'mic_muted': muted,
      'ptt': false,
      'rms': 0,
      'client_ts_ms': DateTime.now().millisecondsSinceEpoch,
    });
    await participant.publishData(
      Uint8List.fromList(utf8.encode(payload)),
      reliable: reliable,
      topic: clientAudioStateTopic,
    );
  }

  Future<void> setMicrophoneEnabled(bool enabled) async {
    await _room?.localParticipant?.setMicrophoneEnabled(enabled);
  }

  Future<void> disconnect() async {
    _conversationId = null;
    _videoController.add(null);
    _room?.unregisterTextStreamHandler(transcriptionTopic);
    _room?.unregisterTextStreamHandler(agentSessionTopic);
    await _room?.disconnect();
    await _room?.dispose();
    await _listener?.dispose();
    _room = null;
    _listener = null;
  }

  Future<void> dispose() async {
    await disconnect();
    await _dataController.close();
    await _stateController.close();
    await _videoController.close();
    await _presenceController.close();
  }
}

class SessionData {
  const SessionData(this.topic, this.payload);

  final String topic;
  final String payload;
}

class SessionState {
  const SessionState(this.state);

  final String state;
}
