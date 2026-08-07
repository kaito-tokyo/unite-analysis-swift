# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

PREFIX ?= $(HOME)/.local
DESTDIR ?=

.PHONY: build install

build:
	swift build --configuration release --product unite-analysis-swift
	swift build --configuration release --product unite-analysis-model-tool

install: build
	install -d "$(DESTDIR)$(PREFIX)/bin"
	install -m 755 "$$(swift build --configuration release --show-bin-path)/unite-analysis-swift" "$(DESTDIR)$(PREFIX)/bin/unite-analysis-swift"
	install -m 755 "$$(swift build --configuration release --show-bin-path)/unite-analysis-model-tool" "$(DESTDIR)$(PREFIX)/bin/unite-analysis-model-tool"
