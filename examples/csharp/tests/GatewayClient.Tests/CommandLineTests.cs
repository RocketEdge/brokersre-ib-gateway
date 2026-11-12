using AwesomeAssertions;
using Xunit;

namespace GatewayClient.Tests;

/// <summary>
/// Tests for <see cref="CommandLine"/>: options, environment and defaults of the sample's
/// executable, parsed without starting anything.
/// </summary>
public sealed class CommandLineTests
{
    /// <summary>No option and no environment: loopback, the paper port, a client id of its own.</summary>
    [Fact]
    public void Parse_NothingGiven_UsesTheDefaults()
    {
        var options = CommandLine.Parse([], NoEnvironment);

        (options.Host, options.Port, options.ClientId, options.PollInterval).Should().Be(
            ("127.0.0.1", 4002, 101, TimeSpan.FromSeconds(30)),
            "these are the documented defaults");
    }

    /// <summary>Every documented option reaches the configuration.</summary>
    [Fact]
    public void Parse_AllOptions_SetsHostPortClientIdAndInterval()
    {
        var options = CommandLine.Parse(["--host", "ib-gateway", "--port", "4004", "--client-id", "7", "--interval", "5"], NoEnvironment);

        (options.Host, options.Port, options.ClientId, options.PollInterval).Should().Be(
            ("ib-gateway", 4004, 7, TimeSpan.FromSeconds(5)),
            "each option sets its own property");
    }

    /// <summary>IBGW_HOST and IBGW_PORT are the variables wait-for-gateway.sh reads as well.</summary>
    [Fact]
    public void Parse_EnvironmentOnly_SuppliesHostPortAndClientId()
    {
        var environment = Environment(("IBGW_HOST", "gateway.test"), ("IBGW_PORT", "4003"), ("IB_CLIENT_ID", "9"));

        var options = CommandLine.Parse([], environment);

        (options.Host, options.Port, options.ClientId).Should().Be(("gateway.test", 4003, 9), "the environment supplies the defaults");
    }

    /// <summary>What is typed on the command line is more specific than the environment.</summary>
    [Fact]
    public void Parse_OptionAndEnvironment_OptionWins()
    {
        var options = CommandLine.Parse(["--port", "4004"], Environment(("IBGW_PORT", "4003")));

        options.Port.Should().Be(4004, "an option overrides the environment");
    }

    /// <summary>A value that cannot work is a usage error that names the option.</summary>
    /// <param name="option">The option under test.</param>
    /// <param name="value">A value it must refuse.</param>
    [Theory]
    [InlineData("--port", "not-a-number")]
    [InlineData("--port", "0")]
    [InlineData("--port", "70000")]
    [InlineData("--client-id", "-3")]
    [InlineData("--client-id", "seven")]
    [InlineData("--interval", "0")]
    [InlineData("--interval", "soon")]
    [InlineData("--host", " ")]
    public void Parse_ValueThatCannotWork_ThrowsNamingTheOption(string option, string value)
    {
        var act = () => CommandLine.Parse([option, value], NoEnvironment);

        act.Should().Throw<ArgumentException>("the value cannot work").WithMessage($"*{option}*");
    }

    /// <summary>An unknown option and an option without its value are usage errors.</summary>
    /// <param name="arguments">The command line, space separated.</param>
    [Theory]
    [InlineData("--frobnicate 1")]
    [InlineData("--port")]
    [InlineData("stray")]
    public void Parse_MalformedCommandLine_Throws(string arguments)
    {
        var act = () => CommandLine.Parse(arguments.Split(' '), NoEnvironment);

        act.Should().Throw<ArgumentException>("the command line is malformed");
    }

    /// <summary>A typo in IBGW_PORT is reported like a typo in --port, naming the variable.</summary>
    [Fact]
    public void Parse_EnvironmentValueThatCannotWork_ThrowsNamingTheVariable()
    {
        var act = () => CommandLine.Parse([], Environment(("IBGW_PORT", "paper")));

        act.Should().Throw<ArgumentException>("the environment value cannot work").WithMessage("*IBGW_PORT*");
    }

    /// <summary>The usage text names every option and every environment variable.</summary>
    [Fact]
    public void Usage_NamesEveryOptionAndVariable()
    {
        CommandLine.Usage.Should().ContainAll(
            ["--host", "--port", "--client-id", "--interval", "IBGW_HOST", "IBGW_PORT", "IB_CLIENT_ID"],
            "the usage text is the only help the executable prints");
    }

    /// <summary>An environment without any variable.</summary>
    /// <param name="name">The variable asked for.</param>
    /// <returns>Always <c>null</c>.</returns>
    private static string? NoEnvironment(string name) => null;

    /// <summary>Builds an environment lookup from name/value pairs.</summary>
    /// <param name="variables">The variables that are set.</param>
    /// <returns>A lookup that returns <c>null</c> for any other name.</returns>
    private static Func<string, string?> Environment(params (string Name, string Value)[] variables)
    {
        var map = variables.ToDictionary(variable => variable.Name, variable => variable.Value, StringComparer.Ordinal);
        return name => map.GetValueOrDefault(name);
    }
}
