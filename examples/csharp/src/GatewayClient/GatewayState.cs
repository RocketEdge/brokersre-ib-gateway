namespace GatewayClient;

/// <summary>
/// Pure state machine: readiness and data-farm status derived from gateway events.
/// </summary>
/// <remarks>
/// <para>
/// It has no I/O and no clock. Feed it the three kinds of event a client sees (connected,
/// disconnected, an IBKR message code) and it answers with the <see cref="GatewayAction"/>
/// the client must take.
/// </para>
/// <para>
/// Invariants: a message code never makes a disconnected client ready; only 1101 and 1102
/// end the pause that 1100 started; a disconnect forgets the farm status, because the next
/// connection is a new session.
/// </para>
/// <para>
/// Threading: not synchronised. IBKR's API delivers callbacks on its own thread, so the
/// owner (<see cref="ResilientClient"/>) guards every call with one lock.
/// </para>
/// </remarks>
public sealed class GatewayState
{
    private readonly SortedSet<string> brokenFarms = new(StringComparer.Ordinal);

    /// <summary>Whether requests may be sent right now.</summary>
    public Readiness Readiness { get; private set; } = Readiness.Disconnected;

    /// <summary>Names of the data farms currently reported broken, sorted (a snapshot).</summary>
    public IReadOnlyList<string> BrokenFarms => [.. brokenFarms];

    /// <summary>
    /// Records a new API connection.
    /// </summary>
    /// <returns>
    /// <see cref="GatewayAction.Resubscribe"/>: a new session has no subscriptions, so
    /// whatever the client subscribes to must be set up now (again).
    /// </returns>
    public GatewayAction OnConnected()
    {
        Readiness = Readiness.Ready;
        brokenFarms.Clear();
        return GatewayAction.Resubscribe;
    }

    /// <summary>
    /// Records that the API connection is gone (closed by the peer or by the client).
    /// </summary>
    /// <returns><see cref="GatewayAction.Pause"/>: nothing may be sent until <see cref="OnConnected"/>.</returns>
    public GatewayAction OnDisconnected()
    {
        Readiness = Readiness.Disconnected;
        brokenFarms.Clear();
        return GatewayAction.Pause;
    }

    /// <summary>
    /// Applies one IBKR message code.
    /// </summary>
    /// <param name="code">The error code of the TWS API error callback.</param>
    /// <param name="message">
    /// Its text; used only to read the farm name of a data-farm code (the part after the last
    /// colon, for example <c>usfarm</c>).
    /// </param>
    /// <returns>
    /// <see cref="GatewayAction.Pause"/> for 1100, <see cref="GatewayAction.Resume"/> for
    /// 1102, <see cref="GatewayAction.Resubscribe"/> for 1101, <see cref="GatewayAction.None"/>
    /// for everything else (farm codes update <see cref="BrokenFarms"/>). Any code received
    /// while disconnected returns <see cref="GatewayAction.None"/> and changes nothing.
    /// </returns>
    public GatewayAction OnError(int code, string message)
    {
        ArgumentNullException.ThrowIfNull(message);
        if (Readiness == Readiness.Disconnected)
        {
            return GatewayAction.None;
        }

        switch (code)
        {
            case IbkrCodes.ConnectivityLost:
                Readiness = Readiness.ConnectivityLost;
                return GatewayAction.Pause;
            case IbkrCodes.ConnectivityRestoredDataKept:
                Readiness = Readiness.Ready;
                return GatewayAction.Resume;
            case IbkrCodes.ConnectivityRestoredDataLost:
                Readiness = Readiness.Ready;
                return GatewayAction.Resubscribe;
        }

        if (IbkrCodes.BrokenFarmKind(code) is { } brokenKind)
        {
            brokenFarms.Add(FarmName(message, brokenKind));
        }
        else if (IbkrCodes.RestoredFarmKind(code) is { } restoredKind)
        {
            brokenFarms.Remove(FarmName(message, restoredKind));
        }

        return GatewayAction.None;
    }

    /// <summary>
    /// Returns the farm a data-farm message is about.
    /// </summary>
    /// <remarks>
    /// IBKR writes <c>Market data farm connection is OK:usfarm</c>: the name follows the last
    /// colon. The text is not a contract, so a message without a name falls back to
    /// <paramref name="kind"/>.
    /// </remarks>
    /// <param name="message">The message text.</param>
    /// <param name="kind">The kind of farm the code stands for.</param>
    /// <returns>The farm name, or <paramref name="kind"/>.</returns>
    private static string FarmName(string message, string kind)
    {
        var colon = message.LastIndexOf(':');
        var name = colon >= 0 ? message[(colon + 1)..].Trim() : string.Empty;
        return name.Length > 0 ? name : kind;
    }
}
