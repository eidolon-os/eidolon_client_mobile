package live.eidolon.eidolon_client_mobile

import com.espressif.provisioning.listeners.ResponseListener
import java.io.IOException
import kotlin.test.*

class ProvisioningExchangeLifecycleTest {
    private class Reply : ResponseListener {
        var successes = 0
        var failures = 0
        override fun onSuccess(bytes: ByteArray?) { successes++ }
        override fun onFailure(error: Exception?) { failures++ }
    }

    @Test fun `lost response poisons visit and late callbacks cannot revive it`() {
        var terminations = 0
        val lifecycle = ProvisioningExchangeLifecycle { error, notify, reply ->
            assertTrue(notify); terminations++; reply?.onFailure(error)
        }
        val reply = Reply()
        val wire = lifecycle.begin(reply)!!
        wire.onFailure(IOException("incomplete headers"))
        wire.onSuccess(byteArrayOf(1))
        wire.onFailure(IOException("late cancellation"))
        assertTrue(lifecycle.closed)
        assertEquals(1, terminations)
        assertEquals(1, reply.failures)
        assertEquals(0, reply.successes)
        val next = Reply()
        assertNull(lifecycle.begin(next))
        assertEquals(1, next.failures)
    }

    @Test fun `reusing listener cannot let an old reply complete a new exchange`() {
        val lifecycle = ProvisioningExchangeLifecycle { _, _, _ -> fail("unexpected termination") }
        val reply = Reply()
        val first = lifecycle.begin(reply)!!
        first.onSuccess(byteArrayOf(1))
        val second = lifecycle.begin(reply)!!
        first.onSuccess(byteArrayOf(2))
        first.onFailure(IOException("old error"))
        assertEquals(1, reply.successes)
        second.onSuccess(byteArrayOf(3))
        assertEquals(2, reply.successes)
        assertEquals(0, reply.failures)
    }

    @Test fun `cancel is idempotent and fences pending response without owner invalidation`() {
        var terminations = 0
        val lifecycle = ProvisioningExchangeLifecycle { error, notify, reply ->
            assertFalse(notify); terminations++; reply?.onFailure(error)
        }
        val reply = Reply()
        val wire = lifecycle.begin(reply)!!
        lifecycle.terminate(IOException("cancel"), false)
        lifecycle.terminate(IOException("cancel again"), false)
        wire.onSuccess(byteArrayOf(1))
        assertEquals(1, terminations)
        assertEquals(1, reply.failures)
        assertEquals(0, reply.successes)
    }

    @Test fun `concurrent exchange is rejected without disturbing active request`() {
        val lifecycle = ProvisioningExchangeLifecycle { _, _, _ -> fail("unexpected termination") }
        val first = Reply(); val second = Reply()
        val wire = lifecycle.begin(first)!!
        assertNull(lifecycle.begin(second))
        wire.onSuccess(byteArrayOf(1))
        assertEquals(1, first.successes)
        assertEquals(1, second.failures)
        assertFalse(lifecycle.closed)
    }

    @Test fun `null decrypted response invalidates authenticated visit`() {
        var notified = false
        val lifecycle = ProvisioningExchangeLifecycle { error, notify, reply ->
            notified = notify; reply?.onFailure(error)
        }
        val reply = Reply()
        lifecycle.begin(reply)!!.onSuccess(null)
        assertTrue(notified)
        assertTrue(lifecycle.closed)
        assertEquals(1, reply.failures)
    }
}
