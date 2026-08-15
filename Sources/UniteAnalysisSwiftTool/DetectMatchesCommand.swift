// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import ArgumentParser
import Foundation
import LDTXRecordingSupport
import RecordVisionSupport

struct DetectMatches: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "detect-matches-v1",
    abstract: "Detect standard 10-minute matches by OCRing the main video timer.",
    discussion: """
      INPUT. --input must be a finalized recording format v2 .ldtxrecord. The main video is the format-v2 fixed file main.fragmented.mp4; LDTXRecordingMainMediaFile does not select another file. --layout is a fixed UI layout JSON containing the game-screen reference size and match-timer rectangle. The command never reads LDTX Visions. custom_fields.json may contain the String-to-String keys unite-analysis-swift.x, .y, .width, and .height; omitted trailing dimensions extend to the display-oriented video edge.

      EXECUTION. AVFoundation decoding and Apple Vision recognition require this command to run outside an application sandbox.

      OCR. The main video is decoded sequentially with AVAssetReader at --sample-interval spacing. Only the timer ROI is sent through VNImageRequestHandler using accurate en-US recognition with automatic language detection and language correction disabled. Every sample is handled in this process without JPEG round-trips or image-by-image process launches.

      DETECTION. Strict MM:SS observations produce standard-match start candidates. A lone 10:00 is insufficient. Consistent candidates are clustered despite missing samples; discontinuous OCR values are retained as excluded diagnostics. A later independently corroborated reset creates another match.

      OUTPUT. Pretty-printed, sorted JSON is written to stdout and optionally atomically to --output. --audit-id accepts a canonical lowercase UUID and atomically writes a managed audit directory at _PokemonUniteAnalysis/audits/<id> containing match-detection.json and deterministic source-video JPEG pages. --output and --audit-id are mutually exclusive. Cells show timer ROI, requested and actual timestamps, OCR text, confidence, disposition, and diagnostic reason. Existing outputs require --force. Matches end at start + 600 seconds.

      SCHEMAS. Print the contracts with `unite-analysis-swift schema match-layout-v1.schema.json` and `unite-analysis-swift schema match-detection-v1.output.schema.json`.

      AUDIT BOUNDARY. The optional contact sheet is generated from decoded source-video frames for human review only. It is never read by match detection and does not add JPEG round-trips to the detection path. Zero observations produce a labeled empty audit artifact.

      LIMITS. Surrendered matches and nonstandard modes are not inferred.
      """.reflowedHelp()
  )

  @Option(help: "Recording format v2 .ldtxrecord path.")
  var input: String

  @Option(help: "Fixed match UI layout JSON path.")
  var layout: String

  @Option(help: "Timer sampling interval in seconds.")
  var sampleInterval = 5.0

  @Option(help: "Optional JSON output path; stdout always receives the same result.")
  var output: String?

  @Option(help: "Canonical lowercase UUID for a managed timer audit directory.")
  var auditId: String?

  @Flag(help: "Allow --output or the managed audit directory to be replaced atomically.")
  var force = false

  struct Output: Encodable, Sendable {
    let schema =
      "https://kaito-tokyo.github.io/unite-analysis-swift/match-detection-v1.output.schema.json"
    let source: String
    let mainMediaFile: String
    let layoutId: String
    let gameScreen: GameScreenRectangle
    let matches: [DetectedMatch]
    let diagnostics: [MatchTimerDiagnostic]
    let auditContactSheet: MatchTimerAuditContactSheetResult?

    private enum CodingKeys: String, CodingKey {
      case schema = "$schema"
      case source, mainMediaFile, layoutId, gameScreen, matches, diagnostics, auditContactSheet
    }
  }

  func outputRecords() -> AsyncThrowingStream<Output, Error> {
    commandOutputStream { continuation in continuation.yield(try await self.result()) }
  }

  private func result() async throws -> Output {
    try validateOutputPath(output.map(resolvePath), force: force)
    if output != nil, auditId != nil {
      throw UniteAnalysisSwiftToolError.message(
        "--output and --audit-id are mutually exclusive")
    }
    let validatedAuditId: String?
    if let auditId {
      guard let uuid = UUID(uuidString: auditId), uuid.uuidString.lowercased() == auditId else {
        throw UniteAnalysisSwiftToolError.message("--audit-id must be a canonical lowercase UUID")
      }
      validatedAuditId = auditId
    } else {
      validatedAuditId = nil
    }
    let recordingURL = resolvePath(input).standardizedFileURL
    guard recordingURL.pathExtension == "ldtxrecord" else {
      throw UniteAnalysisSwiftToolError.message("--input must be a .ldtxrecord directory")
    }
    guard
      FileManager.default.fileExists(atPath: recordingURL.appendingPathComponent(".finalized").path)
    else {
      throw UniteAnalysisSwiftToolError.message("Recording is not finalized: \(recordingURL.path)")
    }
    let mediaURL = try LDTXRecordingBundle.formatV2MainMediaURL(in: recordingURL)
    let mainMediaFile = mediaURL.lastPathComponent
    let asset = AVURLAsset(url: mediaURL)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
      throw UniteAnalysisSwiftToolError.message("Main media has no video track")
    }
    let naturalSize = try await track.load(.naturalSize)
    let transform = try await track.load(.preferredTransform)
    let videoDuration = try await track.load(.timeRange).end.seconds
    let displaySize = naturalSize.applying(transform)
    let videoWidth = Int(abs(displaySize.width).rounded())
    let videoHeight = Int(abs(displaySize.height).rounded())

    let customURL = recordingURL.appendingPathComponent("custom_fields.json")
    var customFields: [String: String] = [:]
    if FileManager.default.fileExists(atPath: customURL.path) {
      do {
        customFields = try JSONDecoder().decode(
          [String: String].self, from: Data(contentsOf: customURL))
      } catch {
        throw UniteAnalysisSwiftToolError.message(
          "custom_fields.json must be a String-to-String object: \(error)")
      }
    }
    let gameScreen: GameScreenRectangle
    do {
      gameScreen = try .resolve(
        customFields: customFields, videoWidth: videoWidth, videoHeight: videoHeight)
    } catch {
      throw UniteAnalysisSwiftToolError.message(String(describing: error))
    }

    let layoutURL = resolvePath(layout)
    let matchLayout: MatchTimerLayout
    do {
      matchLayout = try JSONDecoder().decode(
        MatchTimerLayout.self, from: Data(contentsOf: layoutURL))
      try matchLayout.validate()
    } catch {
      throw UniteAnalysisSwiftToolError.message("Invalid match layout JSON: \(error)")
    }
    let records: [MatchTimerObservation]
    do {
      records = try await MatchTimerVideoOCR.recognize(
        videoURL: mediaURL, gameScreen: gameScreen, layout: matchLayout,
        sampleInterval: sampleInterval)
    } catch {
      throw UniteAnalysisSwiftToolError.message(String(describing: error))
    }
    let detection = MatchTimerDetection(records: records, recordingDuration: videoDuration)
    let auditResult: MatchTimerAuditContactSheetResult?
    var stagedAuditDirectory: URL?
    var finalAuditDirectory: URL?
    if let auditId = validatedAuditId {
      let auditsDirectory = recordingURL.appendingPathComponent("_PokemonUniteAnalysis/audits")
      let finalDirectory = auditsDirectory.appendingPathComponent(auditId, isDirectory: true)
      try validateManagedAuditDestination(finalDirectory, force: force)
      try FileManager.default.createDirectory(
        at: auditsDirectory, withIntermediateDirectories: true)
      let stagedDirectory = auditsDirectory.appendingPathComponent(
        ".\(auditId).\(UUID().uuidString).staged")
      try FileManager.default.createDirectory(
        at: stagedDirectory, withIntermediateDirectories: true)
      stagedAuditDirectory = stagedDirectory
      finalAuditDirectory = finalDirectory
      do {
        let rendered = try await MatchTimerAuditContactSheet.render(
          videoURL: mediaURL, gameScreen: gameScreen, layout: matchLayout,
          diagnostics: detection.diagnostics,
          outputPrefixURL: stagedDirectory.appendingPathComponent("pages/page"),
          force: force)
        auditResult = .init(
          auditId: auditId,
          outputs: rendered.outputs.map { "pages/" + URL(fileURLWithPath: $0).lastPathComponent },
          observationCount: rendered.observationCount, columns: rendered.columns,
          pageCount: rendered.pageCount)
      } catch {
        try? FileManager.default.removeItem(at: stagedDirectory)
        throw UniteAnalysisSwiftToolError.message(String(describing: error))
      }
    } else {
      auditResult = nil
    }
    let result = Output(
      source: "videoOCR", mainMediaFile: mainMediaFile, layoutId: matchLayout.layoutId,
      gameScreen: gameScreen,
      matches: detection.matches, diagnostics: detection.diagnostics,
      auditContactSheet: auditResult)
    if let stagedAuditDirectory, let finalAuditDirectory {
      do {
        try prettyPrintedJSONData(result).write(
          to: stagedAuditDirectory.appendingPathComponent("match-detection.json"))
        try installManagedAuditDirectory(
          stagedAuditDirectory, at: finalAuditDirectory, force: force)
      } catch {
        try? FileManager.default.removeItem(at: stagedAuditDirectory)
        throw UniteAnalysisSwiftToolError.message(String(describing: error))
      }
    }
    return result
  }
}

package func validateManagedAuditDestination(_ url: URL, force: Bool) throws {
  guard FileManager.default.fileExists(atPath: url.path) else { return }
  var isDirectory: ObjCBool = false
  guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
    isDirectory.boolValue
  else {
    throw UniteAnalysisSwiftToolError.message(
      "Managed audit destination is not a directory: \(url.path)")
  }
  guard force else {
    throw UniteAnalysisSwiftToolError.message(
      "Audit already exists: \(url.path). Pass --force to overwrite.")
  }
}

package func installManagedAuditDirectory(_ staged: URL, at output: URL, force: Bool) throws {
  if force, FileManager.default.fileExists(atPath: output.path) {
    _ = try FileManager.default.replaceItemAt(output, withItemAt: staged)
  } else {
    try FileManager.default.moveItem(at: staged, to: output)
  }
}
