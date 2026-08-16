import 'dart:convert';

import 'package:eidolon_client_mobile/src/features/host_setup/host_local_connection_page.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/local_api_client.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/local_api_discovery.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/pinned_http_client.dart';
import 'package:eidolon_client_mobile/src/features/setup/commissioning_transport.dart';
import 'package:eidolon_client_mobile/src/features/setup/controller_key_bridge.dart';
import 'package:eidolon_client_mobile/src/features/setup/host_registry.dart';
import 'package:eidolon_client_mobile/src/features/setup/setup_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/setup_fixtures.dart';

const _tlsFingerprint = 'sha256:ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8';
const _controllerId = 'ectrl-0123456789abcdefabcd';
const _workspaceOperationId = '32c421a3-e0df-40f9-8f75-68745ae39d81';

class _FakeDiscovery implements LocalApiDiscovery {
  @override
  Future<List<LocalApiEndpoint>> discover({
    Duration timeout = const Duration(seconds: 5),
  }) async =>
      const [
        LocalApiEndpoint(
          instanceName: 'Eidolon Local API on eidolon-pi5',
          baseUrl: 'https://192.168.1.26:9002',
          ipAddress: '192.168.1.26',
          contractVersion: '1',
        ),
      ];
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
        'claim_state': 'claimed',
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
      'coverage': 'mounted-devices',
      'devices': withReadyDevice
          ? [
              {
                'device_id': 'device-waveshare-1',
                'admission_state': 'ready',
                'mount': {
                  'revision': 2,
                  'attached_companion_id': 'companion_primary',
                  'updated_at': '2026-08-09T08:10:00Z',
                },
              },
            ]
          : [],
    };

LocalApiClient _clientFor(
  Map<String, dynamic> overview, {
  int workspaceStatusCode = 200,
  bool workspaceReady = false,
  int runtimeStatusCode = 200,
  int devicesStatusCode = 200,
  bool withReadyDevice = false,
  PinnedHttpFailureKind? workspaceTransportFailure,
}) =>
    LocalApiClient(
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
          return http.Response(
            jsonEncode(
              workspaceReady
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
        if (request.url.path == '/api/local/v1/workspace/runtime') {
          if (runtimeStatusCode != 200) {
            return http.Response('', runtimeStatusCode);
          }
          return http.Response(jsonEncode(_workspaceRuntime()), 200);
        }
        if (request.url.path == '/api/local/v1/devices') {
          if (devicesStatusCode != 200) {
            return http.Response('', devicesStatusCode);
          }
          return http.Response(
            jsonEncode(_deviceInventory(withReadyDevice: withReadyDevice)),
            200,
          );
        }
        return http.Response('', 404);
      }),
    );

void main() {
  testWidgets(
      'legacy claimed Host refreshes only TLS trust over BLE then authenticates on LAN',
      (tester) async {
    final transport = _LegacyHostTransport();
    ManagedHost? updated;
    String? pinnedFingerprint;

    await tester.pumpWidget(
      MaterialApp(
        home: HostLocalConnectionPage(
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
          host: _host(tlsSpkiFingerprint: _tlsFingerprint),
          transport: _LegacyHostTransport(),
          controllerKeys: _FakeControllerKeys(),
          discovery: _FakeDiscovery(),
          localApiClientFactory: (_) => _clientFor(
            _hostOverview(workspaceState: 'ready'),
            workspaceReady: true,
            runtimeStatusCode: 503,
          ),
          onHostUpdated: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('local-connection-complete')), findsOneWidget);
    expect(find.byKey(const Key('workspace-ready')), findsOneWidget);
    expect(find.byKey(const Key('local-connection-error')), findsNothing);
    expect(find.byKey(const Key('workspace-runtime-error')), findsOneWidget);
    expect(find.textContaining('日常运行状态暂时不可用'), findsOneWidget);
    // The Host card carries the Eidolon as one row now; what it has been and
    // what is connected to it live on its own page.
    expect(find.text('已创建'), findsNWidgets(2));
  });

  testWidgets('ready Workspace shows only Kernel-confirmed mounted devices',
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
    expect(find.text('设备详情'), findsOneWidget);
    expect(find.textContaining('不代表设备当前在线'), findsOneWidget);
  });

  testWidgets('setup continuation initializes Workspace without redoing claim',
      (tester) async {
    var initialized = false;
    var runtimeAvailable = false;
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
            if (request.url.path == '/api/local/v1/workspace/runtime') {
              expect(request.headers['authorization'],
                  'Bearer $validHostChallenge');
              if (!runtimeAvailable) {
                return http.Response('', 503);
              }
              return http.Response(jsonEncode(_workspaceRuntime()), 200);
            }
            return http.Response('', 404);
          }),
        );

    await tester.pumpWidget(
      MaterialApp(
        home: HostLocalConnectionPage(
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
    expect(find.byKey(const Key('workspace-runtime-error')), findsOneWidget);
    expect(find.textContaining('日常运行状态暂时不可用'), findsOneWidget);
    runtimeAvailable = true;
    await tester.tap(find.byKey(const Key('retry-workspace-runtime')));
    await tester.pumpAndSettle();

    // The rows are named for what they are to a person, not for the parts
    // they are built from: the Companion by its own name, and its persona by
    // the thing someone actually wonders about — how it has changed.
    expect(find.text('Eidolon'), findsOneWidget);
    expect(find.byKey(const Key('workspace-companion')), findsOneWidget);
    expect(find.textContaining('genome'), findsNothing);
    expect(find.text('Memory Workspace'), findsOneWidget);
    // The genome version used to be printed here. It said nothing to the
    // person it was printed at, and what it stood for now has a page.
    expect(find.textContaining('v2'), findsNothing);
    expect(find.text('运行中'), findsNWidgets(2));
    expect(find.byKey(const Key('workspace-runtime-error')), findsNothing);
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
}
