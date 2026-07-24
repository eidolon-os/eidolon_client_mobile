import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:livekit_client/livekit_client.dart';

import '../avatar/avatar_stage.dart';
import '../models/hub_models.dart';
import '../protocol/eidolon_protocol.dart';

class EidolonSession {
  Room? _controlRoom;
  Room? _voiceRoom;
  EventsListener<RoomEvent>? _controlListener;
  EventsListener<RoomEvent>? _voiceListener;

  final _dataController = StreamController<SessionData>.broadcast();
  final _stateController = StreamController<SessionState>.broadcast();
  final _videoController = StreamController<VideoTrack?>.broadcast();
  int _audioStateSequence = 0;

  Stream<SessionData> get dataEvents => _dataController.stream;
  Stream<SessionState> get stateEvents => _stateController.stream;
  Stream<VideoTrack?> get remoteVideo => _videoController.stream;

  bool get isControlConnected =>
      _controlRoom?.connectionState == ConnectionState.connected;
  bool get isVoiceConnected =>
      _voiceRoom?.connectionState == ConnectionState.connected;

  Future<void> connectControl(RoomConfig config) async {
    await disconnectControl();
    if (!config.usable) throw StateError('Control room config is incomplete');
    final room = Room();
    final listener = room.createListener();
    _wireRoom(listener, SessionPlane.control);
    _controlRoom = room;
    _controlListener = listener;
    _stateController.add(SessionState(SessionPlane.control, 'connecting'));
    await room.connect(config.serverUrl, config.token);
    _stateController.add(SessionState(SessionPlane.control, 'connected'));
  }

  Future<void> connectVoice(RoomConfig config) async {
    await disconnectVoice();
    if (!config.usable) throw StateError('Voice room config is incomplete');
    const capture = AudioCaptureOptions(
      echoCancellation: true,
      noiseSuppression: true,
      autoGainControl: true,
      voiceIsolation: true,
      typingNoiseDetection: true,
      stopAudioCaptureOnMute: false,
    );
    final room = Room(
      roomOptions: const RoomOptions(
        adaptiveStream: true,
        dynacast: true,
        defaultAudioCaptureOptions: capture,
      ),
    );
    final listener = room.createListener();
    _wireRoom(listener, SessionPlane.voice);
    _voiceRoom = room;
    _voiceListener = listener;
    room.registerTextStreamHandler(transcriptionTopic,
        (reader, identity) async {
      final payload = await reader.readAll();
      _dataController
          .add(SessionData(SessionPlane.voice, transcriptionTopic, payload));
    });
    // LiveKit Agents may create this stream for session lifecycle data. ESP32
    // deliberately drains it; doing the same prevents backpressure here.
    room.registerTextStreamHandler(agentSessionTopic, (reader, identity) async {
      await reader.readAll();
    });
    _stateController.add(SessionState(SessionPlane.voice, 'connecting'));
    await room.connect(config.serverUrl, config.token);
    await room.localParticipant?.setMicrophoneEnabled(
      true,
      audioCaptureOptions: capture,
    );
    await room.setSpeakerOn(true);
    _stateController.add(SessionState(SessionPlane.voice, 'connected'));
  }

  void _wireRoom(
    EventsListener<RoomEvent> listener,
    SessionPlane plane,
  ) {
    listener
      ..on<DataReceivedEvent>((event) {
        final topic = event.topic ?? '';
        _dataController.add(
          SessionData(
              plane, topic, utf8.decode(event.data, allowMalformed: true)),
        );
      })
      ..on<TrackSubscribedEvent>((event) {
        // Only the avatar worker's video track drives the stage — never a stray
        // video publisher on the voice room.
        if (plane == SessionPlane.voice &&
            event.track is VideoTrack &&
            isAvatarIdentity(event.participant.identity)) {
          _videoController.add(event.track as VideoTrack);
        }
      })
      ..on<TrackUnsubscribedEvent>((event) {
        if (plane == SessionPlane.voice &&
            event.track is VideoTrack &&
            isAvatarIdentity(event.participant.identity)) {
          _videoController.add(null);
        }
      })
      ..on<RoomDisconnectedEvent>((event) {
        _stateController.add(SessionState(plane, 'disconnected'));
        if (plane == SessionPlane.voice) _videoController.add(null);
      })
      ..on<RoomReconnectingEvent>((event) {
        _stateController.add(SessionState(plane, 'reconnecting'));
      })
      ..on<RoomReconnectedEvent>((event) {
        _stateController.add(SessionState(plane, 'connected'));
      });
  }

  Future<void> publishControl(String payload) async {
    final participant = _controlRoom?.localParticipant;
    if (participant == null) throw StateError('Control room is not connected');
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
    final participant = _voiceRoom?.localParticipant;
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
    await _voiceRoom?.localParticipant?.setMicrophoneEnabled(enabled);
  }

  Future<void> disconnectVoice() async {
    _videoController.add(null);
    _voiceRoom?.unregisterTextStreamHandler(transcriptionTopic);
    _voiceRoom?.unregisterTextStreamHandler(agentSessionTopic);
    await _voiceRoom?.disconnect();
    await _voiceRoom?.dispose();
    await _voiceListener?.dispose();
    _voiceRoom = null;
    _voiceListener = null;
  }

  Future<void> disconnectControl() async {
    await _controlRoom?.disconnect();
    await _controlRoom?.dispose();
    await _controlListener?.dispose();
    _controlRoom = null;
    _controlListener = null;
  }

  Future<void> dispose() async {
    await disconnectVoice();
    await disconnectControl();
    await _dataController.close();
    await _stateController.close();
    await _videoController.close();
  }
}

enum SessionPlane { control, voice }

class SessionData {
  const SessionData(this.plane, this.topic, this.payload);

  final SessionPlane plane;
  final String topic;
  final String payload;
}

class SessionState {
  const SessionState(this.plane, this.state);

  final SessionPlane plane;
  final String state;
}
