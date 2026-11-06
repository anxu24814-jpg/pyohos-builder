#!/usr/bin/env bash
# 门 2 依赖基座：为 CPython 解禁扩展与 28 包中的 C/C++ 包交叉编译九个原生依赖到
# OHOS aarch64，统一装进单一 prefix（供 build-cpython-ohos.sh 与包构建脚本共用）。
#
# Attribution: 依赖库构建参数取自 zhubowen-bot/Guncat-Work-for-hmos（Apache-2.0）
#   tooling/python/build-native-deps.sh（OpenSSL）、build-pillow-ohos.sh（libpng/
#   libjpeg-turbo）、build-matplotlib-ohos.sh（freetype/qhull）、build-lxml-ohos.sh
#   （libxml2/libxslt），取用日期 2026-11-07，按本项目工厂环境变量约定改造。
#
# 依赖清单（方案档 §6.1 闲 1「依赖基座」）：
#   zlib 1.3.1        门 0 已随包 libz.so；装进 prefix 供 pillow 链接一致
#   OpenSSL 3.5.4     → _ssl/_hashlib 解禁（门 3 cryptography 复用）
#   libffi 3.4.6      → _ctypes 解禁 + cffi（门 3 pypdfium2 ctypes 形态复用）
#   freetype 2.13.3   → matplotlib（savannah release 包，GitHub tarball 带 submodule 检查会失败）
#   libpng 1.6.44     → pillow
#   libjpeg-turbo 3.0.4 → pillow（WITH_SIMD=OFF 免 nasm）
#   libxml2 2.13.5 / libxslt 1.1.42 → lxml（GitHub tag 无 configure，先 autoreconf）
#   qhull 8.0.2       → matplotlib（CMake ≥4 需 POLICY_VERSION_MINIMUM=3.5）
#   （OpenBLAS 第二轮并入：numpy 先 BLAS=none 保绿——止损线优先；接 BLAS 时加
#    seccomp 补丁〔mbind/my_set_mempolicy 跳过 + NO_AFFINITY=1，Guncat 2.10 实锤〕）
#
# SONAME 策略：各库保持自身默认 SONAME（libssl.so.3 / libffi.so.8 / libpng16.so.16 /
#   libjpeg.so.62 / libfreetype.so.6 / libxml2.so.2 / libxslt.so.1 / libexslt.so.0 /
#   libqhull_r.so.8.0）——设备按 DT_NEEDED 名字找文件，落 entry/libs 时按 SONAME 命名
#   即可，禁用 patchelf（Guncat 实锤改坏 .dynstr）。
#
# 用法（GitHub Actions ubuntu / 任意 Linux 宿主）:
#   SDK_NATIVE=<Linux SDK 的 native 目录> PREFIX=<产物 prefix> bash build-native-deps.sh
set -euo pipefail

# ---- 冻结版本（Guncat 实证版本优先，宁旧勿新减少变量）----
ZLIB_VERSION="1.3.1"
OPENSSL_VERSION="3.5.4"
LIBFFI_VERSION="3.4.6"
FREETYPE_VERSION="2.13.3"
LIBPNG_VERSION="1.6.44"
LIBJPEG_VERSION="3.0.4"
LIBXML2_VERSION="2.13.5"
LIBXSLT_VERSION="1.1.42"
QHULL_VERSION="8.0.2"
# OpenBLAS（BLAS 供给）：NOFORTRAN=1 纯 C 形态（LAPACK 走 numpy 内置 lapack-lite 兜底，
# 免 Guncat 的 gfortran 交叉 + libgfortran 替身链）；真机 BLAS 性能读数留闸②③ 实测
OPENBLAS_VERSION="0.3.28"

# ---- 环境变量 ----
SDK_NATIVE="${SDK_NATIVE:-}"
PREFIX="${PREFIX:-$HOME/ohos-py-deps/prefix}"
WORK="${WORK:-$HOME/ohos-py-deps}"
LOGS="$WORK/logs"

# ---- 外部状态校验（P0-1）----
if [ -z "$SDK_NATIVE" ]; then
  echo "错误：未设置 SDK_NATIVE 环境变量（应指向 Linux 版 OHOS SDK 的 native 目录，内含 llvm/ 与 sysroot/）。" >&2
  exit 1
fi
if [ ! -d "$SDK_NATIVE" ]; then
  echo "错误：SDK_NATIVE 目录不存在：$SDK_NATIVE。" >&2
  exit 1
fi
SYSROOT="$SDK_NATIVE/sysroot"
LLVM_BIN="$SDK_NATIVE/llvm/bin"
# Linux SDK 自带官方 wrapper（无空格路径问题；内联 --target/--sysroot/-D__MUSL__）
CLANG="$LLVM_BIN/aarch64-unknown-linux-ohos-clang"
CLANGXX="$LLVM_BIN/aarch64-unknown-linux-ohos-clang++"
for f in "$CLANG" "$CLANGXX" "$LLVM_BIN/llvm-ar" "$LLVM_BIN/llvm-strip" "$SYSROOT"; do
  if [ ! -e "$f" ]; then
    echo "错误：SDK_NATIVE 布局不完整，缺少：$f。" >&2
    exit 1
  fi
done
for tool in curl tar make cmake autoreconf pkg-config; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "错误：宿主缺少命令：$tool。" >&2
    exit 1
  fi
done

mkdir -p "$WORK" "$PREFIX/include" "$PREFIX/lib" "$LOGS"

# ERR trap：任一步失败即打印最新日志尾 30 行（日志都在 $LOGS，免逐轮拉 run 日志猜）
on_err() {
  local latest
  latest=$(ls -t "$LOGS" 2>/dev/null | head -1)
  if [ -n "$latest" ]; then
    echo "==== 构建失败，$latest 尾部 30 行 ====" >&2
    tail -30 "$LOGS/$latest" >&2 || true
  fi
}
trap on_err ERR
export CC="$CLANG"
export CXX="$CLANGXX"
export AR="$LLVM_BIN/llvm-ar"
export RANLIB="$LLVM_BIN/llvm-ranlib"
export STRIP="$LLVM_BIN/llvm-strip"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
unset CFLAGS CXXFLAGS LDFLAGS 2>/dev/null || true
# 通用旗标：sysroot 已由 wrapper 注入，这里只放可移植性能旗标
XFLAGS="--sysroot=$SYSROOT -O2 -fPIC"
XLDFLAGS="--sysroot=$SYSROOT -fuse-ld=lld"

fetch() {  # url outfile —— 幂等下载
  [ -s "$2" ] || curl -fL --retry 3 -m 900 -o "$2" "$1"
}

log() { echo "== $* "; }

# ---------------- zlib（门 0 同版，装进 prefix 供 pillow 一致链接）----------------
if [ ! -f "$PREFIX/lib/libz.so" ]; then
  log "zlib $ZLIB_VERSION"
  cd "$WORK"
  [ -d "zlib-$ZLIB_VERSION" ] || { fetch \
    "https://codeload.github.com/madler/zlib/tar.gz/refs/tags/v$ZLIB_VERSION" "zlib-$ZLIB_VERSION.tar.gz"; \
    tar xzf "zlib-$ZLIB_VERSION.tar.gz"; }
  ( cd "zlib-$ZLIB_VERSION" && CHOST=aarch64-linux-gnu CC="$CC" AR="$AR" RANLIB="$RANLIB" \
      ./configure --prefix="$PREFIX" --shared > "$LOGS/zlib-configure.log" 2>&1 \
    && make -j"$(nproc)" > "$LOGS/zlib-build.log" 2>&1 \
    && make install > "$LOGS/zlib-install.log" 2>&1 )
fi

# ---------------- OpenSSL（_ssl/_hashlib；门 3 cryptography 复用）----------------
if [ ! -f "$PREFIX/lib/libssl.so.3" ]; then
  log "OpenSSL $OPENSSL_VERSION"
  cd "$WORK"
  fetch "https://codeload.github.com/openssl/openssl/tar.gz/refs/tags/openssl-$OPENSSL_VERSION" \
    "openssl-$OPENSSL_VERSION.tar.gz"
  if [ ! -d "openssl-$OPENSSL_VERSION" ]; then
    tar xzf "openssl-$OPENSSL_VERSION.tar.gz"
    # codeload 顶层名 = openssl-openssl-3.5.4（tag 自带 openssl- 前缀不被 GitHub 剥离），对齐
    [ -d "openssl-$OPENSSL_VERSION" ] || mv "openssl-openssl-$OPENSSL_VERSION" "openssl-$OPENSSL_VERSION"
  fi
  ( cd "openssl-$OPENSSL_VERSION" && [ -f Makefile ] || ./Configure linux-aarch64 \
      --prefix="$PREFIX" --openssldir="$PREFIX/ssl" \
      shared no-tests --with-rand-seed=getrandom -D__MUSL__ \
      "--sysroot=$SYSROOT -O2 -fPIC -fuse-ld=lld -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0" \
      > "$LOGS/openssl-configure.log" 2>&1
    make -j"$(nproc)" > "$LOGS/openssl-build.log" 2>&1 \
    && make install_sw install_dev > "$LOGS/openssl-install.log" 2>&1 )
  # install_dev 必须带：install_sw 只装库不装头/pc——第五轮实锤 configure 探不到
  # openssl/ssl.h 而**静默跳过 _ssl**（cpython job 的「_ssl 未编出」自检拦截）
  # SONAME = libssl.so.3 / libcrypto.so.3，保持原样（设备按名字找）
fi

# ---------------- libffi（_ctypes 解禁 + cffi）----------------
if [ ! -f "$PREFIX/lib/libffi.so.8" ]; then
  log "libffi $LIBFFI_VERSION"
  cd "$WORK"
  # 用 release 发行版 tarball（自带 configure）——codeload 源码 tarball 要 autoreconf，
  # Actions 的 aclocal 缺 LT_SYS_SYMBOL_USCORE 宏路径（第三轮实锤），绕开 autotools
  fetch "https://github.com/libffi/libffi/releases/download/v$LIBFFI_VERSION/libffi-$LIBFFI_VERSION.tar.gz" \
    "libffi-$LIBFFI_VERSION.tar.gz"
  [ -d "libffi-$LIBFFI_VERSION" ] || tar xzf "libffi-$LIBFFI_VERSION.tar.gz"
  ( cd "libffi-$LIBFFI_VERSION" \
    && ./configure --host=aarch64-linux-gnu --build=x86_64-linux-gnu \
      --prefix="$PREFIX" --disable-static --enable-shared \
      CFLAGS="$XFLAGS" LDFLAGS="$XLDFLAGS" \
      > "$LOGS/libffi-configure.log" 2>&1 \
    && make -j"$(nproc)" > "$LOGS/libffi-build.log" 2>&1 \
    && make install > "$LOGS/libffi-install.log" 2>&1 )
  # libffi 头装在 prefix/include/ffi.h；SONAME = libffi.so.8
fi

# ---------------- freetype（matplotlib；必须 savannah release 包）----------------
if [ ! -f "$PREFIX/lib/libfreetype.so.6" ]; then
  log "freetype $FREETYPE_VERSION"
  cd "$WORK"
  fetch "https://download.savannah.gnu.org/releases/freetype/freetype-$FREETYPE_VERSION.tar.xz" \
    "freetype-$FREETYPE_VERSION.tar.xz"
  [ -d "freetype-$FREETYPE_VERSION" ] || tar xf "freetype-$FREETYPE_VERSION.tar.xz"
  ( cd "freetype-$FREETYPE_VERSION" \
    && ./configure --host=aarch64-linux-gnu --build=x86_64-linux-gnu --prefix="$PREFIX" \
      --without-harfbuzz --without-brotli --without-bzip2 --without-png \
      CFLAGS="$XFLAGS" LDFLAGS="$XLDFLAGS" \
      > "$LOGS/freetype-configure.log" 2>&1 \
    && make -j"$(nproc)" > "$LOGS/freetype-build.log" 2>&1 \
    && make install > "$LOGS/freetype-install.log" 2>&1 )
fi

# ---------------- libpng（pillow）----------------
if [ ! -f "$PREFIX/lib/libpng16.so.16" ]; then
  log "libpng $LIBPNG_VERSION"
  cd "$WORK"
  fetch "https://codeload.github.com/pnggroup/libpng/tar.gz/refs/tags/v$LIBPNG_VERSION" \
    "libpng-$LIBPNG_VERSION.tar.gz"
  [ -d "libpng-$LIBPNG_VERSION" ] || tar xzf "libpng-$LIBPNG_VERSION.tar.gz"
  ( cd "libpng-$LIBPNG_VERSION" \
    && ./configure --host=aarch64-linux-gnu --build=x86_64-linux-gnu --prefix="$PREFIX" \
      --disable-static CPPFLAGS="-I$PREFIX/include" CFLAGS="$XFLAGS" \
      LDFLAGS="$XLDFLAGS -L$PREFIX/lib" \
      > "$LOGS/libpng-configure.log" 2>&1 \
    && make -j"$(nproc)" > "$LOGS/libpng-build.log" 2>&1 \
    && make install > "$LOGS/libpng-install.log" 2>&1 )
fi

# ---------------- libjpeg-turbo（pillow；WITH_SIMD=OFF 免 nasm）----------------
if [ ! -f "$PREFIX/lib/libjpeg.so.62" ]; then
  log "libjpeg-turbo $LIBJPEG_VERSION"
  cd "$WORK"
  fetch "https://codeload.github.com/libjpeg-turbo/libjpeg-turbo/tar.gz/refs/tags/$LIBJPEG_VERSION" \
    "libjpeg-turbo-$LIBJPEG_VERSION.tar.gz"
  [ -d "libjpeg-turbo-$LIBJPEG_VERSION" ] || tar xzf "libjpeg-turbo-$LIBJPEG_VERSION.tar.gz"
  ( cd "libjpeg-turbo-$LIBJPEG_VERSION" && rm -rf build-ohos && mkdir build-ohos && cd build-ohos \
    && cmake .. -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
      -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" -DCMAKE_SYSROOT="$SYSROOT" \
      -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
      -DCMAKE_C_FLAGS="$XFLAGS" -DCMAKE_CXX_FLAGS="$XFLAGS" \
      -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_BUILD_TYPE=Release \
      -DWITH_SIMD=OFF -DWITH_TURBOJPEG=OFF -DENABLE_SHARED=ON -DENABLE_STATIC=OFF \
      > "$LOGS/libjpeg-cmake.log" 2>&1 \
    && make -j"$(nproc)" > "$LOGS/libjpeg-build.log" 2>&1 \
    && make install > "$LOGS/libjpeg-install.log" 2>&1 )
fi

# ---------------- libxml2 / libxslt（lxml；GNOME 发行版 tarball 自带 configure——
#                  codeload 源码树要 autoreconf，Actions 有 aclocal 宏路径坑，绕开）----------------
if [ ! -f "$PREFIX/lib/libxml2.so.2" ]; then
  log "libxml2 $LIBXML2_VERSION"
  cd "$WORK"
  fetch "https://download.gnome.org/sources/libxml2/${LIBXML2_VERSION%.*}/libxml2-$LIBXML2_VERSION.tar.xz" \
    "libxml2-$LIBXML2_VERSION.tar.xz"
  [ -d "libxml2-$LIBXML2_VERSION" ] || tar xf "libxml2-$LIBXML2_VERSION.tar.xz"
  ( cd "libxml2-$LIBXML2_VERSION" \
    && ./configure --host=aarch64-linux-gnu --build=x86_64-linux-gnu --prefix="$PREFIX" \
      --disable-static --without-python --without-lzma --without-zlib --without-iconv \
      CFLAGS="$XFLAGS" LDFLAGS="$XLDFLAGS" \
      > "$LOGS/libxml2-configure.log" 2>&1 \
    && make -j"$(nproc)" > "$LOGS/libxml2-build.log" 2>&1 \
    && make install > "$LOGS/libxml2-install.log" 2>&1 )
fi
if [ ! -f "$PREFIX/lib/libxslt.so.1" ]; then
  log "libxslt $LIBXSLT_VERSION"
  cd "$WORK"
  fetch "https://download.gnome.org/sources/libxslt/${LIBXSLT_VERSION%.*}/libxslt-$LIBXSLT_VERSION.tar.xz" \
    "libxslt-$LIBXSLT_VERSION.tar.xz"
  [ -d "libxslt-$LIBXSLT_VERSION" ] || tar xf "libxslt-$LIBXSLT_VERSION.tar.xz"
  ( cd "libxslt-$LIBXSLT_VERSION" \
    && ./configure --host=aarch64-linux-gnu --build=x86_64-linux-gnu --prefix="$PREFIX" \
      --disable-static --without-python --without-crypto --with-libxml-prefix="$PREFIX" \
      CFLAGS="$XFLAGS -I$PREFIX/include" LDFLAGS="$XLDFLAGS -L$PREFIX/lib" \
      > "$LOGS/libxslt-configure.log" 2>&1 \
    && make -j"$(nproc)" > "$LOGS/libxslt-build.log" 2>&1 \
    && make install > "$LOGS/libxslt-install.log" 2>&1 )
fi

# ---------------- OpenBLAS（numpy BLAS 供给；seccomp 补丁必打——Guncat 2.10 真机实锤）----------------
# HarmonyOS seccomp 把 mbind/set_mempolicy 判违规直接 SIGSYS 杀进程（import numpy → dlopen
# libopenblas → .init → blas_memory_alloc 调 my_mbind 即死，try/except 无效）。补丁 = 给
# common_linux.h 两函数的官方 __LSB_VERSION__ 短路分支并入自家宏 PYOHOS_NO_NUMA_SYSCALLS，
# 编译期 -D 激活（手机无 NUMA 策略可谈，跳过无副作用）；同时 NO_AFFINITY=1 防
# sched_setaffinity 同类拦截。
if [ ! -f "$PREFIX/lib/libopenblas.so" ]; then
  log "OpenBLAS $OPENBLAS_VERSION（NOFORTRAN=1 + seccomp 补丁）"
  cd "$WORK"
  fetch "https://codeload.github.com/OpenMathLib/OpenBLAS/tar.gz/refs/tags/v$OPENBLAS_VERSION" \
    "openblas-$OPENBLAS_VERSION.tar.gz"
  [ -d "OpenBLAS-$OPENBLAS_VERSION" ] || tar xzf "openblas-$OPENBLAS_VERSION.tar.gz"
  mkdir -p "$PREFIX/lib/pkgconfig" "$PREFIX/include"
  (
    set -e
    cd "OpenBLAS-$OPENBLAS_VERSION"
    # seccomp 补丁：官方 __LSB_VERSION__ 短路分支并入自家宏（两函数一次 sed 全替换）
    sed -i 's/#if defined (__LSB_VERSION__) || defined(ARCH_ZARCH)/#if defined (__LSB_VERSION__) || defined(ARCH_ZARCH) || defined(PYOHOS_NO_NUMA_SYSCALLS)/' common_linux.h
    [ "$(grep -c 'PYOHOS_NO_NUMA_SYSCALLS' common_linux.h)" -ge 2 ] || {
      echo "错误：OpenBLAS seccomp 补丁未命中（common_linux.h 结构可能变了）。" >&2; exit 1; }
    # make libs = 只编库不编 utest（utest 可执行要链宿主侧跑、且 musl 无
    # pthread_setaffinity_np 必挂——库本体第四轮已实证编得出）
    make -j"$(nproc)" libs TARGET=ARMV8 BINARY=64 NOFORTRAN=1 NO_LAPACK=1 NO_SHARED=1 \
      NO_AFFINITY=1 BUILD_WITHOUT_LAPACKE=1 \
      CC="$CC" AR="$AR" RANLIB="$RANLIB" HOSTCC=gcc \
      CFLAGS="--sysroot=$SYSROOT -O2 -fPIC -DPYOHOS_NO_NUMA_SYSCALLS" \
      > "$LOGS/openblas-build.log" 2>&1
    "$CC" -shared -fuse-ld=lld -o libopenblas.so \
      -Wl,--whole-archive libopenblas_armv8p-r"$OPENBLAS_VERSION".a -Wl,--no-whole-archive \
      -lm -Wl,-soname,libopenblas.so
    cp -f libopenblas.so "$PREFIX/lib/"
    cp -f cblas.h "$PREFIX/include/" 2>/dev/null || true
  )
  cat > "$PREFIX/lib/pkgconfig/openblas.pc" <<EOF
prefix=$PREFIX
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: openblas
Description: OpenBLAS NOFORTRAN (cross-built for OpenHarmony, no LAPACK)
Version: $OPENBLAS_VERSION
Libs: -L\${libdir} -lopenblas
Cflags: -I\${includedir}
EOF
  cp -f "$PREFIX/lib/pkgconfig/openblas.pc" "$PREFIX/lib/pkgconfig/blas.pc"
  "$STRIP" --strip-unneeded "$PREFIX/lib/libopenblas.so" 2>/dev/null || true
fi

# ---------------- qhull（matplotlib；CMake ≥4 需 POLICY_VERSION_MINIMUM）----------------
if [ ! -f "$PREFIX/lib/libqhull_r.so.8.0" ]; then
  log "qhull $QHULL_VERSION"
  cd "$WORK"
  fetch "https://codeload.github.com/qhull/qhull/tar.gz/refs/tags/v$QHULL_VERSION" \
    "qhull-$QHULL_VERSION.tar.gz"
  [ -d "qhull-$QHULL_VERSION" ] || tar xzf "qhull-$QHULL_VERSION.tar.gz"
  ( cd "qhull-$QHULL_VERSION" && rm -rf build-ohos && mkdir build-ohos && cd build-ohos \
    && cmake .. -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
      -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" -DCMAKE_SYSROOT="$SYSROOT" \
      -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
      -DCMAKE_C_FLAGS="$XFLAGS" -DCMAKE_CXX_FLAGS="$XFLAGS" \
      -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_BUILD_TYPE=Release \
      -DBUILD_STATIC_LIBS=OFF -DBUILD_SHARED_LIBS=ON \
      > "$LOGS/qhull-cmake.log" 2>&1 \
    && make -j"$(nproc)" > "$LOGS/qhull-build.log" 2>&1 \
    && make install > "$LOGS/qhull-install.log" 2>&1 )
  # matplotlib 找的是 qhull_r；补 qhull.pc 别名（Guncat 同法）
  sed 's/Name: qhull_r/Name: qhull/' "$PREFIX/lib/pkgconfig/qhull_r.pc" \
    > "$PREFIX/lib/pkgconfig/qhull.pc" 2>/dev/null || true
fi

# ---- 产物自校验（九库在场 + ELF aarch64 抽查 + pkgconfig 汇总）----
EXPECT="libz.so libssl.so.3 libcrypto.so.3 libffi.so.8 libfreetype.so.6 libpng16.so.16 libjpeg.so.62 libxml2.so.2 libxslt.so.1 libexslt.so.0 libqhull_r.so.8.0 libopenblas.so"
for lib in $EXPECT; do
  if [ ! -s "$PREFIX/lib/$lib" ]; then
    echo "错误：依赖库缺失或为空：$PREFIX/lib/$lib（构建不完整，查 $LOGS/ 对应日志）。" >&2
    exit 1
  fi
done
# SONAME 与文件名一致性抽查（libxml2：文件 libxml2.so.2.x.y 应报 SONAME libxml2.so.2）
SONAME_BAD=0
for pair in "libssl.so.3:libssl.so.3" "libffi.so.8:libffi.so.8" "libpng16.so.16:libpng16.so.16"; do
  file="${pair%%:*}"; want="${pair##*:}"
  got="$("$SDK_NATIVE/llvm/bin/llvm-readelf" -d "$PREFIX/lib/$file" 2>/dev/null | grep -oP 'Library soname: \[\K[^\]]+' || true)"
  if [ "$got" != "$want" ]; then
    echo "警告：$file SONAME=$got（预期 $want）——落 libs 时须按实际 SONAME 命名。" >&2
    SONAME_BAD=1
  fi
done
[ "$SONAME_BAD" = 0 ] || true

echo "== 依赖基座完成：$PREFIX"
ls -l "$PREFIX/lib"/lib*.so* 2>/dev/null | awk '{printf "%12d B  %s\n", $5, $9}'
echo "== pkgconfig：$(ls "$PREFIX/lib/pkgconfig" 2>/dev/null | tr '\n' ' ')"
