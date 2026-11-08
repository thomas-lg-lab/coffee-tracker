using System.Text.Json;
using System.Text.Json.Serialization;
using CoffeeTracker.Infrastructure.Ocr;
using CoffeeTracker.Application.Ports.Driven;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;
using Xunit;

namespace CoffeeTracker.Tests.Ocr;

/// <summary>One benchmark image and what the pipeline is expected to make of it.</summary>
/// <param name="File">Filename, relative to the corpus directory holding the manifest.</param>
/// <param name="Condition">
/// How the label was photographed (<c>flat</c>, <c>glare</c>, <c>dark</c>…). Scores are
/// reported per condition, because that is where a change shows its shape: preprocessing
/// that helps a dark bag and hurts a glared one is a wash in the total and obvious here.
/// </param>
public sealed record OcrFixture(string File, string Condition, OcrExpectation Expected)
{
    /// <summary>Absolute path, filled in when the manifest is loaded.</summary>
    public string Path { get; init; } = string.Empty;

    /// <summary>Which corpus it came from: <c>synthetic</c> or <c>real</c>.</summary>
    public string Corpus { get; init; } = string.Empty;
}

/// <summary>
/// The fields the pipeline should come back with. A null is a real expectation, not a
/// blank: it asserts the parser leaves the field alone rather than inventing a value,
/// which is its stated contract.
/// </summary>
public sealed record OcrExpectation(
    string? Name,
    string? Roaster,
    string? Origin,
    string? RoastLevel,
    string? Weight);

/// <summary>
/// Loads the benchmark corpora and answers whether the engine can run here.
/// </summary>
public static class OcrFixtures
{
    private static readonly JsonSerializerOptions ManifestJson = new()
    {
        PropertyNameCaseInsensitive = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    /// <summary>The fixtures directory, copied next to the test assembly at build.</summary>
    public static string Root => System.IO.Path.Combine(AppContext.BaseDirectory, "Ocr", "Fixtures");

    /// <summary>Builds the adapter for one engine.</summary>
    public static IOcrService NewEngine(OcrEngine engine, OcrOptions options, ILoggerFactory logs) =>
        engine == OcrEngine.Tesseract
            ? new TesseractCliOcrService(Options.Create(options), logs.CreateLogger<TesseractCliOcrService>())
            : new RapidOcrService(Options.Create(options), logs.CreateLogger<RapidOcrService>());

    /// <summary>
    /// Whether one engine can run here. Asked through the adapter's own availability
    /// check rather than re-derived, so a change to how either locates its files cannot
    /// leave this lying.
    /// </summary>
    public static bool Available(OcrEngine engine) =>
        engine == OcrEngine.Tesseract
            ? ExecutableOnPath("tesseract")
                && new TesseractCliOcrService(
                    Options.Create(new OcrOptions()),
                    NullLogger<TesseractCliOcrService>.Instance).IsAvailable
            : ExecutableOnPath("python3")
                && new RapidOcrService(
                    Options.Create(new OcrOptions { RapidOcrScriptPath = RapidOcrScript }),
                    NullLogger<RapidOcrService>.Instance).IsAvailable
                && RapidOcrImportable.Value;

    /// <summary>
    /// Whether the reader's Python package is actually installed, paid for once.
    ///
    /// The script being on disk is not enough, and the difference is not academic: a
    /// checkout on a host with python3 but no rapidocr passes every cheaper check, then
    /// every fixture comes back unavailable and the benchmark fails its floor with a
    /// score of zero instead of saying it could not run.
    /// </summary>
    private static readonly Lazy<bool> RapidOcrImportable = new(() =>
    {
        try
        {
            using var probe = System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("python3")
            {
                ArgumentList = { "-c", "import rapidocr" },
                RedirectStandardError = true,
                RedirectStandardOutput = true,
                UseShellExecute = false,
            });

            if (probe is null)
            {
                return false;
            }

            return probe.WaitForExit(TimeSpan.FromSeconds(30)) && probe.ExitCode == 0;
        }
        catch (Exception)
        {
            // Any failure to even ask is an answer: the engine cannot run here.
            return false;
        }
    });

    /// <summary>
    /// The reader script, found in the repo when running from a checkout and at its
    /// installed path in the container. A developer should not have to install the app
    /// to score it.
    /// </summary>
    public static string RapidOcrScript
    {
        get
        {
            var repo = System.IO.Path.GetFullPath(
                System.IO.Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "..", "deploy", "rapidocr", "read.py"));
            return System.IO.File.Exists(repo) ? repo : "/opt/rapidocr/read.py";
        }
    }

    /// <summary>
    /// Every fixture across both corpora, synthetic first. A corpus whose manifest is
    /// missing is skipped rather than failing the run, so a checkout carrying only one of
    /// the two still scores that one.
    /// </summary>
    public static IReadOnlyList<OcrFixture> All()
    {
        List<OcrFixture> fixtures = [];
        foreach (var corpus in (string[])["synthetic", "real"])
        {
            var directory = System.IO.Path.Combine(Root, corpus);
            var manifest = System.IO.Path.Combine(directory, "manifest.json");
            if (!System.IO.File.Exists(manifest))
            {
                continue;
            }

            var loaded = JsonSerializer.Deserialize<Manifest>(
                System.IO.File.ReadAllText(manifest), ManifestJson);

            fixtures.AddRange(
                (loaded?.Fixtures ?? []).Select(f => f with
                {
                    Path = System.IO.Path.Combine(directory, f.File),
                    Corpus = corpus,
                }));
        }

        return fixtures;
    }

    private static bool ExecutableOnPath(string name)
    {
        // Windows needs the extension; Unix does not. The adapter starts the process by
        // bare name, so this asks the same question the process start will.
        var candidates = OperatingSystem.IsWindows() ? new[] { $"{name}.exe", name } : [name];
        return (Environment.GetEnvironmentVariable("PATH") ?? string.Empty)
            .Split(System.IO.Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries)
            .Any(dir => candidates.Any(c =>
            {
                try
                {
                    return System.IO.File.Exists(System.IO.Path.Combine(dir, c));
                }
                catch (ArgumentException)
                {
                    // A malformed PATH entry is not a reason to fail discovery.
                    return false;
                }
            }));
    }

    private sealed record Manifest(IReadOnlyList<OcrFixture> Fixtures);
}

/// <summary>
/// A <see cref="FactAttribute"/> for one engine's benchmark, skipped with a reason when
/// that engine is absent, which is the bare Windows host this repo is often driven from
/// (AGENTS.md § Gotchas). Skipped rather than quietly passing: a benchmark that reports
/// green having measured nothing is worse than one that says it did not run.
/// </summary>
public sealed class OcrBenchmarkFactAttribute : FactAttribute
{
    public OcrBenchmarkFactAttribute(OcrEngine engine)
    {
        if (!OcrFixtures.Available(engine))
        {
            Skip = $"the {engine} engine is not installed here; this one is scored in CI, "
                + "which installs both.";
        }
    }
}
