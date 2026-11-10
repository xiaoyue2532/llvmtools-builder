#!/usr/bin/env bash
#
# 构建宿主端 LLVM 工具集（clang + lld），供后续交叉工具链使用。
#
# CMake 先用 CMAKE_*_FLAGS_RELEASE_INIT 初始化同名的非 INIT 缓存变量。
# 直接传 RELEASE_INIT 会被编译器模块继续追加 -O3 -DNDEBUG，不能把
# 最终优化等级固定为 -O2；这里直接指定最终缓存值并保留 -DNDEBUG。
#
set -euo pipefail

LLVM_VERSION="${LLVM_VERSION:-20.1.8}"
INSTALL_PREFIX="${INSTALL_PREFIX:-/llvmtools}"
SRC_DIR="${SRC_DIR:-$PWD/llvm-project}"
BUILD_DIR="${BUILD_DIR:-$PWD/build-llvm}"
OPT_FLAG="${OPT_FLAG:--O2}"

# [Github Hosted Runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
# says memory is 16 GB, which seems to be enough.
# LINK_JOBS="${LINK_JOBS:-1}"

JOBS="${JOBS:-$(command -v nproc >/dev/null && nproc || getconf _NPROCESSORS_ONLN)}"

if [[ -z "${LLVM_BINDIR:-}" ]]; then
  LLVM_BINDIR="$(dirname "$(readlink -f "$(command -v clang)")")"
fi

echo "==> LLVM version      : $LLVM_VERSION"
echo "==> host LLVM bindir  : $LLVM_BINDIR"
echo "==> install prefix    : $INSTALL_PREFIX"
echo "==> source dir        : $SRC_DIR"
echo "==> build dir         : $BUILD_DIR"
echo "==> RELEASE opt flag  : $OPT_FLAG -DNDEBUG"

# ---------------------------------------------------------------- 源码
if [[ ! -d "$SRC_DIR/llvm" ]]; then
  git clone --depth 1 --branch "llvmorg-${LLVM_VERSION}" \
    https://github.com/llvm/llvm-project.git "$SRC_DIR"
fi

# ---------------------------------------------------------------- 配置
extra_args=(
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX"
  -DCMAKE_C_COMPILER="$LLVM_BINDIR/clang"
  -DCMAKE_CXX_COMPILER="$LLVM_BINDIR/clang++"
  -DCMAKE_AR="$LLVM_BINDIR/llvm-ar"
  -DCMAKE_NM="$LLVM_BINDIR/llvm-nm"
  -DCMAKE_RANLIB="$LLVM_BINDIR/llvm-ranlib"
  -DCMAKE_C_FLAGS_RELEASE="$OPT_FLAG -DNDEBUG"
  -DCMAKE_CXX_FLAGS_RELEASE="$OPT_FLAG -DNDEBUG"
  -DCLANG_DEFAULT_CXX_STDLIB=libc++
  -DCLANG_DEFAULT_LINKER=lld
  -DCLANG_DEFAULT_OBJCOPY=llvm-objcopy
  -DCLANG_DEFAULT_RTLIB=compiler-rt
  -DCLANG_DEFAULT_UNWINDLIB=libunwind
  -DENABLE_LINKER_BUILD_ID=ON
  # No append git repo and commit hash
  -DLLVM_APPEND_VC_REV=OFF
  -DLLVM_BUILD_LLVM_DYLIB=ON
  -DLLVM_DEFAULT_TARGET_TRIPLE="x86_64-pc-linux-gnu"
  -DLLVM_ENABLE_PROJECTS="clang;lld"
  -DLLVM_ENABLE_RTTI=ON
  -DLLVM_HOST_TRIPLE="x86_64-pc-linux-gnu"
  # Reduce compile workload
  -DLLVM_INCLUDE_BENCHMARKS=OFF
  -DLLVM_INCLUDE_EXAMPLES=OFF
  -DLLVM_INCLUDE_TESTS=OFF
  -DLLVM_INSTALL_TOOLCHAIN_ONLY=ON
  -DLLVM_LINK_LLVM_DYLIB=ON
  -DLLVM_USE_LINKER=mold
  # -DLLVM_ENABLE_LLD=ON
  -DLLVM_ENABLE_LIBEDIT=OFF
  -DLLVM_ENABLE_LIBXML2=OFF
  # -DLLVM_PARALLEL_LINK_JOBS="$LINK_JOBS"
)

cmake \
  -S "$SRC_DIR/llvm" -B "$BUILD_DIR" \
  -G Ninja "${extra_args[@]}"

# ---------------------------------------------------------------- 编译
ninja -C "$BUILD_DIR" -j "$JOBS"
ninja -C "$BUILD_DIR" install/strip
