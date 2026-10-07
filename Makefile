# Release packaging for the Rune zig package. See README.md for the runbook.
#
# One host builds every platform: extension_zig is pure Go (CGO_ENABLED=0),
# the grammar and lldb-dap are compiled by `zig cc` for Linux and Apple clang
# for macOS, and zig and zls are prebuilt downloads. macOS packages need Apple
# clang and codesign, so they must be built on macOS.
#
# The macOS tree-sitter.so is signed with Rune's Developer ID. Rune.app runs
# with the hardened runtime, whose library validation refuses to load a
# tree-sitter.so signed by any other team; an ad-hoc signature has no team.
# Packages are not notarized: Rune installs them without the quarantine
# attribute, so Gatekeeper never assesses them.

ZIG_VERSION=0.16.0
# zls refuses to serve a zig whose major.minor differs, so these move together.
ZLS_VERSION=0.16.0
# lldb-dap is built from this LLVM source release by scripts/build-lldb-dap.sh.
# Keep it in sync with rune-language-rust, which also ships an lldb-dap.
LLVM_VERSION=22.1.8

# Platform floors from docs.rune.build; scripts/test.sh enforces them.
MACOS_MIN=13.3
GLIBC_MIN=2.28

PLATFORMS=darwin-arm64 darwin-amd64 linux-arm64 linux-amd64
ENVS=prod staging

TEAM_ID=YYZRWD888J
CODESIGN_IDENTITY=Developer ID Application: Unstable Build, LLC. ($(TEAM_ID))
# Signs and checks macOS packages; shared by every language repo.
MACOS_SIGNING=TEAM_ID=$(TEAM_ID) CODESIGN_IDENTITY="$(CODESIGN_IDENTITY)" \
	TARGET_ARCH=$(TARGET_ARCH) ./scripts/macos-signing.sh

HOST_OS:=$(shell uname | tr '[:upper:]' '[:lower:]')
HOST_ARCH:=$(shell uname -m | sed -e 's/^x86_64$$/amd64/' -e 's/^aarch64$$/arm64/')
TARGET_OS?=$(HOST_OS)
TARGET_ARCH?=$(HOST_ARCH)
PLATFORM=$(TARGET_OS)-$(TARGET_ARCH)

ifeq ($(filter $(PLATFORM),$(PLATFORMS)),)
$(error unsupported platform '$(PLATFORM)'; expected one of: $(PLATFORMS))
endif
ifeq ($(TARGET_OS)-$(HOST_OS),darwin-linux)
$(error $(PLATFORM) packages must be built on macOS)
endif

BUILD=build/$(PLATFORM)
PKG=$(BUILD)/pkg
TAR=$(BUILD)/zig.tar.gz
TOOLCHAIN_STAMP=$(BUILD)/.toolchain-stamp
# Download and lldb-dap build cache. It survives `make clean`; file names carry
# the version.
DL=downloads

# GNU tar is named "gtar" on macOS (Homebrew) but is the default "tar" on Linux.
ifeq ($(HOST_OS),darwin)
GTAR=gtar
else
GTAR=tar
endif

# zig and zls release assets are named after zig's <arch>-<os> pair.
ZIG_ARCH_amd64=x86_64
ZIG_ARCH_arm64=aarch64
ZIG_OS_darwin=macos
ZIG_OS_linux=linux
ZIG_TRIPLE=$(ZIG_ARCH_$(TARGET_ARCH))-$(ZIG_OS_$(TARGET_OS))
ZIG_TARBALL=$(DL)/zig-$(ZIG_TRIPLE)-$(ZIG_VERSION).tar.xz
ZLS_TARBALL=$(DL)/zls-$(ZIG_TRIPLE)-$(ZLS_VERSION).tar.xz

LLVM_SRC=$(DL)/llvm-project-$(LLVM_VERSION).src.tar.xz
LLDB_DAP_TARBALL=$(DL)/lldb-dap-$(LLVM_VERSION)-$(PLATFORM).tar.xz

# The host's own zig compiles the grammar for Linux: `zig cc` cross-compiles
# against a pinned glibc, so no target toolchain or sysroot is needed.
HOST_ZIG_DIR=$(DL)/zig-$(ZIG_ARCH_$(HOST_ARCH))-$(ZIG_OS_$(HOST_OS))-$(ZIG_VERSION)
HOST_ZIG=$(HOST_ZIG_DIR)/zig

CLANG_ARCH_amd64=x86_64
CLANG_ARCH_arm64=arm64
ifeq ($(TARGET_OS),darwin)
PARSER_CC=cc -arch $(CLANG_ARCH_$(TARGET_ARCH)) -mmacosx-version-min=$(MACOS_MIN) -bundle
else
PARSER_CC=$(HOST_ZIG) cc -target $(ZIG_ARCH_$(TARGET_ARCH))-linux-gnu.$(GLIBC_MIN) -shared -fPIC
endif

# $(call fetch,<url>,<file>): download <url> to <file> unless it is cached.
fetch=mkdir -p $(DL) && { [ -f $2 ] || { wget -O $2.part $1 && mv $2.part $2; }; }

RELEASE_TARGETS=$(addprefix release-,$(PLATFORMS))
DARWIN_RELEASE_TARGETS=$(filter release-darwin-%,$(RELEASE_TARGETS))
DIST_TARGETS=$(foreach e,$(ENVS),$(foreach p,$(PLATFORMS),dist-$e-$p))
DIST_ALL_TARGETS=$(addprefix dist-,$(addsuffix -all,$(ENVS)))

.PHONY: default package sign test clean distclean \
	check-dist check-macos release-all $(RELEASE_TARGETS) $(DIST_TARGETS) \
	$(DIST_ALL_TARGETS)

default: $(TAR)

# Stage the prebuilt zig toolchain, zls and the built lldb-dap into the package.
$(TOOLCHAIN_STAMP): Makefile zig-shim.sh $(LLDB_DAP_TARBALL)
	$(call fetch,https://ziglang.org/download/$(ZIG_VERSION)/zig-$(ZIG_TRIPLE)-$(ZIG_VERSION).tar.xz,$(ZIG_TARBALL))
	$(call fetch,https://github.com/zigtools/zls/releases/download/$(ZLS_VERSION)/zls-$(ZIG_TRIPLE).tar.xz,$(ZLS_TARBALL))
	rm -rf $(PKG) && mkdir -p $(PKG)/bin $(PKG)/lib $(PKG)/zig
	# zig: the compiler locates its lib/ (std, libc headers, compiler-rt) by
	# walking up from its own executable path, so it must run from inside
	# zig/ next to its lib/. The installer byte-copies every non-hidden
	# packaged executable into $$RUNE_DATADIR/bin, which would publish a copy
	# severed from lib/; the real binary is therefore hidden (zig/.zig,
	# skipped by the installer) and PATH gets the zig-shim.sh wrapper instead.
	# No ZIG_LIB_DIR is exported, so user-provided toolchains are unaffected.
	$(GTAR) -xJf $(ZIG_TARBALL) -C $(PKG)/zig --strip-components=1
	rm -rf $(PKG)/zig/doc
	# lib/ is data (zig sources, libc headers). Strip exec bits so the
	# installer's flat bin-copy step does not publish lib payload onto PATH.
	find $(PKG)/zig/lib -type f -exec chmod a-x {} +
	mv $(PKG)/zig/zig $(PKG)/zig/.zig
	install -m 0755 zig-shim.sh $(PKG)/bin/zig
	# zls: single static binary, no sibling data.
	$(GTAR) -xJf $(ZLS_TARBALL) -C $(PKG)/bin zls
	# lldb-dap + liblldb (+ lldb-server on Linux). lldb-dap's rpath is
	# @loader_path/../lib ($$ORIGIN/../lib on Linux), which resolves inside
	# the installed package dir (bin/ + lib/ siblings) -- config.yaml
	# therefore invokes it by its package-local path, not through
	# $$RUNE_DATADIR/bin.
	$(GTAR) -xJf $(LLDB_DAP_TARBALL) -C $(PKG) --strip-components=1
	touch $@

$(HOST_ZIG):
	$(call fetch,https://ziglang.org/download/$(ZIG_VERSION)/$(notdir $(HOST_ZIG_DIR)).tar.xz,$(HOST_ZIG_DIR).tar.xz)
	$(GTAR) -xJf $(HOST_ZIG_DIR).tar.xz -C $(DL)

$(LLVM_SRC):
	$(call fetch,https://github.com/llvm/llvm-project/releases/download/llvmorg-$(LLVM_VERSION)/$(notdir $(LLVM_SRC)),$@)

# Upstream lldb-dap prebuilts need macOS 14.0, and glibc 2.34 plus system
# libpython3.11, libxml2 and ncurses, so it is built from source (see the
# script). The first build takes about 10 minutes per platform on a 16-core
# Mac and needs cmake and ninja; the result is cached in $(DL).
$(LLDB_DAP_TARBALL): $(LLVM_SRC) $(HOST_ZIG) scripts/build-lldb-dap.sh
	LLVM_SRC=$(LLVM_SRC) LLVM_VERSION=$(LLVM_VERSION) MACOS_MIN=$(MACOS_MIN) \
		GLIBC_MIN=$(GLIBC_MIN) ZIG=$(HOST_ZIG) WORK=build/lldb \
		./scripts/build-lldb-dap.sh $(TARGET_OS) $(TARGET_ARCH) $@

# Build the grammar and extension_zig into the staged package. They are
# rebuilt on every run: both are quick, and a stale binary must never ship.
package: $(TOOLCHAIN_STAMP) $(if $(filter linux,$(TARGET_OS)),$(HOST_ZIG))
	$(PARSER_CC) -Os -I tree-sitter-zig/src tree-sitter-zig/src/*.c -o $(PKG)/lib/tree-sitter.so
	# All four query kinds come from the grammar repo with no inherits chain,
	# matching the fixtures under rune/internal/ide/syntax/syntaxtest.
	cp tree-sitter-zig/queries/highlights.scm tree-sitter-zig/queries/indents.scm \
		tree-sitter-zig/queries/locals.scm tree-sitter-zig/queries/folds.scm $(PKG)/lib
	cd rune && CGO_ENABLED=0 GOOS=$(TARGET_OS) GOARCH=$(TARGET_ARCH) \
		go build -o $(CURDIR)/$(PKG)/bin/extension_zig ./cmd/extension_zig
	cp config.yaml $(PKG)

# Developer ID-sign tree-sitter.so in a macOS package, the one file Rune loads
# into its own process. The other binaries keep the signatures their linker or
# vendor gave them: re-signing the upstream x86_64 zig and zls overwrote the
# start of their code, so zls crashed on Intel Macs in v0.2.0 and v0.4.1.
# Linux packages are not signed.
sign: package
ifeq ($(TARGET_OS),darwin)
	$(MACOS_SIGNING) sign $(PKG)
endif

$(TAR): sign
	cd $(PKG) && $(GTAR) --no-xattrs --no-acls -czf $(CURDIR)/$@ .

# Verify the tarball (see scripts/test.sh). Binaries only run when the target
# is the host platform; every other check applies to all platforms.
test: $(TAR)
	TAR=$(TAR) TARGET_OS=$(TARGET_OS) TARGET_ARCH=$(TARGET_ARCH) \
		ZIG_VERSION=$(ZIG_VERSION) ZLS_VERSION=$(ZLS_VERSION) \
		MACOS_MIN=$(MACOS_MIN) GLIBC_MIN=$(GLIBC_MIN) \
		TEAM_ID=$(TEAM_ID) CODESIGN_IDENTITY="$(CODESIGN_IDENTITY)" \
		RUN_BINARIES=$(if $(filter $(HOST_OS)-$(HOST_ARCH),$(PLATFORM)),1,0) \
		./scripts/test.sh

# release-<os>-<arch>: build one platform from scratch and test it. This is
# dist-* without the upload.
$(RELEASE_TARGETS): release-%:
	rm -rf build/$*
	$(MAKE) test TARGET_OS=$(word 1,$(subst -, ,$*)) TARGET_ARCH=$(word 2,$(subst -, ,$*))

$(DARWIN_RELEASE_TARGETS): check-macos

# Linux hosts cannot build the macOS packages, so they cannot release all.
release-all: check-macos
	for p in $(PLATFORMS); do $(MAKE) release-$$p || exit 1; done

# dist-<env>-<os>-<arch>: release one platform and upload it to <env>.
$(DIST_TARGETS): dist-%: check-dist
	$(MAKE) release-$(word 2,$(subst -, ,$*))-$(word 3,$(subst -, ,$*))
	./dist.sh $(subst -, ,$*)

# dist-<env>-all: release all four platforms, then upload them. Nothing is
# uploaded unless every platform builds and passes its tests. It fails on
# Linux, which cannot build the macOS packages.
$(DIST_ALL_TARGETS): dist-%-all: check-macos check-dist
	$(MAKE) release-all
	for p in $(PLATFORMS); do ./dist.sh $* $${p%-*} $${p#*-} || exit 1; done

# Fail before any build work if the release cannot be uploaded.
check-dist:
	./check-release-tag.sh
	@command -v bluectl >/dev/null || { echo "error: bluectl is not on PATH" >&2; exit 1; }
	@: "$${BLUE_PGP_KEY:?is not set; see bluectl release upload -h}"
	@: "$${BLUE_PGP_KEYRING:?is not set; see bluectl release upload -h}"

# Fail before any build work if this host cannot sign the macOS packages:
# macOS and the Developer ID identity.
check-macos:
	@$(MACOS_SIGNING) preflight

clean:
	rm -rf build

distclean: clean
	rm -rf $(DL)