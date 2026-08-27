package live.eidolon.eidolon_client_mobile

import java.net.InetAddress
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/// A resolved announcement yields addresses, and only addresses.
///
/// This exists because the opposite shipped: the callback also emitted the
/// service's own `.local` name as a candidate, and on a real phone (Xiaomi
/// df331f93, Pi5) logcat showed both coming out of one resolution in the same
/// millisecond, the name second —
///
///     Resolved Eidolon Local API on eidolon-pi5 to https://192.168.3.206:9002
///     Resolved Eidolon Local API on eidolon-pi5 to https://eidolon-pi5.local:9002
///
/// The name could never be dialled: requests go out through OkHttp, which
/// resolves with getaddrinfo, and Android's getaddrinfo does not resolve
/// `.local`. Being emitted last, it was always the last candidate tried, so its
/// resolution failure was the sentence that reached the person — while the Host
/// was up at that first address and the management screens were talking to it.
class LocalApiAnnouncementTest {
    // Numeric literals only: getByName does not resolve these, so no test here
    // touches a network or a resolver.
    private fun address(literal: String): InetAddress =
        InetAddress.getByName(literal)

    @Test
    fun `an IPv4 announcement offers exactly one candidate`() {
        assertEquals(
            listOf("192.168.3.206" to "192.168.3.206"),
            localApiCandidateHosts(listOf(address("192.168.3.206"))),
        )
    }

    @Test
    fun `no candidate is ever a name`() {
        val hosts = localApiCandidateHosts(
            listOf(address("192.168.3.206"), address("fd00::1")),
        ).map { it.first }

        assertTrue(hosts.isNotEmpty(), "the rule produced nothing to check")
        for (host in hosts) {
            assertTrue(
                !host.contains(".local", ignoreCase = true),
                "candidate $host is a name the transport cannot resolve",
            )
        }
    }

    @Test
    fun `IPv4 comes before IPv6, and IPv6 is bracketed for a URL`() {
        val ipv6 = address("fd00::1")
        // Derived rather than written out: the runtime decides the text form —
        // this JVM answers `fd00:0:0:0:0:0:0:1` for the address written above,
        // and Android need not agree. What is being asserted is the order and
        // the brackets, not how a platform spells an address.
        val expectedIpv6 = ipv6.hostAddress!!

        assertEquals(
            listOf(
                "192.168.3.206" to "192.168.3.206",
                "[$expectedIpv6]" to expectedIpv6,
            ),
            localApiCandidateHosts(listOf(ipv6, address("192.168.3.206"))),
        )
    }

    @Test
    fun `a scoped IPv6 address names an interface on another machine`() {
        // `fe80::1%wlan0` is meaningful only on the host that produced it.
        val scoped = InetAddress.getByName("fe80::1%1")

        assertEquals(
            emptyList(),
            localApiCandidateHosts(listOf(scoped)),
        )
    }

    @Test
    fun `the same address announced twice is one candidate`() {
        assertEquals(
            listOf("192.168.3.206" to "192.168.3.206"),
            localApiCandidateHosts(
                listOf(address("192.168.3.206"), address("192.168.3.206")),
            ),
        )
    }

    @Test
    fun `an announcement that resolved to nothing offers nothing`() {
        assertEquals(emptyList(), localApiCandidateHosts(emptyList()))
    }
}
