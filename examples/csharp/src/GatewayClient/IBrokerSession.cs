namespace GatewayClient;

/// <summary>
/// The broker boundary: everything <see cref="ResilientClient"/> needs from an API connection.
/// </summary>
/// <remarks>
/// <para>
/// The sample's behaviour is written and tested against this interface, without IBKR's
/// assembly. <c>GatewayClient.IbApi</c> implements it on top of IBKR's C# client; the tests
/// implement it with a scriptable fake.
/// </para>
/// <para>
/// It is read-only by design: it can connect, ask for the server time and disconnect. There
/// is no member that could send an order, and none should be added to it.
/// </para>
/// <para>
/// Threading: implementations raise <see cref="ErrorReceived"/> and
/// <see cref="Disconnected"/> on whatever thread their API uses (IBKR's client has its own
/// message thread). Handlers must be quick and must not call back into the session.
/// </para>
/// </remarks>
public interface IBrokerSession
{
    /// <summary>
    /// Raised for every IBKR message code: request id (-1 when it belongs to no request),
    /// code, text. Most codes are notices, not errors.
    /// </summary>
    event Action<int, int, string>? ErrorReceived;

    /// <summary>
    /// Raised when the API connection has been closed, by the peer (gateway restart or stop)
    /// or by <see cref="Disconnect"/>.
    /// </summary>
    event Action? Disconnected;

    /// <summary>Whether an API connection currently stands.</summary>
    bool IsConnected { get; }

    /// <summary>
    /// Opens an API connection.
    /// </summary>
    /// <param name="host">Gateway host name or address.</param>
    /// <param name="port">API port.</param>
    /// <param name="clientId">TWS API client id, unique per gateway.</param>
    /// <param name="timeout">How long connecting may take in total.</param>
    /// <param name="cancellationToken">Cancels the attempt.</param>
    /// <returns>A task that completes when the API is ready for requests.</returns>
    /// <exception cref="GatewayNotReadyException">
    /// The gateway refused the connection, did not answer in time or closed the connection
    /// while connecting. Nothing is left connected when this is thrown.
    /// </exception>
    Task ConnectAsync(string host, int port, int clientId, TimeSpan timeout, CancellationToken cancellationToken);

    /// <summary>
    /// Asks the gateway for IBKR's server time.
    /// </summary>
    /// <param name="timeout">How long to wait for the answer.</param>
    /// <param name="cancellationToken">Cancels the wait.</param>
    /// <returns>The server time (UTC offset zero).</returns>
    /// <exception cref="TimeoutException">No answer arrived within <paramref name="timeout"/>.</exception>
    /// <exception cref="GatewayNotReadyException">The connection is closed or closed meanwhile.</exception>
    Task<DateTimeOffset> GetServerTimeAsync(TimeSpan timeout, CancellationToken cancellationToken);

    /// <summary>Closes the connection; safe to call when it is already closed.</summary>
    void Disconnect();
}
