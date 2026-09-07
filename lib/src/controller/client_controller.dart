import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:livekit_client/livekit_client.dart';

import '../avatar/avatar_stage.dart';
import '../features/conversation/conversation_provisioner.dart';
import '../features/conversation/mobile_body_standing.dart';
import '../features/device_setup/mobile_body_enrollment_session.dart';
import '../features/device_setup/mobile_body_manifest.dart';
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
    ConversationProvisioner? conversationProvisioner,
    MobileBodyEnrollmentSession? enrollment,
  })  : _platform = platform ?? const PlatformBridge(),
        _hubClient = hubClient ?? HubClient(platform: platform),
        _session = session ?? EidolonSession(),
        _vad = vad,
        _conversationProvisioner = conversationProvisioner,
        _enrollment = enrollment,
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
  final ConversationProvisioner? _conversationProvisioner;

  /// The Enrollment this phone has in flight, if this build wired one.
  ///
  /// Null means no control is drawn for any of it. A screen that offered acts
  /// nothing could perform would be worse than the silence it replaced.
  final MobileBodyEnrollmentSession? _enrollment;
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
  // Whether a conversation is under way. The channel is up either way, so this
  // is no longer something that can be read off a connection.
  bool _inConversation = false;
  bool _controlRecoveryInFlight = false;

  /// Guards the one step this controller takes without being asked.
  ///
  /// `complete()` is followed by a re-read, and the re-read runs the same
  /// decision again; without this the second pass would try to collect a Grant
  /// that has already been collected.
  bool _collecting = false;
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
        bodyStanding: config?.bodyStanding,
        enrollmentAct: enrollmentAct,
        enrollmentExpiresAt: config?.bodyEnrollment?.expiresAt,
        deviceFingerprint: config?.deviceFingerprint ?? '',
      );

  String get statusText => uiState.headline;
  String? get error => failure?.technicalDetails;
  bool get microphoneEnabled => uiState.microphoneEnabled;
  bool get agentSpeaking => uiState.agentSpeaking;
  bool get isBusy => _busy;
  bool get canJoin => phase == ClientPhase.ready;
  bool get canLeave => phase == ClientPhase.conversation;
  bool get usesProductProvisioning => _conversationProvisioner != null;

  /// The companion idle-loop clip URL — the resting face. Shown whenever the
  /// device is provisioned (standby included, where only the control room is
  /// connected), so the companion still has a face between calls instead of a
  /// blank placeholder. Null only when the hub / device isn't ready yet.
  String? get idleClipUrl {
    if (usesProductProvisioning) return null;
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

  /// Whether something this screen is waiting on can still arrive.
  ///
  /// The polling predicate, and the one thing the old screen had wrong: it
  /// polled every five seconds for an Enrollment that only this phone may
  /// create and that no version had ever created, so 「待批准」 was permanent by
  /// construction. A standing that cannot advance is not waiting — and that is
  /// still the rule now that the proposal exists, because a proposal nobody has
  /// made is not in flight.
  bool get isWaiting =>
      (phase == ClientPhase.awaitingApproval ||
          phase == ClientPhase.awaitingBinding) &&
      (config?.bodyStanding?.advances ?? true);

  /// The Owner holding this phone can approve it from here.
  bool get awaitsThisControllersApproval =>
      config?.bodyStanding?.awaitsThisControllersApproval ?? false;

  /// What this phone can do about its Enrollment, as of the last projection.
  ///
  /// Recomputed after every provision rather than derived in the widget: the
  /// answer depends on whether the platform still holds a handoff key, which is
  /// a question with an await in it and no place in a build method.
  MobileBodyEnrollmentAct enrollmentAct = MobileBodyEnrollmentAct.none;

  /// The Enrollment the act refers to, when the Authority named one.
  MobileBodyEnrollmentRef? get enrollmentRef => config?.bodyEnrollment;

  /// This phone can propose itself as a Body from here, now.
  ///
  /// Read straight off the standing rather than off the phase: `bodyBlocked`
  /// covers both the stages where a person can act and the one where the gap is
  /// the Host's to close, and drawing the same control for both would put a
  /// button in front of something it cannot change.
  ///
  /// Null standing is false. A screen with no Admission answer has not been
  /// told there is nothing, it has not been told anything.
  bool get canProposeItself =>
      config?.bodyStanding?.canProposeItself ?? false;

  Future<void> start() async {
    if (_busy) return;
    _busy = true;
    _activationTimer?.cancel();
    failure = null;
    notifyListeners();
    try {
      identity = await _platform.getDeviceIdentity();
      if (_conversationProvisioner != null) {
        _setPhase(ClientPhase.discovering);
      } else {
        throw StateError(
          'Owner Domain provisioning target is required; Host mDNS is not a trust source',
        );
      }
      await _registerAndApply();
      hub = HubService(
        instanceName: _conversationProvisioner.serviceName,
        registerUrl: _conversationProvisioner.serviceUri.toString(),
        api: 'device-onboarding-v1',
      );
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
    if (showRegistering) {
      _setPhase(ClientPhase.registering);
    }
    var next = await _provisionConfig(sessionIntent: sessionIntent);
    failure = null;
    // A standing is Admission's own answer about this one device, and it says
    // more than the five status values can carry. When there is one it decides
    // the phase, so that a stage which cannot advance is drawn as stopped
    // rather than as 「待批准」 with a retry button in front of it.
    var standing = next.bodyStanding;
    enrollmentAct = standing == null || _enrollment == null
        ? MobileBodyEnrollmentAct.none
        : await _enrollment.actFor(standing);
    // Redeeming an approved Grant is the device's own step, with no decision
    // left for anybody: the Authority has already said yes, and this process is
    // holding the one-shot key and challenge it takes. A standard device does
    // it without being asked, and the card above says exactly that —
    // 「这一步在这台手机上跑…不需要你做什么」.
    //
    // It used to wait for a tap that no screen drew. `collect` was rendered
    // only from `ClientPhase.bodyBlocked`, and this stage is not blocked — it
    // advances, and this phone can advance it — so the phase fell through to
    // 「立即检查状态」 and the collection never happened. On real hardware that
    // stopped the chain one step short of a Claim, under a true sentence and a
    // control that was not there.
    if (enrollmentAct == MobileBodyEnrollmentAct.collect && !_collecting) {
      _collecting = true;
      try {
        await _enrollment!.complete();
        next = await _provisionConfig(sessionIntent: sessionIntent);
        standing = next.bodyStanding;
        enrollmentAct = standing == null
            ? MobileBodyEnrollmentAct.none
            : await _enrollment.actFor(standing);
      } catch (exception) {
        // Reported rather than swallowed, and the act stays `collect` — so the
        // control is drawn and a person can take the step the phone could not.
        failure = _classifyFailure(exception);
      } finally {
        _collecting = false;
      }
    }
    // Two different facts, and the screen needs both. `advances` is the
    // Authority's: this stage moves on its own. Whether *this phone* can still
    // move it is local, and the Authority cannot know it — the collection
    // challenge and the handoff key live only in the process that proposed.
    //
    // Folding them is not tidiness. `approvedAwaitingHandoff` advances, so on
    // its own it draws 「正在领取归属凭证」 with a 「立即检查状态」 beside it —
    // in front of a collection nobody is performing and nobody can. That is the
    // exact shape this screen was rewritten to delete, arriving from the other
    // side.
    config = next;
    final stalled = enrollmentAct == MobileBodyEnrollmentAct.abandon ||
        enrollmentAct == MobileBodyEnrollmentAct.waitForExpiry;
    if (standing != null && (!standing.advances || stalled)) {
      _activationTimer?.cancel();
      _setPhase(ClientPhase.bodyBlocked);
      return;
    }
    switch (next.status) {
      case HubConfigStatus.pendingApproval:
        _setPhase(ClientPhase.awaitingApproval);
        _scheduleActivationRefresh();
      case HubConfigStatus.waitingBinding:
        _setPhase(ClientPhase.awaitingBinding);
        _scheduleActivationRefresh();
      case HubConfigStatus.active:
        _activationTimer?.cancel();
        if (next.session.usable && !_session.isConnected) {
          _setPhase(ClientPhase.activating);
          await _session.connect(next.session);
        }
        if (_inConversation) {
          _setPhase(ClientPhase.conversation);
        } else {
          _setPhase(ClientPhase.ready);
        }
      case HubConfigStatus.revoked:
      case HubConfigStatus.unregistered:
        throw StateError('设备授权已撤销，请在管理端重新批准');
    }
  }

  Future<HubConfig> _provisionConfig({String sessionIntent = ''}) {
    final provisioner = _conversationProvisioner;
    if (provisioner != null) {
      return provisioner.provision(sessionIntent: sessionIntent);
    }
    final currentHub = hub;
    if (currentHub == null) {
      throw StateError('Hub has not been discovered');
    }
    return _hubClient.register(
      currentHub.registerUrl,
      sessionIntent: sessionIntent,
    );
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

  Future<void> join({
    String sessionIntent = sessionIntentUserInitiated,
  }) async {
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
      final fresh = await _provisionConfig(sessionIntent: sessionIntent);
      config = fresh;
      if (fresh.status != HubConfigStatus.active) {
        throw StateError('设备当前不是 active 状态');
      }
      if (!_session.isConnected) {
        await _session.connect(fresh.session);
      }
      // Asking is what starts a conversation now; the channel was already up.
      await _session.openSession();
      _inConversation = true;
      await _vad.start();
      microphoneState = MicrophoneState.enabled;
      // Full-duplex mobile starts listening as soon as the voice room is ready.
      // Do not overwrite an early `listening` packet from channel with `idle`.
      agentTurn = AgentTurnState.listening;
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
      _inConversation = false;
      voiceConnection = ChannelConnectionState.disconnected;
      microphoneState = MicrophoneState.inactive;
      failure = _classifyFailure(exception, liveKitContext: true);
      phase = _session.isConnected ? ClientPhase.ready : ClientPhase.error;
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
    // Leaving a conversation is something this client says, not somewhere it
    // goes: the channel stays up so the next one can start by asking.
    if (_inConversation) {
      await _session.closeSession();
      _inConversation = false;
    }
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
    controlConnection = connection;
    if (event.state == 'connected') {
      _controlRecoveryTimer?.cancel();
      _controlRecoveryTimer = null;
      _controlRecoveryAttempt = 0;
    } else if (event.state == 'reconnecting' &&
        config?.status == HubConfigStatus.active) {
      _scheduleControlRecovery(_controlReconnectGrace);
    }

    // Losing the channel is the one thing that still ends a conversation
    // without anyone saying so — there is nothing left to carry it. A
    // conversation that ends normally does so via session_end or leave(),
    // both of which leave the channel untouched.
    if (event.state == 'disconnected') {
      if (_inConversation) {
        _inConversation = false;
        voiceConnection = ChannelConnectionState.disconnected;
        _audioStateTimer?.cancel();
        unawaited(_vad.stop());
        agentTurn = AgentTurnState.idle;
        microphoneState = MicrophoneState.inactive;
        videoState = VideoState.audioOnly;
        _showNotice('连接已断开，正在重新连接');
        _setPhase(ClientPhase.ready);
      }
      if (config?.status == HubConfigStatus.active) {
        controlConnection = ChannelConnectionState.reconnecting;
        _scheduleControlRecovery(Duration.zero);
      }
    } else {
      voiceConnection = _inConversation ? connection : voiceConnection;
    }
    notifyListeners();
  }

  /// Re-check the control plane immediately when Android returns the app to
  /// the foreground. LiveKit's built-in retry policy can otherwise spend
  /// close to a minute exhausting its backoff sequence after a Wi-Fi pause.
  void onAppResumed() {
    if (config?.status != HubConfigStatus.active || _session.isConnected) {
      return;
    }
    controlConnection = ChannelConnectionState.reconnecting;
    notifyListeners();
    _scheduleControlRecovery(Duration.zero);
  }

  void _scheduleControlRecovery(Duration delay) {
    if (config?.status != HubConfigStatus.active ||
        _session.isConnected ||
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
        _session.isConnected) {
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
      if (!_session.isConnected) {
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
    if (retry && !_session.isConnected) {
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
      case controlOpRoomJoin:
        await _ack(command, 'accepted', 'OK');
        await join(
          sessionIntent: roomJoinSessionIntent(command.payload),
        );
        if (phase == ClientPhase.conversation) {
          await _ack(command, 'completed', 'OK', result: {'joined': true});
        }
      case controlOpConfigRefresh:
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
      case controlOpDeviceIdentify:
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
        // What Hub knows this device by, which is what a control ack has to
        // name. It used to name the ANDROID_ID-derived install id, a string no
        // party on the other end has a record of.
        deviceId: identity?.deviceInstanceId ?? '',
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
      if (root['type'] == sessionEndType) await leave();
    } catch (_) {
      // Ignore malformed packets from unknown participants.
    }
  }

  void _handleUiState(String payload) {
    try {
      final root = jsonDecode(payload) as Map<String, dynamic>;
      final state = (root['state'] ?? root['phase'])?.toString() ?? '';
      final nextTurn = switch (state) {
        'listening' => AgentTurnState.listening,
        'thinking' => AgentTurnState.thinking,
        'speaking' || 'agent_speaking' => AgentTurnState.speaking,
        _ => null,
      };
      // Unknown packets must not reset a healthy full-duplex session to idle.
      if (nextTurn == null) return;
      agentTurn = nextTurn;
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
      // A participant identity is the Channel's, from the session binding —
      // not a device id, and certainly not the ANDROID_ID-derived install id
      // this used to compare against, which LiveKit never sees.
      final sessionIdentity = config?.session.identity ?? '';
      final speaker = source == 'user' ||
              (sessionIdentity.isNotEmpty && identityValue == sessionIdentity)
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

  /// Propose this phone as a Body.
  ///
  /// The first of two acts by the same person. It stops at a pending proposal
  /// on purpose — the approval that follows is the second, and one call that
  /// did both would be the compensation `纯软件Body准入身份裁决` W1 refused.
  Future<void> proposeSelf({String title = defaultMobileBodyTitle}) =>
      _enrollmentAction(
        MobileBodyEnrollmentAct.propose,
        (session) => session.propose(title: title),
      );

  /// Collect and acknowledge the Grant for an approved proposal.
  Future<void> finishEnrollment() => _enrollmentAction(
        MobileBodyEnrollmentAct.collect,
        (session) => session.complete(),
      );

  /// Withdraw a proposal this phone can no longer finish.
  ///
  /// Only offered where the Authority allows the transition, which is
  /// `pending_review` alone — see [MobileBodyEnrollmentAct.waitForExpiry] for
  /// the state where it does not.
  Future<void> abandonEnrollment() {
    final enrollmentId = enrollmentRef?.enrollmentId;
    if (enrollmentId == null) {
      // Nothing to address the withdrawal to. Refused here rather than sent,
      // because the Authority would answer about an id this screen invented.
      return Future<void>.value();
    }
    return _enrollmentAction(
      MobileBodyEnrollmentAct.abandon,
      (session) => session.abandon(
        enrollmentId: enrollmentId,
        reason: 'device_replaced',
      ),
    );
  }

  /// Run one Enrollment act, then re-read where this phone stands.
  ///
  /// Re-reading is not a refresh for its own sake: every one of these changes
  /// what the Authority will say next, and a screen still showing the previous
  /// answer would be offering the act that was just taken.
  Future<void> _enrollmentAction(
    MobileBodyEnrollmentAct expected,
    Future<void> Function(MobileBodyEnrollmentSession session) act,
  ) async {
    final session = _enrollment;
    if (_busy || session == null || enrollmentAct != expected) return;
    _busy = true;
    failure = null;
    notifyListeners();
    try {
      await act(session);
      await _registerAndApply(showRegistering: false);
    } catch (exception) {
      failure = _classifyFailure(exception);
      notifyListeners();
    } finally {
      _busy = false;
      notifyListeners();
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

  /// The host name a failure says could not be turned into an address.
  ///
  /// Read off the exception's own URI rather than its text, so it says nothing
  /// when the host was already an address: 「到不了 192.168.3.206」 is a network
  /// fact and belongs in the branch below, while 「解析不了 eidolon-pi5.local」 is
  /// a statement about this phone's resolver.
  static String? _unresolvableHost(Object exception) {
    if (exception is! http.ClientException) return null;
    final host = exception.uri?.host;
    if (host == null || host.isEmpty) return null;
    if (InternetAddress.tryParse(host) != null) return null;
    final text = exception.toString().toLowerCase();
    return text.contains('unable to resolve host') ||
            text.contains('no address associated with hostname') ||
            text.contains('unknownhost') ||
            text.contains('failed host lookup')
        ? host
        : null;
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
        message: usesProductProvisioning
            ? '确认平板与主机在同一局域网，并检查主机的 Hub 服务状态'
            : '确认平板与 Hub 在同一局域网，或手动输入 Hub 地址',
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
    // A name this phone cannot resolve is not a network the person should go
    // check. Android resolves with getaddrinfo, which does not resolve `.local`
    // at all, so this failure happens with the Host up, on the same Wi-Fi, and
    // answering a ping — and 「请检查局域网连接」 sent people to look at a network
    // that was working, with a retry that could not succeed.
    final unresolvableHost = _unresolvableHost(exception);
    if (unresolvableHost != null) {
      return ClientFailure(
        kind: ClientErrorKind.discovery,
        title: '这台手机解析不了主机的名字',
        message: '局域网可能是通的 —— 是这台手机没法把 $unresolvableHost 变成一个地址。'
            'Android 的系统解析器不解析 .local 名字。'
            '重试不会改变这一点，请改用主机的 IP 地址接入。',
        technicalDetails: details,
        retryable: false,
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
        title: '无法开始这次对话',
        message: '通道仍然在线，可以再次尝试开始对话',
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
