// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import CoreGraphics
import CxxStdlib
import Foundation
import IconMatcherNative
import ImageIO

private struct DescriptorSourceDocument: Decodable {
  var imageHeight: UInt32 = 256
  var descriptorSize: UInt32 = 128
  var detectorThreshold: Float = 0.0001
  var items: [Item]

  private enum CodingKeys: String, CodingKey {
    case imageHeight
    case descriptorSize
    case detectorThreshold
    case items
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    imageHeight = try container.decodeIfPresent(UInt32.self, forKey: .imageHeight) ?? 256
    descriptorSize = try container.decodeIfPresent(UInt32.self, forKey: .descriptorSize) ?? 128
    detectorThreshold =
      try container.decodeIfPresent(Float.self, forKey: .detectorThreshold) ?? 0.0001
    items = try container.decode([Item].self, forKey: .items)
  }

  struct Item: Decodable {
    var name: String
    var category: Category
    var image: String
    var paddingFraction: Float?
  }

  enum Category: String, Decodable {
    case held
    case battle

    var wireValue: UInt64 { self == .held ? 1 : 2 }
    var defaultPaddingFraction: Float { self == .held ? 0.20 : 0 }
  }
}

private struct BGRAImage {
  var width: Int
  var height: Int
  var bytesPerRow: Int
  var bytes: [UInt8]

  init(_ image: CGImage) throws {
    width = image.width
    height = image.height
    bytesPerRow = width * 4
    bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
    guard
      let context = CGContext(
        data: &bytes,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
          | CGImageAlphaInfo.premultipliedFirst.rawValue)
    else {
      throw ValidationError("Could not create an image conversion context")
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
  }
}

private enum Protobuf {
  static func varint(_ value: UInt64) -> Data {
    var value = value
    var data = Data()
    while value >= 0x80 {
      data.append(UInt8(value & 0x7F) | 0x80)
      value >>= 7
    }
    data.append(UInt8(value))
    return data
  }

  static func unsigned(_ number: UInt64, _ value: UInt64) -> Data {
    var data = varint(number << 3)
    data.append(varint(value))
    return data
  }

  static func bytes(_ number: UInt64, _ value: Data) -> Data {
    var data = varint(number << 3 | 2)
    data.append(varint(UInt64(value.count)))
    data.append(value)
    return data
  }

  static func string(_ number: UInt64, _ value: String) -> Data {
    bytes(number, Data(value.utf8))
  }

  static func float(_ number: UInt64, _ value: Float) -> Data {
    var bitPattern = value.bitPattern.littleEndian
    return withUnsafeBytes(of: &bitPattern) { raw in
      var data = varint(number << 3 | 5)
      data.append(contentsOf: raw)
      return data
    }
  }
}

private func loadImage(_ url: URL) throws -> CGImage {
  guard
    let source = CGImageSourceCreateWithURL(url as CFURL, nil),
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
  else {
    throw ValidationError("Could not read image: \(url.path)")
  }
  return image
}

private func resolveModelPath(_ path: String) -> URL {
  URL(
    fileURLWithPath: path,
    relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  )
  .standardizedFileURL
}

private func modelString(from value: std.string) -> String {
  String(decoding: value.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

package func resolveDescriptorDatabaseID(_ value: String?) throws -> String {
  guard let value else { return UUID().uuidString.lowercased() }
  guard let identifier = UUID(uuidString: value) else {
    throw ValidationError("database-id must be a UUIDv4")
  }
  let bytes = withUnsafeBytes(of: identifier.uuid) { Array($0) }
  guard bytes[6] >> 4 == 4, bytes[8] & 0xC0 == 0x80 else {
    throw ValidationError("database-id must be a UUIDv4")
  }
  return identifier.uuidString.lowercased()
}

package func validateDescriptorCategoryCounts(held: UInt64, battle: UInt64) throws {
  guard held != 1, battle != 1 else {
    throw ValidationError("Each populated descriptor category needs at least two descriptors")
  }
}

package func validateDescriptorOutputPaths(output: URL, xzOutput: URL?) throws {
  guard xzOutput != output else {
    throw ValidationError("xz-output must differ from output")
  }
}

package func validateDescriptorDatabaseByteCount(_ count: Int) throws {
  guard count <= 64 * 1024 * 1024 else {
    throw ValidationError("Descriptor database exceeds the 64 MiB loader limit")
  }
}

package func validateDescriptorEntryRows(_ rows: UInt32) throws {
  guard rows <= 1_000_000 else {
    throw ValidationError("Descriptor entry exceeds the 1000000-row loader limit")
  }
}

package struct BuildDescriptorDatabase: ParsableCommand {
  package static let configuration = CommandConfiguration(
    commandName: "build",
    abstract: "Build an AKAZE item-recognition database from reference icon images.")

  @Argument(help: "JSON source manifest containing names, categories, and image paths.")
  var manifest: String

  @Option(help: "Output descriptor database path.")
  var output: String

  @Option(help: "UUIDv4 database identifier; generated when omitted.")
  var databaseID: String?

  @Option(
    help:
      "Optional transfer artifact path. Compresses the database with xz --threads=1 -9e while retaining the uncompressed database."
  )
  var xzOutput: String?

  package init() {}

}

extension BuildDescriptorDatabase {
  package enum OutputRecord: Sendable {
    case database(itemCount: Int, descriptorCount: UInt64, output: String)
    case compressed(output: String)
  }

  package func outputRecords() -> AsyncThrowingStream<OutputRecord, Error> {
    let (stream, continuation) = AsyncThrowingStream<OutputRecord, Error>.makeStream()
    let task = Task {
      do {
        try Task.checkCancellation()
        for record in try records() {
          continuation.yield(record)
        }
        continuation.finish()
      } catch {
        continuation.finish(throwing: error)
      }
    }
    continuation.onTermination = { _ in task.cancel() }
    return stream
  }

  private func records() throws -> [OutputRecord] {
    let outputURL = resolveModelPath(output)
    let xzOutputURL = xzOutput.map(resolveModelPath)
    try validateDescriptorOutputPaths(output: outputURL, xzOutput: xzOutputURL)
    let manifestURL = manifest == "-" ? nil : resolveModelPath(manifest)
    let manifestData =
      try manifestURL.map { try Data(contentsOf: $0) }
      ?? FileHandle.standardInput.readDataToEndOfFile()
    let document = try JSONDecoder().decode(
      DescriptorSourceDocument.self,
      from: manifestData)
    guard document.imageHeight >= 4, document.imageHeight <= 4096 else {
      throw ValidationError("imageHeight must be between 4 and 4096")
    }
    guard document.descriptorSize >= 1, document.descriptorSize <= 486 else {
      throw ValidationError("descriptorSize must be between 1 and 486 bits")
    }
    guard document.detectorThreshold.isFinite, document.detectorThreshold > 0 else {
      throw ValidationError("detectorThreshold must be positive and finite")
    }
    guard !document.items.isEmpty else {
      throw ValidationError("The source manifest contains no items")
    }
    guard document.items.count <= 4096 else {
      throw ValidationError("The source manifest contains more than 4096 items")
    }
    let baseURL =
      manifestURL?.deletingLastPathComponent()
      ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    var entries = [Data]()
    var descriptorCount: UInt64 = 0
    var heldDescriptorCount: UInt64 = 0
    var battleDescriptorCount: UInt64 = 0
    for item in document.items {
      guard !item.name.isEmpty else { throw ValidationError("Item names must not be empty") }
      let imageURL = URL(fileURLWithPath: item.image, relativeTo: baseURL).standardizedFileURL
      let image = try BGRAImage(loadImage(imageURL))
      let padding = item.paddingFraction ?? item.category.defaultPaddingFraction
      let descriptors = image.bytes.withUnsafeBufferPointer { buffer in
        unite_analysis.IconDescriptors(
          buffer.baseAddress,
          buffer.count,
          UInt32(image.width),
          UInt32(image.height),
          image.bytesPerRow,
          document.imageHeight,
          document.descriptorSize,
          document.detectorThreshold,
          padding)
      }
      guard descriptors.isValid() else {
        throw ValidationError("\(item.name): \(modelString(from: descriptors.errorMessage()))")
      }
      try validateDescriptorEntryRows(descriptors.rows())
      let raw = Data((0..<descriptors.byteCount()).map { descriptors.byte($0) })
      let entry = [
        Protobuf.string(1, item.name),
        Protobuf.unsigned(2, item.category.wireValue),
        Protobuf.unsigned(3, UInt64(descriptors.rows())),
        Protobuf.unsigned(4, UInt64(descriptors.columns())),
        Protobuf.bytes(5, raw),
      ].reduce(into: Data()) { $0.append($1) }
      entries.append(entry)
      descriptorCount += UInt64(descriptors.rows())
      switch item.category {
      case .held:
        heldDescriptorCount += UInt64(descriptors.rows())
      case .battle:
        battleDescriptorCount += UInt64(descriptors.rows())
      }
    }
    try validateDescriptorCategoryCounts(held: heldDescriptorCount, battle: battleDescriptorCount)

    let configuration = [
      Protobuf.unsigned(1, UInt64(document.descriptorSize)),
      Protobuf.float(2, document.detectorThreshold),
      Protobuf.unsigned(3, UInt64(document.imageHeight)),
    ].reduce(into: Data()) { $0.append($1) }
    let identifier = try resolveDescriptorDatabaseID(databaseID)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    var database = Protobuf.unsigned(1, 2)
    database.append(Protobuf.bytes(2, configuration))
    for entry in entries { database.append(Protobuf.bytes(3, entry)) }
    database.append(Protobuf.string(4, identifier))
    database.append(Protobuf.string(5, formatter.string(from: Date())))
    try validateDescriptorDatabaseByteCount(database.count)

    try FileManager.default.createDirectory(
      at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try database.write(to: outputURL, options: .atomic)
    var records: [OutputRecord] = [
      .database(
        itemCount: entries.count, descriptorCount: descriptorCount, output: outputURL.path)
    ]
    if let xzOutputURL {
      try compressXZ(input: outputURL, output: xzOutputURL)
      records.append(.compressed(output: xzOutputURL.path))
    }
    return records
  }
}

private func compressXZ(input: URL, output: URL) throws {
  let process = Process()
  let standardOutput = Pipe()
  let standardError = Pipe()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  process.arguments = ["xz", "--compress", "--stdout", "--threads=1", "-9e", input.path]
  process.standardOutput = standardOutput
  process.standardError = standardError
  do {
    try process.run()
  } catch {
    throw ValidationError("Could not launch xz; install XZ Utils and ensure xz is in PATH")
  }
  let compressed = standardOutput.fileHandleForReading.readDataToEndOfFile()
  let diagnostics = standardError.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  guard process.terminationStatus == 0 else {
    let message = String(decoding: diagnostics, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    throw ValidationError("xz failed: \(message)")
  }
  try FileManager.default.createDirectory(
    at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
  try compressed.write(to: output, options: .atomic)
}
