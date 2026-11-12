namespace GatewayClient;

/// <summary>
/// Settings of one <see cref="ResilientClient"/>.
/// </summary>
/// <remarks>
/// Every property validates its value when it is set (C# 14 <c>field</c> keyword), so an
/// impossible configuration fails where it is written, not when the client first needs it.
/// Immutable after construction.
/// </remarks>
public sealed record ClientOptions
{
    /// <summary>Gateway host name or address. Must not be blank.</summary>
    /// <exception cref="ArgumentException">The value is null, empty or white space.</exception>
    public string Host
    {
        get;
        init
        {
            ArgumentException.ThrowIfNullOrWhiteSpace(value);
            field = value;
        }
    } = "127.0.0.1";

    /// <summary>
    /// API port (1 to 65535): the relay port of the gateway container (4003 live, 4004 paper)
    /// or the host port it is published on (4001 live, 4002 paper).
    /// </summary>
    /// <exception cref="ArgumentOutOfRangeException">The value is outside 1 to 65535.</exception>
    public int Port
    {
        get;
        init
        {
            ArgumentOutOfRangeException.ThrowIfLessThan(value, 1);
            ArgumentOutOfRangeException.ThrowIfGreaterThan(value, 65535);
            field = value;
        }
    } = 4002;

    /// <summary>
    /// TWS API client id (0 or more). Every client connected to one gateway needs its own; a
    /// duplicate is refused with IBKR code 326.
    /// </summary>
    /// <exception cref="ArgumentOutOfRangeException">The value is negative.</exception>
    public int ClientId
    {
        get;
        init
        {
            ArgumentOutOfRangeException.ThrowIfNegative(value);
            field = value;
        }
    } = 101;

    /// <summary>Time between two server-time requests; positive.</summary>
    /// <exception cref="ArgumentOutOfRangeException">The value is zero or negative.</exception>
    public TimeSpan PollInterval
    {
        get;
        init
        {
            ArgumentOutOfRangeException.ThrowIfLessThanOrEqual(value, TimeSpan.Zero);
            field = value;
        }
    } = TimeSpan.FromSeconds(30);

    /// <summary>How long one connection attempt may take; positive.</summary>
    /// <exception cref="ArgumentOutOfRangeException">The value is zero or negative.</exception>
    public TimeSpan ConnectTimeout
    {
        get;
        init
        {
            ArgumentOutOfRangeException.ThrowIfLessThanOrEqual(value, TimeSpan.Zero);
            field = value;
        }
    } = TimeSpan.FromSeconds(10);

    /// <summary>How long to wait for the server time; positive.</summary>
    /// <exception cref="ArgumentOutOfRangeException">The value is zero or negative.</exception>
    public TimeSpan RequestTimeout
    {
        get;
        init
        {
            ArgumentOutOfRangeException.ThrowIfLessThanOrEqual(value, TimeSpan.Zero);
            field = value;
        }
    } = TimeSpan.FromSeconds(10);

    /// <summary>
    /// Unanswered requests in a row after which the connection is treated as dead and
    /// replaced; at least 1.
    /// </summary>
    /// <exception cref="ArgumentOutOfRangeException">The value is below 1.</exception>
    public int MaxMissedPolls
    {
        get;
        init
        {
            ArgumentOutOfRangeException.ThrowIfLessThan(value, 1);
            field = value;
        }
    } = 3;

    /// <summary>Pause policy between connection attempts.</summary>
    /// <exception cref="ArgumentNullException">The value is <c>null</c>.</exception>
    public BackoffPolicy Backoff
    {
        get;
        init
        {
            ArgumentNullException.ThrowIfNull(value);
            field = value;
        }
    } = BackoffPolicy.Default;
}
