using AwesomeAssertions;
using Xunit;

namespace GatewayClient.Tests;

/// <summary>
/// Tests for <see cref="BackoffPolicy"/>: the pause between two connection attempts must
/// grow, stay under its cap and stay inside its jitter band.
/// </summary>
public sealed class BackoffPolicyTests
{
    /// <summary>Without jitter the delays are base, 2x, 4x, ... and then the cap, forever.</summary>
    [Fact]
    public void DelayFor_WithoutJitter_DoublesUntilTheCap()
    {
        var policy = new BackoffPolicy(TimeSpan.FromSeconds(1), TimeSpan.FromSeconds(30), jitter: 0);
        var random = new Random(1);

        var delays = Enumerable.Range(0, 8).Select(attempt => policy.DelayFor(attempt, random).TotalSeconds);

        delays.Should().Equal([1, 2, 4, 8, 16, 30, 30, 30], "the delay doubles from the base and then stays at the cap");
    }

    /// <summary>With jitter j the delay lies in [raw * (1 - j), raw] and never above the cap.</summary>
    /// <param name="seed">Seed of the random generator, so that every run draws the same values.</param>
    [Theory]
    [InlineData(1)]
    [InlineData(2)]
    [InlineData(3)]
    [InlineData(42)]
    [InlineData(2026)]
    public void DelayFor_WithJitter_StaysInsideTheBandAndUnderTheCap(int seed)
    {
        var policy = new BackoffPolicy(TimeSpan.FromSeconds(0.5), TimeSpan.FromSeconds(20), jitter: 0.25);
        var random = new Random(seed);

        for (var attempt = 0; attempt < 12; attempt++)
        {
            var raw = Math.Min(20.0, 0.5 * Math.Pow(2, attempt));

            var delay = policy.DelayFor(attempt, random).TotalSeconds;

            delay.Should().BeInRange(raw * 0.75, raw, "jitter may only shorten the delay of attempt {0}, by at most a quarter", attempt);
        }
    }

    /// <summary>Two draws for the same attempt differ, so clients do not reconnect in lock-step.</summary>
    [Fact]
    public void DelayFor_WithJitter_VariesBetweenDraws()
    {
        var policy = new BackoffPolicy(TimeSpan.FromSeconds(1), TimeSpan.FromSeconds(30), jitter: 0.25);
        var random = new Random(7);

        var draws = Enumerable.Range(0, 10).Select(_ => policy.DelayFor(3, random)).Distinct();

        draws.Should().HaveCount(10, "every draw adds its own jitter");
    }

    /// <summary>After days of retries the attempt number is large; the delay is still the cap.</summary>
    [Fact]
    public void DelayFor_VeryLateAttempt_GivesTheCap()
    {
        var policy = new BackoffPolicy(TimeSpan.FromSeconds(1), TimeSpan.FromSeconds(30), jitter: 0);

        var delay = policy.DelayFor(100_000, new Random(1));

        delay.Should().Be(TimeSpan.FromSeconds(30), "the exponent is bounded, so the delay cannot overflow past the cap");
    }

    /// <summary>Attempt numbers count from zero; a negative one is refused, not clamped.</summary>
    [Fact]
    public void DelayFor_NegativeAttempt_Throws()
    {
        var policy = BackoffPolicy.Default;

        var act = () => policy.DelayFor(-1, new Random(1));

        act.Should().Throw<ArgumentOutOfRangeException>("a negative attempt is a programming error")
            .WithParameterName("attempt");
    }

    /// <summary>A policy that could yield a zero, negative or unbounded delay cannot be built.</summary>
    /// <param name="baseSeconds">Base delay in seconds.</param>
    /// <param name="maxSeconds">Cap in seconds.</param>
    /// <param name="jitter">Jitter fraction.</param>
    /// <param name="parameter">Name of the constructor parameter that must be blamed.</param>
    [Theory]
    [InlineData(0, 30, 0.25, "baseDelay")]
    [InlineData(-1, 30, 0.25, "baseDelay")]
    [InlineData(5, 1, 0.25, "maxDelay")]
    [InlineData(1, 30, -0.1, "jitter")]
    [InlineData(1, 30, 1.5, "jitter")]
    [InlineData(1, 30, double.NaN, "jitter")]
    public void Constructor_ImpossiblePolicy_Throws(double baseSeconds, double maxSeconds, double jitter, string parameter)
    {
        var act = () => new BackoffPolicy(TimeSpan.FromSeconds(baseSeconds), TimeSpan.FromSeconds(maxSeconds), jitter);

        act.Should().Throw<ArgumentOutOfRangeException>("the policy is validated when it is created")
            .WithParameterName(parameter);
    }

    /// <summary>The defaults suit a gateway restart: quick first retries, at most 30 s apart.</summary>
    [Fact]
    public void Default_IsOneSecondDoublingToThirtyWithAQuarterJitter()
    {
        var policy = BackoffPolicy.Default;

        (policy.BaseDelay, policy.MaxDelay, policy.Jitter).Should().Be(
            (TimeSpan.FromSeconds(1), TimeSpan.FromSeconds(30), 0.25),
            "these are the documented defaults");
    }
}
