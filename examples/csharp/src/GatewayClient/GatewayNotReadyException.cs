namespace GatewayClient;

/// <summary>
/// The gateway cannot be used right now: the connection was refused, the API handshake was
/// not answered in time, or the connection closed.
/// </summary>
/// <remarks>
/// This is an expected condition, not a defect: a gateway that is logging in, waiting for a
/// second factor or restarting refuses connections. <see cref="ResilientClient"/> answers it
/// with a retry. Any other exception from a session is treated as a defect and propagates.
/// </remarks>
public sealed class GatewayNotReadyException : Exception
{
    /// <summary>Creates the exception without a message.</summary>
    public GatewayNotReadyException()
    {
    }

    /// <summary>Creates the exception with a reason.</summary>
    /// <param name="message">Why the gateway is not ready; never a raw IBKR message text.</param>
    public GatewayNotReadyException(string message)
        : base(message)
    {
    }

    /// <summary>Creates the exception with a reason and the underlying cause.</summary>
    /// <param name="message">Why the gateway is not ready.</param>
    /// <param name="innerException">The exception that revealed it (for example a socket error).</param>
    public GatewayNotReadyException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}
