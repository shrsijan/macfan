PREFIX  ?= /usr/local
BINDIR   = $(PREFIX)/bin
VERSION := $(shell sed -n 's/^let version = "\(.*\)"/\1/p' Sources/macfan/main.swift)
BIN      = .build/release/macfan
UNIVERSAL = .build/apple/Products/Release/macfan

.PHONY: build install uninstall release clean

build:
	swift build -c release

install: build
	install -d $(BINDIR)
	install -m 755 $(BIN) $(BINDIR)/macfan
	@echo "installed $(BINDIR)/macfan"

uninstall:
	rm -f $(BINDIR)/macfan

# Universal (arm64 + x86_64) binary, tarred for a GitHub release.
release:
	swift build -c release --arch arm64 --arch x86_64
	mkdir -p dist
	tar -czf dist/macfan-$(VERSION)-macos.tar.gz -C $(dir $(UNIVERSAL)) macfan
	shasum -a 256 dist/macfan-$(VERSION)-macos.tar.gz

clean:
	rm -rf .build dist
