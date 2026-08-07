// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import ArgumentParser

@main
struct UniteAnalysisModelTool: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "unite-analysis-model-tool",
    abstract: "Build and maintain Pokémon UNITE recognition models.",
    subcommands: [BuildDescriptorDatabase.self])
}
