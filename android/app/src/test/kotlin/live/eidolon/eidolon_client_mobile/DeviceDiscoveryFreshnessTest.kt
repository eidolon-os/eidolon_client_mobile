package live.eidolon.eidolon_client_mobile

import kotlin.test.*

class DeviceDiscoveryFreshnessTest {
    @Test fun `throttled repeat scan retains a twenty second old device`() {
        assertTrue(isUsableDiscoveryObservation(11_000, 31_000))
        assertTrue(isUsableDiscoveryObservation(11_000, 41_000))
    }
    @Test fun `expired and future observations are rejected`() {
        assertFalse(isUsableDiscoveryObservation(11_000, 41_001))
        assertFalse(isUsableDiscoveryObservation(1_000, 275_000))
        assertFalse(isUsableDiscoveryObservation(276_000, 275_000))
    }
    @Test fun `three recent devices survive independently of request time`() {
        assertEquals(3, listOf(274_001L, 274_002L, 274_003L).count {
            isUsableDiscoveryObservation(it, 275_000)
        })
    }
}
