using System.Globalization;

namespace GatewayClient;

/// <summary>
/// Turns the executable's command line and environment into <see cref="ClientOptions"/>.
/// </summary>
/// <remarks>
/// Kept in the library, away from the executable, so that it is tested without IBKR's
/// assembly. An option wins over its environment variable; the variables are the ones
/// <c>examples/wait-for-gateway.sh</c> reads (<c>IBGW_HOST</c>, <c>IBGW_PORT</c>) plus
/// <c>IB_CLIENT_ID</c>. Pure: no I/O, the environment is passed in as a lookup.
/// </remarks>
public static class CommandLine
{
    /// <summary>The help text of the executable.</summary>
    public const string Usage =
        """
        usage: GatewayClient.IbApi [--host HOST] [--port PORT] [--client-id ID] [--interval SECONDS]
          --host HOST         gateway host name or address   (default: $IBGW_HOST, else 127.0.0.1)
          --port PORT         API port                       (default: $IBGW_PORT, else 4002)
          --client-id ID      TWS API client id              (default: $IB_CLIENT_ID, else 101)
          --interval SECONDS  seconds between two requests   (default: 30)
        Read-only example: prints the IBKR server time and survives gateway outages.
        """;

    /// <summary>
    /// Parses the command line.
    /// </summary>
    /// <param name="arguments">The arguments without the program name: pairs of option and value.</param>
    /// <param name="environment">Looks up an environment variable; returns <c>null</c> when it is not set.</param>
    /// <returns>The options; a value given as an option wins over the environment.</returns>
    /// <exception cref="ArgumentException">
    /// An unknown option, an option without a value, or a value that cannot work. The message
    /// names the option or the environment variable.
    /// </exception>
    public static ClientOptions Parse(IReadOnlyList<string> arguments, Func<string, string?> environment)
    {
        ArgumentNullException.ThrowIfNull(arguments);
        ArgumentNullException.ThrowIfNull(environment);
        var values = new Dictionary<string, (string Source, string Text)>(StringComparer.Ordinal);
        AddFromEnvironment(values, environment, "--host", "IBGW_HOST");
        AddFromEnvironment(values, environment, "--port", "IBGW_PORT");
        AddFromEnvironment(values, environment, "--client-id", "IB_CLIENT_ID");
        for (var index = 0; index < arguments.Count; index += 2)
        {
            var option = arguments[index];
            if (option is not ("--host" or "--port" or "--client-id" or "--interval"))
            {
                throw new ArgumentException($"unknown option or argument: {option}", nameof(arguments));
            }

            if (index + 1 >= arguments.Count)
            {
                throw new ArgumentException($"{option} needs a value", nameof(arguments));
            }

            values[option] = (option, arguments[index + 1]);
        }

        var options = new ClientOptions();
        if (values.TryGetValue("--host", out var host))
        {
            options = Apply(host.Source, "a host name or an address", () => options with { Host = host.Text });
        }

        if (values.TryGetValue("--port", out var port))
        {
            options = Apply(port.Source, "a number from 1 to 65535", () => options with { Port = ParseInteger(port.Text) });
        }

        if (values.TryGetValue("--client-id", out var clientId))
        {
            options = Apply(clientId.Source, "a whole number, 0 or more", () => options with { ClientId = ParseInteger(clientId.Text) });
        }

        if (values.TryGetValue("--interval", out var interval))
        {
            options = Apply(interval.Source, "a positive number of seconds", () => options with { PollInterval = TimeSpan.FromSeconds(ParseSeconds(interval.Text)) });
        }

        return options;
    }

    /// <summary>Records the value of an environment variable as the default of an option.</summary>
    /// <param name="values">The values collected so far, keyed by option.</param>
    /// <param name="environment">The environment lookup.</param>
    /// <param name="option">The option the variable stands for.</param>
    /// <param name="variable">The environment variable.</param>
    private static void AddFromEnvironment(
        Dictionary<string, (string Source, string Text)> values,
        Func<string, string?> environment,
        string option,
        string variable)
    {
        if (environment(variable) is { Length: > 0 } text)
        {
            values[option] = (variable, text);
        }
    }

    /// <summary>
    /// Builds the next options object and turns a refused value into a usage error that names
    /// where the value came from.
    /// </summary>
    /// <param name="source">The option or environment variable the value came from.</param>
    /// <param name="expected">What a usable value looks like, for the message.</param>
    /// <param name="build">Creates the options with the new value; may throw.</param>
    /// <returns>The new options.</returns>
    /// <exception cref="ArgumentException">
    /// The value was refused. The message names <paramref name="source"/> and what is
    /// expected; it does not repeat the value.
    /// </exception>
    private static ClientOptions Apply(string source, string expected, Func<ClientOptions> build)
    {
        try
        {
            return build();
        }
        catch (Exception exception) when (exception is ArgumentException or FormatException or OverflowException)
        {
            throw new ArgumentException($"{source}: expected {expected}", exception);
        }
    }

    /// <summary>Parses a whole number in the invariant culture.</summary>
    /// <param name="text">The text to parse.</param>
    /// <returns>The number.</returns>
    /// <exception cref="FormatException">The text is not a whole number.</exception>
    private static int ParseInteger(string text) => int.Parse(text, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture);

    /// <summary>Parses a number of seconds in the invariant culture.</summary>
    /// <param name="text">The text to parse.</param>
    /// <returns>The number of seconds.</returns>
    /// <exception cref="FormatException">The text is not a number.</exception>
    private static double ParseSeconds(string text) => double.Parse(text, NumberStyles.Float, CultureInfo.InvariantCulture);
}
