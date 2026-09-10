import 'dart:io';

/// Where the Host's Local API answers when nothing told us otherwise.
///
/// A service browse carries the port in its SRV record; a name and a swept
/// address carry nothing, so those two have to assume the published default.
/// Kept here as one constant rather than spelled into each probe so that the
/// day it becomes configurable there is a single place that is wrong.
const int localApiPort = 9002;

class LocalApiEndpoint {
  const LocalApiEndpoint({
    required this.instanceName,
    required this.baseUrl,
    required this.ipAddress,
    required this.contractVersion,
  });

  /// Reads one announcement.
  ///
  /// The two failures are kept apart on purpose. A malformed announcement is
  /// noise and is dropped. A well-formed announcement naming a contract this
  /// App does not speak is a *Host that is there* and cannot be talked to —
  /// collapsing that into "invalid" is how an incompatible Host came to be
  /// reported as no Host at all, leaving the person holding the phone with
  /// nothing to act on.
  factory LocalApiEndpoint.fromMap(Map<Object?, Object?> value) {
    final instanceName = value['instanceName'];
    final baseUrl = value['baseUrl'];
    final ipAddress = value['ipAddress'];
    final contractVersion = value['contractVersion'];
    final uri = baseUrl is String ? Uri.tryParse(baseUrl) : null;
    final parsedAddress =
        ipAddress is String ? InternetAddress.tryParse(ipAddress) : null;
    if (instanceName is! String ||
        instanceName.isEmpty ||
        baseUrl is! String ||
        uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        parsedAddress == null ||
        contractVersion is! String ||
        contractVersion.isEmpty) {
      throw const FormatException('发现了无效的 Eidolon Local API 服务');
    }
    if (contractVersion != '1') {
      throw LocalApiIncompatibleException(
        IncompatibleLocalApi(
          baseUrl: baseUrl,
          contractVersion: contractVersion,
        ),
      );
    }
    return LocalApiEndpoint(
      instanceName: instanceName,
      baseUrl: baseUrl,
      ipAddress: parsedAddress.address,
      contractVersion: contractVersion,
    );
  }

  final String instanceName;
  final String baseUrl;
  final String ipAddress;
  final String contractVersion;
}

/// Something answered where a Local API should be, speaking a contract this
/// App does not know.
class IncompatibleLocalApi {
  const IncompatibleLocalApi({
    required this.baseUrl,
    required this.contractVersion,
  });

  final String baseUrl;
  final String contractVersion;
}

class LocalApiIncompatibleException implements Exception {
  const LocalApiIncompatibleException(this.service);

  final IncompatibleLocalApi service;

  String get baseUrl => service.baseUrl;
  String get contractVersion => service.contractVersion;

  @override
  String toString() => 'Local API at ${service.baseUrl} speaks contract '
      '${service.contractVersion}';
}

/// How a Local API came to be known about.
///
/// Named because the three are independent of each other, not because they are
/// ranked. A service browse needs multicast to reach this phone; a name needs
/// the platform resolver; a swept address needs neither. On the tablet that
/// prompted this, exactly one of the three was broken.
enum LocalApiCandidateOrigin {
  /// DNS-SD service browse for `_eidolon-local-api._tcp`.
  announced,

  /// Resolving a Host mDNS name and asking whether the Local API port answers.
  hostname,

  /// A bounded probe of this phone's own /24.
  subnet,
}

extension LocalApiCandidateOriginLabel on LocalApiCandidateOrigin {
  /// What to call this probe when telling a person what was tried.
  String get label => switch (this) {
        LocalApiCandidateOrigin.announced => 'mDNS 服务浏览',
        LocalApiCandidateOrigin.hostname => '按名解析',
        LocalApiCandidateOrigin.subnet => '本网段探测',
      };
}

/// A place worth asking, and nothing more.
///
/// Discovery produces candidates; verification decides. Which probe found an
/// address carries no authority whatsoever — it is recorded only so a person
/// can be told what was tried, and so a log says how the App got there.
class LocalApiCandidate {
  const LocalApiCandidate({required this.origin, required this.endpoint});

  final LocalApiCandidateOrigin origin;
  final LocalApiEndpoint endpoint;
}

/// What one probe looked at, and what came back.
///
/// A probe that found nothing has removed one lead, not failed the search, and
/// a probe that could not run at all is a third thing again. Both are recorded
/// rather than thrown, because the search continues either way and because
/// "silence everywhere" can only be explained to a person who is told what was
/// asked.
class LocalApiSourceReport {
  const LocalApiSourceReport({
    required this.origin,
    required this.attempted,
    this.candidates = const [],
    this.incompatible = const [],
    this.unavailable,
  });

  final LocalApiCandidateOrigin origin;

  /// What this probe actually looked at, in words a person can check against
  /// their own network — a service type, the names tried, the swept range.
  final String attempted;

  final List<LocalApiCandidate> candidates;

  /// Answers from something that is there but speaks another contract.
  final List<IncompatibleLocalApi> incompatible;

  /// Why the mechanism itself could not run, when it could not. Distinct from
  /// finding nothing: a blocked multicast socket and an empty network are not
  /// the same problem and do not have the same next step.
  final String? unavailable;

  String get outcome {
    if (unavailable != null) return '未能执行（$unavailable）';
    if (candidates.isEmpty && incompatible.isEmpty) return '无应答';
    return [
      if (candidates.isNotEmpty) '${candidates.length} 个候选',
      if (incompatible.isNotEmpty) '${incompatible.length} 个不兼容应答',
    ].join('，');
  }
}

/// Everything every probe learned in one pass.
class LocalApiSurvey {
  const LocalApiSurvey(this.sources);

  final List<LocalApiSourceReport> sources;

  /// Every candidate, each address once, in the order the probes are listed.
  ///
  /// One Host answering two probes is one place to look, not two; keeping the
  /// first also keeps the cheapest evidence, which is why order is by probe
  /// rather than by arrival.
  List<LocalApiCandidate> get candidates {
    final seen = <String>{};
    return [
      for (final source in sources)
        for (final candidate in source.candidates)
          if (seen.add(candidate.endpoint.baseUrl)) candidate,
    ];
  }

  List<LocalApiEndpoint> get endpoints =>
      candidates.map((candidate) => candidate.endpoint).toList(growable: false);

  List<IncompatibleLocalApi> get incompatible =>
      [for (final source in sources) ...source.incompatible];

  /// Nothing anywhere on this network said anything at all.
  bool get sawNothing => candidates.isEmpty && incompatible.isEmpty;

  /// What was tried, so silence can be read as a network fact rather than a
  /// verdict on the Host.
  String describeAttempts() => sources
      .map((source) => '${source.origin.label}（${source.attempted}）：'
          '${source.outcome}')
      .join('；');
}

/// One way of learning where a Local API is.
///
/// Never throws: a probe reports what it looked at and what happened, and the
/// aggregate decides what that means. A probe that threw would take the other
/// probes' findings with it, which is the failure this whole split exists to
/// prevent.
abstract interface class LocalApiCandidateSource {
  LocalApiCandidateOrigin get origin;

  Future<LocalApiSourceReport> probe({required Duration timeout});
}

abstract interface class LocalApiDiscovery {
  Future<LocalApiSurvey> discover({Duration timeout});
}

/// Asks every probe at once and reports all of it.
///
/// Sequential probing would have made the cheap-and-broken one gate the others:
/// on the tablet this was written for, the service browse returned nothing for
/// five seconds while both other probes could reach the Host immediately. They
/// run together because they are independent, and the survey keeps every
/// probe's outcome because the interesting question is usually which one failed.
class MultiSourceLocalApiDiscovery implements LocalApiDiscovery {
  const MultiSourceLocalApiDiscovery(this.sources);

  final List<LocalApiCandidateSource> sources;

  @override
  Future<LocalApiSurvey> discover({
    Duration timeout = const Duration(seconds: 5),
  }) async =>
      LocalApiSurvey(
        await Future.wait(
          sources.map((source) async {
            try {
              return await source.probe(timeout: timeout);
            } catch (error) {
              // A probe is not supposed to throw. If one does it is a defect in
              // that probe, and it must still not cost the survey what the
              // others found.
              return LocalApiSourceReport(
                origin: source.origin,
                attempted: source.origin.label,
                unavailable: '$error',
              );
            }
          }),
        ),
      );
}

/// One foreground list refresh shares a survey across all saved Hosts.
/// A new refresh creates a new pass; this is not a cache across networks.
class LocalApiDiscoveryPass implements LocalApiDiscovery {
  LocalApiDiscoveryPass(this.discovery);
  final LocalApiDiscovery discovery;
  Future<LocalApiSurvey>? _survey;

  @override
  Future<LocalApiSurvey> discover(
          {Duration timeout = const Duration(seconds: 5)}) =>
      _survey ??= discovery.discover(timeout: timeout);
}

/// Reuse an in-flight platform probe when a list and a connection overlap.
/// Finished results are never retained for a later network or refresh.
class SingleFlightLocalApiSource implements LocalApiCandidateSource {
  SingleFlightLocalApiSource(this.source);
  final LocalApiCandidateSource source;
  Future<LocalApiSourceReport>? _pending;
  @override
  LocalApiCandidateOrigin get origin => source.origin;
  @override
  Future<LocalApiSourceReport> probe({required Duration timeout}) =>
      _pending ??=
          source.probe(timeout: timeout).whenComplete(() => _pending = null);
}
