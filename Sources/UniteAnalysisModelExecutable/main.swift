// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Foundation
import UniteAnalysisModelCommands

@main
enum UniteAnalysisModelExecutable {
  static func main() async {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if let output = modelBuiltInCLIOutput(arguments: arguments) {
      try? FileHandle.standardOutput.write(contentsOf: Data("\(output)\n".utf8))
      return
    }
    do {
      let command = try UniteAnalysisModelCommand.parseAsRoot(arguments)
      try await executeModelCLI(command)
    } catch {
      let message = UniteAnalysisModelCommand.fullMessage(for: error)
      if !message.isEmpty {
        try? FileHandle.standardError.write(contentsOf: Data("\(message)\n".utf8))
      }
      let code = UniteAnalysisModelCommand.exitCode(for: error)
      if code != .success {
        Foundation.exit(code.rawValue)
      }
    }
  }
}
