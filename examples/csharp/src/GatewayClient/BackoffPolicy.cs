namespace GatewayClient;

/// <summary>
/// Capped exponential back-off with jitter for connection attempts.
/// </summary>
/// <remarks>
/// <para>
/// The delay before retry number <c>attempt</c> (0 for the first retry) is drawn uniformly
/// from <c>[raw * (1 - Jitter), raw]</c> with
/// <c>raw = min(MaxDelay, BaseDelay * 2^attempt)</c>. Jitter only shortens the delay, so
/// <see cref="MaxDelay"/> is a hard upper bound.
/// </para>
/// <para>
/// Why: a gateway that restarts must not be hammered, and several clients of one gateway
/// must not reconnect in the same instant.
/// </para>
/// <para>Immutable, therefore safe to share between threads.</para>
/// </remarks>
public sealed record BackoffPolicy
{
    /// <summary>
    /// Largest exponent used: 2^32 seconds is far beyond any sensible cap, and a bounded
    /// exponent keeps the arithmetic finite after days of retries.
    /// </summary>
    private const int MaxExponent = 32;

    /// <summary>
    /// Creates a policy.
    /// </summary>
    /// <param name="baseDelay">Delay before the first retry; positive.</param>
    /// <param name="maxDelay">Largest delay; at least <paramref name="baseDelay"/>.</param>
    /// <param name="jitter">Fraction of the delay that may be shaved off, from 0 (none) to 1.</param>
    /// <exception cref="ArgumentOutOfRangeException">A value is outside its range.</exception>
    public BackoffPolicy(TimeSpan baseDelay, TimeSpan maxDelay, double jitter)
    {
        ArgumentOutOfRangeException.ThrowIfLessThanOrEqual(baseDelay, TimeSpan.Zero);
        ArgumentOutOfRangeException.ThrowIfLessThan(maxDelay, baseDelay);
        if (double.IsNaN(jitter) || jitter < 0 || jitter > 1)
        {
            throw new ArgumentOutOfRangeException(nameof(jitter), jitter, "jitter must be between 0 and 1");
        }

        BaseDelay = baseDelay;
        MaxDelay = maxDelay;
        Jitter = jitter;
    }

    /// <summary>One second doubling up to thirty, with a quarter of jitter.</summary>
    public static BackoffPolicy Default { get; } = new(TimeSpan.FromSeconds(1), TimeSpan.FromSeconds(30), 0.25);

    /// <summary>Delay before the first retry.</summary>
    public TimeSpan BaseDelay { get; }

    /// <summary>Largest delay.</summary>
    public TimeSpan MaxDelay { get; }

    /// <summary>Fraction of the delay that may be shaved off, from 0 to 1.</summary>
    public double Jitter { get; }

    /// <summary>
    /// Returns the pause before retry number <paramref name="attempt"/>.
    /// </summary>
    /// <param name="attempt">Number of the retry, counted from 0; must not be negative.</param>
    /// <param name="random">Source of the jitter (injected so that tests are deterministic).</param>
    /// <returns>A delay in <c>[raw * (1 - Jitter), raw]</c>, never above <see cref="MaxDelay"/>.</returns>
    /// <exception cref="ArgumentOutOfRangeException"><paramref name="attempt"/> is negative.</exception>
    /// <exception cref="ArgumentNullException"><paramref name="random"/> is <c>null</c>.</exception>
    public TimeSpan DelayFor(int attempt, Random random)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(attempt);
        ArgumentNullException.ThrowIfNull(random);
        var raw = Math.Min(MaxDelay.TotalSeconds, BaseDelay.TotalSeconds * Math.Pow(2, Math.Min(attempt, MaxExponent)));
        return TimeSpan.FromSeconds(raw * (1 - (Jitter * random.NextDouble())));
    }
}
