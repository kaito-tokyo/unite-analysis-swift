// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Foundation

package func modelBuiltInCLIOutput(arguments: [String]) -> String? {
  let helpRequested = arguments.last == "--help" || arguments.last == "-h"
  let helpPath: [String]
  if arguments.first == "help" {
    helpPath = Array(arguments.dropFirst())
  } else if helpRequested {
    helpPath = Array(arguments.dropLast())
  } else {
    return nil
  }
  switch helpPath {
  case []:
    return UniteAnalysisModelCommand.helpMessage()
  case ["build"]:
    return UniteAnalysisModelCommand.helpMessage(for: BuildDescriptorDatabase.self)
  default:
    return nil
  }
}

package func executeModelCLI(_ parsed: any ParsableCommand) async throws {
  switch parsed {
  case let command as BuildDescriptorDatabase:
    for try await record in command.outputRecords() {
      let line =
        switch record {
        case .database(let itemCount, let descriptorCount, let output):
          "\(itemCount) items, \(descriptorCount) descriptors -> \(output)"
        case .compressed(let output):
          "xz -9e -> \(output)"
        }
      try FileHandle.standardOutput.write(contentsOf: Data("\(line)\n".utf8))
    }
  default:
    throw ValidationError("Unsupported command type: \(String(describing: type(of: parsed)))")
  }
}
