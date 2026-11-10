#!/usr/bin/env bash
# Build one Linux/musl cross toolchain around an existing host LLVM artifact.
set -euo pipefail

required_vars=(
  LLVM_VERSION LLVM_SHA LINUX_SHA MUSL_SHA TARGET_TRIPLE KERNEL_ARCH
  COMPILER_RT_ARCH TARGET_FLAGS QEMU TOOLCHAIN_ROOT WORK_DIR OUT_DIR
)
for name in "${required_vars[@]}"; do
  if [[ -z "${!name:-}" ]]; then
    echo "missing required environment variable: $name" >&2
    exit 2
  fi
done

LLVM_MAJOR="${LLVM_VERSION%%.*}"
JOBS="${JOBS:-$(nproc)}"
BIN_DIR="$TOOLCHAIN_ROOT/bin"
SYSROOT="$TOOLCHAIN_ROOT/$TARGET_TRIPLE"
RESOURCE_DIR="$TOOLCHAIN_ROOT/lib/clang/$LLVM_MAJOR"
LLVM_SRC="$WORK_DIR/llvm-project"
LINUX_SRC="$WORK_DIR/linux"
MUSL_SRC="$WORK_DIR/musl"

checkout_commit() {
  local repository="$1"
  local commit="$2"
  local destination="$3"

  git init -q "$destination"
  git -C "$destination" remote add origin "$repository"
  git -C "$destination" fetch -q --depth 1 origin "$commit"
  git -C "$destination" checkout -q --detach FETCH_HEAD
}

link_tool() {
  local target="$1"
  local name="$2"
  ln -sfn "$target" "$BIN_DIR/$TARGET_TRIPLE-$name"
}

case "$TARGET_TRIPLE" in
  arm-unknown-linux-musleabihf|aarch64-unknown-linux-musl|x86_64-unknown-linux-musl)
    ;;
  *)
    echo "unsupported target: $TARGET_TRIPLE" >&2
    exit 2
    ;;
esac

[[ -x "$BIN_DIR/clang" ]] || {
  echo "host clang is missing from $BIN_DIR" >&2
  exit 1
}
[[ -d "$RESOURCE_DIR/include" ]] || {
  echo "unexpected Clang resource directory: $RESOURCE_DIR" >&2
  exit 1
}

mkdir -p "$WORK_DIR" "$SYSROOT" "$OUT_DIR/$TARGET_TRIPLE"

echo "==> Fetch pinned sources"
checkout_commit https://github.com/llvm/llvm-project.git "$LLVM_SHA" "$LLVM_SRC"
checkout_commit https://github.com/gregkh/linux.git "$LINUX_SHA" "$LINUX_SRC"
checkout_commit https://github.com/xiaoyue2532/musl.git "$MUSL_SHA" "$MUSL_SRC"

echo "==> Create target-prefixed drivers"
link_tool clang as
link_tool clang cc
link_tool clang++ c++
link_tool clang clang
link_tool clang++ clang++
link_tool clang-cpp cpp
link_tool lld ld
link_tool ld.lld ld.lld
link_tool llvm-symbolizer addr2line
link_tool llvm-ar ar
link_tool llvm-nm nm
link_tool llvm-objcopy objcopy
link_tool llvm-objdump objdump
link_tool llvm-ranlib ranlib
link_tool llvm-readobj readelf
link_tool llvm-size size
link_tool llvm-strings strings
link_tool llvm-strip strip

cat > "$BIN_DIR/$TARGET_TRIPLE.cfg" <<EOF
--target=$TARGET_TRIPLE
$TARGET_FLAGS
--sysroot=<CFGDIR>/../$TARGET_TRIPLE
EOF

CC="$BIN_DIR/$TARGET_TRIPLE-clang"
CXX="$BIN_DIR/$TARGET_TRIPLE-clang++"

echo "==> Install Linux 6.18 headers"
make -C "$LINUX_SRC" \
  ARCH="$KERNEL_ARCH" \
  INSTALL_HDR_PATH="$SYSROOT" \
  headers_install

echo "==> Install musl headers"
mkdir -p "$WORK_DIR/build-musl-headers"
(
  cd "$WORK_DIR/build-musl-headers"
  CC="$CC" "$MUSL_SRC/configure" \
    --prefix=/ \
    --build=x86_64-pc-linux-gnu \
    --host="$TARGET_TRIPLE" \
    --disable-wrapper
  make DESTDIR="$SYSROOT" install-headers
)

echo "==> Build bootstrap compiler-rt"
cmake -G Ninja \
  -S "$LLVM_SRC/compiler-rt" \
  -B "$WORK_DIR/build-compiler-rt" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$RESOURCE_DIR" \
  -DCMAKE_ASM_COMPILER="$CC" \
  -DCMAKE_ASM_COMPILER_TARGET="$TARGET_TRIPLE" \
  -DCMAKE_C_COMPILER="$CC" \
  -DCMAKE_C_COMPILER_TARGET="$TARGET_TRIPLE" \
  -DCMAKE_C_COMPILER_WORKS=ON \
  -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_CXX_COMPILER_TARGET="$TARGET_TRIPLE" \
  -DCMAKE_CXX_COMPILER_WORKS=ON \
  -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
  -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON \
  -DCOMPILER_RT_BUILD_CRT=ON \
  -DCOMPILER_RT_BUILD_CTX_PROFILE=OFF \
  -DCOMPILER_RT_BUILD_LIBFUZZER=OFF \
  -DCOMPILER_RT_BUILD_MEMPROF=OFF \
  -DCOMPILER_RT_BUILD_ORC=OFF \
  -DCOMPILER_RT_BUILD_PROFILE=OFF \
  -DCOMPILER_RT_BUILD_SANITIZERS=OFF \
  -DCOMPILER_RT_BUILD_XRAY=OFF
cmake --build "$WORK_DIR/build-compiler-rt" --parallel "$JOBS"
cmake --build "$WORK_DIR/build-compiler-rt" --target install/strip

BUILTINS="$(find "$RESOURCE_DIR" -type f \
  -name "libclang_rt.builtins-${COMPILER_RT_ARCH}.a" -print -quit)"
[[ -n "$BUILTINS" ]] || {
  echo "compiler-rt did not install builtins for $COMPILER_RT_ARCH" >&2
  find "$RESOURCE_DIR" -maxdepth 4 -type f -print >&2
  exit 1
}

echo "==> Build musl"
mkdir -p "$WORK_DIR/build-musl"
(
  cd "$WORK_DIR/build-musl"
  CC="$CC" LIBCC="$BUILTINS" "$MUSL_SRC/configure" \
    --prefix=/ \
    --build=x86_64-pc-linux-gnu \
    --host="$TARGET_TRIPLE" \
    --disable-wrapper
  make -j "$JOBS"
  make DESTDIR="$SYSROOT" install
)

echo "==> Build LLVM runtimes"
cmake -G Ninja \
  -S "$LLVM_SRC/runtimes" \
  -B "$WORK_DIR/build-runtimes" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$SYSROOT" \
  -DCMAKE_ASM_COMPILER="$CC" \
  -DCMAKE_ASM_COMPILER_TARGET="$TARGET_TRIPLE" \
  -DCMAKE_C_COMPILER="$CC" \
  -DCMAKE_C_COMPILER_TARGET="$TARGET_TRIPLE" \
  -DCMAKE_C_COMPILER_WORKS=ON \
  -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_CXX_COMPILER_TARGET="$TARGET_TRIPLE" \
  -DCMAKE_CXX_COMPILER_WORKS=ON \
  -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
  -DCOMPILER_RT_BUILD_CRT=ON \
  -DCOMPILER_RT_BUILD_CTX_PROFILE=OFF \
  -DCOMPILER_RT_BUILD_LIBFUZZER=OFF \
  -DCOMPILER_RT_BUILD_MEMPROF=OFF \
  -DCOMPILER_RT_BUILD_ORC=OFF \
  -DCOMPILER_RT_BUILD_PROFILE=OFF \
  -DCOMPILER_RT_BUILD_SANITIZERS=OFF \
  -DCOMPILER_RT_BUILD_XRAY=OFF \
  -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON \
  -DCOMPILER_RT_INSTALL_PATH="$RESOURCE_DIR" \
  -DCXX_SUPPORTS_FNO_EXCEPTIONS_FLAG=ON \
  -DLIBCXXABI_ENABLE_STATIC_UNWINDER=ON \
  -DLIBCXXABI_USE_COMPILER_RT=ON \
  -DLIBCXXABI_USE_LLVM_UNWINDER=ON \
  -DLIBCXX_CXX_ABI=libcxxabi \
  -DLIBCXX_ENABLE_STATIC_ABI_LIBRARY=ON \
  -DLIBCXX_HAS_MUSL_LIBC=ON \
  -DLIBCXX_USE_COMPILER_RT=ON \
  -DLIBUNWIND_USE_COMPILER_RT=ON \
  -DLLVM_ENABLE_RUNTIMES='libcxx;libcxxabi;libunwind;compiler-rt'
cmake --build "$WORK_DIR/build-runtimes" --parallel "$JOBS"
cmake --build "$WORK_DIR/build-runtimes" --target install/strip

cat >> "$BIN_DIR/$TARGET_TRIPLE.cfg" <<EOF
-nostdinc++
-isystem <CFGDIR>/../$TARGET_TRIPLE/include/c++/v1
-isystem <CFGDIR>/../$TARGET_TRIPLE/include
EOF

echo "==> Smoke test"
cat > "$WORK_DIR/hello.c" <<'EOF'
#include <stdio.h>
int main(void) {
  puts("hello from musl");
  return 0;
}
EOF
"$CC" -static "$WORK_DIR/hello.c" -o "$WORK_DIR/hello"
file "$WORK_DIR/hello"
if [[ "$QEMU" == native ]]; then
  "$WORK_DIR/hello"
else
  "$QEMU" "$WORK_DIR/hello"
fi

cat > "$WORK_DIR/hello.cpp" <<'EOF'
#include <iostream>
int main() {
  std::cout << "hello from libc++\n";
  return 0;
}
EOF
"$CXX" -static "$WORK_DIR/hello.cpp" -o "$WORK_DIR/hello-cxx"
file "$WORK_DIR/hello-cxx"
if [[ "$QEMU" == native ]]; then
  "$WORK_DIR/hello-cxx"
else
  "$QEMU" "$WORK_DIR/hello-cxx"
fi

cat > "$TOOLCHAIN_ROOT/BUILD-MANIFEST.txt" <<EOF
LLVM_VERSION=$LLVM_VERSION
LLVM_COMMIT=$LLVM_SHA
LINUX_REF=linux-6.18.y
LINUX_COMMIT=$LINUX_SHA
MUSL_VERSION=$(<"$MUSL_SRC/VERSION")
MUSL_REF=xiaoyue2532
MUSL_COMMIT=$MUSL_SHA
TARGET_TRIPLE=$TARGET_TRIPLE
TARGET_FLAGS=$TARGET_FLAGS
EOF

echo "==> Package $TARGET_TRIPLE"
archive="$OUT_DIR/$TARGET_TRIPLE/llvmtools-${LLVM_VERSION}-${TARGET_TRIPLE}.tar.zst"
tar --zstd -cf "$archive" \
  --sort=name \
  --owner=0 --group=0 --numeric-owner \
  --mtime="@${SOURCE_DATE_EPOCH:-1704067200}" \
  -C "$(dirname "$TOOLCHAIN_ROOT")" "$(basename "$TOOLCHAIN_ROOT")"
(
  cd "$OUT_DIR/$TARGET_TRIPLE"
  sha256sum ./*.tar.zst > SHA256SUMS
)
ls -lh "$archive"
