#!/bin/bash
# SessionStart hook for Claude Code on the web.
#
# Provisions the native toolchain xtool needs so that `swift build`,
# `swift test`, and `make lint` work inside a web session.
#
# The canonical Linux environment is the project Dockerfile
# (FROM swift:6.3-jammy, builds the libimobiledevice stack + libxadi from
# source). Web sessions don't run that image and the Docker daemon isn't
# available in-session, so we reproduce the Dockerfile's steps natively here.
# Keep this in sync with /Dockerfile -- that file is the source of truth.
set -euo pipefail

# Only run in the remote (Claude Code on the web) environment.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
    echo "session-start: not a remote session, skipping provisioning."
    exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
MARKER_DIR="${HOME}/.cache/xtool-session-start"
mkdir -p "$MARKER_DIR"

log() { echo "session-start: $*"; }

# ---------------------------------------------------------------------------
# Required network hosts.
#
# This environment's outbound network is governed by a policy allowlist. The
# hosts below MUST be reachable for provisioning to succeed; add any that the
# preflight reports as blocked to the environment's network policy.
#
#   download.swift.org     Swift toolchain (swiftly). MANDATORY -- the Linux
#                          toolchain is published nowhere else (no GitHub
#                          mirror, no apt package). Without it `swift build`,
#                          `swift test`, and `xtool` itself cannot be built.
#   github.com             Sources (libimobiledevice stack, xadi) + ldc release.
#   services.gradle.org    Gradle distribution (xtool's own builds).
#
# Needed only to build/test Kotlin Multiplatform projects via Gradle:
#   repo.maven.apache.org / repo1.maven.org   Kotlin, coroutines, etc.
#   plugins.gradle.org     Gradle plugins (KMP, swiftpackage, SKIE, ...).
#   maven.google.com       AndroidX / KMP artifacts.
#   dl.google.com          Android Gradle Plugin -- Android side only; NOT
#                          needed to assemble an iOS XCFramework.
#
# (dlang.org is no longer required: ldc is fetched from GitHub below.)
# ---------------------------------------------------------------------------
preflight_hosts() {
    local blocked=() h
    for h in download.swift.org github.com services.gradle.org \
             repo.maven.apache.org plugins.gradle.org maven.google.com; do
        curl -fsS -o /dev/null --max-time 15 "https://$h/" 2>/dev/null || blocked+=("$h")
    done
    if [ "${#blocked[@]}" -gt 0 ]; then
        log "WARNING: required hosts appear blocked by the network policy:"
        for h in "${blocked[@]}"; do log "  - $h"; done
        case " ${blocked[*]} " in
            *" download.swift.org "*)
                log "  download.swift.org is MANDATORY for the Swift toolchain; the install" ;;
        esac
        case " ${blocked[*]} " in
            *" download.swift.org "*)
                log "  step will fail until it is added to the allowlist." ;;
        esac
    fi
}
preflight_hosts

# Run a command with sudo if available and not already root.
maybe_sudo() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        "$@"
    fi
}

# ---------------------------------------------------------------------------
# 1. apt build dependencies (mirrors Dockerfile build-base)
# ---------------------------------------------------------------------------
if [ ! -f "$MARKER_DIR/apt.done" ]; then
    log "installing apt build dependencies..."
    export DEBIAN_FRONTEND=noninteractive
    maybe_sudo apt-get update
    maybe_sudo apt-get install -y --no-install-recommends \
        ca-certificates \
        build-essential \
        checkinstall \
        git \
        autoconf \
        automake \
        libtool-bin \
        libssl-dev \
        pkg-config \
        libxml2 \
        curl libcurl4-openssl-dev \
        zip unzip \
        liblzma-dev zlib1g-dev
    touch "$MARKER_DIR/apt.done"
else
    log "apt dependencies already installed, skipping."
fi

# ---------------------------------------------------------------------------
# 2. libimobiledevice stack from source (mirrors Dockerfile build-limd)
#    Installs into /usr (pinned versions matching the Dockerfile).
# ---------------------------------------------------------------------------
build_autotools_lib() {
    # $1 = name, $2 = git url, $3 = ref, $4... = extra configure flags
    local name="$1" url="$2" ref="$3"; shift 3
    local src="${MARKER_DIR}/src/${name}"
    if [ -f "$MARKER_DIR/${name}.done" ]; then
        log "${name} already built, skipping."
        return 0
    fi
    log "building ${name} (${ref})..."
    rm -rf "$src"
    git clone --depth 1 --branch "$ref" "$url" "$src"
    (
        cd "$src"
        ./autogen.sh --prefix /usr "$@"
        make
        maybe_sudo make install
    )
    maybe_sudo ldconfig
    touch "$MARKER_DIR/${name}.done"
}

build_autotools_lib libplist \
    https://github.com/libimobiledevice/libplist.git 2.6.0 --without-cython
build_autotools_lib libimobiledevice-glue \
    https://github.com/libimobiledevice/libimobiledevice-glue.git 1.3.1
build_autotools_lib libusbmuxd \
    https://github.com/libimobiledevice/libusbmuxd.git 2.1.0
build_autotools_lib libtatsu \
    https://github.com/libimobiledevice/libtatsu.git 1.0.4
build_autotools_lib libimobiledevice \
    https://github.com/libimobiledevice/libimobiledevice.git master --without-cython

# ---------------------------------------------------------------------------
# 3. libxadi from source via D / ldc (mirrors Dockerfile build-xadi).
#
#    libxadi is only needed for on-device operations (xtool install/launch),
#    NOT for building or testing. ldc is fetched from GitHub releases because
#    dlang.org's installer host is commonly blocked by the network policy. The
#    whole step is best-effort: a failure here must not abort the Swift toolchain
#    install below.
# ---------------------------------------------------------------------------
LDC_VERSION="1.40.0"

# Install ldc from GitHub releases and echo its bin directory.
install_ldc() {
    local root="$MARKER_DIR/ldc"
    if [ -x "$root/bin/dub" ]; then
        echo "$root/bin"; return 0
    fi
    local arch tarball url
    arch="$(uname -m)"
    tarball="ldc2-${LDC_VERSION}-linux-${arch}.tar.xz"
    url="https://github.com/ldc-developers/ldc/releases/download/v${LDC_VERSION}/${tarball}"
    rm -rf "$root"; mkdir -p "$root"
    curl -fsSL "$url" -o "$MARKER_DIR/$tarball" || return 1
    tar xf "$MARKER_DIR/$tarball" -C "$root" --strip-components=1 || return 1
    rm -f "$MARKER_DIR/$tarball"
    echo "$root/bin"
}

build_libxadi() {
    local ldc_bin
    ldc_bin="$(install_ldc)" || return 1
    local src="${MARKER_DIR}/src/xadi"
    rm -rf "$src"
    git clone --depth 1 --branch main https://github.com/xtool-org/xadi.git "$src" || return 1
    (
        cd "$src"
        export PATH="$ldc_bin:$PATH"
        dub build --build=release
        maybe_sudo cp -r bin/libxadi.so /usr/lib/libxadi.so
    ) || return 1
    maybe_sudo ldconfig
}

if [ ! -f "$MARKER_DIR/xadi.done" ]; then
    log "building libxadi (ldc $LDC_VERSION from GitHub)..."
    # Called in an `if` condition so `set -e` does not abort on failure.
    if build_libxadi; then
        touch "$MARKER_DIR/xadi.done"
    else
        log "warning: libxadi build failed (on-device ops unavailable); continuing."
    fi
else
    log "libxadi already built, skipping."
fi

# ---------------------------------------------------------------------------
# 4. Swift toolchain via swiftly (Dockerfile uses swift:6.3-jammy)
# ---------------------------------------------------------------------------
SWIFTLY_BIN="$HOME/.local/share/swiftly/bin"
if ! command -v swift >/dev/null 2>&1 && [ ! -x "$SWIFTLY_BIN/swift" ]; then
    log "installing Swift toolchain via swiftly..."
    ARCH="$(uname -m)"
    TMP_SWIFTLY="$(mktemp -d)"
    (
        cd "$TMP_SWIFTLY"
        curl -fsSLO "https://download.swift.org/swiftly/linux/swiftly-${ARCH}.tar.gz"
        tar zxf "swiftly-${ARCH}.tar.gz"
        ./swiftly init --assume-yes --quiet-shell-followup --skip-install
    )
    rm -rf "$TMP_SWIFTLY"
    export PATH="$SWIFTLY_BIN:$PATH"
    # Install the toolchain matching the Dockerfile (Swift 6.3).
    "$SWIFTLY_BIN/swiftly" install 6.3 --use
else
    log "Swift toolchain already present, skipping install."
fi
export PATH="$SWIFTLY_BIN:$PATH"

# Persist Swift on PATH for the rest of the session.
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
    echo "export PATH=\"$SWIFTLY_BIN:\$PATH\"" >> "$CLAUDE_ENV_FILE"
fi

# ---------------------------------------------------------------------------
# 5. Pre-fetch SwiftLint into the cache path the Makefile expects, so
#    `make lint` works offline. Version comes from .swiftlint.yml.
# ---------------------------------------------------------------------------
if [ -f "$PROJECT_DIR/.swiftlint.yml" ]; then
    SWIFTLINT_VERSION="$(head -1 "$PROJECT_DIR/.swiftlint.yml" | cut -d' ' -f2)"
    SWIFTLINT_DIR="$PROJECT_DIR/.tmp/swiftlint"
    SWIFTLINT_BIN="$SWIFTLINT_DIR/swiftlint-$SWIFTLINT_VERSION"
    if [ ! -x "$SWIFTLINT_BIN" ]; then
        log "fetching SwiftLint $SWIFTLINT_VERSION..."
        rm -rf "$SWIFTLINT_DIR"
        mkdir -p "$SWIFTLINT_DIR"
        curl -fSL \
            "https://github.com/realm/SwiftLint/releases/download/${SWIFTLINT_VERSION}/swiftlint_linux.zip" \
            -o "$SWIFTLINT_DIR/swiftlint.zip"
        unzip -q "$SWIFTLINT_DIR/swiftlint.zip" swiftlint -d "$SWIFTLINT_DIR"
        rm -f "$SWIFTLINT_DIR/swiftlint.zip"
        mv "$SWIFTLINT_DIR/swiftlint" "$SWIFTLINT_BIN"
        ln -sf "swiftlint-$SWIFTLINT_VERSION" "$SWIFTLINT_DIR/swiftlint"
    else
        log "SwiftLint $SWIFTLINT_VERSION already present, skipping."
    fi
fi

# ---------------------------------------------------------------------------
# 6. Warm the SwiftPM dependency cache.
# ---------------------------------------------------------------------------
if command -v swift >/dev/null 2>&1; then
    log "resolving SwiftPM dependencies..."
    (cd "$PROJECT_DIR" && swift package resolve) || \
        log "warning: 'swift package resolve' failed (continuing)."
fi

log "provisioning complete."
