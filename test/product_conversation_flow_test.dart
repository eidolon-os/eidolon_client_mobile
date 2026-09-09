import 'package:eidolon_client_mobile/src/models/conversation_mode.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:eidolon_client_mobile/src/controller/client_controller.dart';
import 'package:eidolon_client_mobile/src/features/conversation/mobile_body_standing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eidolon_client_mobile/src/features/conversation/conversation_flow.dart';
import 'package:eidolon_client_mobile/src/features/conversation/conversation_provisioner.dart';
import 'package:eidolon_client_mobile/src/features/conversation/channel_refusal.dart';
import 'package:eidolon_client_mobile/src/features/conversation/product_conversation_page.dart';
import 'package:eidolon_client_mobile/src/features/device_management/mounted_device_models.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_ports.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/mobile_body_enrollment_session.dart';
import 'package:eidolon_client_mobile/src/generated/management_v1.dart';
import 'package:eidolon_client_mobile/src/models/hub_models.dart';
import 'package:eidolon_client_mobile/src/services/eidolon_session.dart';
import 'support/owner_domain_fixtures.dart';
import 'support/phone_identity_fixtures.dart';

class _Platform extends FakePhonePlatform {
  @override
  Future<bool> requestMicrophonePermission() async => true;
}

class _NoAdmission implements DeviceAdmissionPort {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Device conversation must not call Admission');
}

class _Provisioner implements ConversationProvisioner {
  @override
  String get serviceName => 'Test Host';
  @override
  Uri get serviceUri => Uri.parse('https://owner.test/descriptor');
  @override
  Future<HubConfig> provision(
          {String sessionIntent = '', ConversationMode? mode}) async =>
      const HubConfig(
          status: HubConfigStatus.active,
          session: RoomConfig(
              serverUrl: 'wss://room.test',
              token: 'token',
              identity: 'device',
              roomName: 'room'),
          deviceFingerprint: phoneFingerprint);
}

class _Session extends EidolonSession {
  _Session(this.events);
  final List<String> events;
  final data = StreamController<SessionData>.broadcast();
  int sequence = 0;
  @override
  Stream<SessionData> get dataEvents => data.stream;
  bool connected = false;
  int connections = 0;
  @override
  bool get isConnected => connected;
  @override
  Future<void> connect(RoomConfig config) async {
    connected = true;
    connections++;
  }

  @override
  Future<void> disconnect() async {
    connected = false;
  }

  @override
  String? get conversationId => 'conversation-$sequence';
  @override
  Future<void> openSession() async {
    sequence++;
    events.add('open-$sequence');
  }

  @override
  Future<void> closeSession() async => events.add('close-$sequence');
  @override
  Future<void> setMicrophoneEnabled(bool enabled) async {}
  @override
  Future<void> publishAudioState(
      {required bool muted,
      required bool agentSpeaking,
      bool reliable = false}) async {}
  @override
  Future<void> dispose() async {
    await data.close();
    await super.dispose();
  }
}

class _RecoveryProvisioner extends _Provisioner
    implements RecoverableConversationProvisioner {
  int recoveryCalls = 0;
  bool reject = false;
  bool recovered = false;
  @override
  Future<HubConfig> provision(
          {String sessionIntent = '', ConversationMode? mode}) async =>
      recovered
          ? super.provision(sessionIntent: sessionIntent)
          : const HubConfig(
              status: HubConfigStatus.waitingBinding,
              session: RoomConfig(
                  serverUrl: '', token: '', identity: '', roomName: ''),
              deviceFingerprint: phoneFingerprint,
              bodyStanding: MobileBodyStanding.claimActiveWithoutChannel,
              channelRefusal: ChannelRefusal.ownerMismatch);
  @override
  Future<void> recoverClaim() async {
    recoveryCalls++;
    if (reject) {
      throw const ConversationRecoveryUnavailable('此主机没有可恢复的已完成登记。原记录已保留。');
    }
    recovered = true;
  }
}

class _Harness {
  ConversationProvisioner? provisioner;
  final events = <String>[];
  String companion = 'c_a';
  int revision = 3;
  bool unavailable = false;
  bool loseWriteReply = false;
  final requests = <String>[];
  late final session = _Session(events);
  late final flow = ConversationFlow(
      hostName: '工作室',
      ownerDomainId: ownerDomainIdFixture,
      loadTarget: () async => deviceOnboardingTargetFixture(),
      enrollment: MobileBodyEnrollmentSession(
          loadTarget: () async => deviceOnboardingTargetFixture(),
          buildAdmission: (_) =>
              throw StateError('No enrollment during conversation')),
      management: ConversationManagement(
          controllerId: 'controller',
          admission: _NoAdmission(),
          roster: ({cursor}) async {
            if (unavailable) throw StateError('Controller unavailable');
            return CompanionRosterView.fromJson({
              'contract_version': '1',
              'default_companion_id': 'c_a',
              'next_cursor': null,
              'companions': [
                for (final name in ['a', 'b'])
                  {
                    'companion_id': 'c_$name',
                    'display_name': name == 'a' ? 'Eidolon' : 'Aria',
                    'kind': 'standard',
                    'lifecycle_state': 'active',
                    'revision': 1,
                    'created_at': '2026-09-01T00:00:00Z',
                    'updated_at': '2026-09-01T00:00:00Z'
                  }
              ]
            });
          },
          device: (_) async {
            if (unavailable) throw StateError('Controller unavailable');
            return MountedDevice.fromView(DeviceView.fromJson({
              'device_id': phoneDeviceInstanceId,
              'label': 'Mobile',
              'kind': 'software',
              'state': 'ready',
              'answers_as_companion_id': companion,
              'answers_as_companion_name':
                  companion == 'c_a' ? 'Eidolon' : 'Aria',
              'quiet_because': '',
              'revision': revision,
              'mount_revision': 1,
              'updated_at': '2026-09-01T00:00:00Z',
              'online': 'unknown',
              'online_reason': '',
              'claim_state': 'active',
              'claim_generation': 2,
              'trust_epoch': 1,
              'owner_domain_generation': 1,
              'manifest_id': 'mobile',
              'manifest_revision': 1
            }));
          },
          assign: (
              {required deviceId,
              required requestId,
              required companionId,
              required expectedRevision}) async {
            expect(deviceId, phoneDeviceInstanceId);
            expect(expectedRevision, revision);
            requests.add(requestId);
            if (loseWriteReply) throw TimeoutException('uncertain');
            companion = companionId!;
            revision++;
            events.add('assign-$companion');
          }),
      provisioner: provisioner ?? _Provisioner(),
      platform: _Platform(),
      session: session);
}

Future<void> settle() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  const captures = String.fromEnvironment('CONVERSATION_CAPTURE');
  setUpAll(() async {
    if (captures.isNotEmpty) {
      final loader = FontLoader('ConversationReview')
        ..addFont(Future.value(ByteData.sublistView(
            File('/System/Library/Fonts/Supplemental/Arial Unicode.ttf')
                .readAsBytesSync())));
      await loader.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(Future.value(ByteData.sublistView(
            File('build/unit_test_assets/fonts/MaterialIcons-Regular.otf')
                .readAsBytesSync())));
      await icons.load();
    }
  });
  testWidgets(
      'Owner conflict offers explicit recovery, cancel is inert and failure remains actionable',
      (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final provisioner = _RecoveryProvisioner();
    final h = _Harness()..provisioner = provisioner;
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: ProductConversationPage(
            hostName: '工作室', createFlow: () async => h.flow)));
    await tester.pumpAndSettle();
    expect(find.text('恢复已有登记'), findsOneWidget);
    expect(provisioner.recoveryCalls, 0);
    await tester.tap(find.text('恢复已有登记'));
    await tester.pumpAndSettle();
    expect(find.textContaining('工作室'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(provisioner.recoveryCalls, 0);
    provisioner.reject = true;
    await tester.tap(find.text('恢复已有登记'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('核验并恢复'));
    await tester.pumpAndSettle();
    expect(provisioner.recoveryCalls, 1);
    expect(find.textContaining('原记录已保留'), findsOneWidget);
    expect(find.text('恢复已有登记'), findsOneWidget);
    provisioner.reject = false;
    await tester.tap(find.text('恢复已有登记'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('核验并恢复'));
    await tester.pumpAndSettle();
    expect(provisioner.recoveryCalls, 2);
    expect(find.text('先选择对话方式'), findsOneWidget);
    expect(h.events, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  test(
      'selection is required, refresh preserves drafts, mode change only returns to preparation',
      () async {
    final h = _Harness();
    await h.flow.initialize();
    await h.flow.startConversation();
    await settle();
    expect(h.session.connections, 0);
    expect(h.flow.error, contains('对话方式'));
    await h.flow.choose('c_b');
    await h.flow.refreshManagement();
    expect(h.flow.selectedCompanionId, 'c_b');
    expect(h.companion, 'c_a');
    await h.flow.chooseMode(ConversationMode.ptt);
    await h.flow.startConversation();
    await settle();
    expect(h.session.connections, 1);
    expect(h.flow.client.mode, ConversationMode.ptt);
    await h.flow.chooseMode(ConversationMode.halfDuplex);
    await settle();
    expect(h.flow.client.canJoin, true);
    expect(h.session.connected, false);
    expect(h.session.connections, 1);
    await h.flow.startConversation();
    await settle();
    expect(h.session.connections, 2);
    expect(h.flow.client.mode, ConversationMode.halfDuplex);
    await h.flow.close();
    h.flow.dispose();
  });

  test('A to B to A uses one Device and closes before binding and reopening',
      () async {
    final h = _Harness();
    await h.flow.initialize();
    expect(h.events, isEmpty);
    await h.flow.chooseMode(ConversationMode.fullDuplex);
    await h.flow.startConversation();
    await settle();
    await h.flow.choose('c_b');
    expect(h.flow.client.canLeave, false);
    await h.flow.startConversation();
    await settle();
    await h.flow.choose('c_a');
    await h.flow.startConversation();
    await settle();
    expect(h.events, [
      'open-1',
      'close-1',
      'assign-c_b',
      'open-2',
      'close-2',
      'assign-c_a',
      'open-3'
    ]);
    expect(h.revision, 5);
    await h.flow.close();
    h.flow.dispose();
  });
  test('an uncertain binding retries exactly the same command and revision',
      () async {
    final h = _Harness();
    await h.flow.initialize();
    await h.flow.chooseMode(ConversationMode.ptt);
    h.loseWriteReply = true;
    await h.flow.choose('c_b');
    expect(h.requests, isEmpty);
    await h.flow.startConversation();
    await settle();
    await h.flow.startConversation();
    await settle();
    expect(h.requests, hasLength(2));
    expect(h.requests[0], h.requests[1]);
    expect(h.flow.selectedCompanionId, 'c_b');
    expect(h.events, isEmpty);
    h.loseWriteReply = false;
    await h.flow.startConversation();
    await settle();
    expect(h.requests[2], h.requests[0]);
    expect(h.flow.selectedCompanionId, 'c_b');
    await h.flow.close();
    h.flow.dispose();
  });
  test('unavailable companion selection cannot silently start a conversation',
      () async {
    final h = _Harness()..unavailable = true;
    await h.flow.initialize();
    await h.flow.chooseMode(ConversationMode.fullDuplex);
    await h.flow.startConversation();
    await settle();
    expect(h.events, isEmpty);
    expect(h.session.connections, 0);
    expect(h.flow.managementError, isNotNull);
    await h.flow.close();
    h.flow.dispose();
  });
  test('late session confirmation after leaving does not resurrect a session',
      () async {
    final h = _Harness();
    await h.flow.initialize();
    await h.flow.chooseMode(ConversationMode.fullDuplex);
    await h.flow.startConversation();
    await settle();
    await h.flow.close();
    h.session.data.add(SessionData(
        'eidolon.session_control',
        jsonEncode({
          'schema_v': 1,
          'type': 'session_started',
          'conversation_id': 'conversation-1'
        })));
    await settle();
    expect(h.flow.client.canLeave, false);
    expect(h.flow.client.microphoneEnabled, false);
    h.flow.dispose();
  });
  testWidgets(
      'missing session confirmation closes the microphone after the bounded wait',
      (tester) async {
    final events = <String>[];
    final c = ClientController(
        platform: _Platform(),
        session: _Session(events),
        conversationProvisioner: _Provisioner(),
        conversationConfirmationTimeout: const Duration(seconds: 2));
    await c.start();
    await c.join();
    expect(c.microphoneEnabled, false);
    await tester.pump(const Duration(seconds: 3));
    expect(c.microphoneEnabled, false);
    expect(c.canLeave, false);
    expect(c.failure?.title, '暂时没有接通');
    expect(events, ['open-1', 'close-1']);
    c.dispose();
  });
  testWidgets(
      'empty channel polling is bounded and manual retry starts a new window',
      (tester) async {
    final provisioner = _WaitingProvisioner();
    final c = ClientController(
        platform: _Platform(),
        session: _Session([]),
        conversationProvisioner: provisioner);
    await c.start();
    for (var i = 0; i < 9; i++) {
      await tester.pump(const Duration(seconds: 5));
    }
    expect(c.activationExhausted, true);
    expect(provisioner.calls, 7);
    await tester.pump(const Duration(seconds: 30));
    expect(provisioner.calls, 7);
    await c.retry();
    expect(c.activationExhausted, false);
    await tester.pump(const Duration(seconds: 5));
    expect(provisioner.calls, 9);
    c.dispose();
  });
  for (final size in [
    const Size(390, 844),
    const Size(320, 568),
    const Size(1280, 800)
  ]) {
    testWidgets('conversation page and picker fit $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final h = _Harness();
      final captureKey = GlobalKey();
      await tester.pumpWidget(RepaintBoundary(
          key: captureKey,
          child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: ThemeData.dark(useMaterial3: true).copyWith(
                  textTheme: ThemeData.dark(useMaterial3: true).textTheme.apply(
                      fontFamily:
                          captures.isEmpty ? null : 'ConversationReview')),
              home: ProductConversationPage(
                  hostName: '工作室', createFlow: () async => h.flow))));
      await tester.pumpAndSettle();
      if (captures.isNotEmpty) {
        final boundary = captureKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final rendered = await boundary.toImage();
          final bytes =
              await rendered.toByteData(format: ui.ImageByteFormat.png);
          Directory(captures).createSync(recursive: true);
          File('$captures/conversation-${size.width.toInt()}.png')
              .writeAsBytesSync(bytes!.buffer.asUint8List());
          rendered.dispose();
        });
      }
      expect(find.text('先选择对话方式'), findsOneWidget);
      expect(find.text('Eidolon'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Eidolon'));
      await tester.pumpAndSettle();
      expect(find.text('Aria'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Aria'));
      await tester.pumpAndSettle();
      expect(h.companion, 'c_a');
      expect(h.flow.selectedCompanionId, 'c_b');
      expect(h.events, isEmpty);
      expect(h.session.connections, 0);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
  }
}

class _WaitingProvisioner extends _Provisioner {
  int calls = 0;
  @override
  Future<HubConfig> provision(
      {String sessionIntent = '', ConversationMode? mode}) async {
    calls++;
    return const HubConfig(
        status: HubConfigStatus.waitingBinding,
        session:
            RoomConfig(serverUrl: '', token: '', identity: '', roomName: ''),
        deviceFingerprint: phoneFingerprint,
        bodyStanding: MobileBodyStanding.claimActiveWithoutChannel);
  }
}
