using System.Diagnostics;
using System.Text.Json;
using CoffeeTracker.Application.Ports.Driven;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace CoffeeTracker.Infrastructure.Ocr;

/// <summary>
/// OCR adapter backed by RapidOCR, the PP-OCR detection and recognition models packaged
/// on onnxruntime.
///
/// It exists because Tesseract is a document engine and a coffee bag is a photograph.
/// Measured over the benchmark's nine real bags, Tesseract returned "lam" where the
/// label reads "LA LIBERTAD", "INA\" for "L'Original", and nothing at all for "INTENSO
/// BLEND"; RapidOCR reads all three, plus a script-font logo Tesseract never saw. See
/// AGENTS.md § OCR for the scorecard.
///
/// Like the Tesseract adapter it shells out to a process and pipes the image over
/// **stdin**, so no caller-controlled value becomes a path or an argument. RapidOCR's own
/// CLI only accepts `-img &lt;path&gt;`, which would mean writing a temp file for every scan,
/// so the repo ships a small reader (deploy/rapidocr/read.py) that takes stdin and prints
/// one JSON object per recognised line.
/// </summary>
public class RapidOcrService(IOptions<OcrOptions> options, ILogger<RapidOcrService> logger)
    : IOcrService, IDisposable
{
    private readonly string _python =
        string.IsNullOrWhiteSpace(options.Value.PythonPath) ? "python3" : options.Value.PythonPath!;

    private readonly string _script =
        string.IsNullOrWhiteSpace(options.Value.RapidOcrScriptPath)
            ? "/opt/rapidocr/read.py"
            : options.Value.RapidOcrScriptPath!;

    private readonly TimeSpan _timeout =
        TimeSpan.FromSeconds(options.Value.TimeoutSeconds > 0 ? options.Value.TimeoutSeconds : 30);

    // Same bargain as the Tesseract adapter, a much lower default. Each process here
    // imports numpy and onnxruntime and loads the detection and recognition models, so
    // it costs hundreds of megabytes where a tesseract process costs tens. The shared
    // Ocr:MaxConcurrency cannot be set per engine, and ProcessorCount * 2 on the eight
    // cores of a NAS would admit sixteen of them: enough simultaneous scans to get the
    // container OOM-killed, which takes the whole app down instead of degrading to 503.
    private const int DefaultConcurrency = 2;

    private readonly SemaphoreSlim _gate =
        new(options.Value.MaxConcurrency > 0 ? options.Value.MaxConcurrency : DefaultConcurrency);

    /// <summary>
    /// The reader script has to be there. Whether the Python packages behind it are is
    /// not knowable without paying for an import, so a broken install shows up as a
    /// failed run and is logged, exactly as a missing tesseract binary is.
    /// </summary>
    public bool IsAvailable => File.Exists(_script);

    public Task<bool> IsAvailableAsync(CancellationToken ct = default) => Task.FromResult(IsAvailable);

    public void Dispose()
    {
        _gate.Dispose();
        GC.SuppressFinalize(this);
    }

    public async Task<OcrResult> ReadAsync(Stream image, CancellationToken ct = default)
    {
        await _gate.WaitAsync(ct);

        using var linked = CancellationTokenSource.CreateLinkedTokenSource(ct);
        linked.CancelAfter(_timeout);
        var token = linked.Token;

        Process? process = null;
        Task<string>? stdoutTask = null;
        Task<string>? stderrTask = null;
        try
        {
            var psi = new ProcessStartInfo(_python)
            {
                RedirectStandardInput = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
            };
            psi.ArgumentList.Add(_script);

            process = Process.Start(psi)
                ?? throw new InvalidOperationException($"Could not start '{_python}'.");

            // Drain before writing, so a large image cannot deadlock against a full pipe.
            stdoutTask = process.StandardOutput.ReadToEndAsync(token);
            stderrTask = process.StandardError.ReadToEndAsync(token);

            await UprightImage.WriteToAsync(image, process.StandardInput.BaseStream, token);
            process.StandardInput.Close();

            await process.WaitForExitAsync(token);
            var output = await stdoutTask;
            var error = await stderrTask;

            if (process.ExitCode != 0)
            {
                logger.LogWarning("rapidocr exited {ExitCode}: {Error}", process.ExitCode, error);
                return OcrResult.Unavailable;
            }

            return BuildResult(output);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            throw;
        }
        catch (OperationCanceledException)
        {
            logger.LogWarning(
                "rapidocr exceeded the {TimeoutSeconds}s timeout; killing it and reporting unavailable.",
                _timeout.TotalSeconds);
            return OcrResult.Unavailable;
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "rapidocr failed; reporting unavailable.");
            return OcrResult.Unavailable;
        }
        finally
        {
            if (process is not null)
            {
                try
                {
                    if (!process.HasExited)
                    {
                        process.Kill(entireProcessTree: true);
                    }
                }
                catch (InvalidOperationException)
                {
                    // Raced with exit, nothing to kill.
                }

                await Observe(stdoutTask);
                await Observe(stderrTask);
                process.Dispose();
            }

            _gate.Release();
        }
    }

    private static async Task Observe(Task? task)
    {
        if (task is null)
        {
            return;
        }

        try
        {
            await task;
        }
        catch
        {
            // Already handled by the caller's catch, or cancelled; ignore here.
        }
    }

    /// <summary>
    /// One JSON object per line, so a line the reader could not encode costs that line
    /// rather than the whole document.
    /// </summary>
    private static OcrResult BuildResult(string stdout)
    {
        List<OcrLine> lines = [];
        foreach (var row in stdout.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            ReaderLine? parsed;
            try
            {
                parsed = JsonSerializer.Deserialize<ReaderLine>(row, ReaderJson);
            }
            catch (JsonException)
            {
                continue;
            }

            if (!string.IsNullOrWhiteSpace(parsed?.Text))
            {
                lines.Add(new OcrLine(parsed.Text, parsed.Conf, parsed.Height, parsed.Top));
            }
        }

        // RawText is what the scan response shows the user, so it carries every line the
        // engine read. Filtering is the parser's job; hiding text here would make a bad
        // scan impossible to diagnose from the response.
        return OcrResult.Read(string.Join('\n', lines.Select(l => l.Text)), lines, NoiseFloor);
    }

    /// <summary>
    /// Confidence below which this engine's output is noise. Swept over the benchmark:
    /// 55 and 70 both score 82.8%, 80 scores 81.8%, and 90 upward falls away as genuine
    /// lines start being dropped. 70 sits in the middle of that plateau.
    ///
    /// Note that it does not separate clutter from text the way Tesseract's 55 does:
    /// this engine reads a bag's small print confidently, so a barcode caption came back
    /// at 81 and would clear any gate that keeps the real lines. What actually keeps that
    /// out of the fields is the rest of the parser, the four-letter minimum and the
    /// height ranking. The gate here is a floor against garbage, not the main defence.
    /// </summary>
    private const double NoiseFloor = 70;

    private static readonly JsonSerializerOptions ReaderJson = new() { PropertyNameCaseInsensitive = true };

    private sealed record ReaderLine(string Text, double Conf, int Top, int Height);
}
