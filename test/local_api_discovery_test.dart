import 'dart:async';

import 'package:eidolon_client_mobile/src/features/host_setup/local_api_candidate_sources.dart';
import 'package:eidolon_client_mobile/src/features/host_setup/local_api_discovery.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// A source that answers from a script, so a survey can be assembled without a
/// network.
class _ScriptedSource implements LocalApiCandidateSource {
  _ScriptedSource(
    this.origin,
    this._report, {
    this.gate,
  });

  @override
  final LocalApiCandidateOrigin origin;

  final LocalApiSourceReport Function(LocalApiCandidateOrigin origin) _report;

  /// Held open so a test can prove every probe was started before any of them
  /// finished.
  final Future<void>? gate;

  var started = 0;

  @override
  Future<LocalApiSourceReport> probe({required Duration timeout}) async {
    started += 1;
    if (gate != null) await gate;
    return _report(origin);
  }
}

LocalApiSourceReport _found(
  LocalApiCandidateOrigin origin,
  String baseUrl, {
  String ipAddress = '192.168.3.206',
}) =>
    LocalApiSourceReport(
      origin: origin,
      attempted: 'scripted',
      candidates: [
        LocalApiCandidate(
          origin: origin,
          endpoint: LocalApiEndpoint(
            instanceName: 'Eidolon Local API',
            baseUrl: baseUrl,
            ipAddress: ipAddress,
            contractVersion: '1',
          ),
        ),
      ],
    );

LocalApiSourceReport _silent(LocalApiCandidateOrigin origin) =>
    LocalApiSourceReport(origin: origin, attempted: 'scripted');

void main() {
  test(
      'a stalled hostname resolver cannot hold the survey or dial after its deadline',
      () async {
    final unresolved = Completer<List<String>>();
    var sockets = 0;
    final discovery = MultiSourceLocalApiDiscovery([
      _ScriptedSource(LocalApiCandidateOrigin.announced,
          (origin) => _found(origin, 'https://192.168.1.33:9002')),
      HostnameLocalApiSource(
          names: ['missing.local'],
          resolve: (_) => unresolved.future,
          probePort: (address, port, timeout) async {
            sockets++;
            return true;
          }),
    ]);
    final survey =
        await discovery.discover(timeout: const Duration(milliseconds: 20));
    expect(survey.endpoints.single.baseUrl, 'https://192.168.1.33:9002');
    unresolved.complete(['192.168.1.32']);
    await Future<void>.delayed(Duration.zero);
    expect(sockets, 0);
  });

  group('a discovered service that names another contract', () {
    test('is incompatible rather than invalid', () {
      expect(
        () => LocalApiEndpoint.fromMap(const {
          'instanceName': 'Eidolon Local API',
          'baseUrl': 'https://192.168.3.206:9002',
          'ipAddress': '192.168.3.206',
          'contractVersion': '2',
        }),
        throwsA(
          isA<LocalApiIncompatibleException>()
              .having((error) => error.contractVersion, 'contractVersion', '2')
              .having(
                (error) => error.baseUrl,
                'baseUrl',
                'https://192.168.3.206:9002',
              ),
        ),
      );
    });

    test('is still invalid when the announcement itself is malformed', () {
      expect(
        () => LocalApiEndpoint.fromMap(const {
          'instanceName': 'Eidolon Local API',
          'baseUrl': 'http://192.168.3.206:9002',
          'ipAddress': '192.168.3.206',
          'contractVersion': '2',
        }),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('the service browse', () {
    const channelName = 'live.eidolon.mobile/platform';
    late TestDefaultBinaryMessenger messenger;

    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    });

    tearDown(() {
      messenger.setMockMethodCallHandler(
        const MethodChannel(channelName),
        null,
      );
      debugDefaultTargetPlatformOverride = null;
    });

    void answer(Future<Object?> Function(MethodCall call) handler) {
      messenger.setMockMethodCallHandler(
        const MethodChannel(channelName),
        handler,
      );
    }

    test('reports silence as an answer instead of an error', () async {
      answer((_) async => const <Object?>[]);

      final report = await AnnouncedLocalApiSource().probe(
        timeout: const Duration(seconds: 1),
      );

      expect(report.candidates, isEmpty);
      expect(report.incompatible, isEmpty);
      expect(report.unavailable, isNull);
    });

    test('keeps an incompatible answer apart from a usable one', () async {
      answer(
        (_) async => const <Object?>[
          {
            'instanceName': 'Eidolon Local API',
            'baseUrl': 'https://192.168.3.206:9002',
            'ipAddress': '192.168.3.206',
            'contractVersion': '1',
          },
          {
            'instanceName': 'Eidolon Local API',
            'baseUrl': 'https://192.168.3.207:9002',
            'ipAddress': '192.168.3.207',
            'contractVersion': '9',
          },
          {'instanceName': 'broken'},
        ],
      );

      final report = await AnnouncedLocalApiSource().probe(
        timeout: const Duration(seconds: 1),
      );

      expect(
        report.candidates.map((candidate) => candidate.endpoint.baseUrl),
        ['https://192.168.3.206:9002'],
      );
      expect(report.incompatible.single.contractVersion, '9');
      expect(report.unavailable, isNull);
    });

    test('says the mechanism failed when the platform refuses', () async {
      answer(
        (_) async => throw PlatformException(
          code: 'DISCOVERY_FAILED',
          message: 'NSD start failed: 3',
        ),
      );

      final report = await AnnouncedLocalApiSource().probe(
        timeout: const Duration(seconds: 1),
      );

      expect(report.unavailable, contains('DISCOVERY_FAILED'));
      expect(report.candidates, isEmpty);
    });
  });

  group('resolving a known Host name', () {
    test('offers whatever answers on the Local API port', () async {
      final probed = <String>[];
      final source = HostnameLocalApiSource(
        names: const ['eidolon-pi5.local', 'eidolon-absent.local'],
        resolve: (name) async =>
            name == 'eidolon-pi5.local' ? ['192.168.3.206'] : const [],
        probePort: (host, port, _) async {
          probed.add('$host:$port');
          return true;
        },
      );

      final report = await source.probe(timeout: const Duration(seconds: 1));

      expect(probed, ['192.168.3.206:$localApiPort']);
      // This used to assert `https://eidolon-pi5.local:$localApiPort` — the
      // name — which is how the defect stayed green. The probe just above
      // resolves in Dart, and the request that follows goes out through the
      // Android pinned transport, whose OkHttp client resolves with
      // getaddrinfo: Android does not resolve `.local` there at all. So the
      // source proved an address worked and handed back one the transport
      // could never dial, and a phone with the Host up, pingable, and its
      // management screens live was told 「无法连接到 Hub / 请检查局域网连接」.
      //
      // What is probed is what must be dialled.
      expect(report.candidates.single.endpoint.baseUrl,
          'https://192.168.3.206:$localApiPort');
      expect(report.candidates.single.endpoint.ipAddress, '192.168.3.206');
      // The name is still what was attempted, and still names the instance.
      expect(
          report.candidates.single.endpoint.instanceName, 'eidolon-pi5.local');
      expect(report.attempted, contains('eidolon-pi5.local'));
    });

    test('a name that resolves but does not answer is not a candidate',
        () async {
      final source = HostnameLocalApiSource(
        names: const ['eidolon-pi5.local'],
        resolve: (_) async => ['192.168.3.206'],
        probePort: (_, __, ___) async => false,
      );

      final report = await source.probe(timeout: const Duration(seconds: 1));

      expect(report.candidates, isEmpty);
      expect(report.unavailable, isNull);
    });
  });

  group('sweeping this phone\'s own subnet', () {
    test('probes its /24, skips itself and never exceeds its concurrency',
        () async {
      final probed = <String>[];
      var inFlight = 0;
      var peak = 0;
      final source = SubnetLocalApiSource(
        concurrency: 4,
        localAddresses: () async => ['192.168.3.207'],
        probePort: (host, port, _) async {
          inFlight += 1;
          peak = peak > inFlight ? peak : inFlight;
          await Future<void>.delayed(Duration.zero);
          inFlight -= 1;
          probed.add(host);
          return host == '192.168.3.206';
        },
      );

      final report = await source.probe(timeout: const Duration(seconds: 5));

      expect(probed, hasLength(253));
      expect(probed, isNot(contains('192.168.3.207')));
      expect(probed, contains('192.168.3.1'));
      expect(probed, contains('192.168.3.254'));
      expect(peak, lessThanOrEqualTo(4));
      expect(report.candidates.single.endpoint.baseUrl,
          'https://192.168.3.206:$localApiPort');
      expect(report.attempted, contains('192.168.3.0/24'));
    });

    test('refuses to sweep anything that is not a private LAN', () async {
      final source = SubnetLocalApiSource(
        localAddresses: () async => ['203.0.113.9'],
        probePort: (_, __, ___) async =>
            fail('a public range must never be swept'),
      );

      final report = await source.probe(timeout: const Duration(seconds: 1));

      expect(report.candidates, isEmpty);
      expect(report.unavailable, isNotNull);
    });
  });

  group('the survey', () {
    // The defect itself: this phone had exactly one way of producing a
    // candidate, and its failure was reported as "no Host on the LAN" while the
    // Host answered a direct request from the same tablet.
    test('a phone asks all three probes, not only the announcement', () {
      final discovery =
          platformLocalApiDiscovery() as MultiSourceLocalApiDiscovery;

      expect(discovery.sources.map((source) => source.origin), [
        LocalApiCandidateOrigin.announced,
        LocalApiCandidateOrigin.hostname,
        LocalApiCandidateOrigin.subnet,
      ]);
    });

    test('a silent service browse does not hide a reachable Host', () async {
      final discovery = MultiSourceLocalApiDiscovery([
        _ScriptedSource(LocalApiCandidateOrigin.announced, _silent),
        _ScriptedSource(LocalApiCandidateOrigin.hostname, _silent),
        _ScriptedSource(
          LocalApiCandidateOrigin.subnet,
          (origin) => _found(origin, 'https://192.168.3.206:9002'),
        ),
      ]);

      final survey = await discovery.discover();

      expect(survey.sawNothing, isFalse);
      expect(survey.endpoints.single.baseUrl, 'https://192.168.3.206:9002');
      expect(
        survey.candidates.single.origin,
        LocalApiCandidateOrigin.subnet,
      );
    });

    test('asks every source at once rather than one after another', () async {
      final gate = Completer<void>();
      final sources = [
        _ScriptedSource(
          LocalApiCandidateOrigin.announced,
          _silent,
          gate: gate.future,
        ),
        _ScriptedSource(
          LocalApiCandidateOrigin.hostname,
          _silent,
          gate: gate.future,
        ),
        _ScriptedSource(
          LocalApiCandidateOrigin.subnet,
          _silent,
          gate: gate.future,
        ),
      ];
      final discovery = MultiSourceLocalApiDiscovery(sources);

      final pending = discovery.discover();
      await Future<void>.delayed(Duration.zero);

      expect(sources.map((source) => source.started), [1, 1, 1]);
      gate.complete();
      await pending;
    });

    test('keeps one address once, whichever source found it first', () async {
      final discovery = MultiSourceLocalApiDiscovery([
        _ScriptedSource(
          LocalApiCandidateOrigin.announced,
          (origin) => _found(origin, 'https://192.168.3.206:9002'),
        ),
        _ScriptedSource(
          LocalApiCandidateOrigin.subnet,
          (origin) => _found(origin, 'https://192.168.3.206:9002'),
        ),
      ]);

      final survey = await discovery.discover();

      expect(survey.candidates, hasLength(1));
      expect(
        survey.candidates.single.origin,
        LocalApiCandidateOrigin.announced,
      );
    });

    test('a source that throws does not lose what the others found', () async {
      final discovery = MultiSourceLocalApiDiscovery([
        _ScriptedSource(
          LocalApiCandidateOrigin.announced,
          (_) => throw StateError('browse exploded'),
        ),
        _ScriptedSource(
          LocalApiCandidateOrigin.subnet,
          (origin) => _found(origin, 'https://192.168.3.206:9002'),
        ),
      ]);

      final survey = await discovery.discover();

      expect(survey.endpoints, hasLength(1));
      expect(
        survey.sources
            .firstWhere(
                (report) => report.origin == LocalApiCandidateOrigin.announced)
            .unavailable,
        contains('browse exploded'),
      );
    });

    test('names every source it tried, so silence can be read', () async {
      final discovery = MultiSourceLocalApiDiscovery([
        _ScriptedSource(LocalApiCandidateOrigin.announced, _silent),
        _ScriptedSource(LocalApiCandidateOrigin.hostname, _silent),
        _ScriptedSource(LocalApiCandidateOrigin.subnet, _silent),
      ]);

      final survey = await discovery.discover();
      final described = survey.describeAttempts();

      expect(survey.sawNothing, isTrue);
      expect(described, contains('mDNS 服务浏览'));
      expect(described, contains('按名解析'));
      expect(described, contains('本网段探测'));
    });
  });
}
