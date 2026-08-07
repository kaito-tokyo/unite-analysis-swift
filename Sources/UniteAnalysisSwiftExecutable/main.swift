// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import UniteAnalysisSwiftCommands

@main
enum UniteAnalysisSwiftExecutable {
  static func main() async {
    await UniteAnalysisSwiftCommand.main()
  }
}
