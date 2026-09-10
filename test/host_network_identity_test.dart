import 'dart:async';

import 'package:eidolon_client_mobile/src/features/host_setup/host_locator.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/host_product_session.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/local_api_client.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/local_api_discovery.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/pinned_http_client.dart';
import 'package:eidolon_client_mobile/src/features/setup/host_list_info.dart';
import 'package:eidolon_client_mobile/src/features/setup/host_registry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';

import 'support/host_session_fixtures.dart';
import 'support/local_api_fixtures.dart';

LocalApiSurvey survey(String address) => announcedSurvey([
      LocalApiEndpoint(
          instanceName: 'Mac',
          baseUrl: 'https://$address:9002',
          ipAddress: address,
          contractVersion: '1'),
    ]);

class Discovery implements LocalApiDiscovery {
  Discovery(this.read);
  final Future<LocalApiSurvey> Function() read;
  int calls = 0;
  @override
  Future<LocalApiSurvey> discover(
      {Duration timeout = const Duration(seconds: 5)}) {
    calls++;
    return read();
  }
}

void main() {
  test('list relocates a saved Host with a stale IP and preserves its identity',
      () async {
    final original = hostFixture(lastKnownBaseUrl: 'https://192.168.1.9:9002')
        .copyWith(displayName: '书房 Mac');
    final registry = InMemoryHostRegistry([original]);
    final discovery = Discovery(() async => survey('10.0.0.9'));
    final dialled = <String>[];
    final result = await readHostListInfo(
      original,
      discovery: discovery,
      controllerKeys: FakeControllerKeys(),
      clientFactory: (_) => LocalApiClient(httpClient: MockClient((request) {
        dialled.add(request.url.host);
        return hostSessionResponse(request);
      })),
      managementClientFactory: (_) => throw StateError('monitor unavailable'),
    );
    await registry.updateObservation(result.host);
    final hosts = await registry.load();
    expect(hosts, hasLength(1));
    expect(hosts.single.hostId, original.hostId);
    expect(hosts.single.claimedAt, original.claimedAt);
    expect(hosts.single.displayName, '书房 Mac');
    expect(hosts.single.lastKnownBaseUrl, 'https://10.0.0.9:9002');
    expect(result.status, startsWith('可连接'));
    expect(dialled.toSet(), {'10.0.0.9'});
  });

  test(
      'a list refresh shares one discovery pass and the next refresh starts fresh',
      () async {
    final discovery = Discovery(() async => survey('10.0.0.9'));
    final pass = LocalApiDiscoveryPass(discovery);
    await Future.wait([pass.discover(), pass.discover()]);
    await pass.discover();
    expect(discovery.calls, 1);
    await LocalApiDiscoveryPass(discovery).discover();
    expect(discovery.calls, 2);
  });

  test('a wrong device at the old IP cannot prevent finding the Host elsewhere',
      () async {
    final host = hostFixture(lastKnownBaseUrl: 'https://192.168.1.9:9002');
    var published = 0;
    final session = HostProductSession(
      host: host,
      transport: NoopTransport(),
      controllerKeys: FakeControllerKeys(),
      locator: HostLocator([
        const RememberedAddressSource(),
        PublishedAddressSource((_) async {
          published++;
          return ['https://10.0.0.9:9002'];
        }),
      ]),
      clientFactory: (_) =>
          LocalApiClient(httpClient: MockClient((request) async {
        if (request.url.host == '192.168.1.9') {
          throw PinnedHttpException(
              kind: PinnedHttpFailureKind.secureChannel,
              message: 'another device owns the old IP');
        }
        return hostSessionResponse(request);
      })),
    );
    addTearDown(session.close);
    final connected = await session.connect();
    expect(connected.hostId, host.hostId);
    expect(connected.lastKnownBaseUrl, 'https://10.0.0.9:9002');
    expect(published, 1);
  });

  test(
      'concurrent connects share relocation and never publish an obsolete network',
      () async {
    final pending = Completer<LocalApiSurvey>();
    var round = 0;
    final discovery = Discovery(
        () async => ++round == 1 ? await pending.future : survey('10.0.0.9'));
    final updates = <ManagedHost>[];
    final session = HostProductSession(
      host: hostFixture(),
      transport: NoopTransport(),
      controllerKeys: FakeControllerKeys(),
      discovery: discovery,
      clientFactory: (_) =>
          LocalApiClient(httpClient: MockClient(hostSessionResponse)),
      onHostConnected: (host) async => updates.add(host),
    );
    addTearDown(session.close);
    final first = session.connect();
    final second = session.connect();
    expect(identical(first, second), isTrue);
    await Future<void>.delayed(Duration.zero);
    session.invalidateLocation();
    pending.complete(survey('192.168.1.9'));
    await Future.wait([first, second]);
    expect(updates, hasLength(1));
    expect(updates.single.lastKnownBaseUrl, 'https://10.0.0.9:9002');
    expect(discovery.calls, 2);
  });

  test(
      'an authenticated machine name remains a locator hint after saving a numeric IP',
      () {
    final host = hostFixture(lastKnownBaseUrl: 'https://192.168.1.9:9002')
        .copyWith(machineInfo: const HostMachineInfo(hostname: 'study-mac'));
    expect(hostNamesRemembered(host), ['study-mac.local']);
  });
}
