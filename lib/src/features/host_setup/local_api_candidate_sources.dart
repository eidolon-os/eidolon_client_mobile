import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'local_api_discovery.dart';

/// Whether anything is listening there, cheaply.
///
/// A completed TCP handshake is all a probe needs: it makes an address worth
/// asking, and nothing more than that. Whether the thing that answered is the
/// Owner's Host is settled afterwards, by the signature and the pin, on the
/// same path every candidate takes.
typedef LocalApiPortProbe = Future<bool> Function(
  String host,
  int port,
  Duration timeout,
);

typedef HostNameResolver = Future<List<String>> Function(String name);

typedef LocalIpv4Addresses = Future<List<String>> Function();

Future<bool> _connect(String host, int port, Duration timeout) async {
  try {
    final socket = await Socket.connect(host, port, timeout: timeout);
    socket.destroy();
    return true;
  } on Object {
    return false;
  }
}

/// DNS-SD service browse — whoever answers the announcement on this network.
///
/// The mechanism this App had, and the one that fails silently: multicast does
/// not reach every phone on every network, and Android's NsdManager reports a
/// blocked browse as an empty one. Kept, because when it works it is the only
/// probe that learns the port rather than assuming it.
class AnnouncedLocalApiSource implements LocalApiCandidateSource {
  AnnouncedLocalApiSource({MethodChannel? channel})
      : _channel =
            channel ?? const MethodChannel('live.eidolon.mobile/platform');

  final MethodChannel _channel;

  @override
  LocalApiCandidateOrigin get origin => LocalApiCandidateOrigin.announced;

  @override
  Future<LocalApiSourceReport> probe({required Duration timeout}) async {
    const attempted = '_eidolon-local-api._tcp';
    if (defaultTargetPlatform != TargetPlatform.android) {
      return const LocalApiSourceReport(
        origin: LocalApiCandidateOrigin.announced,
        attempted: attempted,
        unavailable: '这个平台上没有服务浏览',
      );
    }
    final List<Object?>? raw;
    try {
      raw = await _channel.invokeListMethod<Object?>('discoverLocalApis', {
        'timeoutMs': timeout.inMilliseconds,
      });
    } on PlatformException catch (error) {
      return LocalApiSourceReport(
        origin: LocalApiCandidateOrigin.announced,
        attempted: attempted,
        unavailable: '${error.code}：${error.message ?? ''}',
      );
    }
    final candidates = <LocalApiCandidate>[];
    final incompatible = <IncompatibleLocalApi>[];
    for (final item in raw ?? const <Object?>[]) {
      if (item is! Map) continue;
      try {
        candidates.add(
          LocalApiCandidate(
            origin: LocalApiCandidateOrigin.announced,
            endpoint: LocalApiEndpoint.fromMap(
              Map<Object?, Object?>.from(item),
            ),
          ),
        );
      } on LocalApiIncompatibleException catch (error) {
        incompatible.add(error.service);
      } on FormatException {
        // Noise on the wire. Dropped, and deliberately not reported: unlike an
        // incompatible Host there is nothing a person could do about it.
      }
    }
    return LocalApiSourceReport(
      origin: LocalApiCandidateOrigin.announced,
      attempted: attempted,
      candidates: candidates,
      incompatible: incompatible,
    );
  }
}

/// Resolve the Host's own mDNS name, then ask whether its Local API answers.
///
/// Independent of the service browse because it uses a different half of mDNS:
/// name resolution through the platform resolver, not multicast browsing. That
/// is not a theoretical distinction — on the tablet this was written for the
/// browse returned nothing while the same Host's `.local` name resolved and
/// pinged.
///
/// Names are supplied, never assumed. This shipped with one compiled in —
/// `eidolon-pi5.local`, the name the first board's image happened to have. One
/// App binary serves every household, and before a Host is claimed the phone
/// does not know which Host it is about to meet, so a name fixed at build time
/// is right for one installation and dead weight for the rest: the board this
/// was tested against answers to `orangepi5-max.local`, and the compiled-in
/// name matched no Host in service.
///
/// A name is a way to learn an address, so it has to be learned too — from a
/// Host this phone has already talked to. With no names this probe reports that
/// and stands down; the browse either side of it needs no name at all, and the
/// subnet sweep finds a Host by the port it answers on regardless of what it is
/// called.
class HostnameLocalApiSource implements LocalApiCandidateSource {
  HostnameLocalApiSource({
    Iterable<String>? names,
    this.port = localApiPort,
    HostNameResolver? resolve,
    LocalApiPortProbe? probePort,
    this.attemptTimeout = const Duration(milliseconds: 1200),
  })  : names = List<String>.unmodifiable(names ?? const <String>[]),
        _resolve = resolve ?? _lookup,
        _probePort = probePort ?? _connect;

  final List<String> names;
  final int port;
  final Duration attemptTimeout;
  final HostNameResolver _resolve;
  final LocalApiPortProbe _probePort;

  static Future<List<String>> _lookup(String name) async {
    try {
      final addresses = await InternetAddress.lookup(
        name,
        type: InternetAddressType.IPv4,
      );
      return addresses
          .map((address) => address.address)
          .toList(growable: false);
    } on Object {
      return const [];
    }
  }

  @override
  LocalApiCandidateOrigin get origin => LocalApiCandidateOrigin.hostname;

  @override
  Future<LocalApiSourceReport> probe({required Duration timeout}) async {
    if (names.isEmpty) {
      return LocalApiSourceReport(
        origin: origin,
        attempted: '没有可解析的主机名',
        unavailable: '这台手机还不知道任何 Host 名字',
      );
    }
    final watch = Stopwatch()..start();
    final found = await Future.wait(
        names.map((name) => _probeName(name, timeout, watch)));
    return LocalApiSourceReport(
      origin: origin,
      attempted: '${names.join('、')}（端口 $port）',
      candidates: found.whereType<LocalApiCandidate>().toList(growable: false),
    );
  }

  Future<LocalApiCandidate?> _probeName(
      String name, Duration timeout, Stopwatch watch) async {
    final addresses =
        await _resolve(name).timeout(timeout, onTimeout: () => const []);
    final remaining = timeout - watch.elapsed;
    if (remaining <= Duration.zero) return null;
    if (addresses.isEmpty) return null;
    final address = addresses.first;
    if (!await _probePort(address, port,
        remaining < attemptTimeout ? remaining : attemptTimeout)) {
      return null;
    }
    // Dialled at the address this name just resolved to, and named after the
    // name only for the record.
    //
    // It used to be dialled by name, on the reasoning that a name survives a
    // new DHCP lease while an address does not. The reasoning was sound and the
    // conclusion was still wrong, because the probe above and the request that
    // follows do not use the same resolver: the probe resolves here in Dart,
    // and the request goes out through the Android pinned transport, whose
    // OkHttp client resolves with getaddrinfo — **which does not resolve
    // `.local` at all**. So this source proved an address worked and then
    // handed back an address the transport could not reach, on every Android
    // phone, and the person was shown `Unable to resolve host
    // "eidolon-pi5.local"` for a Host that was up, pingable and one probe away.
    //
    // Freshness across a lease is not lost: an address that stops answering is
    // found again by locating the Host, which is what HostLocator is for. That
    // is the mechanism for a perishable address — not embedding a name the
    // transport cannot resolve and hoping.
    return LocalApiCandidate(
      origin: origin,
      endpoint: LocalApiEndpoint(
        instanceName: name,
        baseUrl: 'https://$address:$port',
        ipAddress: address,
        contractVersion: '1',
      ),
    );
  }
}

/// Ask this phone's own /24 whether anything answers on the Local API port.
///
/// Independent of mDNS altogether — no multicast, no resolver — which is what
/// makes it the probe that still works when the other two do not.
///
/// Not a security compromise, for one reason: verification is the gate, and
/// this is not it. An impostor listening on the port produces a candidate and
/// then fails to produce a Host-signed descriptor and a matching SPKI pin, so
/// it is refused exactly as it would be if mDNS had announced it. What the
/// sweep is bounded by is cost and blast radius, not trust: this phone's own
/// private /24, one port, a short per-address timeout, a fixed number of
/// sockets at a time, and a cap on how many addresses are tried at all.
///
/// Those bounds are also what the survey's latency costs: 253 addresses at
/// [concurrency] sockets and [attemptTimeout] each is on the order of a second
/// and a half when nothing answers, and a survey waits for every probe.
class SubnetLocalApiSource implements LocalApiCandidateSource {
  SubnetLocalApiSource({
    this.port = localApiPort,
    this.concurrency = 48,
    this.attemptTimeout = const Duration(milliseconds: 300),
    this.maxAddresses = 512,
    LocalIpv4Addresses? localAddresses,
    LocalApiPortProbe? probePort,
  })  : _localAddresses = localAddresses ?? _ownAddresses,
        _probePort = probePort ?? _connect;

  final int port;
  final int concurrency;
  final Duration attemptTimeout;
  final int maxAddresses;
  final LocalIpv4Addresses _localAddresses;
  final LocalApiPortProbe _probePort;

  static Future<List<String>> _ownAddresses() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: false,
    );
    return [
      for (final interface in interfaces)
        for (final address in interface.addresses) address.address,
    ];
  }

  /// Only ranges reserved for private networks are ever swept. A phone on a
  /// carrier or hotel network must not have this App knocking on 253 addresses
  /// that belong to strangers.
  static bool _isPrivate(String address) {
    final octets = address.split('.');
    if (octets.length != 4) return false;
    final numbers = octets.map(int.tryParse).toList(growable: false);
    if (numbers.any((octet) => octet == null || octet < 0 || octet > 255)) {
      return false;
    }
    final [first, second, ...] = numbers.cast<int>();
    return first == 10 ||
        (first == 192 && second == 168) ||
        (first == 172 && second >= 16 && second <= 31);
  }

  @override
  LocalApiCandidateOrigin get origin => LocalApiCandidateOrigin.subnet;

  @override
  Future<LocalApiSourceReport> probe({required Duration timeout}) async {
    final own = (await _localAddresses()).where(_isPrivate).toSet();
    if (own.isEmpty) {
      return LocalApiSourceReport(
        origin: origin,
        attempted: '没有可探测的网段',
        unavailable: '这台设备没有处于私有网段的局域网 IPv4 地址',
      );
    }
    // The prefix length is not something this phone is told, so /24 is assumed.
    // It is the home and office LAN, and being wrong costs a probe that finds
    // nothing rather than a wrong answer.
    final prefixes = own
        .map((address) => address.substring(0, address.lastIndexOf('.')))
        .toSet();
    final targets = <String>[
      for (final prefix in prefixes)
        for (var host = 1; host <= 254; host++)
          if (!own.contains('$prefix.$host')) '$prefix.$host',
    ];
    final scanned = targets.take(maxAddresses).toList(growable: false);
    final answered = List<bool>.filled(scanned.length, false);
    final stopwatch = Stopwatch()..start();
    var next = 0;

    Future<void> worker() async {
      while (true) {
        if (stopwatch.elapsed >= timeout) return;
        final index = next++;
        if (index >= scanned.length) return;
        answered[index] = await _probePort(
          scanned[index],
          port,
          attemptTimeout,
        );
      }
    }

    await Future.wait(
      List.generate(min(concurrency, scanned.length), (_) => worker()),
    );

    return LocalApiSourceReport(
      origin: origin,
      attempted: '${prefixes.map((prefix) => '$prefix.0/24').join('、')} '
          '共 ${scanned.length} 个地址（端口 $port）',
      candidates: [
        for (var index = 0; index < scanned.length; index++)
          if (answered[index])
            LocalApiCandidate(
              origin: origin,
              endpoint: LocalApiEndpoint(
                instanceName: scanned[index],
                baseUrl: 'https://${scanned[index]}:$port',
                ipAddress: scanned[index],
                contractVersion: '1',
              ),
            ),
      ],
    );
  }
}

final _announcedSource = SingleFlightLocalApiSource(AnnouncedLocalApiSource());
final _subnetSource = SingleFlightLocalApiSource(SubnetLocalApiSource());

/// Every probe this phone has, asked at once.
LocalApiDiscovery platformLocalApiDiscovery({Iterable<String>? hostNames}) =>
    MultiSourceLocalApiDiscovery([
      _announcedSource,
      HostnameLocalApiSource(names: hostNames),
      _subnetSource,
    ]);
