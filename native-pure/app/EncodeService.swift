// EncodeService.swift — Step 3's encode bridge: one track's
// audio file -> 44.1 kHz / 16-bit / stereo WAV (AVAssetReader)
// -> atracdenc -> raw ATRAC3+ frames (376 B/frame at 64 kbps).
// Jobs run in parallel under an OperationQueue whose
// maxConcurrentOperationCount is the user's Encode workers
// setting; results are slotted by playlist index so the final
// order is exact, whatever order the jobs finish in.
//
// atracdenc is the vendored binary from encoder/atracdenc-src,
// built by build-app.sh into Contents/Resources. Its CLI was
// verified against src/help.cpp + src/main.cpp (see
// STEP3-NOTES.md): -e <codec>, -i <in>, -o <out>,
// --bitrate <kbps>, --container raw; no positional arguments.

import Foundation
import AVFoundation

/// One track's encode job, in playlist order.
struct EncodeJob {
  let index: Int
  let title: String
  let source: URL
}

/// A failure that names the track it belongs to (the store logs
/// it verbatim and aborts the build — a disc with a silent hole
/// is worse than no disc).
enum EncodeFailure: LocalizedError {
  case encoderMissing
  case decodeFailed(track: String, reason: String)
  case encodeFailed(track: String, reason: String)
  case badFrames(track: String, bytes: Int)
  case cancelled

  var errorDescription: String? {
    switch self {
    case .encoderMissing:
      return "atracdenc was not found inside the app bundle"
    case .decodeFailed(let t, let r):
      return "could not decode “\(t)”: \(r)"
    case .encodeFailed(let t, let r):
      return "atracdenc failed on “\(t)”: \(r)"
    case .badFrames(let t, let b):
      return "“\(t)” encoded to \(b) bytes — not a whole number of 376-byte frames"
    case .cancelled:
      return "encoding cancelled"
    }
  }
}

/// Cancellation handle for one encode run: the store keeps it
/// and calls cancel() from the Cancel button; queued jobs drop
/// out and running atracdenc processes are terminated.
final class EncodeHandle {
  private let lock = NSLock()
  private var processes: [Int: Process] = [:]
  private var cancelledFlag = false
  var queue: OperationQueue?

  var isCancelled: Bool {
    lock.lock(); defer { lock.unlock() }
    return cancelledFlag
  }

  func addProcess(_ p: Process, index: Int) {
    lock.lock(); processes[index] = p; lock.unlock()
  }

  func removeProcess(index: Int) {
    lock.lock(); processes[index] = nil; lock.unlock()
  }

  func cancel() {
    lock.lock()
    cancelledFlag = true
    let running = Array(processes.values)
    lock.unlock()
    queue?.cancelAllOperations()
    for p in running where p.isRunning { p.terminate() }
  }
}

enum EncodeService {

  /// The bundled encoder, or nil (the store logs a clear error
  /// rather than crashing when it is absent).
  static func encoderURL() -> URL? {
    Bundle.main.url(forResource: "atracdenc", withExtension: nil)
  }

  /// Encode every job, at most `workers` at a time. Returns the
  /// frames in JOB order. onProgress fires per finished track
  /// with (completed, total, that track's title), from a
  /// background thread — hop before touching UI state.
  static func encodeAll(
    jobs: [EncodeJob], workers: Int, handle: EncodeHandle,
    onProgress: @escaping (Int, Int, String) -> Void
  ) async throws -> [[UInt8]] {
    guard let encoder = encoderURL() else {
      throw EncodeFailure.encoderMissing
    }
    return try await withCheckedThrowingContinuation { cont in
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          let frames = try encodeAllSync(jobs: jobs, workers: workers,
                                         handle: handle, encoder: encoder,
                                         onProgress: onProgress)
          cont.resume(returning: frames)
        } catch {
          cont.resume(throwing: error)
        }
      }
    }
  }

  private static func encodeAllSync(
    jobs: [EncodeJob], workers: Int, handle: EncodeHandle,
    encoder: URL,
    onProgress: @escaping (Int, Int, String) -> Void
  ) throws -> [[UInt8]] {
    let fm = FileManager.default
    let tmpRoot = fm.temporaryDirectory
      .appendingPathComponent("DiscWrightEncode-" + UUID().uuidString,
                              isDirectory: true)
    try fm.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmpRoot) }

    var results = [[UInt8]?](repeating: nil, count: jobs.count)
    var firstError: Error? = nil
    let stateLock = NSLock()
    var completed = 0

    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = max(1, workers)
    queue.qualityOfService = .userInitiated
    handle.queue = queue

    for job in jobs {
      let op = BlockOperation {
        do {
          if handle.isCancelled { return }
          let dir = tmpRoot.appendingPathComponent(
            "track-\(job.index)", isDirectory: true)
          try fm.createDirectory(at: dir, withIntermediateDirectories: true)
          let wav = dir.appendingPathComponent("in.wav")
          let raw = dir.appendingPathComponent("out.raw")
          try decodeToWav(source: job.source, dest: wav, title: job.title)
          if handle.isCancelled { return }
          try runEncoder(encoder: encoder, wav: wav, raw: raw,
                         handle: handle, job: job)
          if handle.isCancelled { return }
          let data = try Data(contentsOf: raw)
          guard data.count > 0, data.count % FRAME_SIZE == 0 else {
            throw EncodeFailure.badFrames(track: job.title,
                                          bytes: data.count)
          }
          stateLock.lock()
          results[job.index] = [UInt8](data)
          completed += 1
          let done = completed
          stateLock.unlock()
          onProgress(done, jobs.count, job.title)
        } catch {
          stateLock.lock()
          if firstError == nil { firstError = error }
          stateLock.unlock()
          queue.cancelAllOperations()
        }
      }
      queue.addOperation(op)
    }
    queue.waitUntilAllOperationsAreFinished()

    if let e = firstError { throw e }
    if handle.isCancelled { throw EncodeFailure.cancelled }
    // No error and not cancelled: every slot was filled.
    return results.map { $0 ?? [] }
  }

  // ---- one track: decode to WAV ----

  /// Decode + resample `source` to a canonical 44.1 kHz /
  /// 16-bit / stereo WAV at `dest`, streamed buffer by buffer
  /// (a long track never sits whole in memory). AVAssetReader's
  /// output settings do the resampling/channel conversion, so
  /// mp3 / flac / m4a / wav / … all land in the same PCM shape
  /// atracdenc's libsndfile backend expects.
  private static func decodeToWav(source: URL, dest: URL, title: String) throws {
    let asset = AVURLAsset(url: source)
    guard let track = asset.tracks(withMediaType: .audio).first else {
      throw EncodeFailure.decodeFailed(track: title,
                                       reason: "no audio track found")
    }
    let reader: AVAssetReader
    do {
      reader = try AVAssetReader(asset: asset)
    } catch {
      throw EncodeFailure.decodeFailed(track: title, reason: "\(error)")
    }
    let settings: [String: Any] = [
      AVFormatIDKey: Int(kAudioFormatLinearPCM),
      AVSampleRateKey: 44100,
      AVNumberOfChannelsKey: 2,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ]
    let output = AVAssetReaderTrackOutput(track: track,
                                          outputSettings: settings)
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else {
      throw EncodeFailure.decodeFailed(track: title,
                                       reason: "reader rejected the track")
    }
    reader.add(output)

    let fm = FileManager.default
    fm.createFile(atPath: dest.path, contents: nil)
    guard let fh = try? FileHandle(forWritingTo: dest) else {
      throw EncodeFailure.decodeFailed(track: title,
                                       reason: "could not create temp WAV")
    }
    // Placeholder header; patched with the real sizes at the end.
    try fh.write(contentsOf: Data(count: 44))
    var dataBytes = 0
    guard reader.startReading() else {
      try? fh.close()
      throw EncodeFailure.decodeFailed(
        track: title,
        reason: reader.error.map { "\($0)" } ?? "reader would not start")
    }
    while reader.status == .reading {
      guard let sb = output.copyNextSampleBuffer() else { break }
      guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
      let len = CMBlockBufferGetDataLength(block)
      if len == 0 { continue }
      var bytes = [UInt8](repeating: 0, count: len)
      let st = CMBlockBufferCopyDataBytes(block, atOffset: 0,
                                          dataLength: len,
                                          destination: &bytes)
      guard st == kCMBlockBufferNoErr else {
        try? fh.close()
        throw EncodeFailure.decodeFailed(track: title,
                                         reason: "sample buffer copy failed")
      }
      try fh.write(contentsOf: Data(bytes))
      dataBytes += len
    }
    if reader.status == .failed {
      try? fh.close()
      throw EncodeFailure.decodeFailed(
        track: title,
        reason: reader.error.map { "\($0)" } ?? "decode failed")
    }
    guard dataBytes > 0 else {
      try? fh.close()
      throw EncodeFailure.decodeFailed(track: title,
                                       reason: "decoded to silence (0 samples)")
    }
    fh.seek(toFileOffset: 0)
    try fh.write(contentsOf: Data(wavHeader(dataBytes: dataBytes)))
    try fh.close()
  }

  /// Canonical 44-byte PCM WAV header for 44.1k/16-bit/stereo.
  private static func wavHeader(dataBytes: Int) -> [UInt8] {
    var h: [UInt8] = []
    func tag(_ s: String) { h.append(contentsOf: s.utf8) }
    func le32(_ v: Int) {
      h.append(UInt8(v & 0xff)); h.append(UInt8((v >> 8) & 0xff))
      h.append(UInt8((v >> 16) & 0xff)); h.append(UInt8((v >> 24) & 0xff))
    }
    func le16(_ v: Int) {
      h.append(UInt8(v & 0xff)); h.append(UInt8((v >> 8) & 0xff))
    }
    tag("RIFF"); le32(36 + dataBytes); tag("WAVE")
    tag("fmt "); le32(16); le16(1); le16(2)
    le32(44100); le32(44100 * 4); le16(4); le16(16)
    tag("data"); le32(dataBytes)
    return h
  }

  // ---- one track: atracdenc ----

  /// The standing hardware-proven recipe (see STEP3-NOTES.md):
  ///   atracdenc -e atrac3plus --bitrate 64 --container raw -i in.wav -o out.raw
  /// Output goes to a log file in the track's temp dir (never a
  /// pipe — a full pipe buffer cannot deadlock the encode).
  private static func runEncoder(encoder: URL, wav: URL, raw: URL,
                                 handle: EncodeHandle, job: EncodeJob) throws {
    let logURL = raw.deletingLastPathComponent()
      .appendingPathComponent("atracdenc.log")
    FileManager.default.createFile(atPath: logURL.path, contents: nil)
    let logFH = try? FileHandle(forWritingTo: logURL)

    let proc = Process()
    proc.executableURL = encoder
    proc.arguments = ["-e", "atrac3plus",
                      "--bitrate", "64",
                      "--container", "raw",
                      "-i", wav.path,
                      "-o", raw.path]
    if let logFH {
      proc.standardOutput = logFH
      proc.standardError = logFH
    }
    handle.addProcess(proc, index: job.index)
    defer { handle.removeProcess(index: job.index) }
    do {
      try proc.run()
    } catch {
      throw EncodeFailure.encodeFailed(track: job.title, reason: "\(error)")
    }
    proc.waitUntilExit()
    try? logFH?.close()
    if handle.isCancelled { throw EncodeFailure.cancelled }
    guard proc.terminationStatus == 0 else {
      let tail = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
      let trimmed = tail.trimmingCharacters(in: .whitespacesAndNewlines)
      throw EncodeFailure.encodeFailed(
        track: job.title,
        reason: trimmed.isEmpty
          ? "atracdenc exited with status \(proc.terminationStatus)"
          : trimmed)
    }
  }
}
