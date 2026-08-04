SRC=tree-sitter-zig rune
LIB=$(wildcard pkg/**/*) $(wildcard pkg/*) pkg
TAR=zig.tar.gz
NOTARIZE_ZIP=zig-notarize.zip
CODESIGN_IDENTITY=Developer ID Application: Unstable Build, LLC. (YYZRWD888J)
NOTARY_PROFILE=notary-profile
UNAME=$(shell uname)

# GNU tar is named "gtar" on macOS (Homebrew) but is the default "tar" on Linux.
ifeq ($(UNAME),Darwin)
GTAR=gtar
else
GTAR=tar
endif

# Pinned prebuilt toolchain versions (downloaded per target os/arch). Zig needs
# no bootstrap step: the compiler, zls and lldb-dap are all prebuilt downloads.
ZIG_VERSION=0.16.0
# zls refuses to serve a zig whose major.minor differs, so these move together.
ZLS_VERSION=0.16.0
# lldb-dap is extracted from the official prebuilt LLVM release. Keep this in
# sync with rune-language-rust: both packages copy a `lldb-dap` into the shared
# $RUNE_DATADIR/bin, and identical versions make that collision a no-op.
# macOS x86_64 prebuilts stopped at LLVM 19, so darwin-amd64 is skipped.
LLVM_VERSION=22.1.8

HOST_OS=$(shell uname | tr '[:upper:]' '[:lower:]')
HOST_ARCH=$(shell uname -m | sed -e 's/^x86_64$$/amd64/' -e 's/^aarch64$$/arm64/')
TARGET_OS=$(HOST_OS)
TARGET_ARCH?=$(HOST_ARCH)

CROSS=$(filter-out $(HOST_ARCH),$(TARGET_ARCH))
CGO_ENABLED=$(if $(CROSS),0,1)

GNU_TRIPLE_amd64=x86_64-linux-gnu
GNU_TRIPLE_arm64=aarch64-linux-gnu
CC=$(if $(CROSS),$(GNU_TRIPLE_$(TARGET_ARCH))-gcc,gcc)

# extension_zig imports ide/syntax and go-tree-sitter, so it must build with
# CGO enabled even for cross-arch releases. clang cross-compiles natively on
# macOS via -arch; Linux needs the matching GNU cross toolchain.
CLANG_ARCH_amd64=x86_64
CLANG_ARCH_arm64=arm64
ifeq ($(HOST_OS),darwin)
EXT_CC=clang $(if $(CROSS),-arch $(CLANG_ARCH_$(TARGET_ARCH)),)
else
EXT_CC=$(CC)
endif

# Zig release asset naming: zig-<arch>-<os>-<version>.tar.xz
ZIG_ARCH_amd64=x86_64
ZIG_ARCH_arm64=aarch64
ZIG_ARCH=$(ZIG_ARCH_$(TARGET_ARCH))
ZIG_OS_darwin=macos
ZIG_OS_linux=linux
ZIG_OS=$(ZIG_OS_$(TARGET_OS))
ZIG_DIST=zig-$(ZIG_ARCH)-$(ZIG_OS)-$(ZIG_VERSION)
# zls release asset naming: zls-<arch>-<os>.tar.xz
ZLS_DIST=zls-$(ZIG_ARCH)-$(ZIG_OS)

# LLVM release asset naming (different per OS).
LLVM_ARCH_amd64_linux=X64
LLVM_ARCH_arm64_linux=ARM64
LLVM_ARCH_arm64_darwin=ARM64
LLVM_OSNAME_darwin=macOS
LLVM_OSNAME_linux=Linux
LLVM_ASSET=LLVM-$(LLVM_VERSION)-$(LLVM_OSNAME_$(TARGET_OS))-$(LLVM_ARCH_$(TARGET_ARCH)_$(TARGET_OS)).tar.xz

BLUECTL_CONFIG_ROOT := $(abspath deploy/bluectl)

DIST_TARGETS := \
	dist-prod-darwin-arm64 dist-prod-darwin-amd64 \
	dist-prod-linux-arm64  dist-prod-linux-amd64  \
	dist-staging-darwin-arm64 dist-staging-darwin-amd64 \
	dist-staging-linux-arm64  dist-staging-linux-amd64

.PHONY: $(DIST_TARGETS) clean sign notarize notary-credentials toolchain test
default: $(TAR)

# Stage the prebuilt zig toolchain, zls and lldb-dap for the target os/arch.
toolchain:
	@mkdir -p pkg/bin pkg/lib
	# zig: the compiler resolves its lib/ (std, libc headers, compiler-rt)
	# RELATIVE to its own executable, so the binary must ship with its sibling
	# lib/ intact under pkg/zig/. The installer additionally byte-copies every
	# packaged executable into $$RUNE_DATADIR/bin, and that copy is severed from
	# lib/ -- config.yaml sets ZIG_LIB_DIR to repair it.
	wget -O zig.tar.xz https://ziglang.org/download/$(ZIG_VERSION)/$(ZIG_DIST).tar.xz
	rm -rf pkg/zig && mkdir -p pkg/zig
	tar -xJf zig.tar.xz -C pkg/zig --strip-components=1
	rm -rf zig.tar.xz pkg/zig/doc
	# lib/ is data (zig sources, libc headers). Strip exec bits so the
	# installer's flat bin-copy step does not publish lib payload onto PATH.
	find pkg/zig/lib -type f -exec chmod a-x {} +
	chmod +x pkg/zig/zig
	# zls: single static binary, no sibling data.
	wget -O zls.tar.xz https://github.com/zigtools/zls/releases/download/$(ZLS_VERSION)/$(ZLS_DIST).tar.xz
	rm -rf zls-extract && mkdir -p zls-extract
	tar -xJf zls.tar.xz -C zls-extract
	cp zls-extract/zls pkg/bin/zls
	chmod +x pkg/bin/zls
	rm -rf zls.tar.xz zls-extract
	# lldb-dap: extract only bin/lldb-dap + the liblldb shared lib it links
	# from the ~1.5GB prebuilt LLVM tarball; never the build-time static .a
	# archives. lldb-dap's rpath is @loader_path/../lib, which resolves inside
	# the installed package dir (bin/ + lib/ siblings) -- config.yaml therefore
	# invokes it by its package-local path, not through $$RUNE_DATADIR/bin.
	@if [ "$(TARGET_OS)-$(TARGET_ARCH)" = "darwin-amd64" ]; then \
		echo "skip lldb-dap: no official macOS-amd64 LLVM $(LLVM_VERSION) prebuilt"; \
	else \
		wget -O llvm.tar.xz https://github.com/llvm/llvm-project/releases/download/llvmorg-$(LLVM_VERSION)/$(LLVM_ASSET); \
		mkdir -p llvm-extract; \
		tar -xJf llvm.tar.xz -C llvm-extract --strip-components=1 '*/bin/lldb-dap'; \
		tar -xJf llvm.tar.xz -C llvm-extract --strip-components=1 '*/lib/liblldb.*dylib' 2>/dev/null || true; \
		tar -xJf llvm.tar.xz -C llvm-extract --strip-components=1 '*/lib/liblldb.so*'   2>/dev/null || true; \
		tar -xJf llvm.tar.xz -C llvm-extract --strip-components=1 '*/lib/libLLVM.so*'   2>/dev/null || true; \
		cp llvm-extract/bin/lldb-dap pkg/bin/lldb-dap; \
		cp -a llvm-extract/lib/liblldb.*dylib pkg/lib/ 2>/dev/null || true; \
		cp -a llvm-extract/lib/liblldb.so* pkg/lib/ 2>/dev/null || true; \
		cp -a llvm-extract/lib/libLLVM.so* pkg/lib/ 2>/dev/null || true; \
		chmod +x pkg/bin/lldb-dap; \
		rm -rf llvm.tar.xz llvm-extract; \
	fi

$(LIB): $(SRC) toolchain
	@mkdir -p pkg/bin pkg/lib
ifeq ($(HOST_OS),darwin)
	cd tree-sitter-zig && cc -o parser.so -I./src src/*.c -Os -bundle -arch arm64 -arch x86_64
else
	cd tree-sitter-zig && $(CC) -o parser.so -I./src src/*.c -Os -shared -fPIC
endif
	cp tree-sitter-zig/parser.so pkg/lib/tree-sitter.so
	# All four query kinds come from the grammar repo with no inherits chain,
	# matching the fixtures under rune/ide/syntax/syntaxtest/zig.
	cp tree-sitter-zig/queries/highlights.scm pkg/lib
	cp tree-sitter-zig/queries/indents.scm pkg/lib
	cp tree-sitter-zig/queries/locals.scm pkg/lib
	cp tree-sitter-zig/queries/folds.scm pkg/lib
	cd rune && CGO_ENABLED=1 CC="$(EXT_CC)" GOOS=$(TARGET_OS) GOARCH=$(TARGET_ARCH) \
		go build -o $(PWD)/pkg/bin/extension_zig ./cmd/extension_zig
	cp config.yaml pkg

ifeq ($(UNAME),Darwin)
sign: $(LIB)
	codesign --force --options runtime --sign "$(CODESIGN_IDENTITY)" pkg/zig/zig
	codesign --force --options runtime --sign "$(CODESIGN_IDENTITY)" pkg/bin/zls
	codesign --force --options runtime --sign "$(CODESIGN_IDENTITY)" pkg/bin/extension_zig
	codesign --force --options runtime --sign "$(CODESIGN_IDENTITY)" pkg/lib/tree-sitter.so
	# lldb-dap + liblldb are absent for darwin-amd64 (no prebuilt LLVM); sign the
	# dylib before the binary so the binary's rpath ref stays valid.
	@for f in pkg/lib/liblldb*.dylib pkg/bin/lldb-dap; do \
		[ -f "$$f" ] && codesign --force --options runtime --sign "$(CODESIGN_IDENTITY)" "$$f" || true; \
	done

$(NOTARIZE_ZIP): sign
	zip $(NOTARIZE_ZIP) pkg/zig/zig pkg/bin/zls pkg/bin/extension_zig pkg/lib/tree-sitter.so
	@for f in pkg/bin/lldb-dap pkg/lib/liblldb*.dylib; do \
		[ -f "$$f" ] && zip $(NOTARIZE_ZIP) "$$f" || true; \
	done

notarize: $(NOTARIZE_ZIP)
	xcrun notarytool submit $(NOTARIZE_ZIP) --keychain-profile "$(NOTARY_PROFILE)" --wait
else
sign: $(LIB)
	@echo "Skipping codesign (not on macOS)"

notarize: sign
	@echo "Skipping notarization (not on macOS)"
endif

$(TAR): $(LIB) sign
	cd pkg && $(GTAR) --no-xattrs --no-acls -czf ../$(TAR) .

# Verify release-tarball properties (no .go source leaks, zig lib payload, etc).
test: $(TAR)
	TAR=$(TAR) NOTARIZE_ZIP=$(NOTARIZE_ZIP) ZIG_VERSION=$(ZIG_VERSION) \
		ZLS_VERSION=$(ZLS_VERSION) ./scripts/test.sh

$(DIST_TARGETS): dist-%: check-release-tag
	@env=$$(echo $* | cut -d- -f1); \
	 os=$$(echo $*  | cut -d- -f2); \
	 arch=$$(echo $* | cut -d- -f3); \
	 if [ "$$os" != "$(HOST_OS)" ]; then \
	   echo "error: $@ targets OS '$$os' but host OS is '$(HOST_OS)'; build $$os releases on a $$os machine" >&2; \
	   exit 1; \
	 fi; \
	 $(MAKE) clean; \
	 $(MAKE) notarize $(TAR) TARGET_ARCH=$$arch; \
	 $(MAKE) test TARGET_ARCH=$$arch; \
	 BLUECTL_CONFIG_DIR=$(BLUECTL_CONFIG_ROOT)/$$env/$$os-$$arch \
	 BLUE_TARGET_OS=$$os BLUE_TARGET_ARCH=$$arch ./dist.sh

.PHONY: check-release-tag
check-release-tag:
	./check-release-tag.sh

notary-credentials:
	xcrun notarytool store-credentials "$(NOTARY_PROFILE)" --team-id "YYZRWD888J"

clean:
	rm -rf $(TAR)
	rm -rf $(NOTARIZE_ZIP)
	rm -rf pkg/
	rm -rf llvm.tar.xz llvm-extract zig.tar.xz zls.tar.xz zls-extract
	rm -f tree-sitter-zig/parser.so