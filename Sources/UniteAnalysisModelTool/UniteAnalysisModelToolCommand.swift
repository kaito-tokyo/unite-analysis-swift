// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import ArgumentParser

package struct UniteAnalysisModelCommand: ParsableCommand {
  package static let configuration = CommandConfiguration(
    commandName: "unite-analysis-model-tool",
    abstract: "Build and maintain ポケモンユナイト recognition models.",
    version: "0.1.4",
    subcommands: [BuildDescriptorDatabase.self])

  package init() {}
}
