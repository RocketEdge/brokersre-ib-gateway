using IBApi;

namespace GatewayClient.IbApi;

/// <summary>
/// <see cref="IBrokerSession"/> on top of IBKR's official C# client (<c>CSharpAPI.dll</c>).
/// </summary>
/// <remarks>
/// <para>
/// Read-only by construction: the only request it ever sends is the server-time request.
/// IBKR's client itself sends the handshake and the start-API message when connecting, and
/// nothing else. No order, cancel or what-if member of the API is referenced here.
/// </para>
/// <para>
/// One <see cref="Connection"/> object per connection attempt: IBKR's client keeps threads
/// alive for a moment after a disconnect, and they call back into the wrapper they were
/// created with. A fresh wrapper per connection means a late callback of an old connection
/// can be recognised (it is not the current one) and dropped, instead of being mistaken for
/// an event of the new connection.
/// </para>
/// <para>
/// Threading: IBKR's client reads the socket on one thread and this class runs a second,
/// the message pump (<c>ib-api-messages</c>), which decodes messages and calls the wrapper.
/// <see cref="ErrorReceived"/> and <see cref="Disconnected"/> are therefore raised on the
/// pump thread or the reader thread; <see cref="Disconnect"/> raises
/// <see cref="Disconnected"/> on the caller's thread. The field <c>current</c> is guarded by
/// one lock; events are raised outside it.
/// </para>
/// <para>
/// Written against TWS API 10.48.01, whose error callback has the signature
/// <c>error(int id, long errorTime, int errorCode, string errorMsg, string advancedOrderRejectJson)</c>.
/// Older API releases have a different signature and do not compile with this file.
/// </para>
/// </remarks>
public sealed class IbApiSession : IBrokerSession
{
    private readonly Lock gate = new();
    private Connection? current;

    /// <inheritdoc />
    public event Action<int, int, string>? ErrorReceived;

    /// <inheritdoc />
    public event Action? Disconnected;

    /// <inheritdoc />
    public bool IsConnected
    {
        get
        {
            lock (gate)
            {
                return current?.Client.IsConnected() ?? false;
            }
        }
    }

    /// <inheritdoc />
    /// <remarks>
    /// IBKR's <c>eConnect</c> blocks while it opens the socket and reads the server version,
    /// so it runs on a pool thread and is abandoned when <paramref name="timeout"/> passes.
    /// The connection counts as ready when the gateway has sent the next valid id, which is
    /// its answer to the start-API message.
    /// </remarks>
    public async Task ConnectAsync(string host, int port, int clientId, TimeSpan timeout, CancellationToken cancellationToken)
    {
        Disconnect();
        var connection = new Connection(this);
        lock (gate)
        {
            current = connection;
        }

        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(timeout);
        try
        {
            await Task.Run(
                () =>
                {
                    connection.Client.eConnect(host, port, clientId);

                    // If the attempt was given up while eConnect was still opening the socket,
                    // the connection it got in the end must not stay open and hold the client id.
                    connection.CloseIfAbandoned();
                },
                CancellationToken.None)
                .WaitAsync(deadline.Token)
                .ConfigureAwait(false);
            if (!connection.Client.IsConnected())
            {
                throw new GatewayNotReadyException($"connection failed: {connection.ConnectFailure ?? "refused or closed during the handshake"}");
            }

            connection.StartMessagePump();
            await connection.ApiReady.Task.WaitAsync(deadline.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            Abandon(connection);
            throw new GatewayNotReadyException($"no answer within {timeout.TotalSeconds:F0} s");
        }
        catch
        {
            Abandon(connection);
            throw;
        }
    }

    /// <inheritdoc />
    public async Task<DateTimeOffset> GetServerTimeAsync(TimeSpan timeout, CancellationToken cancellationToken)
    {
        Connection? connection;
        lock (gate)
        {
            connection = current;
        }

        if (connection is null || !connection.Client.IsConnected())
        {
            throw new GatewayNotReadyException("not connected");
        }

        var pending = connection.BeginTimeRequest();
        connection.Client.reqCurrentTime();
        return await pending.Task.WaitAsync(timeout, cancellationToken).ConfigureAwait(false);
    }

    /// <inheritdoc />
    public void Disconnect()
    {
        Connection? connection;
        lock (gate)
        {
            connection = current;
            current = null;
        }

        if (connection is null)
        {
            return;
        }

        var wasConnected = connection.Client.IsConnected();
        connection.Close();
        if (wasConnected)
        {
            Disconnected?.Invoke();
        }
    }

    /// <summary>Gives up a connection attempt: it stops being current and its socket is closed.</summary>
    /// <param name="connection">The connection that failed to become ready.</param>
    private void Abandon(Connection connection)
    {
        lock (gate)
        {
            if (ReferenceEquals(current, connection))
            {
                current = null;
            }
        }

        connection.Close();
    }

    /// <summary>Forwards an IBKR message code of the current connection; drops one of an old connection.</summary>
    /// <param name="connection">The connection the callback came from.</param>
    /// <param name="requestId">Request the message belongs to, or -1.</param>
    /// <param name="code">The IBKR message code.</param>
    /// <param name="message">Its text.</param>
    private void OnError(Connection connection, int requestId, int code, string message)
    {
        lock (gate)
        {
            if (!ReferenceEquals(current, connection))
            {
                return;
            }
        }

        ErrorReceived?.Invoke(requestId, code, message);
    }

    /// <summary>Reports the current connection as closed by the peer; ignores an old connection.</summary>
    /// <param name="connection">The connection the callback came from.</param>
    private void OnConnectionClosed(Connection connection)
    {
        lock (gate)
        {
            if (!ReferenceEquals(current, connection))
            {
                return;
            }

            current = null;
        }

        Disconnected?.Invoke();
    }

    /// <summary>
    /// One connection: IBKR's socket client, its signal and the wrapper that receives its
    /// callbacks. Only the callbacks this sample needs are overridden; every other callback
    /// of <see cref="DefaultEWrapper"/> does nothing.
    /// </summary>
    /// <param name="owner">The session that created this connection.</param>
    private sealed class Connection(IbApiSession owner) : DefaultEWrapper
    {
        private readonly Lock gate = new();
        private readonly EReaderMonitorSignal signal = new();
        private EClientSocket? client;
        private TaskCompletionSource<DateTimeOffset>? pendingTime;
        private volatile string? connectFailure;
        private volatile bool closed;

        /// <summary>IBKR's socket client of this connection (created on first use).</summary>
        public EClientSocket Client
        {
            get
            {
                lock (gate)
                {
                    return client ??= new EClientSocket(this, signal);
                }
            }
        }

        /// <summary>Completes when the gateway has answered the start-API message; fails when the connection closes first.</summary>
        public TaskCompletionSource ApiReady { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);

        /// <summary>Type name of the exception IBKR's client reported while connecting, if any.</summary>
        public string? ConnectFailure => connectFailure;

        /// <summary>
        /// Starts IBKR's reader thread and the message pump that decodes what it reads. Both
        /// end by themselves when the connection is closed.
        /// </summary>
        public void StartMessagePump()
        {
            var socket = Client;
            var reader = new EReader(socket, signal);
            reader.Start();
            var pump = new Thread(() =>
            {
                while (socket.IsConnected())
                {
                    signal.waitForSignal();
                    reader.processMsgs();
                }
            })
            {
                IsBackground = true,
                Name = "ib-api-messages",
            };
            pump.Start();
        }

        /// <summary>Registers a server-time request; a request still pending is abandoned.</summary>
        /// <returns>The completion source the answer will complete.</returns>
        public TaskCompletionSource<DateTimeOffset> BeginTimeRequest()
        {
            var pending = new TaskCompletionSource<DateTimeOffset>(TaskCreationOptions.RunContinuationsAsynchronously);
            lock (gate)
            {
                pendingTime = pending;
            }

            return pending;
        }

        /// <summary>Closes the socket and wakes the message pump so that it ends.</summary>
        public void Close()
        {
            closed = true;
            Client.eDisconnect();
            signal.issueSignal();

            // Observe a failure nobody awaits (an abandoned attempt), so it is not reported as unobserved.
            _ = ApiReady.Task.Exception;
        }

        /// <summary>
        /// Closes the socket if <see cref="Close"/> has already been called. For the thread
        /// that runs IBKR's blocking <c>eConnect</c>: when the attempt was given up before the
        /// socket existed, <see cref="Close"/> found nothing to close, and the connection
        /// that <c>eConnect</c> established afterwards would otherwise stay open.
        /// </summary>
        public void CloseIfAbandoned()
        {
            if (closed)
            {
                Client.eDisconnect();
            }
        }

        /// <summary>An IBKR message code (most are notices): passed to the session.</summary>
        /// <param name="id">Request id, or -1.</param>
        /// <param name="errorTime">Time of the message in epoch milliseconds; not used.</param>
        /// <param name="errorCode">The IBKR message code.</param>
        /// <param name="errorMsg">Its text.</param>
        /// <param name="advancedOrderRejectJson">Not used: this sample sends no orders.</param>
        public override void error(int id, long errorTime, int errorCode, string errorMsg, string advancedOrderRejectJson) =>
            owner.OnError(this, id, errorCode, errorMsg ?? string.Empty);

        /// <summary>An exception inside IBKR's client (refused socket, broken connection): its type is kept as the reason of a failed connect.</summary>
        /// <param name="e">The exception.</param>
        public override void error(Exception e) => connectFailure ??= e?.GetType().Name;

        /// <summary>A free-text notice of IBKR's client; nothing to do.</summary>
        /// <param name="str">The text.</param>
        public override void error(string str)
        {
        }

        /// <summary>The gateway's answer to the start-API message: the API is ready for requests.</summary>
        /// <param name="orderId">The next valid id; not used, this sample sends no orders.</param>
        public override void nextValidId(int orderId) => ApiReady.TrySetResult();

        /// <summary>The answer to the server-time request.</summary>
        /// <param name="time">IBKR's server time in epoch seconds.</param>
        public override void currentTime(long time) => TakePendingTime()?.TrySetResult(DateTimeOffset.FromUnixTimeSeconds(time));

        /// <summary>The connection is closed (by the peer or by <see cref="Close"/>): fail what was pending and tell the session.</summary>
        public override void connectionClosed()
        {
            ApiReady.TrySetException(new GatewayNotReadyException("the gateway closed the connection while connecting"));
            TakePendingTime()?.TrySetException(new GatewayNotReadyException("the connection closed during the request"));
            owner.OnConnectionClosed(this);
        }

        /// <summary>Takes the pending server-time request, if any, so that it is completed once.</summary>
        /// <returns>The pending completion source, or <c>null</c>.</returns>
        private TaskCompletionSource<DateTimeOffset>? TakePendingTime()
        {
            lock (gate)
            {
                var pending = pendingTime;
                pendingTime = null;
                return pending;
            }
        }
    }
}
