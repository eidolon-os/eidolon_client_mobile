package live.eidolon.eidolon_client_mobile

import java.net.Inet4Address
import java.net.InetAddress

/// How a resolved mDNS announcement becomes addresses this app can dial.
///
/// Pulled out of the NsdManager callback so it can be tested, because the rule
/// it carries was wrong in a way review did not catch. The callback used to add
/// the service's own `.local` name as one more candidate, reasoning that a name
/// outlives a DHCP lease. Two things were wrong with that:
///
///  - the announcement has *already* resolved to addresses, and the name
///    candidate was only added when at least one address was known, so it
///    carried no reachability the addresses did not already carry; and
///  - requests go out through OkHttp, which resolves with getaddrinfo, and
///    Android's getaddrinfo does not resolve `.local` at all.
///
/// So every connection paid for one doomed attempt, and because the name was
/// emitted last it was always the last candidate tried — which, before the
/// failure reporting in `HostProductSession.connect()` was fixed, made its
/// `Unable to resolve host "eidolon-pi5.local"` the sentence that reached the
/// screen. A phone whose Host was up at 192.168.3.206, pingable, and already
/// answering the management screens was told 「无法连接到 Hub / 请检查局域网连接」.
///
/// Returns `(host, ipAddress)` pairs: `host` goes into the base URL, so IPv6 is
/// bracketed; `ipAddress` is the bare address Dart records.
internal fun localApiCandidateHosts(
    addresses: List<InetAddress>,
): List<Pair<String, String>> {
    val ipv4Addresses = addresses
        .filterIsInstance<Inet4Address>()
        .mapNotNull { it.hostAddress }
    val ipv6Addresses = addresses
        .filterNot { it is Inet4Address }
        .mapNotNull { it.hostAddress }
        // A scoped address (`fe80::1%wlan0`) names an interface on the machine
        // that produced it, so it means nothing to this phone.
        .filterNot { it.contains('%') }
    return buildList {
        addAll(ipv4Addresses.map { it to it })
        addAll(ipv6Addresses.map { "[$it]" to it })
    }.distinctBy { it.first }
}
