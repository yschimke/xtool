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
# 3. libxadi from source via D / ldc (mirrors Dockerfile build-xadi)
# ---------------------------------------------------------------------------
if [ ! -f "$MARKER_DIR/xadi.done" ]; then
    log "installing D toolchain (ldc) and building libxadi..."
    if [ ! -f "$HOME/dlang/install.sh" ]; then
        curl -fsS https://dlang.org/install.sh | bash -s ldc
    fi
    XADI_SRC="${MARKER_DIR}/src/xadi"
    rm -rf "$XADI_SRC"
    git clone --depth 1 --branch main https://github.com/xtool-org/xadi.git "$XADI_SRC"
    (
        cd "$XADI_SRC"
        # shellcheck disable=SC1090
        source "$("$HOME/dlang/install.sh" ldc -a)"
        dub build --build=release
        maybe_sudo cp -r bin/libxadi.so /usr/lib/libxadi.so
    )
    maybe_sudo ldconfig
    touch "$MARKER_DIR/xadi.done"
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
