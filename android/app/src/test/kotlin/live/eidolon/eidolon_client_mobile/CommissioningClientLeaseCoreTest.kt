package live.eidolon.eidolon_client_mobile

import kotlin.test.Test
import kotlin.test.assertEquals

class CommissioningClientLeaseCoreTest {
    @Test
    fun `softap remains leased until committed evidence is acknowledged`() {
        val core = CommissioningClientLeaseCore()

        assertEquals(
            CommissioningClientLeaseAction.SendNetworkCandidate,
            core.handle(CommissioningClientLeaseEvent.Start),
        )
        assertEquals(
            CommissioningClientLeaseAction.ApplyNetworkCandidate,
            core.handle(CommissioningClientLeaseEvent.NetworkCandidateAccepted),
        )
        assertEquals(
            CommissioningClientLeaseAction.ReadTerminalStatus,
            core.handle(CommissioningClientLeaseEvent.ConfigurationApplied),
        )
        assertEquals(
            CommissioningClientLeaseAction.ReadTerminalStatus,
            core.handle(CommissioningClientLeaseEvent.StatusApplying),
        )
        assertEquals(
            CommissioningClientLeaseState.AwaitingTerminal,
            core.state,
        )
        assertEquals(
            CommissioningClientLeaseAction.SendTerminalAck,
            core.handle(CommissioningClientLeaseEvent.StatusCommitted),
        )
        assertEquals(
            CommissioningClientLeaseAction.ReleaseSucceeded,
            core.handle(CommissioningClientLeaseEvent.TerminalAckAccepted),
        )
        assertEquals(CommissioningClientLeaseState.Closed, core.state)
    }

    @Test
    fun `vendor wifi success cannot close the lease before eidolon terminal`() {
        val core = CommissioningClientLeaseCore()
        core.handle(CommissioningClientLeaseEvent.Start)
        core.handle(CommissioningClientLeaseEvent.NetworkCandidateAccepted)
        core.handle(CommissioningClientLeaseEvent.ConfigurationApplied)

        assertEquals(
            CommissioningClientLeaseAction.None,
            core.handle(CommissioningClientLeaseEvent.NetworkCandidateAccepted),
        )
        assertEquals(CommissioningClientLeaseState.AwaitingTerminal, core.state)
    }

    @Test
    fun `failure releases once and stale callbacks cannot release again`() {
        val core = CommissioningClientLeaseCore()
        core.handle(CommissioningClientLeaseEvent.Start)

        assertEquals(
            CommissioningClientLeaseAction.ReleaseFailed,
            core.handle(CommissioningClientLeaseEvent.Failed),
        )
        assertEquals(
            CommissioningClientLeaseAction.None,
            core.handle(CommissioningClientLeaseEvent.Failed),
        )
        assertEquals(
            CommissioningClientLeaseAction.None,
            core.handle(CommissioningClientLeaseEvent.StatusCommitted),
        )
    }
}
