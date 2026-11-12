namespace GatewayClient;

/// <summary>
/// Whether a client may send a request right now.
/// </summary>
public enum Readiness
{
    /// <summary>No API connection. Connect (with back-off) before anything else.</summary>
    Disconnected,

    /// <summary>Connected, and the gateway can reach IBKR. Requests are allowed.</summary>
    Ready,

    /// <summary>
    /// Connected to the gateway, but the gateway reported IBKR code 1100. Send nothing and
    /// keep the connection: IBKR restores it and reports 1101 or 1102.
    /// </summary>
    ConnectivityLost,
}
