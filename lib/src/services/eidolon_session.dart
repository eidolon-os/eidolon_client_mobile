import 'dart:async';
import 'dart:convert';
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

  final _dataController = StreamController<SessionData>.broadcast();
  final _stateController = StreamController<SessionState>.broadcast();
  final _videoController = StreamController<VideoTrack?>.broadcast();
  int _audioStateSequence = 0;

  Stream<SessionData> get dataEvents => _dataController.stream;
  Stream<SessionState> get stateEvents => _stateController.stream;
  Stream<VideoTrack?> get remoteVideo => _videoController.stream;

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
    await _publishSessionRequest(sessionOpenType);
    await _room?.localParticipant
        ?.setMicrophoneEnabled(true, audioCaptureOptions: _capture);
  }

  /// Say the conversation is over. The channel stays exactly as it is.
  Future<void> closeSession() async {
    await _room?.localParticipant?.setMicrophoneEnabled(false);
    _videoController.add(null);
    await _publishSessionRequest(sessionCloseType);
  }

  Future<void> _publishSessionRequest(String type) async {
    final participant = _room?.localParticipant;
    if (participant == null) throw StateError('Channel is not connected');
    await participant.publishData(
      Uint8List.fromList(utf8.encode(jsonEncode({
        'schema_v': 1,
        'type': type,
      }))),
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
      ..on<RoomDisconnectedEvent>((event) {
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
      'type': 'client.audio_state',
      'seq': ++_audioStateSequence,
      'input_mode': 'auto',
      'playback_state': agentSpeaking ? 'agent_speaking' : 'idle',
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
