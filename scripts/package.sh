#!/usr/bin/env bash
#
# 把安装好的 llvmtools 打成可复现的 tar.zst，并生成 SHA256SUMS。
#
set -euo pipefail

INSTALL_PREFIX="${INSTALL_PREFIX:-/llvmtools}"
LLVM_VERSION="${LLVM_VERSION:-20.1.8}"
OUT_DIR="${OUT_DIR:-$PWD/dist}"
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1704067200}"

mkdir -p "$OUT_DIR"

name="llvmtools-${LLVM_VERSION}-x86_64-pc-linux-gnu"
prefix_parent="$(dirname "$INSTALL_PREFIX")"
prefix_base="$(basename "$INSTALL_PREFIX")"

# 直接原地打包，避免再复制一份几个 GB 的目录
tarball="$OUT_DIR/${name}.tar.zst"
tar --zstd -cf "$tarball" \
  --sort=name \
  --owner=0 --group=0 --numeric-owner \
  --mtime="@${SOURCE_DATE_EPOCH}" \
  -C "$prefix_parent" "$prefix_base"

rm -f "$OUT_DIR/SHA256SUMS"
( cd "$OUT_DIR" && sha256sum ./*.tar.zst >SHA256SUMS )

ls -lh "$tarball"
cat "$OUT_DIR/SHA256SUMS"