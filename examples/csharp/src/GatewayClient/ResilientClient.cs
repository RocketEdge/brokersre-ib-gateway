using Microsoft.Extensions.Logging;

namespace GatewayClient;

/// <summary>
/// Keeps one read-only API connection usable across outages and gateway restarts.
/// </summary>
/// <remarks>
/// <para>
/// The client owns an <see cref="IBrokerSession"/> and a <see cref="GatewayState"/>.
/// <see cref="RunAsync"/> loops until cancelled: connect when disconnected (retrying with
/// back-off), ask for the server time when ready, pause. Events from the session (IBKR
/// message codes, a closed socket) update the state between two steps; they never start a
/// request themselves.
/// </para>
/// <para>Robustness rules it implements:</para>
/// <list type="bullet">
/// <item>a failed connection attempt is normal ("gateway not ready"), never an error;</item>
/// <item>during IBKR code 1100 nothing is sent and the connection is kept;</item>
/// <item>
/// <see cref="ClientOptions.MaxMissedPolls"/> unanswered requests in a row replace a
/// connection that looks dead (a half-open socket never reports a disconnect);
/// </item>
/// <item>stopping (cancelling <see cref="RunAsync"/>) closes the connection, which frees the client id.</item>
/// </list>
/// <para>
/// Threading: the loop runs one step at a time on the caller's task; the session raises its
/// events on its own thread (IBKR's client has a message thread). Every access to the state
/// and the counters therefore takes the same lock. The re-subscribe hook and the logger are
/// called outside the lock. <see cref="Random"/> is used by the loop only.
/// </para>
/// <para>
/// Log lines carry codes and farm names, never the raw text of an IBKR message: that text
/// can name an account.
/// </para>
/// </remarks>
public sealed partial class ResilientClient
{
    private readonly Lock gate = new();
    private readonly GatewayState state = new();
    private readonly IBrokerSession session;
    private readonly ClientOptions options;
    private readonly ILogger<ResilientClient> logger;
    private readonly Func<TimeSpan, CancellationToken, Task> delay;
    private readonly Random random;
    private readonly Action? onResubscribe;
    private int missedPolls;
    private int resubscriptions;
    private DateTimeOffset? lastServerTime;
    private volatile bool stopping;

    /// <summary>
    /// Creates the client and attaches it to the session's events.
    /// </summary>
    /// <param name="session">The broker boundary; not connected yet.</param>
    /// <param name="options">Endpoint, timeouts and back-off.</param>
    /// <param name="logger">Where the client reports what it does.</param>
    /// <param name="delay">Awaitable pause; <see cref="Task.Delay(TimeSpan, CancellationToken)"/> when omitted (injected by the tests).</param>
    /// <param name="random">Source of the back-off jitter; a new generator when omitted.</param>
    /// <param name="onResubscribe">
    /// Called whenever subscriptions must be (re-)established: after every connection and
    /// after every IBKR code 1101. This sample has none; a strategy sets up its subscriptions
    /// here. It may be called on the session's event thread.
    /// </param>
    /// <exception cref="ArgumentNullException">A required argument is <c>null</c>.</exception>
    public ResilientClient(
        IBrokerSession session,
        ClientOptions options,
        ILogger<ResilientClient> logger,
        Func<TimeSpan, CancellationToken, Task>? delay = null,
        Random? random = null,
        Action? onResubscribe = null)
    {
        ArgumentNullException.ThrowIfNull(session);
        ArgumentNullException.ThrowIfNull(options);
        ArgumentNullException.ThrowIfNull(logger);
        this.session = session;
        this.options = options;
        this.logger = logger;
        this.delay = delay ?? Task.Delay;
        this.random = random ?? new Random();
        this.onResubscribe = onResubscribe;
        session.ErrorReceived += OnErrorReceived;
        session.Disconnected += OnDisconnected;
    }

    /// <summary>Whether requests may be sent right now.</summary>
    public Readiness Readiness
    {
        get
        {
            lock (gate)
            {
                return state.Readiness;
            }
        }
    }

    /// <summary>Names of the data farms currently reported broken, sorted (a snapshot).</summary>
    public IReadOnlyList<string> BrokenFarms
    {
        get
        {
            lock (gate)
            {
                return state.BrokenFarms;
            }
        }
    }

    /// <summary>
    /// How often subscriptions had to be (re-)established: once per connection plus once per
    /// IBKR code 1101.
    /// </summary>
    public int Resubscriptions
    {
        get
        {
            lock (gate)
            {
                return resubscriptions;
            }
        }
    }

    /// <summary>The last server time received (UTC), or <c>null</c>.</summary>
    public DateTimeOffset? LastServerTime
    {
        get
        {
            lock (gate)
            {
                return lastServerTime;
            }
        }
    }

    /// <summary>
    /// Makes one connection attempt.
    /// </summary>
    /// <param name="cancellationToken">Cancels the attempt.</param>
    /// <returns>
    /// <c>true</c> when the connection stands (the state is then <see cref="Readiness.Ready"/>
    /// and the re-subscribe hook has run); <c>false</c> when the gateway is not ready
    /// (<see cref="GatewayNotReadyException"/>: refused, not answered in time, cut while
    /// connecting). Any other exception is a defect and propagates.
    /// </returns>
    public async Task<bool> ConnectOnceAsync(CancellationToken cancellationToken)
    {
        try
        {
            await session.ConnectAsync(options.Host, options.Port, options.ClientId, options.ConnectTimeout, cancellationToken).ConfigureAwait(false);
        }
        catch (GatewayNotReadyException exception)
        {
            LogNotReady(options.Host, options.Port, exception.Message);
            return false;
        }

        GatewayAction action;
        lock (gate)
        {
            missedPolls = 0;
            action = state.OnConnected();
        }

        LogConnected(options.Host, options.Port, options.ClientId);
        Apply(action);
        return true;
    }

    /// <summary>
    /// Retries <see cref="ConnectOnceAsync"/> until it succeeds, pausing per the back-off policy.
    /// </summary>
    /// <remarks>
    /// The attempt counter starts at zero on every call, so a later outage is retried quickly
    /// at first. There is no attempt limit: a gateway may wait for a second factor for a long
    /// time, and giving up would only move the retry loop into a supervisor.
    /// </remarks>
    /// <param name="cancellationToken">Cancels the wait.</param>
    /// <returns>A task that completes when the connection stands.</returns>
    public async Task ConnectUntilReadyAsync(CancellationToken cancellationToken)
    {
        var attempt = 0;
        while (!await ConnectOnceAsync(cancellationToken).ConfigureAwait(false))
        {
            var pause = options.Backoff.DelayFor(attempt, random);
            LogNextAttempt(pause.TotalSeconds);
            await delay(pause, cancellationToken).ConfigureAwait(false);
            attempt++;
        }
    }

    /// <summary>
    /// Asks for the IBKR server time if, and only if, the client is ready.
    /// </summary>
    /// <param name="cancellationToken">Cancels the request.</param>
    /// <returns>
    /// The server time (UTC), or <c>null</c> when nothing was sent (disconnected, or paused by
    /// IBKR code 1100) or no usable answer came. An unanswered request counts towards
    /// <see cref="ClientOptions.MaxMissedPolls"/>; reaching it, or a connection that closed
    /// during the request, drops the connection so that <see cref="RunAsync"/> reconnects.
    /// </returns>
    public async Task<DateTimeOffset?> PollOnceAsync(CancellationToken cancellationToken)
    {
        if (Readiness != Readiness.Ready)
        {
            return null;
        }

        DateTimeOffset answer;
        try
        {
            answer = await session.GetServerTimeAsync(options.RequestTimeout, cancellationToken).ConfigureAwait(false);
        }
        catch (TimeoutException)
        {
            int missed;
            lock (gate)
            {
                missed = ++missedPolls;
            }

            LogMissedPoll(missed, options.MaxMissedPolls);
            if (missed >= options.MaxMissedPolls)
            {
                LogConnectionLooksDead();
                DropConnection();
            }

            return null;
        }
        catch (GatewayNotReadyException)
        {
            LogClosedDuringRequest();
            DropConnection();
            return null;
        }

        var utc = answer.ToUniversalTime();
        lock (gate)
        {
            missedPolls = 0;
            lastServerTime = utc;
        }

        LogServerTime(utc);
        return utc;
    }

    /// <summary>
    /// Runs until cancelled: connect when needed, poll when ready, pause, repeat.
    /// </summary>
    /// <param name="cancellationToken">Cancelling it is the way to stop the client.</param>
    /// <returns>A task that ends with <see cref="OperationCanceledException"/> when stopped.</returns>
    /// <exception cref="OperationCanceledException">The client was stopped; the connection has been closed.</exception>
    public async Task RunAsync(CancellationToken cancellationToken)
    {
        stopping = false;
        try
        {
            while (true)
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (Readiness == Readiness.Disconnected)
                {
                    await ConnectUntilReadyAsync(cancellationToken).ConfigureAwait(false);
                }

                await PollOnceAsync(cancellationToken).ConfigureAwait(false);
                await delay(options.PollInterval, cancellationToken).ConfigureAwait(false);
            }
        }
        finally
        {
            // Tell the disconnect handler that this disconnect is ours, not the gateway's.
            stopping = true;
            session.Disconnect();
        }
    }

    /// <summary>Carries out what the state machine asked for (only re-subscribing needs work).</summary>
    /// <param name="action">The action returned by <see cref="GatewayState"/>.</param>
    private void Apply(GatewayAction action)
    {
        if (action != GatewayAction.Resubscribe)
        {
            return;
        }

        lock (gate)
        {
            resubscriptions++;
        }

        onResubscribe?.Invoke();
    }

    /// <summary>Closes the connection and makes sure the state says so, whatever the session reports.</summary>
    private void DropConnection()
    {
        session.Disconnect();
        OnDisconnected();
    }

    /// <summary>
    /// Reacts to one IBKR message code. Called on the session's event thread.
    /// </summary>
    /// <param name="requestId">Request the message belongs to, or -1; not used.</param>
    /// <param name="code">The IBKR message code.</param>
    /// <param name="message">Its text; read for the farm name only and never logged.</param>
    private void OnErrorReceived(int requestId, int code, string message)
    {
        if (code == IbkrCodes.ClientIdInUse)
        {
            LogClientIdInUse(options.ClientId);
            return;
        }

        GatewayAction action;
        IReadOnlyList<string> farmsBefore;
        IReadOnlyList<string> farmsAfter;
        lock (gate)
        {
            farmsBefore = state.BrokenFarms;
            action = state.OnError(code, message);
            farmsAfter = state.BrokenFarms;
        }

        switch (action)
        {
            case GatewayAction.Pause:
                LogConnectivityLost();
                break;
            case GatewayAction.Resume:
                LogConnectivityRestored();
                break;
            case GatewayAction.Resubscribe:
                LogConnectivityRestoredDataLost();
                break;
            default:
                if (!farmsBefore.SequenceEqual(farmsAfter, StringComparer.Ordinal))
                {
                    LogFarms(code, farmsAfter.Count == 0 ? "none" : string.Join(", ", farmsAfter));
                }

                break;
        }

        Apply(action);
    }

    /// <summary>
    /// Records a closed connection once; <see cref="RunAsync"/> reconnects on its next step.
    /// Called on the session's event thread or by <see cref="DropConnection"/>.
    /// </summary>
    private void OnDisconnected()
    {
        lock (gate)
        {
            if (state.Readiness == Readiness.Disconnected)
            {
                return;
            }

            state.OnDisconnected();
        }

        // A disconnect made by RunAsync on its way out is a stop: the last line of a stopped
        // client must not promise a reconnect.
        if (stopping)
        {
            LogStopped();
        }
        else
        {
            LogDisconnected();
        }
    }

    [LoggerMessage(EventId = 1, Level = LogLevel.Information, Message = "gateway not ready at {Host}:{Port} ({Reason})")]
    private partial void LogNotReady(string host, int port, string reason);

    [LoggerMessage(EventId = 2, Level = LogLevel.Information, Message = "connected to {Host}:{Port}, client id {ClientId}")]
    private partial void LogConnected(string host, int port, int clientId);

    [LoggerMessage(EventId = 3, Level = LogLevel.Information, Message = "next connection attempt in {Seconds:F1} s")]
    private partial void LogNextAttempt(double seconds);

    [LoggerMessage(EventId = 4, Level = LogLevel.Warning, Message = "no answer to the server-time request ({Missed} of {Limit} in a row)")]
    private partial void LogMissedPoll(int missed, int limit);

    [LoggerMessage(EventId = 5, Level = LogLevel.Error, Message = "the connection looks dead: closing it to reconnect")]
    private partial void LogConnectionLooksDead();

    [LoggerMessage(EventId = 6, Level = LogLevel.Warning, Message = "the connection closed during the server-time request")]
    private partial void LogClosedDuringRequest();

    [LoggerMessage(EventId = 7, Level = LogLevel.Information, Message = "IBKR server time {ServerTime:O}")]
    private partial void LogServerTime(DateTimeOffset serverTime);

    [LoggerMessage(EventId = 8, Level = LogLevel.Error, Message = "client id {ClientId} is already in use on this gateway (IBKR code 326): stop the other client or choose another --client-id")]
    private partial void LogClientIdInUse(int clientId);

    [LoggerMessage(EventId = 9, Level = LogLevel.Warning, Message = "IBKR code 1100: connectivity lost; sending nothing, keeping the connection")]
    private partial void LogConnectivityLost();

    [LoggerMessage(EventId = 10, Level = LogLevel.Information, Message = "IBKR code 1102: connectivity restored, data maintained; continuing")]
    private partial void LogConnectivityRestored();

    [LoggerMessage(EventId = 11, Level = LogLevel.Warning, Message = "IBKR code 1101: connectivity restored, data lost; re-subscribing")]
    private partial void LogConnectivityRestoredDataLost();

    [LoggerMessage(EventId = 12, Level = LogLevel.Information, Message = "IBKR code {Code}: data farms now broken: {Farms}")]
    private partial void LogFarms(int code, string farms);

    [LoggerMessage(EventId = 13, Level = LogLevel.Warning, Message = "disconnected from the gateway (restart or shutdown); will reconnect")]
    private partial void LogDisconnected();

    [LoggerMessage(EventId = 14, Level = LogLevel.Information, Message = "disconnected: client stopped")]
    private partial void LogStopped();
}
