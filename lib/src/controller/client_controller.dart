import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:livekit_client/livekit_client.dart';

import '../avatar/avatar_stage.dart';
import '../models/client_ui_state.dart';
import '../models/hub_models.dart';
import '../platform/platform_bridge.dart';
import '../protocol/eidolon_protocol.dart';
import '../services/eidolon_session.dart';
import '../services/hub_client.dart';
import '../services/vad_processor.dart';

export '../models/client_ui_state.dart';

class ClientController extends ChangeNotifier {
  ClientController({
    PlatformBridge? platform,
    HubClient? hubClient,
    EidolonSession? session,
    VadProcessor vad = const NoOpVadProcessor(),
    Duration controlReconnectGrace = const Duration(seconds: 2),
    Duration controlRecoveryRetry = const Duration(seconds: 2),
  })  : _platform = platform ?? const PlatformBridge(),
        _hubClient = hubClient ?? HubClient(platform: platform),
        _session = session ?? EidolonSession(),
        _vad = vad,
        _controlReconnectGrace = controlReconnectGrace,
        _controlRecoveryRetry = controlRecoveryRetry {
    _dataSubscription = _session.dataEvents.listen(_onSessionData);
    _stateSubscription = _session.stateEvents.listen(_onSessionState);
    _videoSubscription = _session.remoteVideo.listen((track) {
      remoteVideoTrack = track;
      videoState = track == null
          ? (videoState == VideoState.playing
              ? VideoState.interrupted
              : VideoState.audioOnly)
          : VideoState.playing;
      notifyListeners();
    });
  }

  final PlatformBridge _platform;
  final HubClient _hubClient;
  final EidolonSession _session;
  final VadProcessor _vad;
  final Duration _controlReconnectGrace;
  final Duration _controlRecoveryRetry;

  late final StreamSubscription<SessionData> _dataSubscription;
  late final StreamSubscription<SessionState> _stateSubscription;
  late final StreamSubscription<VideoTrack?> _videoSubscription;
  Timer? _activationTimer;
  Timer? _audioStateTimer;
  Timer? _noticeTimer;
  Timer? _attentionTimer;
  Timer? _controlRecoveryTimer;
  bool _busy = false;
  bool _controlRecoveryInFlight = false;
  int _controlRecoveryAttempt = 0;

  ClientPhase phase = ClientPhase.idle;
  ChannelConnectionState controlConnection =
      ChannelConnectionState.disconnected;
  ChannelConnectionState voiceConnection = ChannelConnectionState.disconnected;
  AgentTurnState agentTurn = AgentTurnState.idle;
  MicrophoneState microphoneState = MicrophoneState.inactive;
  VideoState videoState = VideoState.audioOnly;
  DeviceAttentionEffect attentionEffect = DeviceAttentionEffect.none;
  int attentionSequence = 0;
  HubService? hub;
  HubConfig? config;
  DeviceIdentity? identity;
  ClientFailure? failure;
  String? notice;
  VideoTrack? remoteVideoTrack;
  final List<TranscriptLine> transcript = [];

  ClientUiState get uiState => ClientUiState(
        phase: phase,
        controlConnection: controlConnection,
        voiceConnection: voiceConnection,
        agentTurn: agentTurn,
        microphone: microphoneState,
        video: videoState,
        busy: _busy,
        attention: attentionEffect,
        attentionSequence: attentionSequence,
        failure: failure,
        notice: notice,
      );

  String get statusText => uiState.headline;
  String? get error => failure?.technicalDetails;
  bool get microphoneEnabled => uiState.microphoneEnabled;
  bool get agentSpeaking => uiState.agentSpeaking;
  bool get isBusy => _busy;
  bool get canJoin => phase == ClientPhase.ready;
  bool get canLeave => phase == ClientPhase.conversation;

  /// The companion idle-loop clip URL — the resting face. Shown whenever the
  /// device is provisioned (standby included, where only the control room is
  /// connected), so the companion still has a face between calls instead of a
  /// blank placeholder. Null only when the hub / device isn't ready yet.
  String? get idleClipUrl {
    final currentHub = hub;
    if (currentHub == null) return null;
    const usable = {
      ClientPhase.ready,
      ClientPhase.conversation,
    };
    if (!usable.contains(phase)) return null;
    return companionIdleUrl(currentHub.registerUrl);
  }

  /// Signed headers to fetch the idle clip — same device auth as registration.
  Future<Map<String, String>> idleClipHeaders() async {
    final signed = await _platform.signRequest(
      method: 'GET',
      pathQuery: companionIdlePath,
      body: '',
    );
    return {
      'X-Device-ID': signed.deviceId,
      'X-Device-Nonce': signed.nonce,
      'X-Device-Timestamp': signed.timestamp,
      'X-Device-Public-Key': signed.publicKey,
      'X-Device-Signature': signed.signature,
    };
  }

  bool get isWaiting =>
      phase == ClientPhase.awaitingApproval ||
      phase == ClientPhase.awaitingBinding;

  Future<void> start({String? manualRegisterUrl}) async {
    if (_busy) return;
    _busy = true;
    _activationTimer?.cancel();
    failure = null;
    notifyListeners();
    try {
      identity = await _platform.getDeviceIdentity();
      if (manualRegisterUrl != null && manualRegisterUrl.trim().isNotEmpty) {
        hub = HubService(
          instanceName: 'Manual Hub',
          registerUrl: manualRegisterUrl.trim(),
        );
      } else {
        _setPhase(ClientPhase.discovering);
        hub = await _platform.discoverHub();
      }
      await _registerAndApply();
    } catch (exception) {
      _fail(exception);
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> _registerAndApply({
    String sessionIntent = '',
    bool showRegistering = true,
  }) async {
    final currentHub = hub;
    if (currentHub == null) throw StateError('Hub has not been discovered');
    if (showRegistering) {
      _setPhase(ClientPhase.registering);
    }
    final next = await _hubClient.register(
      currentHub.registerUrl,
      sessionIntent: sessionIntent,
    );
    config = next;
    failure = null;
    switch (next.status) {
      case HubConfigStatus.pendingApproval:
        _setPhase(ClientPhase.awaitingApproval);
        _scheduleActivationRefresh();
      case HubConfigStatus.waitingBinding:
        _setPhase(ClientPhase.awaitingBinding);
        _scheduleActivationRefresh();
      case HubConfigStatus.active:
        _activationTimer?.cancel();
        if (next.control?.usable == true && !_session.isControlConnected) {
          _setPhase(ClientPhase.activating);
          await _session.connectControl(next.control!);
        }
        if (_session.isVoiceConnected) {
          _setPhase(ClientPhase.conversation);
        } else {
          _setPhase(ClientPhase.ready);
        }
      case HubConfigStatus.revoked:
      case HubConfigStatus.unregistered:
        throw StateError('设备授权已撤销，请在管理端重新批准');
    }
  }

  void _scheduleActivationRefresh() {
    _activationTimer?.cancel();
    _activationTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (_busy || !isWaiting) return;
      _busy = true;
      notifyListeners();
      try {
        await _registerAndApply(showRegistering: false);
      } catch (exception) {
        failure = _classifyFailure(exception);
        notifyListeners();
      } finally {
        _busy = false;
        notifyListeners();
      }
    });
  }

  Future<void> join({String sessionIntent = 'user_initiated'}) async {
    if (_busy ||
        (phase != ClientPhase.ready && phase != ClientPhase.conversation)) {
      return;
    }
    _busy = true;
    failure = null;
    microphoneState = MicrophoneState.requestingPermission;
    _setPhase(ClientPhase.joining);
    try {
      final allowed = await _platform.requestMicrophonePermission();
      if (!allowed) throw StateError('需要麦克风权限才能开始对话');
      microphoneState = MicrophoneState.switching;
      notifyListeners();
      final currentHub = hub;
      if (currentHub == null) throw StateError('Hub is unavailable');
      final fresh = await _hubClient.register(
        currentHub.registerUrl,
        sessionIntent: sessionIntent,
      );
      config = fresh;
      if (fresh.status != HubConfigStatus.active) {
        throw StateError('设备当前不是 active 状态');
      }
      await _session.connectVoice(fresh.active);
      await _vad.start();
      microphoneState = MicrophoneState.enabled;
      agentTurn = AgentTurnState.idle;
      _setPhase(ClientPhase.conversation);
      await _session.publishAudioState(
        muted: false,
        agentSpeaking: agentSpeaking,
        reliable: true,
      );
      _audioStateTimer?.cancel();
      _audioStateTimer = Timer.periodic(const Duration(seconds: 2), (_) {
        unawaited(
          _session.publishAudioState(
            muted: !microphoneEnabled,
            agentSpeaking: agentSpeaking,
          ),
        );
      });
    } catch (exception) {
      await _session.disconnectVoice();
      voiceConnection = ChannelConnectionState.disconnected;
      microphoneState = MicrophoneState.inactive;
      failure = _classifyFailure(exception, liveKitContext: true);
      phase =
          _session.isControlConnected ? ClientPhase.ready : ClientPhase.error;
      notifyListeners();
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> leave() async {
    _activationTimer?.cancel();
    _audioStateTimer?.cancel();
    await _vad.stop();
    await _session.disconnectVoice();
    remoteVideoTrack = null;
    videoState = VideoState.audioOnly;
    agentTurn = AgentTurnState.idle;
    microphoneState = MicrophoneState.inactive;
    voiceConnection = ChannelConnectionState.disconnected;
    _setPhase(ClientPhase.ready);
  }

  Future<void> toggleMicrophone() async {
    if (phase != ClientPhase.conversation ||
        microphoneState == MicrophoneState.switching) {
      return;
    }
    final wasEnabled = microphoneState == MicrophoneState.enabled;
    microphoneState = MicrophoneState.switching;
    notifyListeners();
    try {
      await _session.setMicrophoneEnabled(!wasEnabled);
      microphoneState =
          wasEnabled ? MicrophoneState.muted : MicrophoneState.enabled;
      await _session.publishAudioState(
        muted: wasEnabled,
        agentSpeaking: agentSpeaking,
        reliable: true,
      );
    } catch (exception) {
      microphoneState =
          wasEnabled ? MicrophoneState.enabled : MicrophoneState.muted;
      failure = _classifyFailure(exception, liveKitContext: true);
    }
    notifyListeners();
  }

  void _onSessionState(SessionState event) {
    final connection = switch (event.state) {
      'connecting' => ChannelConnectionState.connecting,
      'connected' => ChannelConnectionState.connected,
      'reconnecting' => ChannelConnectionState.reconnecting,
      _ => ChannelConnectionState.disconnected,
    };
    if (event.plane == SessionPlane.control) {
      controlConnection = connection;
      if (event.state == 'connected') {
        _controlRecoveryTimer?.cancel();
        _controlRecoveryTimer = null;
        _controlRecoveryAttempt = 0;
      } else if (event.state == 'reconnecting' &&
          config?.status == HubConfigStatus.active) {
        _scheduleControlRecovery(_controlReconnectGrace);
      }
    } else {
      voiceConnection = connection;
    }

    if (event.plane == SessionPlane.voice &&
        event.state == 'disconnected' &&
        phase == ClientPhase.conversation) {
      _audioStateTimer?.cancel();
      unawaited(_vad.stop());
      agentTurn = AgentTurnState.idle;
      microphoneState = MicrophoneState.inactive;
      videoState = VideoState.audioOnly;
      _showNotice('语音会话已结束，控制连接仍保持在线');
      _setPhase(ClientPhase.ready);
    }
    if (event.plane == SessionPlane.control &&
        event.state == 'disconnected' &&
        config?.status == HubConfigStatus.active) {
      controlConnection = ChannelConnectionState.reconnecting;
      _scheduleControlRecovery(Duration.zero);
    }
    notifyListeners();
  }

  /// Re-check the control plane immediately when Android returns the app to
  /// the foreground. LiveKit's built-in retry policy can otherwise spend
  /// close to a minute exhausting its backoff sequence after a Wi-Fi pause.
  void onAppResumed() {
    if (config?.status != HubConfigStatus.active ||
        _session.isControlConnected) {
      return;
    }
    controlConnection = ChannelConnectionState.reconnecting;
    notifyListeners();
    _scheduleControlRecovery(Duration.zero);
  }

  void _scheduleControlRecovery(Duration delay) {
    if (config?.status != HubConfigStatus.active ||
        _session.isControlConnected ||
        _controlRecoveryInFlight) {
      return;
    }
    if (_controlRecoveryTimer?.isActive == true) {
      if (delay > Duration.zero) return;
      _controlRecoveryTimer?.cancel();
    }
    _controlRecoveryTimer = Timer(delay, () {
      _controlRecoveryTimer = null;
      unawaited(_recoverControl());
    });
  }

  Future<void> _recoverControl() async {
    if (_controlRecoveryInFlight ||
        config?.status != HubConfigStatus.active ||
        _session.isControlConnected) {
      return;
    }
    if (_busy) {
      _scheduleControlRecovery(const Duration(milliseconds: 250));
      return;
    }

    _controlRecoveryInFlight = true;
    _busy = true;
    _controlRecoveryAttempt += 1;
    final stopwatch = Stopwatch()..start();
    debugPrint(
      'Control recovery attempt=$_controlRecoveryAttempt started',
    );
    notifyListeners();
    var retry = false;
    try {
      await _registerAndApply(showRegistering: false);
      if (!_session.isControlConnected) {
        retry = true;
      } else {
        failure = null;
        debugPrint(
          'Control recovery succeeded in ${stopwatch.elapsedMilliseconds}ms',
        );
      }
    } catch (exception) {
      retry = true;
      failure = _classifyFailure(exception);
      debugPrint(
        'Control recovery failed in ${stopwatch.elapsedMilliseconds}ms: '
        '$exception',
      );
    } finally {
      stopwatch.stop();
      _controlRecoveryInFlight = false;
      _busy = false;
      notifyListeners();
    }
    if (retry && !_session.isControlConnected) {
      _scheduleControlRecovery(_controlRecoveryRetry);
    }
  }

  Future<void> _onSessionData(SessionData event) async {
    switch (event.topic) {
      case controlTopic:
        await _handleControlCommand(event.payload);
      case sessionControlTopic:
        await _handleSessionControl(event.payload);
      case uiStateTopic:
        _handleUiState(event.payload);
      case transcriptionTopic:
        _handleTranscription(event.payload);
    }
  }

  Future<void> _handleControlCommand(String payload) async {
    final command = ControlCommand.parse(payload);
    if (command == null) return;
    if (command.expired) {
      await _ack(command, 'error', 'EXPIRED',
          message: 'Command TTL has elapsed');
      return;
    }
    switch (command.op) {
      case 'room.join':
        await _ack(command, 'accepted', 'OK');
        await join(
          sessionIntent: command.payload['session_intent']?.toString() ??
              'proactive_initiated',
        );
        if (phase == ClientPhase.conversation) {
          await _ack(command, 'completed', 'OK', result: {'joined': true});
        }
      case 'config.refresh':
        try {
          await _registerAndApply(showRegistering: false);
          await _ack(command, 'completed', 'OK');
        } catch (exception) {
          await _ack(
            command,
            'error',
            'CONFIG_REFRESH_FAILED',
            message: exception.toString(),
          );
        }
      case 'device.identify':
        await _handleIdentify(command);
      case 'body.presence.set':
        await _handleBodyPresence(command);
      default:
        await _ack(command, 'error', 'UNSUPPORTED_OPERATION');
    }
  }

  Future<void> _handleIdentify(ControlCommand command) async {
    _triggerAttention(
      DeviceAttentionEffect.identify,
      '管理端正在点名这台设备',
    );
    try {
      final played = await _platform.playIdentifyFeedback();
      await _ack(
        command,
        'completed',
        'OK',
        result: {'played': played},
      );
    } catch (exception) {
      await _ack(
        command,
        'error',
        'FEEDBACK_FAILED',
        message: exception.toString(),
      );
    }
  }

  Future<void> _handleBodyPresence(ControlCommand command) async {
    final state = command.payload['state']?.toString() ?? '';
    final actionId = command.payload['action_id']?.toString() ?? '';
    if (state != 'awake' || actionId.isEmpty) {
      await _ack(
        command,
        'error',
        'INVALID_ARGUMENT',
        message: 'body.presence.set requires state=awake and action_id',
      );
      return;
    }

    await _ack(command, 'accepted', 'OK');
    _triggerAttention(
      DeviceAttentionEffect.wiggle,
      '管理端让这台设备动一动',
    );
    try {
      final applied = await _platform.playWiggleFeedback();
      await _ack(
        command,
        'completed',
        'OK',
        result: {
          'action_id': actionId,
          'state': state,
          'applied': applied,
        },
      );
    } catch (exception) {
      await _ack(
        command,
        'error',
        'FEEDBACK_FAILED',
        message: exception.toString(),
      );
    }
  }

  Future<void> _ack(
    ControlCommand command,
    String status,
    String code, {
    String message = '',
    Map<String, dynamic>? result,
  }) async {
    await _session.publishControl(
      buildControlAck(
        command: command,
        deviceId: identity?.deviceId ?? '',
        status: status,
        code: code,
        message: message,
        result: result,
      ),
    );
  }

  Future<void> _handleSessionControl(String payload) async {
    try {
      final root = jsonDecode(payload) as Map<String, dynamic>;
      if (root['type'] == 'session_end') await leave();
    } catch (_) {
      // Ignore malformed packets from unknown participants.
    }
  }

  void _handleUiState(String payload) {
    try {
      final root = jsonDecode(payload) as Map<String, dynamic>;
      final state = (root['state'] ?? root['phase'])?.toString() ?? '';
      agentTurn = switch (state) {
        'listening' => AgentTurnState.listening,
        'thinking' => AgentTurnState.thinking,
        'speaking' || 'agent_speaking' => AgentTurnState.speaking,
        _ => AgentTurnState.idle,
      };
      if (phase == ClientPhase.conversation) {
        unawaited(
          _session.publishAudioState(
            muted: !microphoneEnabled,
            agentSpeaking: agentSpeaking,
            reliable: true,
          ),
        );
      }
      notifyListeners();
    } catch (_) {
      // UI state is advisory.
    }
  }

  void _handleTranscription(String payload) {
    try {
      final root = jsonDecode(payload) as Map<String, dynamic>;
      final text = (root['text'] ??
                  root['transcript'] ??
                  root['transcription'] ??
                  root['content'])
              ?.toString() ??
          '';
      if (text.isEmpty) return;
      final identityValue =
          (root['participant_identity'] ?? root['identity'])?.toString() ?? '';
      final source = (root['source'] ?? root['role'])?.toString() ?? '';
      final speaker = source == 'user' || identityValue == identity?.deviceId
          ? '你'
          : 'Eidolon';
      final isFinal = root['final'] == true || root['is_final'] == true;
      final segmentId = (root['segment_id'] ??
              root['stream_id'] ??
              root['id'] ??
              '$speaker-current')
          .toString();
      final line = TranscriptLine(
        id: segmentId,
        speaker: speaker,
        text: text,
        isFinal: isFinal,
      );
      final pendingIndex = transcript.lastIndexWhere(
        (existing) =>
            !existing.isFinal &&
            (existing.id == segmentId || existing.speaker == speaker),
      );
      if (pendingIndex >= 0) {
        transcript[pendingIndex] = line;
      } else {
        transcript.add(line);
      }
      if (transcript.length > 40) {
        transcript.removeRange(0, transcript.length - 40);
      }
      notifyListeners();
    } catch (_) {
      // Ignore unrelated/malformed data packets on this topic.
    }
  }

  Future<void> checkActivation() async {
    if (_busy || hub == null || !isWaiting) return;
    _busy = true;
    failure = null;
    notifyListeners();
    try {
      await _registerAndApply(showRegistering: false);
    } catch (exception) {
      failure = _classifyFailure(exception);
      notifyListeners();
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> retry() async {
    if (_busy) return;
    if (hub == null) {
      await start();
      return;
    }
    _busy = true;
    failure = null;
    notifyListeners();
    try {
      await _registerAndApply();
    } catch (exception) {
      _fail(exception);
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  void dismissFailure() {
    failure = null;
    notifyListeners();
  }

  void _showNotice(String message) {
    notice = message;
    _noticeTimer?.cancel();
    _noticeTimer = Timer(const Duration(seconds: 3), () {
      notice = null;
      notifyListeners();
    });
    notifyListeners();
  }

  void _triggerAttention(DeviceAttentionEffect effect, String message) {
    attentionEffect = effect;
    attentionSequence += 1;
    _attentionTimer?.cancel();
    _attentionTimer = Timer(const Duration(milliseconds: 1600), () {
      attentionEffect = DeviceAttentionEffect.none;
      notifyListeners();
    });
    _showNotice(message);
  }

  void _setPhase(ClientPhase value) {
    phase = value;
    notifyListeners();
  }

  void _fail(Object exception) {
    failure = _classifyFailure(exception);
    _setPhase(ClientPhase.error);
  }

  ClientFailure _classifyFailure(
    Object exception, {
    bool liveKitContext = false,
  }) {
    final details = exception.toString();
    final lower = details.toLowerCase();
    if (lower.contains('microphone') ||
        lower.contains('麦克风') ||
        lower.contains('permission')) {
      return ClientFailure(
        kind: ClientErrorKind.permission,
        title: '需要麦克风权限',
        message: '请允许使用麦克风后再次开始对话',
        technicalDetails: details,
      );
    }
    if (lower.contains('mdns') || lower.contains('no compatible eidolon hub')) {
      return ClientFailure(
        kind: ClientErrorKind.discovery,
        title: '没有发现 Eidolon Hub',
        message: '确认平板与 Hub 在同一局域网，或手动输入 Hub 地址',
        technicalDetails: details,
      );
    }
    if (exception is HubRequestException) {
      final authorization =
          exception.statusCode == 401 || exception.statusCode == 403;
      return ClientFailure(
        kind: authorization
            ? ClientErrorKind.authorization
            : ClientErrorKind.protocol,
        title: authorization ? '设备身份未被接受' : 'Hub 返回了错误',
        message: authorization ? '请在管理端重新批准这台移动设备' : 'Hub 拒绝了本次请求，请查看详情或稍后重试',
        technicalDetails: details,
        retryable: !authorization,
      );
    }
    if (exception is http.ClientException ||
        exception is TimeoutException ||
        lower.contains('socket') ||
        lower.contains('network') ||
        lower.contains('connection')) {
      return ClientFailure(
        kind: ClientErrorKind.network,
        title: liveKitContext ? '语音连接中断' : '无法连接到 Hub',
        message: '请检查局域网连接，应用会在可恢复状态下继续尝试',
        technicalDetails: details,
      );
    }
    if (liveKitContext || lower.contains('livekit')) {
      return ClientFailure(
        kind: ClientErrorKind.liveKit,
        title: '无法建立语音会话',
        message: '控制连接仍会保持，可以再次尝试开始对话',
        technicalDetails: details,
      );
    }
    return ClientFailure(
      kind: ClientErrorKind.unknown,
      title: '操作未完成',
      message: '可以重试；若问题持续，请展开技术详情进行排查',
      technicalDetails: details,
    );
  }

  @override
  void dispose() {
    _activationTimer?.cancel();
    _audioStateTimer?.cancel();
    _noticeTimer?.cancel();
    _attentionTimer?.cancel();
    _controlRecoveryTimer?.cancel();
    unawaited(_dataSubscription.cancel());
    unawaited(_stateSubscription.cancel());
    unawaited(_videoSubscription.cancel());
    unawaited(_session.dispose());
    _hubClient.dispose();
    super.dispose();
  }
}

class TranscriptLine {
  const TranscriptLine({
    required this.id,
    required this.speaker,
    required this.text,
    required this.isFinal,
  });

  final String id;
  final String speaker;
  final String text;
  final bool isFinal;
}
