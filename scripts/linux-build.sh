#!/usr/bin/env bash
# Full build on a Linux host (CI or any Linux box), reproducing docs/BUILDING.md:
#
#   bash scripts/linux-build.sh           # everything: tools, libc++, OpenSSL, FFmpeg, Eden, .pkg
#   bash scripts/linux-build.sh eden      # Eden+package only (needs libcxx18/ and prefix/ cached)
#
# System requirements (installed by the GitHub Actions workflow; any Debian-ish distro):
#   clang/llvm 18 (clang clang++ llvm-ar llvm-ranlib llvm-nm ld.lld), cmake 3.28+, ninja,
#   glslangValidator, perl, make, python3, curl, git, unzip, file, tar.
#
# Host tools and SDKs are downloaded or linked into _tools/, sdk-dl/ etc. (gitignored). The
# Windows-absolute paths in tools/*.sh, toolchain/*.cmake, configure-eden.sh and package-eden.sh
# are rewritten to this layout on first run, exactly like docs/BUILDING.md section 0 asks, except
# this script does it for you:
#   $REPO/sdk-dl/orbis-sdk-v1    kit release: toolchain + orbis-compat + sdk (bin/linux tools)
#   $TOOLS/llvm/bin              symlink farm to the system llvm-18 binaries
#   $TOOLS/bin/cygpath|python    shims so the author's scripts run unmodified
#   $TOOLS/OpenOrbis/OpenOrbis/PS4Toolchain   OpenOrbis 0.5.4 (piglet modules for packaging)
#   $TOOLS/hbmenu                        nx-hbmenu, downloaded (hbmenu.nro -> testroms/)
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
TOOLS="${EDEN_TOOLS:-$REPO/_tools}"
JOBS="${MAXJOBS:-$(nproc)}"
NPROC_IS="$JOBS"

SDK_GZ_URL=https://github.com/orbis-ports/orbis-porting-kit/releases/download/orbis-sdk-v1/orbis-sdk-v1.tar.gz
OO_GZ_URL=https://github.com/OpenOrbis/OpenOrbis-PS4-Toolchain/releases/download/v0.5.4/toolchain-llvm-18.tar.gz
HBMENU_URL=https://github.com/switchbrew/nx-hbmenu/releases/download/v3.6.1/nx-hbmenu_v3.6.1.zip
OPENSSL_URL=https://www.openssl.org/source/openssl-3.6.2.tar.gz
FFMPEG_SHA=c7b5f1537d9c52efa50fd10d106ca015ddde1818

say() { echo -e "\n===== $* =====" >&2; }

# Runs on every startup: idempotent and cheap, so a restored `_tools/` cache can never leave
# Windows paths behind in the tracked build files.
nonfatal() { "$@" || echo "warning: $* failed" >&2; }

{
    say "rewriting hardcoded Windows paths (docs/BUILDING.md section 0)"
    files="tools/ps4-cc.sh toolchain/eden-ps4.cmake toolchain/runtimes-ps4.cmake configure-eden.sh package-eden.sh"
    for f in $files; do
        nonfatal sed -i \
            -e "s#C:/Users/alejo/eden-ps4#$REPO#g" \
            -e "s#/c/Users/alejo/eden-ps4#$REPO#g" \
            -e "s#C:/Users/alejo/soh-ps4/tools#$TOOLS#g" \
            -e "s#/c/Users/alejo/soh-ps4/tools#$TOOLS#g" \
            -e 's/\(clang\|clang++\|llvm-ar\|llvm-ranlib\)\.exe/\1/g' \
            "$f"
    done
    # tools/env-build.sh is Windows-only; regenerate it for Linux (same variable names).
    cat > tools/env-build.sh <<EOF
# Linux rewrite of the original tools/env-build.sh; variable names and flags kept identical.
export PATH="$REPO/tools/bin:$TOOLS/llvm/bin:$TOOLS/bin:\$PATH"
export PS4_SDK=$REPO/sdk-dl/orbis-sdk-v1/sdk
export PS4_COMPAT=$REPO/sdk-dl/orbis-sdk-v1/orbis-compat
export PS4_OVERLAY=$REPO/toolchain/include-overlay
export PS4_PREFIX=$REPO/prefix
export PS4_CFLAGS="--target=x86_64-pc-freebsd12-elf -O2 -fPIC -funwind-tables -D__PS4__ -D__ORBIS__ -D_BSD_SOURCE=1 -U__FreeBSD__ -isysroot \$PS4_SDK -isystem \$PS4_OVERLAY -isystem \$PS4_COMPAT/include -isystem \$PS4_SDK/include -include orbis_prefix.h"
EOF
}

# ----------------------------------------------------------------- 1. host bits
say "host shims and llvm symlinks into $TOOLS"
mkdir -p "$TOOLS/bin" "$TOOLS/llvm/bin" "$REPO/tools/bin" testroms out 2>/dev/null || true
LLVM_SYS=/usr/lib/llvm-18/bin
for t in clang clang++ llvm-ar llvm-ranlib llvm-nm ld.lld ld llvm-objcopy llvm-readobj llvm-addr2line \
         llvm-strip llvm-cxxfilt llvm-dwarfdump llvm-objdump clang-tidy; do
    src="$LLVM_SYS/$t"; [ -x "$src" ] || { src="$(command -v "$t" || true)"; [ -n "$src" ] && src="$(readlink -f "$src")" && [ -x "$src" ] || continue; }
    ln -sf "$src" "$TOOLS/llvm/bin/$t"
done
# shims so the author's scripts run unmodified on Linux
cat > "$TOOLS/bin/cygpath" <<'EOF'
#!/usr/bin/env bash
# Only -m/-u are used (paths are already POSIX on Linux); print the arguments unchanged.
if [ "${1:-}" = -m ] || [ "${1:-}" = -u ]; then shift; fi
if [ $# -gt 0 ]; then printf '%s\n' "$*"; fi
EOF
cat > "$TOOLS/bin/python" <<'EOF'
#!/usr/bin/env bash
exec python3 "$@"
EOF
chmod +x "$TOOLS/bin/cygpath" "$TOOLS/bin/python"
# package-eden.sh: use the kit's native Linux pkg tools instead of bin/windows
sed -i 's#BIN="$SDK/bin/windows"#BIN="$SDK/bin/linux"#' package-eden.sh

# ----------------------------------------------------------------- 2. SDK + OpenOrbis + hbmenu
if [ ! -f "$REPO/sdk-dl/orbis-sdk-v1/toolchain/orbis-sdk.cmake" ]; then
    say "downloading orbis-porting-kit orbis-sdk-v1"
    mkdir -p sdk-dl
    curl -L --fail -o sdk-dl/orbis-sdk.tar.gz "$SDK_GZ_URL"
    tar -xzf sdk-dl/orbis-sdk.tar.gz -C sdk-dl
    # orbis-compat should ship prebuilt; build it only if missing.
    if [ ! -f sdk-dl/orbis-sdk-v1/orbis-compat/build/liborbis-compat.a ]; then
        (cd sdk-dl/orbis-sdk-v1/orbis-compat && bash build.sh)
    fi
    # package-eden.sh still names the tools with .exe (it ran on Windows): Linux executes
    # ELF under any filename, so symlink the Linux tools to the names the script calls.
    for n in create-fself create-gp4 PkgTool.Core; do
        [ -x "sdk-dl/orbis-sdk-v1/sdk/bin/linux/$n" ] && \
            ln -sf "$n" "sdk-dl/orbis-sdk-v1/sdk/bin/linux/$n.exe"
    done
fi
OO_DIR="$TOOLS/OpenOrbis/OpenOrbis/PS4Toolchain"
if [ ! -d "$OO_DIR/samples/piglet" ]; then
    say "downloading OpenOrbis 0.5.4 toolchain (piglet modules for packaging)"
    curl -L --fail -o "$TOOLS/oo-toolchain.tar.gz" "$OO_GZ_URL"
    mkdir -p "$TOOLS/OpenOrbis"
    tar -xzf "$TOOLS/oo-toolchain.tar.gz" -C "$TOOLS/OpenOrbis"
fi
if [ ! -f testroms/hbmenu.nro ]; then
    say "downloading the Homebrew Menu test program (nx-hbmenu 3.6.1)"
    curl -L --fail -o "$TOOLS/hbmenu.zip" "$HBMENU_URL"
    unzip -oq "$TOOLS/hbmenu.zip" -d "$TOOLS/hbmenu"
    cp "$TOOLS/hbmenu/hbmenu.nro" testroms/
    cp "$TOOLS/hbmenu/hbmenu-LICENSE.txt" testroms/ 2>/dev/null || true
fi

[ -x "$TOOLS/llvm/bin/clang" ] || { echo "error: clang not found (install llvm-18 / apt.llvm.org)"; exit 1; }
have() { command -v "$1" >/dev/null; }
for tool in cmake ninja glslangValidator perl make python3 curl git unzip file; do
    have "$tool" || { echo "error: required tool '$tool' not on PATH"; exit 1; }
done

# ----------------------------------------------------------------- 3. libc++ 18 for the PS4
LLVM_TAG=llvmorg-18.1.8
if [ ! -f "$REPO/libcxx18/lib/libc++.a" ]; then
    say "building libc++ 18 for the PS4 (docs/BUILDING.md section 3)"
    if [ ! -d "$REPO/deps/llvm-project/.git" ]; then
        mkdir -p "$REPO/deps"
        git clone -q --filter=blob:none --no-checkout \
            https://github.com/llvm/llvm-project "$REPO/deps/llvm-project"
        git -C "$REPO/deps/llvm-project" checkout -q "$LLVM_TAG"
        git -C "$REPO/deps/llvm-project" sparse-checkout set runtimes libcxx libcxxabi libunwind cmake llvm/cmake llvm/utils/llvm-lit
    fi
    OPS="$REPO/deps/llvm-project/libcxx/src/filesystem/operations.cpp"
    python3 - "$OPS" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
if 'defined(__ORBIS__)' not in s:
    old = '#if __has_include(<sys/sendfile.h>)'
    if old not in s:
        for i, line in enumerate(s.splitlines()[:80], 1):
            sys.stdout.write(f'{i}: {line}\n')
        sys.exit("operations.cpp: could not find the Linux sendfile condition to patch")
    open(p, 'w').write(s.replace(old, '#if __has_include(<sys/sendfile.h>) && !defined(__ORBIS__)'))
PY
    cmake -S "$REPO/deps/llvm-project/runtimes" -B "$REPO/build-libcxx" -G Ninja \
        -DCMAKE_TOOLCHAIN_FILE="$REPO/toolchain/runtimes-ps4.cmake" \
        -DLLVM_ENABLE_RUNTIMES="libcxx;libcxxabi" \
        -DLIBCXX_ENABLE_SHARED=OFF -DLIBCXXABI_ENABLE_SHARED=OFF \
        -DLIBCXX_HAS_MUSL_LIBC=ON -DLIBCXX_CXX_ABI=libcxxabi \
        -DLIBCXX_ENABLE_NEW_DELETE_DEFINITIONS=OFF -DLIBCXXABI_USE_LLVM_UNWINDER=OFF \
        -DLIBCXX_ENABLE_TIME_ZONE_DATABASE=OFF -DLIBCXX_INCLUDE_BENCHMARKS=OFF \
        -DLIBCXX_HAS_PTHREAD_API=ON \
        -DLLVM_INCLUDE_TESTS=OFF -DLIBCXX_INCLUDE_TESTS=OFF -DLIBCXXABI_INCLUDE_TESTS=OFF \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$REPO/libcxx18"
    cmake --build "$REPO/build-libcxx" -j "$NPROC_IS"
    cmake --install "$REPO/build-libcxx"
    printf '#undef __FreeBSD__\n' >> "$REPO/libcxx18/include/c++/v1/__config_site"
else say "libc++18 cache hit"; fi

# ----------------------------------------------------------------- 4. OpenSSL + FFmpeg
source tools/env-build.sh
export PATH="$TOOLS/bin:$PATH"   # cygpath/python shims first
if [ ! -f "$REPO/prefix/lib/libssl.a" ]; then
    say "cross-building OpenSSL 3.6.2 (docs/BUILDING.md section 4)"
    if [ ! -d "$REPO/deps/openssl-3.6.2" ]; then
        mkdir -p "$REPO/deps"
        curl -L --fail -o "$REPO/deps/openssl.tar.gz" "$OPENSSL_URL"
        tar -xzf "$REPO/deps/openssl.tar.gz" -C "$REPO/deps"
    fi
    (
        cd "$REPO/deps/openssl-3.6.2"
        CFLAGS="$PS4_CFLAGS -nostdlibinc" CC="$TOOLS/llvm/bin/clang" AR="$TOOLS/llvm/bin/llvm-ar" \
        RANLIB="$TOOLS/llvm/bin/llvm-ranlib" perl Configure linux-x86_64-clang \
            no-shared no-tests no-apps no-docs no-dso no-async no-afalgeng no-engine no-ui-console \
            no-secure-memory no-module --with-rand-seed=devrandom --prefix="$REPO/prefix" \
            --libdir=lib --openssldir=/app0/ssl
        make -j "$NPROC_IS" build_libs
        make install_dev
    )
else say "openssl cache hit"; fi
if [ ! -f "$REPO/prefix/lib/libavcodec.a" ]; then
    say "cross-building FFmpeg ($FFMPEG_SHA) (docs/BUILDING.md section 4)"
    if [ ! -d "$REPO/deps/ffmpeg/.git" ]; then
        git clone -q --filter=blob:none --no-checkout https://github.com/FFmpeg/FFmpeg "$REPO/deps/ffmpeg"
        git -C "$REPO/deps/ffmpeg" fetch -q origin "$FFMPEG_SHA"
        git -C "$REPO/deps/ffmpeg" checkout -q -f "$FFMPEG_SHA"
    fi
    mkdir -p "$REPO/deps/build-ffmpeg" "$REPO/deps/tmp"
    export TMPDIR="$REPO/deps/tmp"
    (
        cd "$REPO/deps/build-ffmpeg"
        ../ffmpeg/configure \
            --prefix="$REPO/prefix" --enable-cross-compile --arch=x86_64 --target-os=freebsd \
            --host-cc="$TOOLS/llvm/bin/clang" --host-ld="$TOOLS/llvm/bin/clang" \
            --cc="bash $REPO/tools/ps4-cc.sh" --ld="bash $REPO/tools/ps4-cc.sh" \
            --ar="$TOOLS/llvm/bin/llvm-ar" --ranlib="$TOOLS/llvm/bin/llvm-ranlib" \
            --nm="$TOOLS/llvm/bin/llvm-nm" --disable-x86asm --disable-autodetect --disable-everything \
            --disable-programs --disable-doc --disable-avdevice --disable-avformat --disable-network \
            --disable-swresample --enable-decoder='h264,vp8,vp9' --enable-filter='yadif,scale' \
            --enable-pic --enable-pthreads --disable-shared --enable-static
        make -j "$NPROC_IS"
        make install
    )
else say "ffmpeg cache hit"; fi

# ----------------------------------------------------------------- 5. Eden
if [ ! -d "$REPO/deps/eden/src" ]; then
    say "fetching Eden + port patches (scripts/fetch-eden.sh)"
    bash scripts/fetch-eden.sh
fi
say "configuring Eden"
bash configure-eden.sh
say "building eden-ps4 ($NPROC_IS jobs)"
cmake --build "$REPO/build-eden" --target eden-ps4 -j "$NPROC_IS"

# ----------------------------------------------------------------- 6. Package
say "packaging the .pkg"
bash package-eden.sh
say "DONE: $(ls "$REPO"/out-eden/*.pkg 2>/dev/null)"
