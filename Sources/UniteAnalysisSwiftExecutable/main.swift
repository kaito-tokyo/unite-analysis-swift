// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Foundation
import UniteAnalysisSwiftCommands

@main
enum UniteAnalysisSwiftExecutable {
  static func main() async {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if let output = builtInCLIOutput(arguments: arguments) {
      try? FileHandle.standardOutput.write(contentsOf: Data("\(output)\n".utf8))
      return
    }
    do {
      let command = try UniteAnalysisSwiftCommand.parseAsRoot(arguments)
      try await executeCLI(command)
    } catch {
      let message = UniteAnalysisSwiftCommand.fullMessage(for: error)
      if !message.isEmpty {
        try? FileHandle.standardError.write(contentsOf: Data("\(message)\n".utf8))
      }
      let code = UniteAnalysisSwiftCommand.exitCode(for: error)
      if code != .success {
        Foundation.exit(code.rawValue)
      }
    }
  }
}
