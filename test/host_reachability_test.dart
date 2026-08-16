import 'dart:convert';

import 'package:eidolon_client_mobile/src/features/host_setup/host_locator.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/host_product_session.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/local_api_client.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/local_api_discovery.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/pinned_http_client.dart';
import 'package:eidolon_client_mobile/src/features/setup/host_registry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/host_session_fixtures.dart';

/// The scenarios 已认领主机的可达性架构.md §4 requires to be invisible.
void main() {
  group('an address is the most perishable thing the App holds', () {
    test('what answered the announcement is offered before what was remembered',
        () async {
      // A Host that moved is found where it moved to; the remembered address
      // is stale by definition once something answers now.
      final locator = HostLocator([
        _Source(HostAddressEvidence.announced, ['https://192.168.3.206:9002']),
        const RememberedAddressSource(),
      ]);

      final tiers = await locator
          .locate(hostFixture(lastKnownBaseUrl: 'https://192.168.100.15:9002'))
          .toList();

      expect(tiers.first.single.endpoint.baseUrl, 'https://192.168.3.206:9002');
      expect(tiers.first.single.evidence, HostAddressEvidence.announced);
      // Still offered, but only after the fresher one has failed to answer:
      // later is deferred, never skipped.
      expect(tiers.last.single.evidence, HostAddressEvidence.remembered);
    });

    test('silence on one means is not silence everywhere', () async {
      // Same Wi-Fi, same subnet, ping fine, and no announcement reaching this
      // phone. A Host already claimed must not become unreachable for it.
      final locator = HostLocator([
        _Source.failing(HostAddressEvidence.announced),
        const RememberedAddressSource(),
      ]);

      final tiers = await locator
          .locate(hostFixture(lastKnownBaseUrl: 'https://192.168.3.206:9002'))
          .toList();

      expect(tiers.single.single.evidence, HostAddressEvidence.remembered);
    });

    test('a costly means is not consulted while a cheap one has answers',
        () async {
      // Reading the Host's own statement costs a permission, a scan and a
      // connection. Paying that when an announcement already answered would
      // make every connection slower for a case that did not arise.
      var published = 0;
      final locator = HostLocator([
        _Source(HostAddressEvidence.announced, ['https://192.168.3.206:9002']),
        PublishedAddressSource((_) async {
          published += 1;
          return ['https://192.168.3.206:9002'];
        }),
      ]);

      final first = await locator.locate(hostFixture()).first;

      expect(first.single.evidence, HostAddressEvidence.announced);
      expect(published, 0);
    });

    test('when nothing was learned at all, the first reason travels', () async {
      final locator = HostLocator([
        _Source.failing(HostAddressEvidence.announced),
        const RememberedAddressSource(),
      ]);

      await expectLater(
        locator.locate(hostFixture()).toList(),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('the conversation survives the address changing under it', () {
    test('a Host that stopped answering is looked for again, and the '
        'operation simply completes', () async {
      // The Host moved while the App was open. Nothing above this layer should
      // learn that anything happened.
      var announced = 'https://192.168.3.206:9002';
      var reachable = announced;
      var workspaceCalls = 0;

      final session = HostProductSession(
        host: hostFixture(),
        transport: NoopTransport(),
        controllerKeys: FakeControllerKeys(),
        locator: HostLocator([
          _Source.dynamic(HostAddressEvidence.announced, () => [announced]),
        ]),
        clientFactory: (_) => LocalApiClient(
          httpClient: MockClient((request) async {
            if (!request.url.toString().startsWith(reachable)) {
              throw PinnedHttpException(
                kind: PinnedHttpFailureKind.unreachable,
                message: 'no route',
              );
            }
            if (request.url.path == '/api/local/v1/setup/workspace') {
              workspaceCalls += 1;
              return http.Response(jsonEncode(workspaceBody()), 200);
            }
            return hostSessionResponse(request);
          }),
        ),
      );
      addTearDown(session.close);
      await session.connect();

      // Same machine, new address; the old one answers nothing.
      announced = 'https://192.168.3.99:9002';
      reachable = announced;

      final workspace = await session.execute(
        (client, baseUrl, token) =>
            client.fetchWorkspace(baseUrl, accessToken: token),
      );

      // It completed. That it completed at a different address than the one
      // this session started on is the entire point, and nothing above this
      // layer had to know.
      expect(workspace, isNotNull);
      expect(workspaceCalls, 1);
      expect(session.connection?.endpoint.baseUrl, announced);
    });

    test('a Host that answered and refused is not looked for again', () async {
      // It decided something. Re-locating would hide what it said.
      var attempts = 0;
      final session = HostProductSession(
        host: hostFixture(),
        transport: NoopTransport(),
        controllerKeys: FakeControllerKeys(),
        locator: HostLocator([
          _Source(HostAddressEvidence.announced, ['https://10.0.0.5:9002']),
        ]),
        clientFactory: (_) => LocalApiClient(
          httpClient: MockClient((request) async {
            if (request.url.path == '/api/local/v1/setup/workspace') {
              attempts += 1;
              return http.Response('{"detail":"nope"}', 409);
            }
            return hostSessionResponse(request);
          }),
        ),
      );
      addTearDown(session.close);
      await session.connect();

      await expectLater(
        session.execute(
          (client, baseUrl, token) =>
              client.fetchWorkspace(baseUrl, accessToken: token),
        ),
        throwsA(isA<LocalApiRequestException>()),
      );
      expect(attempts, 1);
    });

    test('this phone changing network drops the address, not the Host',
        () async {
      final session = HostProductSession(
        host: hostFixture(),
        transport: NoopTransport(),
        controllerKeys: FakeControllerKeys(),
        locator: HostLocator([
          _Source(HostAddressEvidence.announced, ['https://10.0.0.5:9002']),
        ]),
        clientFactory: (_) =>
            LocalApiClient(httpClient: MockClient(hostSessionResponse)),
      );
      addTearDown(session.close);
      await session.connect();
      expect(session.connection, isNotNull);

      session.invalidateLocation();

      // Who the Host is survives; only where it was does not.
      expect(session.connection, isNull);
      expect(session.host.hostId, hostFixture().hostId);
    });
  });
}

class _Source implements HostAddressSource {
  _Source(this.evidence, List<String> urls) : _urls = (() => urls);
  _Source.dynamic(this.evidence, this._urls);
  _Source.failing(this.evidence)
      : _urls = (() => throw StateError('nothing announced'));

  @override
  final HostAddressEvidence evidence;
  final List<String> Function() _urls;

  @override
  Future<List<LocalApiEndpoint>> locate(ManagedHost host) async => _urls()
      .map(
        (url) => LocalApiEndpoint(
          instanceName: 'fake',
          baseUrl: url,
          ipAddress: Uri.parse(url).host,
          contractVersion: '1',
        ),
      )
      .toList();
}
