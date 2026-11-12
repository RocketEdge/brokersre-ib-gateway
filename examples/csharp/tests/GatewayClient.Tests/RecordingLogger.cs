using Microsoft.Extensions.Logging;

namespace GatewayClient.Tests;

/// <summary>
/// An <see cref="ILogger{TCategoryName}"/> that keeps every formatted message with its level,
/// so that a test can assert on what an operator would read.
/// </summary>
/// <typeparam name="T">The logger category.</typeparam>
internal sealed class RecordingLogger<T> : ILogger<T>
{
    /// <summary>Every message logged so far.</summary>
    public List<(LogLevel Level, string Message)> Entries { get; } = [];

    /// <inheritdoc />
    public IDisposable? BeginScope<TState>(TState state)
        where TState : notnull => null;

    /// <inheritdoc />
    public bool IsEnabled(LogLevel logLevel) => true;

    /// <inheritdoc />
    public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception, Func<TState, Exception?, string> formatter)
    {
        ArgumentNullException.ThrowIfNull(formatter);
        Entries.Add((logLevel, formatter(state, exception)));
    }
}
