package live.eidolon.eidolon_client_mobile

/**
 * Host- and Android-independent ownership core for the controller side of a
 * commissioning transport lease.
 *
 * The vendor transport may carry the protocol, but it must not decide when an
 * Eidolon commissioning act is terminal. The SoftAP route remains owned until
 * committed device evidence has been observed and acknowledged.
 */
internal enum class CommissioningClientLeaseState {
    Idle,
    SettingNetworkCandidate,
    ApplyingNetworkCandidate,
    AwaitingTerminal,
    AcknowledgingTerminal,
    Closed,
}

internal enum class CommissioningClientLeaseEvent {
    Start,
    NetworkCandidateAccepted,
    ConfigurationApplied,
    StatusApplying,
    StatusCommitted,
    TerminalAckAccepted,
    Failed,
}

internal enum class CommissioningClientLeaseAction {
    None,
    SendNetworkCandidate,
    ApplyNetworkCandidate,
    ReadTerminalStatus,
    SendTerminalAck,
    ReleaseSucceeded,
    ReleaseFailed,
}

internal class CommissioningClientLeaseCore {
    var state: CommissioningClientLeaseState = CommissioningClientLeaseState.Idle
        private set

    @Synchronized
    fun handle(event: CommissioningClientLeaseEvent): CommissioningClientLeaseAction {
        if (event == CommissioningClientLeaseEvent.Failed &&
            state != CommissioningClientLeaseState.Idle &&
            state != CommissioningClientLeaseState.Closed
        ) {
            state = CommissioningClientLeaseState.Closed
            return CommissioningClientLeaseAction.ReleaseFailed
        }
        return when (state) {
            CommissioningClientLeaseState.Idle ->
                if (event == CommissioningClientLeaseEvent.Start) {
                    state = CommissioningClientLeaseState.SettingNetworkCandidate
                    CommissioningClientLeaseAction.SendNetworkCandidate
                } else {
                    CommissioningClientLeaseAction.None
                }

            CommissioningClientLeaseState.SettingNetworkCandidate ->
                if (event == CommissioningClientLeaseEvent.NetworkCandidateAccepted) {
                    state = CommissioningClientLeaseState.ApplyingNetworkCandidate
                    CommissioningClientLeaseAction.ApplyNetworkCandidate
                } else {
                    CommissioningClientLeaseAction.None
                }

            CommissioningClientLeaseState.ApplyingNetworkCandidate ->
                if (event == CommissioningClientLeaseEvent.ConfigurationApplied) {
                    state = CommissioningClientLeaseState.AwaitingTerminal
                    CommissioningClientLeaseAction.ReadTerminalStatus
                } else {
                    CommissioningClientLeaseAction.None
                }

            CommissioningClientLeaseState.AwaitingTerminal -> when (event) {
                CommissioningClientLeaseEvent.StatusApplying ->
                    CommissioningClientLeaseAction.ReadTerminalStatus

                CommissioningClientLeaseEvent.StatusCommitted -> {
                    state = CommissioningClientLeaseState.AcknowledgingTerminal
                    CommissioningClientLeaseAction.SendTerminalAck
                }

                else -> CommissioningClientLeaseAction.None
            }

            CommissioningClientLeaseState.AcknowledgingTerminal ->
                if (event == CommissioningClientLeaseEvent.TerminalAckAccepted) {
                    state = CommissioningClientLeaseState.Closed
                    CommissioningClientLeaseAction.ReleaseSucceeded
                } else {
                    CommissioningClientLeaseAction.None
                }

            CommissioningClientLeaseState.Closed -> CommissioningClientLeaseAction.None
        }
    }
}
