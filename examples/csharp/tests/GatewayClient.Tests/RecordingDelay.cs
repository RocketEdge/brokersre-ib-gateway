namespace GatewayClient.Tests;

/// <summary>
/// Stand-in for <c>Task.Delay</c>: records every pause and returns at once.
/// </summary>
/// <remarks>
/// <see cref="Events"/> maps the index of a pause (0 for the first) to an action run during
/// that pause, which is how a test lets the gateway do something "while the client sleeps".
/// After <c>stopAfter</c> pauses the delay throws <see cref="OperationCanceledException"/>,
/// the way a real client is stopped by cancelling its token.
/// </remarks>
/// <param name="stopAfter">Number of pauses after which the client is stopped; <c>null</c> for never.</param>
internal sealed class RecordingDelay(int? stopAfter = null)
{
    /// <summary>Every pause requested so far, in order.</summary>
    public List<TimeSpan> Delays { get; } = [];

    /// <summary>Actions to run during the pause with the given index.</summary>
    public Dictionary<int, Action> Events { get; } = [];

    /// <summary>Records <paramref name="delay"/>, runs the scripted action, maybe stops the client.</summary>
    /// <param name="delay">The pause the client asked for.</param>
    /// <param name="cancellationToken">Unused: the stop is scripted by <c>stopAfter</c>.</param>
    /// <returns>A completed task.</returns>
    /// <exception cref="OperationCanceledException">When <c>stopAfter</c> pauses have been recorded.</exception>
    public Task DelayAsync(TimeSpan delay, CancellationToken cancellationToken)
    {
        var index = Delays.Count;
        Delays.Add(delay);
        if (Events.TryGetValue(index, out var action))
        {
            action();
        }

        if (stopAfter is not null && Delays.Count >= stopAfter)
        {
            throw new OperationCanceledException("the test stops the client here");
        }

        return Task.CompletedTask;
    }
}
