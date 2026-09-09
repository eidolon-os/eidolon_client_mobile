import 'package:eidolon_client_mobile/src/models/conversation_mode.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/host_locator.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/local_api_candidate_sources.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/local_api_discovery.dart';
import 'package:eidolon_client_mobile/src/features/setup/host_registry.dart';
import 'package:eidolon_client_mobile/src/controller/client_controller.dart';
import 'package:eidolon_client_mobile/src/features/conversation/conversation_provisioner.dart';
import 'package:eidolon_client_mobile/src/models/hub_models.dart';
import 'package:eidolon_client_mobile/src/services/eidolon_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'support/phone_identity_fixtures.dart';

/// A name is a way to learn an address, never a way to address a Host.
///
/// Found on a real phone: 「连接我的 Eidolon」 spun for thirty seconds and said
/// 「无法连接到 Hub / 请检查局域网连接」, with
/// `Unable to resolve host "eidolon-pi5.local"` in the technical details —
/// while the Host was up at 192.168.3.206, on the same Wi-Fi, answering a ping,
/// and the management screens were talking to it at that moment.
///
/// Two resolvers, not one. The probe below resolves in Dart; the request goes
/// out through the Android pinned transport, whose OkHttp client resolves with
/// getaddrinfo — and Android's getaddrinfo does not resolve `.local` at all.
/// So a candidate could be proved reachable and then handed over in a form the
/// transport could never dial, on every Android phone.
void main() {
  group('the hostname probe', () {
    test('dials the address it proved, not the name it started from',
        () async {
      final report = await HostnameLocalApiSource(
        names: const ['eidolon-pi5.local'],
        port: 9002,
        resolve: (name) async => const ['192.168.3.206'],
        probePort: (host, port, timeout) async => host == '192.168.3.206',
      ).probe(timeout: const Duration(seconds: 1));

      final endpoint = report.candidates.single.endpoint;
      expect(endpoint.baseUrl, 'https://192.168.3.206:9002');
      expect(endpoint.baseUrl, isNot(contains('.local')));
      // The name is not lost — it is just not the address.
      expect(endpoint.instanceName, 'eidolon-pi5.local');
      expect(endpoint.ipAddress, '192.168.3.206');
    });

    test('a name that will not resolve offers nothing', () async {
      final report = await HostnameLocalApiSource(
        names: const ['eidolon-pi5.local'],
        resolve: (name) async => const [],
        probePort: (host, port, timeout) async => true,
      ).probe(timeout: const Duration(seconds: 1));

      expect(report.candidates, isEmpty);
    });

    // The defect: `eidolon-pi5.local` was compiled into the App. One binary
    // serves every household, and before a Host is claimed the phone does not
    // know which Host it will meet — so a build-time name is right for one
    // installation and by the time this was found it matched no Host in
    // service. Names are supplied now, and only ever learned ones.
    test('a phone with no learned name stands the probe down', () async {
      final report = await HostnameLocalApiSource(
        resolve: (_) async => throw StateError('nothing to resolve'),
        probePort: (_, __, ___) async => throw StateError('nothing to dial'),
      ).probe(timeout: const Duration(milliseconds: 50));

      expect(report.candidates, isEmpty);
      expect(report.unavailable, isNotNull);
    });
  });

  group('the names a phone has learned', () {
    ManagedHost remembering(String? url) => ManagedHost(
          hostId: 'host-01',
          displayName: 'Host',
          hostPublicKey: 'key',
          hostFingerprint: 'sha256:aa',
          bleServiceUuid: '0000',
          controllerId: 'ectrl-01',
          claimedAt: DateTime.utc(2026, 9, 8),
          tlsSpkiFingerprint: 'sha256:bb',
          lastKnownBaseUrl: url,
        );

    test('a name a Host actually answered on is one to try again', () {
      expect(
        hostNamesRemembered(remembering('https://orangepi5-max.local:9002')),
        ['orangepi5-max.local'],
      );
    });

    test('an address is not a name, and resolving one leads nowhere', () {
      expect(
        hostNamesRemembered(remembering('https://192.168.1.33:9002')),
        isEmpty,
      );
    });

    test('a Host never yet reached offers nothing rather than a guess', () {
      expect(hostNamesRemembered(remembering(null)), isEmpty);
    });
  });

  group('the locator', () {
    ManagedHost host({String? lastKnownBaseUrl}) => ManagedHost(
          hostId: 'host-01',
          displayName: 'Pi5',
          hostPublicKey: 'key',
          hostFingerprint: 'sha256:aa',
          bleServiceUuid: '0000',
          controllerId: 'ectrl-01',
          claimedAt: DateTime.utc(2026, 8, 27),
          tlsSpkiFingerprint: 'sha256:bb',
          lastKnownBaseUrl: lastKnownBaseUrl,
        );

    Future<List<String>> dialled(
      HostLocator locator,
      ManagedHost value,
    ) async {
      final urls = <String>[];
      await for (final tier in locator.locate(value)) {
        for (final candidate in tier) {
          urls.add(candidate.endpoint.baseUrl);
        }
      }
      return urls;
    }

    test('a remembered name is resolved before it is offered', () async {
      // This is the case that survives fixing the probe: a `.local` base URL
      // that once connected is persisted as lastKnownBaseUrl, so it comes back
      // on every reconnect until something resolves it.
      final locator = HostLocator(
        [const RememberedAddressSource()],
        resolve: (name) async =>
            name == 'eidolon-pi5.local' ? const ['192.168.3.206'] : const [],
      );

      expect(
        await dialled(
          locator,
          host(lastKnownBaseUrl: 'https://eidolon-pi5.local:9002'),
        ),
        ['https://192.168.3.206:9002'],
      );
    });

    test('a remembered name that will not resolve is dropped, not dialled',
        () async {
      final locator = HostLocator(
        [const RememberedAddressSource()],
        resolve: (name) async => const [],
      );

      expect(
        await dialled(
          locator,
          host(lastKnownBaseUrl: 'https://eidolon-pi5.local:9002'),
        ),
        isEmpty,
      );
    });

    test('an address is passed through untouched', () async {
      var resolverCalls = 0;
      final locator = HostLocator(
        [const RememberedAddressSource()],
        resolve: (name) async {
          resolverCalls += 1;
          return const [];
        },
      );

      expect(
        await dialled(
          locator,
          host(lastKnownBaseUrl: 'https://192.168.3.206:9002'),
        ),
        ['https://192.168.3.206:9002'],
      );
      expect(resolverCalls, 0);
    });

    test('nothing the transport cannot dial reaches a candidate', () async {
      final locator = HostLocator(
        [_Source(const ['https://eidolon-pi5.local:9002', 'https://10.0.0.5:9002'])],
        resolve: (name) async => const [],
      );

      final urls = await dialled(locator, host());

      expect(urls, ['https://10.0.0.5:9002']);
    });
  });

  group('what the conversation screen says about it', () {
    Future<ClientController> attempt(Object error) async {
      final controller = ClientController(
        platform: FakePhonePlatform(),
        session: _Session(),
        conversationProvisioner: _ThrowingProvisioner(error),
      );
      await controller.start();
      addTearDown(controller.dispose);
      return controller;
    }

    test('an unresolvable name is not the person\'s network to check',
        () async {
      final controller = await attempt(
        http.ClientException(
          'Unable to resolve host "eidolon-pi5.local": '
              'No address associated with hostname',
          Uri.parse('https://eidolon-pi5.local:9002/api/local/v1/host'),
        ),
      );

      final failure = controller.failure!;
      expect(failure.message, isNot(contains('请检查局域网连接')));
      expect(failure.message, contains('eidolon-pi5.local'));
      expect(failure.message, contains('.local'));
      // And no retry, because retrying cannot resolve what the resolver will
      // not resolve. This was the sixth screen today whose only action was one
      // that could never succeed.
      expect(failure.retryable, isFalse);
    });

    test('an address that cannot be reached is still a network fact', () async {
      final controller = await attempt(
        http.ClientException(
          'Failed to connect to /192.168.3.206:9002',
          Uri.parse('https://192.168.3.206:9002/api/local/v1/host'),
        ),
      );

      final failure = controller.failure!;
      expect(failure.title, '无法连接到 Hub');
      expect(failure.message, contains('请检查局域网连接'));
      expect(failure.retryable, isTrue);
    });
  });
}

class _ThrowingProvisioner implements ConversationProvisioner {
  _ThrowingProvisioner(this.error);

  final Object error;

  @override
  String get serviceName => 'owner-domain_01';

  @override
  Uri get serviceUri => Uri.parse('https://hub.example/admission');

  @override
  Future<HubConfig> provision({String sessionIntent = '', ConversationMode? mode}) async => throw error;
}

class _Session extends EidolonSession {
  @override
  bool get isConnected => false;

  @override
  Future<void> connect(RoomConfig config) async {}
}

class _Source implements HostAddressSource {
  const _Source(this.urls);

  final List<String> urls;

  @override
  HostAddressEvidence get evidence => HostAddressEvidence.announced;

  @override
  Future<List<LocalApiEndpoint>> locate(ManagedHost host) async => [
        for (final url in urls)
          LocalApiEndpoint(
            instanceName: 'offered',
            baseUrl: url,
            ipAddress: Uri.parse(url).host,
            contractVersion: '1',
          ),
      ];
}
