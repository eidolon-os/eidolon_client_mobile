import 'dart:async';
import 'dart:convert';

import 'package:eidolon_client_mobile/src/features/conversation/device_owner_directory.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/owner_authority_routes.dart';
import 'package:eidolon_client_mobile/src/features/device_setup/device_setup_models.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/local_api_discovery.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/network_changes.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/pinned_http_client.dart';
import 'package:eidolon_client_mobile/src/features/setup/host_registry.dart';
import 'package:eidolon_client_mobile/src/platform/app_preferences.dart';
import 'package:eidolon_client_mobile/src/generated/device_foundation_v1.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/host_session_fixtures.dart';
import 'support/local_api_fixtures.dart';
import 'support/owner_domain_fixtures.dart';

class _Network implements NetworkChanges {
  final events = StreamController<void>.broadcast(sync: true);
  @override
  Stream<void> get changes => events.stream;
  @override
  Future<void> close() => events.close();
}

class _Discovery implements LocalApiDiscovery {
  List<String> addresses = [];
  @override
  Future<LocalApiSurvey> discover(
          {Duration timeout = const Duration(seconds: 5)}) async =>
      announcedSurvey([
        for (final address in addresses)
          LocalApiEndpoint(
              instanceName: 'candidate',
              baseUrl: 'https://$address:9002',
              ipAddress: address,
              contractVersion: '1'),
      ]);
}

class _Client extends MockClient {
  _Client(super.fn, this.onClose);
  final void Function() onClose;
  @override
  void close() {
    onClose();
    super.close();
  }
}

final _pull =
    Uri.parse('https://owner-a.local/api/device-control/v1/configuration:pull');
final _admission =
    Uri.parse('https://owner-a.local/api/admission/v1/claims:acknowledge');

void main() {
  late InMemoryHostRegistry registry;
  late _Network network;
  late _Discovery discovery;
  final original = hostFixture(lastKnownBaseUrl: 'https://192.168.1.33:9002');
  setUp(() {
    registry = InMemoryHostRegistry([original]);
    network = _Network();
    discovery = _Discovery();
  });
  OwnerAuthorityRoutes routes(OwnerTransportBuilder transport) {
    final routes = OwnerAuthorityRoutes(
        registry: registry,
        networkChanges: network,
        discovery: discovery,
        transport: transport);
    addTearDown(routes.close);
    return routes;
  }

  test(
      'directory renewal, Admission and Device Control use registry IP without Controller bootstrap',
      () async {
    final calls = <String>[];
    final routing = routes((target, hints) => MockClient((request) async {
          expect(target.ownerRootCertificate, ownerRootCertificateFixture);
          expect(hints, {'owner-a.local': '192.168.1.33'});
          expect(request.url.host, 'owner-a.local');
          expect(request.headers.containsKey('authorization'), false);
          calls.add('${request.method} ${request.url.path}');
          if (request.method == 'GET') {
            return http.Response(
                jsonEncode(ownerDomainDescriptorJsonFixture), 200);
          }
          return http.Response('', request.method == 'HEAD' ? 404 : 200);
        }));
    final prefs = InMemoryAppPreferences();
    final directory = DeviceOwnerDirectory(
        preferences: prefs,
        verifier: const AcceptingOwnerDomainDirectoryVerifier(),
        routes: routing);
    await directory.open(
        hostId: original.hostId,
        bootstrap: () async => deviceOnboardingTargetFixture());
    final restored = await directory.open(
        hostId: original.hostId,
        bootstrap: () => throw StateError('Controller revoked'));
    final admission = directory.transport(restored);
    final control = directory.transport(restored);
    await admission.post(_admission,
        body: '{"nonce":"one","signature":"device"}');
    await control.post(_pull, body: '{"nonce":"two","signature":"device"}');
    admission.close();
    control.close();
    expect(calls, [
      'HEAD /',
      'GET /api/device-onboarding/v1/descriptor',
      'POST /api/admission/v1/claims:acknowledge',
      'POST /api/device-control/v1/configuration:pull'
    ]);
    expect((await prefs.readString('eidolon.device-owner-directory.v1'))!,
        isNot(contains('192.168.')));
  });

  test(
      'an already created client reads a moved Host address on its next request',
      () async {
    final sent = <String>[];
    final routing = routes((_, hints) => MockClient((request) async {
          if (request.method == 'POST') sent.add(hints['owner-a.local']!);
          return http.Response('', 200);
        }));
    final client =
        routing.client(deviceOnboardingTargetFixture(), () => original.hostId);
    addTearDown(client.close);
    await client.post(_pull);
    await registry
        .save(original.copyWith(lastKnownBaseUrl: 'https://192.168.2.9:9002'));
    await client.post(_pull);
    expect(sent, ['192.168.1.33', '192.168.2.9']);
  });

  test(
      'failed TLS candidate gets no Device act; discovered Owner keeps original signed request',
      () async {
    discovery.addresses = ['192.168.1.34'];
    final probes = <String>[];
    final acts = <String>[];
    final routing = routes((_, hints) => MockClient((request) async {
          final address = hints['owner-a.local']!;
          if (request.method == 'HEAD') {
            probes.add(address);
            if (address.endsWith('.33')) {
              throw PinnedHttpException(
                  kind: PinnedHttpFailureKind.secureChannel,
                  message: 'wrong Owner root');
            }
            return http.Response('', 405);
          }
          acts.add(address);
          expect(request.url, _admission);
          expect(request.body, '{"nonce":"only-once","signature":"device"}');
          return http.Response('', 200);
        }));
    final client =
        routing.client(deviceOnboardingTargetFixture(), () => original.hostId);
    addTearDown(client.close);
    await client.post(_admission,
        body: '{"nonce":"only-once","signature":"device"}');
    expect(probes, ['192.168.1.33', '192.168.1.34']);
    expect(acts, ['192.168.1.34']);
  });

  test(
      'concurrent APIs share public probe and cancelling one leaves the other alive',
      () async {
    final probing = Completer<void>();
    final response = Completer<http.Response>();
    var probeCount = 0;
    var posts = 0;
    var closedWhilePending = false;
    final routing = routes((_, hints) => _Client((request) async {
          if (request.method == 'HEAD') {
            probeCount++;
            probing.complete();
            return response.future;
          }
          posts++;
          return http.Response('', 200);
        }, () {
          if (!response.isCompleted) {
            closedWhilePending = true;
            response.completeError(PinnedHttpException(
                kind: PinnedHttpFailureKind.cancelled, message: 'closed'));
          }
        }));
    final one =
        routing.client(deviceOnboardingTargetFixture(), () => original.hostId);
    final two =
        routing.client(deviceOnboardingTargetFixture(), () => original.hostId);
    addTearDown(one.close);
    addTearDown(two.close);
    final first = one.post(_admission);
    final firstFailed = expectLater(first, throwsA(isA<PinnedHttpException>()));
    await probing.future;
    final second = two.post(_pull);
    await Future<void>.delayed(Duration.zero);
    one.close();
    await firstFailed;
    expect(closedWhilePending, false);
    response.complete(http.Response('', 404));
    await second;
    expect(probeCount, 1);
    expect(posts, 1);
  });

  test('closing the last waiting API cancels the native probe and sends no act',
      () async {
    final probing = Completer<void>();
    final response = Completer<http.Response>();
    var closed = false;
    var posts = 0;
    final routing = routes((_, hints) => _Client((request) async {
          if (request.method == 'HEAD') {
            probing.complete();
            return response.future;
          }
          posts++;
          return http.Response('', 200);
        }, () {
          closed = true;
          if (!response.isCompleted) {
            response.completeError(PinnedHttpException(
                kind: PinnedHttpFailureKind.cancelled, message: 'closed'));
          }
        }));
    final client =
        routing.client(deviceOnboardingTargetFixture(), () => original.hostId);
    final pending =
        expectLater(client.post(_pull), throwsA(isA<PinnedHttpException>()));
    await probing.future;
    client.close();
    await pending;
    expect(closed, true);
    expect(posts, 0);
  });

  test(
      'network change invalidates all Owner APIs and restarts only pending location reads',
      () async {
    final probing = Completer<void>();
    final stale = Completer<http.Response>();
    var probes = 0;
    final posts = <String>[];
    final routing = routes((_, hints) => _Client((request) async {
          final address = hints['owner-a.local']!;
          if (request.method == 'HEAD') {
            probes++;
            if (address.endsWith('.33')) {
              probing.complete();
              return stale.future;
            }
            return http.Response('', 200);
          }
          posts.add(address);
          return http.Response('', 200);
        }, () {
          if (hints['owner-a.local']!.endsWith('.33') && !stale.isCompleted) {
            stale.completeError(PinnedHttpException(
                kind: PinnedHttpFailureKind.cancelled,
                message: 'network changed'));
          }
        }));
    final client =
        routing.client(deviceOnboardingTargetFixture(), () => original.hostId);
    addTearDown(client.close);
    final pending = client.post(_pull);
    await probing.future;
    await registry
        .save(original.copyWith(lastKnownBaseUrl: 'https://192.168.2.34:9002'));
    network.events.add(null);
    await pending;
    expect(probes, 2);
    expect(posts, ['192.168.2.34']);
  });

  test(
      'network loss after sending an act cancels it without replaying the nonce',
      () async {
    final sending = Completer<void>();
    final response = Completer<http.Response>();
    var posts = 0;
    final routing = routes((_, hints) {
      var writing = false;
      return _Client((request) async {
        if (request.method == 'HEAD') {
          return http.Response('', 200);
        }
        writing = true;
        posts++;
        sending.complete();
        return response.future;
      }, () {
        if (writing && !response.isCompleted) {
          response.completeError(PinnedHttpException(
              kind: PinnedHttpFailureKind.cancelled,
              message: 'network changed'));
        }
      });
    });
    final client =
        routing.client(deviceOnboardingTargetFixture(), () => original.hostId);
    addTearDown(client.close);
    final failed = expectLater(
        client.post(_admission, body: '{"nonce":"once"}'),
        throwsA(isA<PinnedHttpException>()));
    await sending.future;
    network.events.add(null);
    await failed;
    expect(posts, 1);
  });

  test(
      'client refuses origins absent from the signed directory before transport creation',
      () async {
    var opened = false;
    final routing = routes((_, hints) {
      opened = true;
      return MockClient((_) async => http.Response('', 200));
    });
    final client =
        routing.client(deviceOnboardingTargetFixture(), () => original.hostId);
    addTearDown(client.close);
    await expectLater(
        client.post(Uri.parse('https://impostor.local/api/admission')),
        throwsA(isA<PinnedHttpException>()));
    expect(opened, false);
  });

  test(
      'a dropped Host invalidates cached location but never replays its failed act',
      () async {
    var moved = false;
    final attempts = <String>[];
    discovery.addresses = ['192.168.1.34'];
    final routing = routes((_, hints) => MockClient((request) async {
          final address = hints['owner-a.local']!;
          if (request.method == 'POST') attempts.add(address);
          if (moved && address.endsWith('.33')) {
            throw PinnedHttpException(
                kind: PinnedHttpFailureKind.unreachable, message: 'Wi-Fi lost');
          }
          return http.Response('', 200);
        }));
    final client =
        routing.client(deviceOnboardingTargetFixture(), () => original.hostId);
    addTearDown(client.close);
    await client.post(_pull);
    moved = true;
    await expectLater(
        client.post(_admission), throwsA(isA<PinnedHttpException>()));
    expect(attempts, ['192.168.1.33', '192.168.1.33']);
    await client.post(_admission);
    expect(attempts, ['192.168.1.33', '192.168.1.33', '192.168.1.34']);
  });

  test(
      'remote signed authority uses normal DNS without routing through selected Host',
      () async {
    final remote = DeviceOnboardingTarget(
      ownerDomainId: ownerDomainIdFixture,
      ownerRootCertificate: ownerRootCertificateFixture,
      authoritySigningCertificate: authoritySigningCertificateFixture,
      ownerDomainDescriptor: OwnerDomainDescriptorV1.fromJson({
        ...ownerDomainDescriptorJsonFixture,
        'descriptor_uri': 'https://owner.example/api/descriptor',
      }),
    );
    var calls = 0;
    final routing = routes((_, hints) => MockClient((request) async {
          expect(hints, isEmpty);
          expect(request.method, 'GET');
          calls++;
          return http.Response('', 200);
        }));
    await registry.remove(original.hostId);
    final client = routing.client(remote, () => original.hostId);
    addTearDown(client.close);
    await client.get(Uri.parse(remote.ownerDomainDescriptor.descriptorUri));
    expect(calls, 1);
  });

  test(
      'a new registry observation cancels an older lookup without waiting for its deadline',
      () async {
    final probing = Completer<void>();
    final stale = Completer<http.Response>();
    final posts = <String>[];
    final routing = routes((_, hints) => _Client((request) async {
          final address = hints['owner-a.local']!;
          if (request.method == 'HEAD' && address.endsWith('.33')) {
            probing.complete();
            return stale.future;
          }
          if (request.method == 'POST') posts.add(address);
          return http.Response('', 200);
        }, () {
          if (hints['owner-a.local']!.endsWith('.33') && !stale.isCompleted) {
            stale.completeError(PinnedHttpException(
                kind: PinnedHttpFailureKind.cancelled,
                message: 'location superseded'));
          }
        }));
    final client =
        routing.client(deviceOnboardingTargetFixture(), () => original.hostId);
    addTearDown(client.close);
    final old =
        expectLater(client.post(_pull), throwsA(isA<PinnedHttpException>()));
    await probing.future;
    await registry
        .save(original.copyWith(lastKnownBaseUrl: 'https://192.168.2.34:9002'));
    await client.post(_pull);
    await old;
    expect(posts, ['192.168.2.34']);
  });
}
