package live.eidolon.eidolon_client_mobile

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class OwnWifiReturnTest {
    private class FakePort : OwnWifiReturn.Port<String> {
        val requests = mutableListOf<Request>()

        inner class Request(val offered: (String) -> Unit) {
            var released = false
        }

        val open: List<Request> get() = requests.filterNot { it.released }

        override fun requestOrdinaryWifi(offered: (String) -> Unit): () -> Unit {
            val request = Request(offered)
            requests += request
            return { request.released = true }
        }
    }

    @Test
    fun `releasing the device network asks Android for ordinary wifi`() {
        val port = FakePort()
        val ownWifi = OwnWifiReturn(port)

        ownWifi.deviceNetworkReleased("device-ap")

        assertEquals(1, port.open.size)
        assertTrue(ownWifi.returning)
    }

    @Test
    fun `the request is let go once another network satisfies it`() {
        val port = FakePort()
        val ownWifi = OwnWifiReturn(port)
        ownWifi.deviceNetworkReleased("device-ap")

        port.requests.single().offered("home")

        assertTrue(port.open.isEmpty())
        assertFalse(ownWifi.returning)
    }

    @Test
    fun `the setup network still being torn down is not the phone's own`() {
        val port = FakePort()
        val ownWifi = OwnWifiReturn(port)
        ownWifi.deviceNetworkReleased("device-ap")

        port.requests.single().offered("device-ap")

        assertEquals(1, port.open.size)
        assertTrue(ownWifi.returning)

        port.requests.single().offered("home")
        assertTrue(port.open.isEmpty())
    }

    @Test
    fun `a new visit takes the radio before anything is given back`() {
        val port = FakePort()
        val ownWifi = OwnWifiReturn(port)
        ownWifi.deviceNetworkReleased("device-ap")

        ownWifi.deviceVisitStarting()

        assertTrue(port.open.isEmpty())
        assertFalse(ownWifi.returning)
    }

    @Test
    fun `an answer to a request already let go changes nothing`() {
        val port = FakePort()
        val ownWifi = OwnWifiReturn(port)
        ownWifi.deviceNetworkReleased("device-ap")
        val first = port.requests.single()
        ownWifi.deviceVisitStarting()
        ownWifi.deviceNetworkReleased("device-ap-2")

        first.offered("home")

        assertEquals(1, port.open.size)
        assertTrue(ownWifi.returning)
    }

    @Test
    fun `a second release replaces the first request rather than stacking`() {
        val port = FakePort()
        val ownWifi = OwnWifiReturn(port)

        ownWifi.deviceNetworkReleased(null)
        ownWifi.deviceNetworkReleased("device-ap")

        assertEquals(2, port.requests.size)
        assertEquals(1, port.open.size)
    }

    @Test
    fun `a visit that never joined still gives the radio back`() {
        val port = FakePort()
        val ownWifi = OwnWifiReturn(port)

        ownWifi.deviceNetworkReleased(null)
        port.requests.single().offered("home")

        assertTrue(port.open.isEmpty())
    }

    @Test
    fun `closing lets go of an unanswered request`() {
        val port = FakePort()
        val ownWifi = OwnWifiReturn(port)
        ownWifi.deviceNetworkReleased("device-ap")

        ownWifi.close()

        assertTrue(port.open.isEmpty())
    }
}
