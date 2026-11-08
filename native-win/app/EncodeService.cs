// EncodeService.cs — Step 3's encode bridge, the Windows
// port of EncodeService.swift: one track's audio file ->
// 44.1 kHz / 16-bit / stereo WAV (bundled ffmpeg.exe) -> raw
// ATRAC3+ frames (bundled atracdenc.exe, 376 B/frame at
// 64 kbps). Jobs run in parallel under a semaphore whose
// count is the user's Encode workers setting; results are
// slotted by playlist index so the final order is exact,
// whatever order the jobs finish in.
//
// The tools live in a "tools" folder beside DiscWright.exe
// (put there by build-app.cmd: ffmpeg from the pinned gyan.dev
// build, atracdenc built from the vendored sources against
// vcpkg's libsndfile — see STEP3-NOTES.md).
//
// Child output: the Mac hands atracdenc a log FILE handle
// directly (never a pipe — a full pipe buffer can deadlock an
// encode). .NET's Process cannot take a raw handle, so each
// child here is drained continuously by the async line events
// into the same per-track log file; the drain never stops, so
// the deadlock the rule guards against cannot form. A failure
// names its track and carries the log's tail, as on the Mac.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using DiscWright.Core;

namespace DiscWright;

/// <summary>One track's encode job, in playlist order
/// (EncodeJob in EncodeService.swift).</summary>
public sealed class EncodeJob
{
    public int Index;
    public string Title = "";
    public string Source = "";
}

/// <summary>The failure kinds of EncodeFailure in
/// EncodeService.swift, with the same user-facing wording.</summary>
public enum EncodeFailureKind
{
    ToolsMissing,
    DecodeFailed,
    EncodeFailed,
    BadFrames,
    Cancelled,
}

/// <summary>A failure that names the track it belongs to (the
/// store logs it verbatim and aborts the build — a disc with a
/// silent hole is worse than no disc).</summary>
public sealed class EncodeException : Exception
{
    public EncodeFailureKind Kind { get; }
    public string? ToolName { get; }
    public string? Track { get; }
    public string? Reason { get; }
    public int Bytes { get; }

    private EncodeException(EncodeFailureKind kind, string message,
                            string? tool = null, string? track = null,
                            string? reason = null, int bytes = 0)
        : base(message)
    {
        Kind = kind;
        ToolName = tool;
        Track = track;
        Reason = reason;
        Bytes = bytes;
    }

    public static EncodeException ToolsMissing(string tool) =>
        new(EncodeFailureKind.ToolsMissing,
            $"{tool} was not found in the app's tools folder", tool: tool);

    public static EncodeException DecodeFailed(string track, string reason) =>
        new(EncodeFailureKind.DecodeFailed,
            $"could not decode “{track}”: {reason}", track: track, reason: reason);

    public static EncodeException EncodeFailed(string track, string reason) =>
        new(EncodeFailureKind.EncodeFailed,
            $"atracdenc failed on “{track}”: {reason}", track: track, reason: reason);

    public static EncodeException BadFrames(string track, int bytes) =>
        new(EncodeFailureKind.BadFrames,
            $"“{track}” encoded to {bytes} bytes — not a whole number " +
            $"of {Atrac.FrameSize}-byte frames", track: track, bytes: bytes);

    public static EncodeException Cancelled() =>
        new(EncodeFailureKind.Cancelled, "encoding cancelled");
}

/// <summary>Cancellation handle for one encode run: the store
/// keeps it and calls Cancel() from the Cancel button; queued
/// jobs drop out and running child processes are killed.
/// (EncodeHandle in EncodeService.swift.)</summary>
public sealed class EncodeHandle
{
    private readonly object _lock = new();
    private readonly HashSet<Process> _processes = new();
    private volatile bool _cancelled;

    public bool IsCancelled => _cancelled;

    internal void AddProcess(Process p)
    {
        lock (_lock) _processes.Add(p);
    }

    internal void RemoveProcess(Process p)
    {
        lock (_lock) _processes.Remove(p);
    }

    public void Cancel()
    {
        _cancelled = true;
        Process[] running;
        lock (_lock) running = _processes.ToArray();
        foreach (var p in running)
        {
            try { if (!p.HasExited) p.Kill(); }
            catch { /* already gone — cancellation is best-effort */ }
        }
    }
}

public static class EncodeService
{
    /// <summary>The tools folder beside the exe, and the two
    /// tools in it. Null from MissingTool() when both exist.</summary>
    public static string ToolsDir =>
        Path.Combine(AppContext.BaseDirectory, "tools");
    public static string FfmpegPath => Path.Combine(ToolsDir, "ffmpeg.exe");
    public static string EncoderPath => Path.Combine(ToolsDir, "atracdenc.exe");

    public static string? MissingTool()
    {
        if (!File.Exists(FfmpegPath)) return "ffmpeg";
        if (!File.Exists(EncoderPath)) return "atracdenc";
        return null;
    }

    /// <summary>Encode every job, at most `workers` at a time.
    /// Returns the frame buffers in JOB order. onProgress fires
    /// per finished track with (completed, total, that track's
    /// title), from a background thread — hop before touching
    /// UI state. Any track failure aborts the whole encode:
    /// pending jobs drop out and the first failure is thrown.
    /// (encodeAll in EncodeService.swift.)</summary>
    public static byte[][] EncodeAll(
        IReadOnlyList<EncodeJob> jobs, int workers, EncodeHandle handle,
        Action<int, int, string> onProgress)
    {
        if (MissingTool() is { } missing)
            throw EncodeException.ToolsMissing(missing);

        string tmpRoot = Path.Combine(Path.GetTempPath(),
            "DiscWrightEncode-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(tmpRoot);
        try
        {
            var results = new byte[]?[jobs.Count];
            var stateLock = new object();
            Exception? firstError = null;
            int completed = 0;
            using var gate = new SemaphoreSlim(Math.Max(1, workers));

            var tasks = new List<Task>();
            foreach (var job in jobs)
            {
                tasks.Add(Task.Run(() =>
                {
                    gate.Wait();
                    try
                    {
                        // Drop out if the run has failed or
                        // been cancelled (the Mac's queue
                        // cancellation does the same).
                        if (handle.IsCancelled) return;
                        lock (stateLock) { if (firstError != null) return; }

                        string dir = Path.Combine(tmpRoot, $"track-{job.Index}");
                        Directory.CreateDirectory(dir);
                        string wav = Path.Combine(dir, "in.wav");
                        string raw = Path.Combine(dir, "out.raw");
                        DecodeToWav(job, wav, handle);
                        if (handle.IsCancelled) return;
                        RunEncoder(job, wav, raw, handle);
                        if (handle.IsCancelled) return;

                        byte[] data = File.ReadAllBytes(raw);
                        if (data.Length == 0 || data.Length % Atrac.FrameSize != 0)
                            throw EncodeException.BadFrames(job.Title, data.Length);
                        int done;
                        lock (stateLock)
                        {
                            results[job.Index] = data;
                            completed += 1;
                            done = completed;
                        }
                        onProgress(done, jobs.Count, job.Title);
                    }
                    catch (Exception ex)
                    {
                        lock (stateLock) { firstError ??= ex; }
                    }
                    finally
                    {
                        gate.Release();
                    }
                }));
            }
            Task.WaitAll(tasks.ToArray());

            if (firstError != null) throw firstError;
            if (handle.IsCancelled) throw EncodeException.Cancelled();
            // No error and not cancelled: every slot was filled.
            return results.Select(r => r ?? Array.Empty<byte>()).ToArray();
        }
        finally
        {
            try { Directory.Delete(tmpRoot, recursive: true); }
            catch { /* temp litter is not worth a failed build */ }
        }
    }

    // ---- one track: decode to WAV (ffmpeg) ----

    /// <summary>Decode + resample the source to the canonical
    /// 44.1 kHz / 16-bit / stereo WAV atracdenc's libsndfile
    /// backend expects (the AVAssetReader output settings did
    /// this on the Mac). ffmpeg writes errors to its log file;
    /// a nonzero exit fails the track with the log's tail.</summary>
    private static void DecodeToWav(EncodeJob job, string wav, EncodeHandle handle)
    {
        string logPath = Path.Combine(Path.GetDirectoryName(wav)!, "ffmpeg.log");
        var psi = new ProcessStartInfo(FfmpegPath)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        psi.ArgumentList.Add("-y");
        psi.ArgumentList.Add("-v");
        psi.ArgumentList.Add("error");
        psi.ArgumentList.Add("-i");
        psi.ArgumentList.Add(job.Source);
        psi.ArgumentList.Add("-ar");
        psi.ArgumentList.Add("44100");
        psi.ArgumentList.Add("-ac");
        psi.ArgumentList.Add("2");
        psi.ArgumentList.Add("-sample_fmt");
        psi.ArgumentList.Add("s16");
        psi.ArgumentList.Add(wav);
        int exit;
        try
        {
            exit = RunChild(psi, logPath, handle, job);
        }
        catch (EncodeException) { throw; }
        catch (Exception ex)
        {
            throw EncodeException.DecodeFailed(job.Title, ex.Message);
        }
        if (handle.IsCancelled) throw EncodeException.Cancelled();
        if (exit != 0)
        {
            string tail = LogTail(logPath);
            throw EncodeException.DecodeFailed(job.Title,
                tail.Length > 0 ? tail : $"ffmpeg exited with status {exit}");
        }
        // ffmpeg can exit 0 having produced nothing usable for
        // an input it cannot read — the Mac's "decoded to
        // silence (0 samples)" guard, in file terms.
        if (!File.Exists(wav) || new FileInfo(wav).Length <= 44)
            throw EncodeException.DecodeFailed(job.Title,
                "ffmpeg produced no audio (empty WAV)");
    }

    // ---- one track: atracdenc ----

    /// <summary>The standing hardware-proven recipe:
    ///   atracdenc -e atrac3plus --bitrate 64 --container raw -i in.wav -o out.raw
    /// (verified against the vendored src/help.cpp — see the
    /// Mac's STEP3-NOTES.md; --bitrate is the ladder selector).</summary>
    private static void RunEncoder(EncodeJob job, string wav, string raw,
                                   EncodeHandle handle)
    {
        string logPath = Path.Combine(Path.GetDirectoryName(raw)!, "atracdenc.log");
        var psi = new ProcessStartInfo(EncoderPath)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        psi.ArgumentList.Add("-e");
        psi.ArgumentList.Add("atrac3plus");
        psi.ArgumentList.Add("--bitrate");
        psi.ArgumentList.Add("64");
        psi.ArgumentList.Add("--container");
        psi.ArgumentList.Add("raw");
        psi.ArgumentList.Add("-i");
        psi.ArgumentList.Add(wav);
        psi.ArgumentList.Add("-o");
        psi.ArgumentList.Add(raw);
        int exit;
        try
        {
            exit = RunChild(psi, logPath, handle, job);
        }
        catch (EncodeException) { throw; }
        catch (Exception ex)
        {
            throw EncodeException.EncodeFailed(job.Title, ex.Message);
        }
        if (handle.IsCancelled) throw EncodeException.Cancelled();
        if (exit != 0)
        {
            string tail = LogTail(logPath);
            throw EncodeException.EncodeFailed(job.Title,
                tail.Length > 0 ? tail : $"atracdenc exited with status {exit}");
        }
    }

    // ---- child plumbing ----

    /// <summary>Run one child with both output streams drained
    /// continuously into the track's log file (see the file
    /// header for why this is async drains, not the Mac's raw
    /// handle). The process is registered with the handle for
    /// the whole run, so Cancel kills whichever child a track
    /// is currently in. Returns the child's exit code.</summary>
    private static int RunChild(ProcessStartInfo psi, string logPath,
                                EncodeHandle handle, EncodeJob job)
    {
        using var writer = new StreamWriter(
            new FileStream(logPath, FileMode.Create, FileAccess.Write, FileShare.Read));
        var writeLock = new object();
        void OnLine(object sender, DataReceivedEventArgs e)
        {
            if (e.Data == null) return;
            lock (writeLock)
            {
                writer.WriteLine(e.Data);
                writer.Flush();
            }
        }

        using var proc = new Process { StartInfo = psi };
        proc.OutputDataReceived += OnLine;
        proc.ErrorDataReceived += OnLine;
        handle.AddProcess(proc);
        try
        {
            if (!proc.Start())
                throw new InvalidOperationException(
                    $"could not start {Path.GetFileName(psi.FileName)}");
            proc.BeginOutputReadLine();
            proc.BeginErrorReadLine();
            proc.WaitForExit();
            // The parameterless second wait lets the async line
            // readers flush before the log is read back.
            proc.WaitForExit();
            return proc.ExitCode;
        }
        finally
        {
            handle.RemoveProcess(proc);
        }
    }

    /// <summary>The child's log tail, for failure messages:
    /// the whole log, trimmed — the Mac embeds it the same
    /// way. Capped to the last 600 characters so a chatty
    /// failure cannot flood the app's log.</summary>
    private static string LogTail(string logPath)
    {
        try
        {
            string tail = File.ReadAllText(logPath).Trim();
            if (tail.Length > 600) tail = tail.Substring(tail.Length - 600);
            return tail;
        }
        catch
        {
            return "";
        }
    }
}
