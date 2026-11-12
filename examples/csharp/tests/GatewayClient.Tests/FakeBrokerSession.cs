namespace GatewayClient.Tests;

/// <summary>
/// A scriptable <see cref="IBrokerSession"/>; nothing here opens a socket.
/// </summary>
/// <remarks>
/// <para>
/// Contract: <see cref="ConnectScript"/> holds one entry per future connection attempt (an
/// exception to throw, or <c>null</c> to succeed; when it is empty every attempt succeeds).
/// <see cref="TimeScript"/> holds one entry per future server-time request (an exception to
/// throw or a time to return; when it is empty <see cref="ServerTime"/> is returned).
/// <see cref="EmitError"/> and <see cref="Drop"/> play the gateway's side.
/// </para>
/// <para>Every call is recorded so that a test can assert on what was (not) sent.</para>
/// <para>Threading: single-threaded use by the tests; no synchronisation.</para>
/// </remarks>
internal sealed class FakeBrokerSession : IBrokerSession
{
    /// <summary>The answer of a healthy gateway to a server-time request.</summary>
    public static readonly DateTimeOffset ServerTime = new(2026, 11, 12, 14, 30, 0, TimeSpan.Zero);

    /// <inheritdoc />
    public event Action<int, int, string>? ErrorReceived;

    /// <inheritdoc />
    public event Action? Disconnected;

    /// <summary>Outcomes of the next connection attempts: an exception, or <c>null</c> for success.</summary>
    public Queue<Exception?> ConnectScript { get; } = new();

    /// <summary>Outcomes of the next server-time requests: an exception or a <see cref="DateTimeOffset"/>.</summary>
    public Queue<object> TimeScript { get; } = new();

    /// <summary>Every connection attempt: host, port, client id and timeout.</summary>
    public List<(string Host, int Port, int ClientId, TimeSpan Timeout)> ConnectCalls { get; } = [];

    /// <summary>The timeout of every server-time request made.</summary>
    public List<TimeSpan> TimeRequests { get; } = [];

    /// <summary>How often <see cref="Disconnect"/> was called.</summary>
    public int DisconnectCalls { get; private set; }

    /// <inheritdoc />
    public bool IsConnected { get; private set; }

    /// <inheritdoc />
    public Task ConnectAsync(string host, int port, int clientId, TimeSpan timeout, CancellationToken cancellationToken)
    {
        ConnectCalls.Add((host, port, clientId, timeout));
        if (ConnectScript.TryDequeue(out var failure) && failure is not null)
        {
            return Task.FromException(failure);
        }

        IsConnected = true;
        return Task.CompletedTask;
    }

    /// <inheritdoc />
    public Task<DateTimeOffset> GetServerTimeAsync(TimeSpan timeout, CancellationToken cancellationToken)
    {
        TimeRequests.Add(timeout);
        if (!TimeScript.TryDequeue(out var outcome))
        {
            return Task.FromResult(ServerTime);
        }

        return outcome is Exception failure
            ? Task.FromException<DateTimeOffset>(failure)
            : Task.FromResult((DateTimeOffset)outcome);
    }

    /// <inheritdoc />
    public void Disconnect()
    {
        DisconnectCalls++;
        if (IsConnected)
        {
            IsConnected = false;
            Disconnected?.Invoke();
        }
    }

    /// <summary>Plays the gateway sending IBKR message <paramref name="code"/>.</summary>
    /// <param name="code">The IBKR message code.</param>
    /// <param name="message">Its text.</param>
    public void EmitError(int code, string message = "") => ErrorReceived?.Invoke(-1, code, message);

    /// <summary>Plays the peer closing the socket (daily restart, gateway stopped).</summary>
    public void Drop()
    {
        IsConnected = false;
        Disconnected?.Invoke();
    }
}
