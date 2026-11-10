# llvmtools CI

在 GitHub Actions 上自动构建博客《构建 LLVM 交叉工具链》里的宿主端工具集（`clang` + `lld`），
产物为 `llvmtools-<version>-x86_64-pc-linux-gnu.tar.zst`。

## Release 使用 `-O2`

发行版 CMake 的 `Modules/Compiler/GNU.cmake` 里是：

```cmake
string(APPEND CMAKE_${lang}_FLAGS_RELEASE_INIT " -O3")
string(APPEND CMAKE_${lang}_FLAGS_RELEASE_INIT " -DNDEBUG")
```

`_INIT` 是同名非 INIT 缓存变量的初始化值。在全新的构建目录里传入
`-DCMAKE_*_FLAGS_RELEASE_INIT=-O2` 后，编译器模块仍会继续追加默认值，最终
得到类似 `-O2 -O3 -DNDEBUG`，实际生效的还是最后一个 `-O3`；在已经配置过的
构建目录里，修改 `_INIT` 又不会重置现有缓存。

脚本直接指定最终使用的**非 INIT** 缓存变量，并保留 Release 默认需要的
`-DNDEBUG`：

```
-DCMAKE_C_FLAGS_RELEASE="-O2 -DNDEBUG"
-DCMAKE_CXX_FLAGS_RELEASE="-O2 -DNDEBUG"
```

这样 CI 不需要修改 `/usr/share/cmake/...`。

## 本地复现

```bash
sudo pacman -S clang llvm lld ninja cmake zstd   # Arch
export LLVM_BINDIR=/usr/lib/llvm20/bin           # 可选，默认自动探测 `command -v clang`
export INSTALL_PREFIX=/llvmtools                 # 需要写 / 时用 sudo 或改这里
bash scripts/build.sh
bash scripts/package.sh
```

## 可调环境变量

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `LLVM_VERSION` | `20.1.8` | 对应 `llvmorg-<tag>` |
| `OPT_FLAG` | `-O2` | Release 优化等级，脚本自动补 `-DNDEBUG` |
| `LINK_JOBS` | `1` | 链接并发，runner 内存有限 |

## 后续

宿主 LLVM 和交叉工具链是两个独立的手动 workflow。先运行
`build-llvmtools` 一次；之后运行 `build-cross-toolchains`，输入宿主构建的
run ID 和 LLVM 版本，即可反复复用该 artifact，不会重新编译 LLVM。

首批交叉目标为：

- `arm-unknown-linux-musleabihf`
- `aarch64-unknown-linux-musl`
- `x86_64-unknown-linux-musl`

每个矩阵任务依次构建 Linux 6.18 headers、维护在
`xiaoyue2532/musl` 的 musl 1.2.6、bootstrap compiler-rt 和 LLVM runtimes。
首轮 runtimes 安装后，sysroot 会建立 `usr -> .` 链接，再进行一次不跳过编译器
检查、并启用 ORC/XRay 的完整 runtimes 重建。产物中的 Clang 配置使用
`<CFGDIR>` 相对定位 sysroot，不写入 libc++ 的绝对搜索路径，因此工具链不要求
安装到 `/llvmtools`。
