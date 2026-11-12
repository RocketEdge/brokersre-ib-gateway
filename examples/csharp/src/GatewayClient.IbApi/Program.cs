using System.Runtime.InteropServices;
using Microsoft.Extensions.Logging;

namespace GatewayClient.IbApi;

/// <summary>
/// Entry point of the sample: a <see cref="ResilientClient"/> on IBKR's C# client that prints
/// the IBKR server time until it is stopped.
/// </summary>
internal static class Program
{
    /// <summary>
    /// Parses the command line, wires logging (UTC, one line per event) and runs the client
    /// until Ctrl+C or SIGTERM.
    /// </summary>
    /// <param name="args">The command line; see <see cref="CommandLine.Usage"/>.</param>
    /// <returns>0 after a requested stop, 2 for a usage error.</returns>
    public static async Task<int> Main(string[] args)
    {
        ClientOptions options;
        try
        {
            options = CommandLine.Parse(args, Environment.GetEnvironmentVariable);
        }
        catch (ArgumentException exception)
        {
            await Console.Error.WriteLineAsync(exception.Message).ConfigureAwait(false);
            await Console.Error.WriteLineAsync(CommandLine.Usage).ConfigureAwait(false);
            return 2;
        }

        using var loggerFactory = LoggerFactory.Create(builder => builder.AddSimpleConsole(console =>
        {
            console.SingleLine = true;
            console.UseUtcTimestamp = true;
            console.TimestampFormat = "yyyy-MM-ddTHH:mm:ss.fffZ ";
        }));
        using var stop = new CancellationTokenSource();
        Console.CancelKeyPress += (_, cancel) =>
        {
            // Keep the process alive long enough to disconnect, which frees the client id.
            cancel.Cancel = true;
            stop.Cancel();
        };
        using var terminate = PosixSignalRegistration.Create(PosixSignal.SIGTERM, signal =>
        {
            signal.Cancel = true;
            stop.Cancel();
        });

        var client = new ResilientClient(new IbApiSession(), options, loggerFactory.CreateLogger<ResilientClient>());
        try
        {
            await client.RunAsync(stop.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            // The requested stop; RunAsync has closed the connection.
        }

        return 0;
    }
}
