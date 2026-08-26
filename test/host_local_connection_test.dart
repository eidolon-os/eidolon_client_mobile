import 'dart:convert';
import 'dart:io';

import 'package:eidolon_client_mobile/src/features/host_setup/host_local_connection_page.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/local_api_client.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/local_api_discovery.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/pinned_http_client.dart';
import 'package:eidolon_client_mobile/src/features/setup/commissioning_transport.dart';
import 'package:eidolon_client_mobile/src/features/setup/controller_key_bridge.dart';
import 'package:eidolon_client_mobile/src/features/setup/host_registry.dart';
import 'package:eidolon_client_mobile/src/features/setup/setup_models.dart';
import 'package:eidolon_client_mobile/src/management/management_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/local_api_fixtures.dart';

import 'support/setup_fixtures.dart';

const _tlsFingerprint = 'sha256:ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8';
const _controllerId = 'ectrl-0123456789abcdefabcd';
const _workspaceOperationId = '32c421a3-e0df-40f9-8f75-68745ae39d81';

class _FakeDiscovery implements LocalApiDiscovery {
  @override
  Future<LocalApiSurvey> discover({
    Duration timeout = const Duration(seconds: 5),
  }) async =>
      announcedSurvey(const [
        LocalApiEndpoint(
          instanceName: 'Eidolon Local API on eidolon-pi5',
          baseUrl: 'https://192.168.1.26:9002',
          ipAddress: '192.168.1.26',
          contractVersion: '1',
        ),
      ]);
}

class _FakeControllerKeys implements ControllerKeyBridge {
  @override
  Future<ControllerIdentity> getIdentity() async => const ControllerIdentity(
        controllerId: _controllerId,
        publicKey: 'controller-public-key',
        fingerprint: 'sha256:controller',
      );

  @override
  Future<String> signChallenge(Map<String, dynamic> challenge) async =>
      'valid-controller-signature';
}

class _LegacyHostTransport implements CommissioningTransport {
  int scans = 0;
  int opens = 0;

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<List<NearbyEidolonHost>> scan({
    required String serviceUuid,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    scans += 1;
    return const [
      NearbyEidolonHost(
        address: 'AA:BB:CC:DD:EE:FF',
        name: 'Eidolon-4c0285',
        hostMarker: '4c0285',
        rssi: -40,
      ),
    ];
  }

  @override
  Future<String> open({
    required String address,
    required String serviceUuid,
  }) async {
    opens += 1;
    return jsonEncode(validCommissioningEndpoint);
  }

  @override
  Future<void> secure({required String tlsSpkiFingerprint}) async =>
      throw StateError('Trust refresh must not open a BLE TLS session');

  @override
  Future<Map<String, dynamic>> request(
    String operation,
    Map<String, dynamic> payload,
  ) async =>
      throw StateError('Trust refresh must not mutate Bootstrap state');

  @override
  Future<void> close() async {}
}

ManagedHost _host({String? tlsSpkiFingerprint}) => ManagedHost(
      hostId: validHostId,
      hostPublicKey: validHostPublicKey,
      hostFingerprint: validHostPublicKeyFingerprint,
      bleServiceUuid: validBleServiceUuid,
      controllerId: _controllerId,
      displayName: 'Eidolon-4c0285',
      claimedAt: DateTime.parse('2026-08-05T00:20:00Z'),
      tlsSpkiFingerprint: tlsSpkiFingerprint,
    );

Map<String, dynamic> _hostOverview({
  String hostId = validHostId,
  String workspaceState = 'absent',
  String claimState = 'claimed',
}) =>
    {
      'contract_version': '1',
      'status': 'running',
      'mode': 'development',
      'descriptor': {
        'contract_version': '1',
        'host_id': hostId,
        'host_public_key': validHostPublicKey,
        'host_public_key_fingerprint': validHostPublicKeyFingerprint,
        'ble_service_uuid': validBleServiceUuid,
      },
      'state': {
        'reset_epoch': 2,
        'claim_state': claimState,
        'network_state': 'connected',
        'workspace_state': workspaceState,
        'recovery_state': 'normal',
        'updated_at': '2026-08-06T08:00:00Z',
      },
    };

Map<String, dynamic> _workspaceRuntime() => {
      'contract_version': '1',
      'operation_id': _workspaceOperationId,
      'state': 'ready',
      'owner': {
        'owner_id': 'owner_primary',
        'display_name': 'Manson',
        'lifecycle_state': 'active',
      },
      'primary_companion': {
        'companion_id': 'companion_primary',
        'display_name': 'Eidolon',
        'lifecycle_state': 'active',
      },
      'persona': {
        'genome_id': 'genome_current',
        'version': 2,
        'lifecycle_state': 'committed',
        'schema_version': 'eidolon.persona_genome',
        'genome_hash': 'sha256:${'a' * 64}',
        'realizer_version': '1',
      },
      'memory_workspace': {
        'realm_id': 'realm_primary',
        'lifecycle_state': 'active',
      },
    };

Map<String, dynamic> _deviceInventory({bool withReadyDevice = false}) => {
      'contract_version': '1',
      'coverage': '只包含已经属于你的设备。',
      'devices': withReadyDevice
          ? [
              {
                'device_id': 'device-waveshare-1',
                'label': 'esp-box-3',
                'kind': 'esp-box-3',
                'state': 'ready',
                'answers_as_companion_id': 'companion_primary',
                'answers_as_companion_name': '小忆',
                'revision': 2,
                'updated_at': '2026-08-09T08:10:00Z',
                'online': 'unknown',
                'online_reason': '这台主机没有任何东西在观测设备是否开着',
                'claim_state': 'active',
                'claim_generation': 1,
                'trust_epoch': 1,
                'owner_domain_generation': 3,
                'manifest_id': 'esp-box-3',
                'manifest_revision': 1,
              },
            ]
          : [],
    };

/// A Host answers in bytes, and a name is not necessarily latin1 — which is
/// what `http.Response(String, …)` assumes. The product reads bodyBytes as
/// UTF-8; a fake that cannot even encode 曼森 fails where the Host would not.
/// What the Host says this person is called, shared by the two fakes.
///
/// Renaming goes over the management contract and reading the workspace goes
/// over `/api/local/v1`, so the name has to live somewhere both can see —
/// exactly as it lives in one authority on a real Host.
class _OwnerName {
  String value = 'Manson';
  final List<String> written = <String>[];
}

/// A Host that answers the management surface but has nothing interesting to say.
///
/// Every connected session reads `/context` now — it is how a row this Host
/// cannot serve gets shown as held back rather than opening onto a page that
/// fails — so a test that stubs only `/api/local/v1` describes a Host that
/// cannot exist. Without this the session falls back to the production factory
/// and a widget test reaches for a real socket, which does not fail: it hangs.
ManagementClient _quietManagementClient({
  bool withReadyDevice = false,
  int homeStatus = 200,
}) =>
    _managementClientFor(
      _OwnerName(),
      devices: _deviceInventory(withReadyDevice: withReadyDevice),
      homeStatus: homeStatus,
    );

Map<String, dynamic> _homeAnswer(_OwnerName ownerName) => {
      'contract_version': '1',
      'owner_display_name': ownerName.value,
      'owner_revision': 3,
      // A list, and two of them running at once — the case the old shape could
      // not express, because it carried one promoted Companion.
      'companions': [
        {
          'companion_id': 'companion_primary',
          'display_name': '小忆',
          'kind': 'conversational',
          'lifecycle_state': 'active',
          'revision': 4,
          'created_at': '2026-08-01T00:00:00+00:00',
          'updated_at': '2026-08-01T00:00:00+00:00',
          'running': true,
          'last_active_at': '2026-08-26T09:30:00+00:00',
        },
        {
          'companion_id': 'companion_second',
          'display_name': '阿力',
          'kind': 'conversational',
          'lifecycle_state': 'active',
          'revision': 2,
          'created_at': '2026-08-02T00:00:00+00:00',
          'updated_at': '2026-08-02T00:00:00+00:00',
          'running': true,
          'last_active_at': '2026-08-26T09:20:00+00:00',
        },
      ],
      'default_companion_id': 'companion_primary',
      'runtime_unavailable': '',
      'memory': '还没记下什么',
      'companion_counts': {'total': 2, 'ready': 2, 'waiting': 0, 'put_away': 0},
      'devices': {'total': 0, 'ready': 0, 'waiting': 0, 'put_away': 0},
      'machine_attention': <String>[],
      'unavailable': <String, String>{},
    };

ManagementClient _managementClientFor(
  _OwnerName ownerName, {
  Map<String, dynamic>? devices,
  int homeStatus = 200,
}) =>
    ManagementClient(
      httpClient: MockClient((request) async {
        if (request.url.path == '/api/management/v1/home') {
          // The one read a screen makes when it opens. A Host that cannot
          // answer it still has a claimed, ready Workspace — which is the case
          // the degraded card below exists for.
          if (homeStatus != 200) {
            return _jsonResponse({'detail': '概览暂时读不到'}, homeStatus);
          }
          return _jsonResponse(_homeAnswer(ownerName));
        }
        if (request.url.path == '/api/management/v1/devices') {
          // Devices moved to the management contract with the rest of what a
          // person manages; an empty list is a real answer.
          return _jsonResponse(devices ?? _deviceInventory());
        }
        if (request.url.path == '/api/management/v1/context') {
          // Every capability off and every reason given, which is the honest
          // answer for a Host these tests never configured — and it keeps this
          // file about what it is about.
          return _jsonResponse({
            'contract_version': '1',
            'owner': {'owner_id': 'owner-1', 'display_name': 'Manson', 'revision': 4},
            'default_companion_id': 'companion-a',
            'capabilities': <String, bool>{},
            'unavailable': <String, String>{},
            'limits': <String, int?>{'max_active_companions': null},
          });
        }
        if (request.url.path == '/api/management/v1/host/vitals') {
          // The system page reads the machine over the management contract
          // now. A Host that answers with no readings is a real state — the
          // page says so rather than hanging — and it keeps this test about
          // what it is about.
          return _jsonResponse({
            'operation': 'host.vitals',
            'contract_version': '1',
            'observed_at': '2026-08-25T09:00:00Z',
            'vitals': <Map<String, dynamic>>[],
          });
        }
        if (request.url.path == '/api/management/v1/host/services') {
          return _jsonResponse({'services': <Map<String, dynamic>>[]});
        }
        if (request.url.path == '/api/management/v1/controllers') {
          // The cockpit asks who may manage this Host over the same contract as
          // everything else now. An empty list is a real answer and keeps this
          // test about what it is about — that the page is reachable.
          return _jsonResponse({'contract_version': '1', 'controllers': []});
        }
        if (request.url.path == '/api/management/v1/owner') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          ownerName.value = body['display_name']! as String;
          ownerName.written.add(ownerName.value);
          return _jsonResponse({
            'contract_version': '1',
            'owner_id': 'owner-1',
            'display_name': ownerName.value,
            'revision': 4,
          });
        }
        return _jsonResponse({'detail': 'not part of this test'}, 404);
      }),
    );

http.Response _jsonResponse(Object body, [int status = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(body)), status);

LocalApiClient _clientFor(
  Map<String, dynamic> overview, {
  int workspaceStatusCode = 200,
  bool workspaceReady = false,
  int runtimeStatusCode = 200,
  bool withReadyDevice = false,
  PinnedHttpFailureKind? workspaceTransportFailure,
  // The Host is the authority on what anyone is called, and renaming now
  // happens over the management contract — so the name lives in a box both
  // fakes share, and a later read here answers with what that write was told.
  // A client that painted its own copy would pass a test the product fails.
  _OwnerName? ownerName,
}) {
  ownerName ??= _OwnerName();
  return LocalApiClient(
    httpClient: MockClient((request) async {
      if (request.url.path == '/api/local/v1/host') {
        return http.Response(jsonEncode(overview), 200);
      }
      if (request.url.path == '/api/local/v1/auth/challenges') {
        return http.Response(
          jsonEncode({
            'contract_version': '1',
            'purpose': 'eidolon-controller-local-auth-v1',
            'controller_id': _controllerId,
            'challenge': validHostChallenge,
            'reset_epoch': 2,
          }),
          200,
        );
      }
      if (request.url.path == '/api/local/v1/auth/sessions') {
        return http.Response(
          jsonEncode({
            'contract_version': '1',
            'token_type': 'Bearer',
            'access_token': validHostChallenge,
            'expires_at': '2026-08-06T09:00:00Z',
            'controller': {
              'contract_version': '1',
              'controller_id': _controllerId,
              'role': 'host_admin',
              'display_name': 'Test tablet',
              'platform': 'android',
              'reset_epoch': 2,
              'owner_id': workspaceReady ? 'owner_primary' : null,
            },
          }),
          200,
        );
      }
      if (request.url.path == '/api/local/v1/setup/workspace') {
        if (workspaceTransportFailure case final kind?) {
          throw PinnedHttpException(
            kind: kind,
            message: 'simulated workspace transport failure',
            uri: request.url,
          );
        }
        if (workspaceStatusCode != 200) {
          return http.Response('', workspaceStatusCode);
        }
        return _jsonResponse(
          workspaceReady
              ? {
                  'contract_version': '1',
                  'operation_id': _workspaceOperationId,
                  'state': 'ready',
                  'owner': {
                    'owner_id': 'owner_primary',
                    'display_name': ownerName!.value,
                    'lifecycle_state': 'active',
                  },
                  'workspace': {
                    'state': 'ready',
                    'primary_companion_id': 'companion_primary',
                    'persona_genome_id': 'genome_origin',
                    'memory_realm_id': 'realm_primary',
                  },
                }
              : {
                  'contract_version': '1',
                  'operation_id': _workspaceOperationId,
                  'state': 'absent',
                  'owner': null,
                  'workspace': null,
                },
        );
      }
      if (request.url.path == '/api/local/v1/workspace/runtime') {
        if (runtimeStatusCode != 200) {
          return http.Response('', runtimeStatusCode);
        }
        return http.Response(jsonEncode(_workspaceRuntime()), 200);
      }
      return http.Response('', 404);
    }),
  );
}

void main() {
  _theseTestsDescribeAHostThatCanAnswer();
  testWidgets(
      'legacy claimed Host refreshes only TLS trust over BLE then authenticates on LAN',
      (tester) async {
    final transport = _LegacyHostTransport();
    ManagedHost? updated;
    String? pinnedFingerprint;

    await tester.pumpWidget(
      MaterialApp(
        home: HostLocalConnectionPage(
          managementClientFactory: (_) => _quietManagementClient(),
          host: _host(),
          transport: transport,
          controllerKeys: _FakeControllerKeys(),
          discovery: _FakeDiscovery(),
          localApiClientFactory: (fingerprint) {
            pinnedFingerprint = fingerprint;
            return _clientFor(_hostOverview());
          },
          onHostUpdated: (host) async => updated = host,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(transport.scans, 1);
    expect(transport.opens, 1);
    expect(updated?.tlsSpkiFingerprint, _tlsFingerprint);
    expect(pinnedFingerprint, _tlsFingerprint);
    expect(find.byKey(const Key('local-connection-complete')), findsOneWidget);
    expect(find.text('已安全连接'), findsOneWidget);
    expect(find.text('Host IP：192.168.1.26'), findsOneWidget);
    expect(find.textContaining(_controllerId), findsOneWidget);
  });

  testWidgets('LAN candidate with another Host identity is rejected',
      (tester) async {
    final transport = _LegacyHostTransport();
    const otherHostId = 'ehost-0123456789abcdefabcd';

    await tester.pumpWidget(
      MaterialApp(
        home: HostLocalConnectionPage(
          managementClientFactory: (_) => _quietManagementClient(),
          host: _host(tlsSpkiFingerprint: _tlsFingerprint),
          transport: transport,
          controllerKeys: _FakeControllerKeys(),
          discovery: _FakeDiscovery(),
          localApiClientFactory: (_) =>
              _clientFor(_hostOverview(hostId: otherHostId)),
          onHostUpdated: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(transport.scans, 0);
    expect(find.byKey(const Key('local-connection-complete')), findsNothing);
    expect(find.byKey(const Key('local-connection-error')), findsOneWidget);
    expect(find.textContaining('另一台 Host'), findsOneWidget);
  });

  testWidgets(
      'Workspace outage does not turn a valid Host connection into failure',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: HostLocalConnectionPage(
          managementClientFactory: (_) => _quietManagementClient(),
          host: _host(tlsSpkiFingerprint: _tlsFingerprint),
          transport: _LegacyHostTransport(),
          controllerKeys: _FakeControllerKeys(),
          discovery: _FakeDiscovery(),
          localApiClientFactory: (_) => _clientFor(
            _hostOverview(),
            workspaceStatusCode: 503,
          ),
          onHostUpdated: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('local-connection-complete')), findsOneWidget);
    expect(find.byKey(const Key('local-connection-error')), findsNothing);
    expect(find.byKey(const Key('workspace-setup-error')), findsOneWidget);
    expect(find.textContaining('认领和 Wi-Fi 不会回滚'), findsOneWidget);
  });

  testWidgets(
      'Workspace transport interruption does not erase a valid Host session',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: HostLocalConnectionPage(
          managementClientFactory: (_) => _quietManagementClient(),
          host: _host(tlsSpkiFingerprint: _tlsFingerprint),
          transport: _LegacyHostTransport(),
          controllerKeys: _FakeControllerKeys(),
          discovery: _FakeDiscovery(),
          localApiClientFactory: (_) => _clientFor(
            _hostOverview(),
            workspaceTransportFailure: PinnedHttpFailureKind.io,
          ),
          onHostUpdated: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('local-connection-complete')), findsOneWidget);
    expect(find.byKey(const Key('local-connection-error')), findsNothing);
    expect(find.byKey(const Key('workspace-setup-error')), findsOneWidget);
    expect(find.textContaining('本地安全连接在传输过程中中断'), findsOneWidget);
  });

  testWidgets(
      'runtime outage preserves ready Workspace and degrades only daily status',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: HostLocalConnectionPage(
          // The Host answers everything except the one read a screen opens
          // with. A ready, claimed Workspace and no overview is a real state.
          managementClientFactory: (_) => _quietManagementClient(homeStatus: 503),
          host: _host(tlsSpkiFingerprint: _tlsFingerprint),
          transport: _LegacyHostTransport(),
          controllerKeys: _FakeControllerKeys(),
          discovery: _FakeDiscovery(),
          localApiClientFactory: (_) => _clientFor(
            _hostOverview(workspaceState: 'ready'),
            workspaceReady: true,
          ),
          onHostUpdated: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('local-connection-complete')), findsOneWidget);
    expect(find.byKey(const Key('workspace-ready')), findsOneWidget);
    expect(find.byKey(const Key('local-connection-error')), findsNothing);
    expect(find.byKey(const Key('home-error')), findsOneWidget);
    expect(find.textContaining('概览暂时读不到'), findsOneWidget);
    // The home read failed, so there are no Eidolon rows to draw — and the
    // card says the overview could not be read rather than drawing rows full of
    // guesses. What it must not do is invent a state: 「运行中」 used to appear
    // here whenever a default Companion existed, which was true even when this
    // very read had failed.
    expect(find.textContaining('运行中'), findsNothing);
    expect(find.byKey(const Key('no-companions-row')), findsNothing);
  });

  testWidgets('星图入口在 Owner 就绪后出现，且不取代运行驾驶舱', (tester) async {
    // 两个入口并存是刻意的：驾驶舱的 vitals/服务/动态来自会应答的端点，而星图的
    // 运行 lane 还没有 producer。用一屏大部分「读不到」的图换掉它，是把退步装成
    // 进展。§3.2 的替换等运行 lane 落地。
    await tester.binding.setSurfaceSize(const Size(900, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: HostLocalConnectionPage(
          managementClientFactory: (_) => _quietManagementClient(),
          host: _host(tlsSpkiFingerprint: _tlsFingerprint),
          transport: _LegacyHostTransport(),
          controllerKeys: _FakeControllerKeys(),
          discovery: _FakeDiscovery(),
          localApiClientFactory: (_) => _clientFor(
            _hostOverview(workspaceState: 'ready'),
            workspaceReady: true,
          ),
          onHostUpdated: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('open-constellation')), findsOneWidget);
    expect(find.byKey(const Key('open-runtime-cockpit')), findsOneWidget);
  });

  testWidgets('主机还没有主人时没有星图入口', (tester) async {
    // 没有主人的主权域无物可画。门看的是「这台主机有主人」——
    // 而不是 Workspace setup 读取是否成功：真机上出现过 Owner 已认领、
    // 会话有效、setup 读取失败的组合，那时 /context 和 roster 都答得出，
    // 星图却被藏了。
    await tester.pumpWidget(
      MaterialApp(
        home: HostLocalConnectionPage(
          managementClientFactory: (_) => _quietManagementClient(),
          host: _host(tlsSpkiFingerprint: _tlsFingerprint),
          transport: _LegacyHostTransport(),
          controllerKeys: _FakeControllerKeys(),
          discovery: _FakeDiscovery(),
          localApiClientFactory: (_) =>
              _clientFor(_hostOverview(claimState: 'unclaimed')),
          onHostUpdated: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('open-constellation')), findsNothing);
  });

  testWidgets('Workspace 读不到但主机有主人时，星图入口仍在', (tester) async {
    // 真机上的组合：Owner 已认领、管理会话有效、`/setup/workspace` 失败。
    // 星图的来源是 /context 与 roster，两者都不依赖那次读取。
    await tester.binding.setSurfaceSize(const Size(900, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: HostLocalConnectionPage(
          managementClientFactory: (_) => _quietManagementClient(),
          host: _host(tlsSpkiFingerprint: _tlsFingerprint),
          transport: _LegacyHostTransport(),
          controllerKeys: _FakeControllerKeys(),
          discovery: _FakeDiscovery(),
          localApiClientFactory: (_) => _clientFor(
            _hostOverview(),
            workspaceTransportFailure: PinnedHttpFailureKind.io,
          ),
          onHostUpdated: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('open-constellation')), findsOneWidget);
    // 而运行驾驶舱按它自己的门（Workspace 就绪）照常缺席。
    expect(find.byKey(const Key('open-runtime-cockpit')), findsNothing);
  });

  testWidgets('ready Workspace shows only Kernel-confirmed mounted devices',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: HostLocalConnectionPage(
          // The devices come over the management contract now, so the fake
          // that answers it is the one that has to hold them.
          managementClientFactory: (_) =>
              _quietManagementClient(withReadyDevice: true),
          host: _host(tlsSpkiFingerprint: _tlsFingerprint),
          transport: _LegacyHostTransport(),
          controllerKeys: _FakeControllerKeys(),
          discovery: _FakeDiscovery(),
          localApiClientFactory: (_) => _clientFor(
            _hostOverview(workspaceState: 'ready'),
            workspaceReady: true,
            withReadyDevice: true,
          ),
          conversationBuilder: (_, __) => Scaffold(
            key: const Key('conversation-placeholder'),
            appBar: AppBar(title: const Text('Conversation')),
            body: const Text('Conversation'),
          ),
          onHostUpdated: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('mounted-devices-card')), findsOneWidget);
    expect(find.byKey(const Key('conversation-card')), findsOneWidget);
    await tester.tap(find.byKey(const Key('open-conversation')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('conversation-placeholder')), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('1'), findsOneWidget);
    await tester.tap(find.byKey(const Key('open-mounted-devices')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('mounted-devices-page')), findsOneWidget);
    expect(
      find.byKey(const Key('mounted-device-device-waveshare-1')),
      findsOneWidget,
    );
    expect(find.text('已接入'), findsOneWidget);
    // A mount revision is a fact about a record. What belongs on a list of
    // someone's devices is what each one is — and when the Host cannot say,
    // the tail of the identifier, which is at least something to read out.
    expect(find.textContaining('revision 2'), findsNothing);
    expect(find.textContaining('waveshare-1'), findsWidgets);
    expect(find.textContaining('尚未安全认领'), findsOneWidget);

    await tester.tap(
      find.byKey(const Key('mounted-device-device-waveshare-1')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('mounted-device-detail')), findsOneWidget);
    // The page is titled by the device it is about, not by what kind of page
    // it is — that was the last screen naming a thing after its own machinery.
    expect(find.text('设备详情'), findsNothing);
    expect(find.byKey(const Key('mounted-device-detail')), findsOneWidget);
    expect(find.textContaining('不代表设备当前在线'), findsOneWidget);
  });

  testWidgets('setup continuation initializes Workspace without redoing claim',
      (tester) async {
    var initialized = false;
    var overviewAvailable = false;
    var finished = false;
    final requests = <String>[];

    LocalApiClient clientFactory(String _) => LocalApiClient(
          httpClient: MockClient((request) async {
            requests.add('${request.method} ${request.url.path}');
            if (request.url.path == '/api/local/v1/host') {
              return http.Response(jsonEncode(_hostOverview()), 200);
            }
            if (request.url.path == '/api/local/v1/auth/challenges') {
              return http.Response(
                jsonEncode({
                  'contract_version': '1',
                  'purpose': 'eidolon-controller-local-auth-v1',
                  'controller_id': _controllerId,
                  'challenge': validHostChallenge,
                  'reset_epoch': 2,
                }),
                200,
              );
            }
            if (request.url.path == '/api/local/v1/auth/sessions') {
              return http.Response(
                jsonEncode({
                  'contract_version': '1',
                  'token_type': 'Bearer',
                  'access_token': validHostChallenge,
                  'expires_at': '2026-08-08T09:00:00Z',
                  'controller': {
                    'contract_version': '1',
                    'controller_id': _controllerId,
                    'role': 'host_admin',
                    'display_name': 'Test tablet',
                    'platform': 'android',
                    'reset_epoch': 2,
                    'owner_id': initialized ? 'owner_primary' : null,
                  },
                }),
                200,
              );
            }
            if (request.url.path == '/api/local/v1/setup/workspace' &&
                request.method == 'GET') {
              return http.Response(
                jsonEncode(
                  initialized
                      ? {
                          'contract_version': '1',
                          'operation_id': _workspaceOperationId,
                          'state': 'ready',
                          'owner': {
                            'owner_id': 'owner_primary',
                            'display_name': 'Manson',
                            'lifecycle_state': 'active',
                          },
                          'workspace': {
                            'state': 'ready',
                            'primary_companion_id': 'companion_primary',
                            'persona_genome_id': 'genome_origin',
                            'memory_realm_id': 'realm_primary',
                          },
                        }
                      : {
                          'contract_version': '1',
                          'operation_id': _workspaceOperationId,
                          'state': 'absent',
                          'owner': null,
                          'workspace': null,
                        },
                ),
                200,
              );
            }
            if (request.url.path == '/api/local/v1/setup/workspace' &&
                request.method == 'PUT') {
              expect(request.headers['authorization'],
                  'Bearer $validHostChallenge');
              expect(jsonDecode(request.body), {
                'owner_display_name': 'Manson',
                'companion_display_name': 'Eidolon',
              });
              initialized = true;
              return http.Response(
                jsonEncode({
                  'contract_version': '1',
                  'operation_id': _workspaceOperationId,
                  'state': 'ready',
                  'owner': {
                    'owner_id': 'owner_primary',
                    'display_name': 'Manson',
                    'lifecycle_state': 'active',
                  },
                  'workspace': {
                    'state': 'ready',
                    'primary_companion_id': 'companion_primary',
                    'persona_genome_id': 'genome_origin',
                    'memory_realm_id': 'realm_primary',
                  },
                }),
                200,
              );
            }
            return http.Response('', 404);
          }),
        );

    await tester.pumpWidget(
      MaterialApp(
        home: HostLocalConnectionPage(
          // The overview is the read this screen opens with, and this test is
          // about it coming back: gated on a flag the test flips rather than on
          // a fake built once.
          managementClientFactory: (_) => ManagementClient(
            httpClient: MockClient((request) async {
              if (request.url.path == '/api/management/v1/home') {
                if (!overviewAvailable) {
                  return _jsonResponse({'detail': '概览暂时读不到'}, 503);
                }
                return _jsonResponse(_homeAnswer(_OwnerName()));
              }
              if (request.url.path == '/api/management/v1/devices') {
                return _jsonResponse(_deviceInventory());
              }
              return _jsonResponse({'detail': 'not part of this test'}, 404);
            }),
          ),
          host: _host(tlsSpkiFingerprint: _tlsFingerprint),
          transport: _LegacyHostTransport(),
          controllerKeys: _FakeControllerKeys(),
          discovery: _FakeDiscovery(),
          localApiClientFactory: clientFactory,
          onHostUpdated: (_) async {},
          setupContinuation: true,
          onSetupComplete: () => finished = true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('local-connection-complete')), findsOneWidget);
    expect(find.byKey(const Key('workspace-setup')), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('workspace-owner-name')),
      'Manson',
    );
    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('initialize-workspace')));
    await tester.pumpAndSettle();

    expect(initialized, isTrue);
    expect(find.byKey(const Key('workspace-ready')), findsOneWidget);
    expect(find.text('你好，Manson。'), findsOneWidget);
    expect(find.byKey(const Key('home-error')), findsOneWidget);
    expect(find.textContaining('概览暂时读不到'), findsOneWidget);
    overviewAvailable = true;
    // Scrolled to rather than tapped where it used to be: the card grew a row
    // (the roster entry), and a fixed drag distance stops landing on this
    // button — which then reads as "the runtime never came back".
    await tester.ensureVisible(find.byKey(const Key('retry-home')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('retry-home')));
    await tester.pumpAndSettle();

    // One row per Eidolon, each by its own name. Not one promoted with the rest
    // reduced to a count: this is the Owner's screen, and it is about their
    // Eidolons.
    expect(find.text('小忆'), findsOneWidget);
    expect(find.text('阿力'), findsOneWidget);
    expect(
      find.byKey(const Key('home-companion-companion_primary')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('home-companion-companion_second')),
      findsOneWidget,
    );
    // **Both are running**, which the old shape could not say — and the one
    // that replies unaddressed is marked rather than promoted.
    expect(find.text('在运行'), findsNWidgets(2));
    expect(find.textContaining('没指名时由它回答'), findsOneWidget);
    // What each Eidolon has been through is on its own page, not here: on this
    // card it could only ever describe whichever one answered.
    expect(find.textContaining('第 1 章'), findsNothing);
    expect(find.textContaining('genome'), findsNothing);
    // The memory row is the *Owner's*: one Realm per person, every Eidolon
    // reading it through an audience. It used to be labelled 它的记忆 and
    // describe whichever Companion answered.
    expect(find.text('Memory Workspace'), findsNothing);
    expect(find.text('你的记忆'), findsOneWidget);
    expect(find.text('它的记忆'), findsNothing);
    expect(find.textContaining('realm_primary'), findsNothing);
    // The genome version used to be printed here. It said nothing to the
    // person it was printed at, and what it stood for now has a page.
    expect(find.textContaining('v2'), findsNothing);
    // 「运行中」 is gone from this card entirely. It was printed whenever the
    // Owner had a default Companion — a routing setting rendered as a runtime
    // fact — on two rows that were not even about the same thing.
    expect(find.text('运行中'), findsNothing);
    expect(find.byKey(const Key('home-error')), findsNothing);
    expect(find.text('我的 Eidolon'), findsOneWidget);
    await tester.tap(find.byKey(const Key('finish-workspace-setup')));
    expect(finished, isTrue);
    expect(requests, contains('PUT /api/local/v1/setup/workspace'));
  });

  testWidgets('system page exposes Host orthogonal state and real IP',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: HostLocalConnectionPage(
          host: _host(tlsSpkiFingerprint: _tlsFingerprint),
          transport: _LegacyHostTransport(),
          controllerKeys: _FakeControllerKeys(),
          discovery: _FakeDiscovery(),
          localApiClientFactory: (_) => _clientFor(_hostOverview()),
          managementClientFactory: (_) => _managementClientFor(_OwnerName()),
          onHostUpdated: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('open-host-system-status')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('host-system-page')), findsOneWidget);
    expect(find.text('192.168.1.26'), findsOneWidget);
    expect(find.text('Reset epoch'), findsOneWidget);
    expect(find.text('已认领'), findsOneWidget);
    expect(find.textContaining('发布、激活和回滚仍由 Ops'), findsOneWidget);
  });

  testWidgets('failed reauthentication invalidates the whole product session',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var expireSession = false;
    final client = MockClient((request) async {
      if (request.url.path == '/api/local/v1/host') {
        return http.Response(jsonEncode(_hostOverview()), 200);
      }
      if (request.url.path == '/api/local/v1/auth/challenges') {
        if (expireSession) return http.Response('', 404);
        return http.Response(
          jsonEncode({
            'contract_version': '1',
            'purpose': 'eidolon-controller-local-auth-v1',
            'controller_id': _controllerId,
            'challenge': validHostChallenge,
            'reset_epoch': 2,
          }),
          200,
        );
      }
      if (request.url.path == '/api/local/v1/auth/sessions') {
        return http.Response(
          jsonEncode({
            'contract_version': '1',
            'token_type': 'Bearer',
            'access_token': validHostChallenge,
            'expires_at': '2030-08-08T09:00:00Z',
            'controller': {
              'contract_version': '1',
              'controller_id': _controllerId,
              'role': 'host_admin',
              'display_name': 'Test tablet',
              'platform': 'android',
              'reset_epoch': 2,
              'owner_id': null,
            },
          }),
          200,
        );
      }
      if (request.url.path == '/api/local/v1/setup/workspace') {
        if (expireSession) return http.Response('', 401);
        return http.Response(
          jsonEncode({
            'contract_version': '1',
            'operation_id': _workspaceOperationId,
            'state': 'absent',
            'owner': null,
            'workspace': null,
          }),
          200,
        );
      }
      return http.Response('', 404);
    });
    await tester.pumpWidget(
      MaterialApp(
        home: HostLocalConnectionPage(
          managementClientFactory: (_) => _quietManagementClient(),
          host: _host(tlsSpkiFingerprint: _tlsFingerprint),
          transport: _LegacyHostTransport(),
          controllerKeys: _FakeControllerKeys(),
          discovery: _FakeDiscovery(),
          localApiClientFactory: (_) => LocalApiClient(httpClient: client),
          onHostUpdated: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('workspace-setup')), findsOneWidget);

    expireSession = true;
    await tester.tap(find.byKey(const Key('retry-workspace-status')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('local-connection-error')), findsOneWidget);
    expect(find.textContaining('主机已重置或不再授权'), findsOneWidget);
    expect(find.byKey(const Key('workspace-setup')), findsNothing);
  });

  testWidgets('how the Host was found is not printed at the person',
      (tester) async {
    // Locating gained sources beyond discovery, and their internal labels
    // began appearing on screen as 服务：remembered. Where the Host answered
    // is a fact about their Host; which mechanism found it is a fact about
    // this App, and the person is not the one who should be reading it.
    await tester.pumpWidget(
      MaterialApp(
        home: HostLocalConnectionPage(
          managementClientFactory: (_) => _quietManagementClient(),
          host: _host(),
          onHostUpdated: (_) async {},
          transport: _LegacyHostTransport(),
          controllerKeys: _FakeControllerKeys(),
          discovery: _FakeDiscovery(),
          localApiClientFactory: (_) => _clientFor(_hostOverview()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('服务：'), findsNothing);
    expect(find.textContaining('remembered'), findsNothing);
    expect(find.textContaining('published'), findsNothing);
    expect(find.textContaining('Host IP：'), findsOneWidget);
  });

  testWidgets('a person can correct the name they gave at first use', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final ownerName = _OwnerName();
    // One Host, so one fake: a factory that built a fresh one per call would
    // forget the name it was just told.
    final host = _clientFor(
      _hostOverview(workspaceState: 'ready'),
      workspaceReady: true,
      ownerName: ownerName,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: HostLocalConnectionPage(
          host: _host(tlsSpkiFingerprint: _tlsFingerprint),
          transport: _LegacyHostTransport(),
          controllerKeys: _FakeControllerKeys(),
          discovery: _FakeDiscovery(),
          localApiClientFactory: (_) => host,
          managementClientFactory: (_) => _managementClientFor(ownerName),
          onHostUpdated: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('你好，Manson。'), findsOneWidget);

    await tester.tap(find.byKey(const Key('rename-owner')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('owner-name-field')),
      '  曼森  ',
    );
    await tester.tap(find.byKey(const Key('confirm-owner-name')));
    await tester.pumpAndSettle();

    expect(ownerName.written, ['曼森']);
    // Shown because the Host said so afterwards, not because the screen
    // assumed the write took.
    expect(find.text('你好，曼森。'), findsOneWidget);
  });

  testWidgets('cancelling and clearing the box both leave a person named', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final ownerName = _OwnerName();
    // One Host, so one fake: a factory that built a fresh one per call would
    // forget the name it was just told.
    final host = _clientFor(
      _hostOverview(workspaceState: 'ready'),
      workspaceReady: true,
      ownerName: ownerName,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: HostLocalConnectionPage(
          host: _host(tlsSpkiFingerprint: _tlsFingerprint),
          transport: _LegacyHostTransport(),
          controllerKeys: _FakeControllerKeys(),
          discovery: _FakeDiscovery(),
          localApiClientFactory: (_) => host,
          managementClientFactory: (_) => _managementClientFor(ownerName),
          onHostUpdated: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('rename-owner')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('rename-owner')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('owner-name-field')), '   ');
    await tester.tap(find.byKey(const Key('confirm-owner-name')));
    await tester.pumpAndSettle();

    expect(ownerName.written, isEmpty);
    expect(find.text('你好，Manson。'), findsOneWidget);
  });

  testWidgets('the cockpit is reachable, not merely built', (tester) async {
    // A page nothing links to is the same fault as a module with no route:
    // present, working, invisible. This has been shipped twice this week in
    // other places, so the entry gets its own assertion rather than being
    // assumed from the page existing.
    await tester.binding.setSurfaceSize(const Size(900, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: HostLocalConnectionPage(
          host: _host(tlsSpkiFingerprint: _tlsFingerprint),
          transport: _LegacyHostTransport(),
          controllerKeys: _FakeControllerKeys(),
          discovery: _FakeDiscovery(),
          localApiClientFactory: (_) => _clientFor(
            _hostOverview(workspaceState: 'ready'),
            workspaceReady: true,
            withReadyDevice: true,
          ),
          managementClientFactory: (_) => _managementClientFor(_OwnerName()),
          onHostUpdated: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('open-runtime-cockpit')), findsOneWidget);
    await tester.tap(find.byKey(const Key('open-runtime-cockpit')));
    await tester.pumpAndSettle();

    expect(find.text('运行驾驶舱'), findsOneWidget);
    // The sovereign domain is the reason this screen exists; if the Workspace
    // is ready it has to be drawn.
    expect(find.byKey(const Key('cockpit-sovereign-domain')), findsOneWidget);
  });

  testWidgets('the roster is reachable, not merely built', (tester) async {
    // Same fault as the cockpit's, and worth its own assertion for the same
    // reason: the roster is the first screen that can show a second Eidolon,
    // and a screen nothing links to cannot be told from one that is broken.
    await tester.binding.setSurfaceSize(const Size(900, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: HostLocalConnectionPage(
          host: _host(tlsSpkiFingerprint: _tlsFingerprint),
          transport: _LegacyHostTransport(),
          controllerKeys: _FakeControllerKeys(),
          discovery: _FakeDiscovery(),
          localApiClientFactory: (_) => _clientFor(
            _hostOverview(workspaceState: 'ready'),
            workspaceReady: true,
          ),
          // Answers per path: the roster screen reads /context first, to learn
          // what this Host can do before drawing an action for it.
          managementClientFactory: (_) => ManagementClient(
            httpClient: MockClient((request) async {
              final body = request.url.path.endsWith('/context')
                  ? {
                      'contract_version': '1',
                      'owner': {
                        'owner_id': 'owner-1',
                        'display_name': 'Manson',
                        'revision': 3,
                      },
                      'default_companion_id': 'companion-a',
                      'capabilities': {'companion.read': true},
                      'limits': {'max_active_companions': null},
                    }
                  : {
                      'contract_version': '1',
                      'default_companion_id': 'companion-a',
                      'companions': [
                        {
                          'companion_id': 'companion-a',
                          'display_name': '小忆',
                          'kind': 'standard',
                          'lifecycle_state': 'active',
                          'revision': 2,
                          'created_at': '2026-08-24T09:30:00+00:00',
                          'updated_at': '2026-08-24T09:30:00+00:00',
                        },
                      ],
                      'next_cursor': null,
                    };
              return http.Response.bytes(
                utf8.encode(jsonEncode(body)),
                200,
                headers: const {'content-type': 'application/json'},
              );
            }),
          ),
          onHostUpdated: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    final entry = find.byKey(const Key('open-companion-roster'));
    expect(entry, findsOneWidget);
    await tester.ensureVisible(entry);
    await tester.pumpAndSettle();
    await tester.tap(entry);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('roster-row-companion-a')), findsOneWidget);
    expect(find.byKey(const Key('roster-default-badge')), findsOneWidget);
  });

  testWidgets('the memory library is reachable, not merely built',
      (tester) async {
    // The row for "它的记忆" carried no way in until now: it said the memory
    // exists and left the person there. Same assertion as the cockpit's and the
    // roster's, for the same reason.
    await tester.binding.setSurfaceSize(const Size(900, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: HostLocalConnectionPage(
          host: _host(tlsSpkiFingerprint: _tlsFingerprint),
          transport: _LegacyHostTransport(),
          controllerKeys: _FakeControllerKeys(),
          discovery: _FakeDiscovery(),
          localApiClientFactory: (_) => _clientFor(
            _hostOverview(workspaceState: 'ready'),
            workspaceReady: true,
          ),
          // Answers per path: the library screen reads /context first, to learn
          // whether this Host can govern memory before drawing the action.
          managementClientFactory: (_) => ManagementClient(
            httpClient: MockClient((request) async {
              final body = request.url.path.endsWith('/context')
                  ? {
                      'contract_version': '1',
                      'owner': {
                        'owner_id': 'owner-1',
                        'display_name': 'Manson',
                        'revision': 3,
                      },
                      'default_companion_id': 'companion-a',
                      'capabilities': {'memory.read': true},
                      'limits': {'max_active_companions': null},
                    }
                  : {
                      'contract_version': '1',
                      'wings': [
                        {
                          'wing_id': 'Wing_Life',
                          'display_name': '生活',
                          'description': '',
                          'entry_count': 1,
                          'rooms': [
                            {
                              'room_id': '饮食',
                              'entry_count': 1,
                              'titles': ['乌龙茶'],
                              'more': false,
                            },
                          ],
                        },
                      ],
                      'entry_count': 1,
                      'withheld_count': 0,
                      'truncated': false,
                    };
              return http.Response.bytes(
                utf8.encode(jsonEncode(body)),
                200,
                headers: const {'content-type': 'application/json'},
              );
            }),
          ),
          onHostUpdated: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    final entry = find.byKey(const Key('open-memory-library'));
    expect(entry, findsOneWidget);
    await tester.ensureVisible(entry);
    await tester.pumpAndSettle();
    await tester.tap(entry);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('memory-wing-Wing_Life')), findsOneWidget);
    expect(find.text('饮食'), findsOneWidget);
  });
}


/// A test in this file must describe a Host that can answer, on both surfaces.
///
/// Twelve constructions here stubbed `/api/local/v1` and left the management
/// client to its production default, which in a widget test reaches for a real
/// socket — and that does not fail, it hangs. Nothing caught it until a connected
/// session started reading `/context`, at which point four tests timed out for a
/// reason that had nothing to do with what they were testing.
void _theseTestsDescribeAHostThatCanAnswer() {
  test('every page in this file is given a management surface to talk to', () {
    final source = File('test/host_local_connection_test.dart')
        .readAsStringSync();
    final blocks = source.split('HostLocalConnectionPage(');
    // The first chunk is everything before the first construction.
    for (var index = 1; index < blocks.length; index += 1) {
      final block = blocks[index];
      final head = block.substring(0, block.length.clamp(0, 900));
      expect(
        head,
        contains('managementClientFactory'),
        reason:
            'construction #$index leaves the management client to the production '
            'factory, which opens a real socket in a widget test',
      );
    }
  });
}
