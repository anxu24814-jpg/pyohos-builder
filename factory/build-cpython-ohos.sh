#!/usr/bin/env bash
# 交叉编译 CPython 3.13.18 为 HarmonyOS (OHOS) aarch64 动态库 + 标准库 zip。
#
# Attribution: 本脚本机制与结构取自 zhubowen-bot/Guncat-Work-for-hmos 仓库
#   tooling/python/build-cpython-ohos.sh（Apache-2.0），取用日期 2026-11-06，
#   按本项目门 0 冻结基线（CPython 3.13.18 / 禁模块清单 / 产物五件）改造。
#   原脚本覆盖 3.12；3.13 的 Modules/Setup.stdlib 相对 3.12 有重构，
#   禁模块清单以 3.13 实际报错微调的余地见下方 Setup.local 段注释。
#
# 机制要点（Guncat 真机实证，详见 docs/调研-鸿蒙Python运行时构建路线-20261106.md §3）:
#   1) configure 拿 `$CC --print-multiarch` 与推导三元组比对，OHOS clang 应答
#      aarch64-linux-ohos 会导致 "internal configure error" —— 用 cc/cxx 包装器把
#      --print-multiarch 应答伪造成 aarch64-linux-gnu，实际编译目标仍是 OHOS。
#   2) 设备上 C 扩展经 dlopen 加载，必须自带 DT_NEEDED libpython3.13.so
#      （否则 PyModuleDef_Init: symbol not found）—— 第二遍 make 用
#      -Wl,--no-as-needed -lpython3.13 重链全部 C 扩展；同时把 libpython 的
#      SONAME 规范成单文件 libpython3.13.so（包里只需一个文件）。
#   3) stdlib zip 必须 zip -qr0 存储模式（zipimport 解压依赖 zlib 扩展存在
#      鸡生蛋问题；存储模式可直接 mmap；HAP 自身是 zip 会再压一次，体积几乎不涨）。
#   4) 禁用 patchelf（Guncat 实锤曾改坏 .dynstr，soname 名字错位一字节）。
#
# 用法（GitHub Actions ubuntu / 任意 Linux 宿主）:
#   SDK_NATIVE=<Linux SDK 的 native 目录> \
#   BUILD_PYTHON=python3.13 \
#   OUT_DIR=<产物输出目录> \
#   PY_DEPS_PREFIX=<依赖基座 prefix，可选> \
#   bash build-cpython-ohos.sh
#
# 门 2 演进（2026-11-07）：PY_DEPS_PREFIX 在场时启用扩展供给形态——
#   · Setup.local 去掉 _ctypes 禁用（libffi 由 build-native-deps.sh 提供，解禁；
#     cffi/pypdfium2 的 ctypes 形态依赖它）
#   · configure 追加 --with-openssl=<prefix>（_ssl/_hashlib 由 OpenSSL 3.5 供给）
#   · CPPFLAGS/LDFLAGS 指 prefix（zlib 等优先取基座版本）
#   · 产物 tarball 增补 deps-libs/（libssl.so.3 libcrypto.so.3 libffi.so.8——设备上
#     无系统侧实现，随应用 lib 目录分发）
#   prefix 缺席时保持门 0 形态（_ctypes 禁、无 _ssl），兼容旧行。
set -euo pipefail

# ---- 冻结基线（门 0 契约，勿改：scripts/python-runtime/manifest.json 单源）----
PY_VERSION="3.13.18"          # v3.13 系最高 tag，冻结依据任务书 §0
ZLIB_VERSION="1.3.1"          # Guncat 同版（zlib/binascii 两个扩展 NEEDED libz.so）
SOVER="3.13"                  # libpython3.13.so / python313.zip 命名尾缀

# ---- 环境变量 ----
SDK_NATIVE="${SDK_NATIVE:-}"
BUILD_PYTHON="${BUILD_PYTHON:-python3.13}"
OUT_DIR="${OUT_DIR:-$PWD/out}"
WORK="${WORK:-$HOME/cpython-ohos-$PY_VERSION}"
# 门 2 依赖基座 prefix（build-native-deps.sh 产物）；在场即启用扩展供给形态
PY_DEPS_PREFIX="${PY_DEPS_PREFIX:-}"
if [ -n "$PY_DEPS_PREFIX" ] && [ ! -d "$PY_DEPS_PREFIX" ]; then
  echo "错误：PY_DEPS_PREFIX 目录不存在：$PY_DEPS_PREFIX（应先跑 build-native-deps.sh）。" >&2
  exit 1
fi

# ---- 外部状态校验（P0-1：任一不满足即中文报错退出非零）----
if [ -z "$SDK_NATIVE" ]; then
  echo "错误：未设置 SDK_NATIVE 环境变量（应指向 Linux 版 OHOS SDK 的 native 目录，内含 llvm/ 与 sysroot/）。" >&2
  exit 1
fi
if [ ! -d "$SDK_NATIVE" ]; then
  echo "错误：SDK_NATIVE 目录不存在：$SDK_NATIVE。请先解压 Linux SDK 并传入其 native 子目录。" >&2
  exit 1
fi
SYSROOT="$SDK_NATIVE/sysroot"
CLANG="$SDK_NATIVE/llvm/bin/clang"
CLANGXX="$SDK_NATIVE/llvm/bin/clang++"
LLVM_BIN="$SDK_NATIVE/llvm/bin"
for f in "$CLANG" "$CLANGXX" "$LLVM_BIN/llvm-ar" "$LLVM_BIN/llvm-strip" "$SYSROOT"; do
  if [ ! -e "$f" ]; then
    echo "错误：SDK_NATIVE 布局不完整，缺少：$f。预期 native 目录内含 llvm/bin/ 与 sysroot/。" >&2
    exit 1
  fi
done
if ! command -v "$BUILD_PYTHON" >/dev/null 2>&1; then
  echo "错误：找不到宿主构建 python：$BUILD_PYTHON。交叉编译要求同 major.minor 版本（3.13.x）作 --with-build-python。" >&2
  exit 1
fi
BUILD_PY_VER="$("$BUILD_PYTHON" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
if [ "$BUILD_PY_VER" != "3.13" ]; then
  echo "错误：BUILD_PYTHON 是 $BUILD_PY_VER，CPython configure 要求 build python 与目标 major.minor 全等（3.13.x），否则直接拒绝。" >&2
  exit 1
fi
for tool in curl tar make zip; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "错误：宿主缺少命令：$tool。" >&2
    exit 1
  fi
done

mkdir -p "$WORK/toolchain" "$OUT_DIR"

# ---- 编译器包装器（只为对齐 --print-multiarch；等价于官方 wrapper 形态：
#      --target=aarch64-linux-ohos --sysroot=... -D__MUSL__，见 OHOS SDK
#      llvm/bin/aarch64-unknown-linux-ohos-clang 的内联参数）----
for kind in cc cxx; do
  real="$CLANG"; [ "$kind" = "cxx" ] && real="$CLANGXX"
  cat > "$WORK/toolchain/ohos-$kind" <<EOF
#!/bin/sh
case "\$1" in
  --print-multiarch) echo aarch64-linux-gnu; exit 0 ;;
esac
exec "$real" --target=aarch64-linux-ohos --sysroot="$SYSROOT" -D__MUSL__ "\$@"
EOF
  chmod +x "$WORK/toolchain/ohos-$kind"
done

# ---- 取 CPython 源码 ----
cd "$WORK"
if [ ! -d "Python-$PY_VERSION" ]; then
  if [ ! -s "Python-$PY_VERSION.tgz" ]; then
    echo "== 下载 Python $PY_VERSION 源码包"
    curl -fL --retry 3 -m 900 -o "Python-$PY_VERSION.tgz" \
      "https://www.python.org/ftp/python/$PY_VERSION/Python-$PY_VERSION.tgz"
  fi
  tar xzf "Python-$PY_VERSION.tgz"
fi

cd "Python-$PY_VERSION"
[ -f Makefile ] && make distclean >/dev/null 2>&1 || true

export CC="$WORK/toolchain/ohos-cc"
export CXX="$WORK/toolchain/ohos-cxx"
export AR="$LLVM_BIN/llvm-ar"
export RANLIB="$LLVM_BIN/llvm-ranlib"
export STRIP="$LLVM_BIN/llvm-strip"
# --sysroot/--target/-D__MUSL__ 已由包装器统一注入，这里只放通用旗标
export CFLAGS="-O2 -fPIC -Wno-error=implicit-function-declaration -Wno-error=int-conversion"
export CXXFLAGS="-O2 -fPIC"
export LDFLAGS="-fuse-ld=lld"
EXTRA_CONFIGURE_ARGS=""
if [ -n "$PY_DEPS_PREFIX" ]; then
  # 门 2 形态：头/库指基座 prefix（zlib 等优先取基座版），_ssl/_hashlib 由 OpenSSL 供给
  export CFLAGS="$CFLAGS -I$PY_DEPS_PREFIX/include"
  export CXXFLAGS="$CXXFLAGS -I$PY_DEPS_PREFIX/include"
  export LDFLAGS="$LDFLAGS -L$PY_DEPS_PREFIX/lib"
  export PKG_CONFIG_PATH="$PY_DEPS_PREFIX/lib/pkgconfig"
  EXTRA_CONFIGURE_ARGS="--with-openssl=$PY_DEPS_PREFIX --with-openssl-rpath=no"
fi

echo "== configure (host=aarch64-linux-gnu, CC=OHOS clang)"
# 交叉编译时 configure 不能探测设备文件/运行时行为，这些答案按 Linux 默认值给死
export ac_cv_file__dev_ptmx=no
export ac_cv_file__dev_ptc=no
export ac_cv_buggy_getaddrinfo=no
export ac_cv_little_endian_double=yes

# 禁模块清单 = manifest.json gate1DisabledModules（门 0 冻结，Guncat L77-103 同源）。
# _locale 必禁（musl 无 libintl，Guncat 实录 _localemodule 找 textdomain 构建失败）；
# _ctypes 因无 libffi 禁用（门 2 自编 libffi 后解禁）。
# ★ 3.13 的 Modules/Setup.stdlib 相对 3.12 有重构：若 3.13 实际构建报「模块名不识别」
#   或某模块仍被拉入，按报错在本清单内增删后重跑（登记变更记录），不得改两遍 make 机制。
# 必须在 configure 之前写 —— Modules/Setup 是 configure 阶段用 Setup.stdlib + Setup.local
# 合成的；之后写只会在部分构建顺序下碰巧生效，重编会把禁用模块又拉回来。
# 门 2 形态（deps 在场）解禁 _ctypes（libffi 已供给）；门 0 形态保持禁用。
if [ -n "$PY_DEPS_PREFIX" ]; then
  cat > Modules/Setup.local <<'EOF'
*disabled*
_locale
_curses
_curses_panel
readline
_tkinter
_dbm
_gdbm
_ndbm
_uuid
nis
ossaudiodev
spwd
_crypt
_multiprocessing
EOF
else
  cat > Modules/Setup.local <<'EOF'
*disabled*
_locale
_ctypes
_curses
_curses_panel
readline
_tkinter
_dbm
_gdbm
_ndbm
_uuid
nis
ossaudiodev
spwd
_crypt
_multiprocessing
EOF
fi

# 不传 --with-openssl：sysroot 里没有 OpenSSL 头，configure 会自动跳过 _ssl/_hashlib
# （门 2 形态经 EXTRA_CONFIGURE_ARGS 供给基座 OpenSSL）。
./configure --build=x86_64-linux-gnu --host=aarch64-linux-gnu \
  --enable-shared --without-ensurepip --disable-ipv6 --disable-test-modules \
  --with-build-python="$BUILD_PYTHON" --with-computed-gotos \
  $EXTRA_CONFIGURE_ARGS \
  > "$WORK/configure.log" 2>&1

echo "== make -j$(nproc)（第一遍：正常构建）"
make -j"$(nproc)" > "$WORK/build.log" 2>&1

# ---- 第二遍：规范 libpython SONAME + 给全部 C 扩展加 DT_NEEDED libpython ----
echo "== 重链 libpython（SONAME=libpython$SOVER.so）与全部扩展"
# EXT_SUFFIX 必须取目标构建的值（cpython-313-aarch64-linux-gnu.so），
# 不能用宿主 python 的 sysconfig（x86_64），否则 rm 不到任何模块、等于没重链。
EXT_SUFFIX="$(grep -m1 '^EXT_SUFFIX=' Makefile | cut -d= -f2 | tr -d ' \t')"
[ -n "$EXT_SUFFIX" ] || { echo "错误：Makefile 里没找到 EXT_SUFFIX。" >&2; exit 1; }
# deps 形态：BLDSHARED 覆盖会把 LDFLAGS 里的 -L 弄丢——_ssl/_hashlib/_ctypes 链接
# 找不到 libssl/libffi 即被 CPython 软失败机制静默跳过（make 仍返回 0，第七轮实锤：
# configure 探测全过而产物缺三扩展），必须显式补回 -L
DEPS_SHARED_L=""
if [ -n "$PY_DEPS_PREFIX" ]; then
  DEPS_SHARED_L="-L$PY_DEPS_PREFIX/lib"
fi
# 重新链接 libpython 让 SONAME 与文件名一致（libpython3.13.so），扩展的 DT_NEEDED 才对得上。
# 不用 patchelf：它曾在本类项目改出损坏的 .dynstr（加载时 soname 错位一字节）。
rm -f "libpython$SOVER.so" "libpython$SOVER.so.1.0"
make "libpython$SOVER.so" "INSTSONAME=libpython$SOVER.so" "LDLIBRARY=libpython$SOVER.so" \
  "BLDSHARED=\$(CC) -shared \$(PY_CORE_LDFLAGS) -Wl,-soname,libpython$SOVER.so" \
  >> "$WORK/build.log" 2>&1
rm -f Modules/*"$EXT_SUFFIX"
make -j"$(nproc)" sharedmods \
  "BLDSHARED=\$(CC) -shared \$(PY_CORE_LDFLAGS) $DEPS_SHARED_L -L$PWD -Wl,--no-as-needed -lpython$SOVER" \
  >> "$WORK/build.log" 2>&1

# 软失败守卫：CPython 扩展构建失败只打 warning（make 返回 0）——显式抓出并失败
if grep -E "^(Failed to build these modules|Could not build these modules):" "$WORK/build.log" | tail -5 | grep -q .; then
  echo "错误：存在链接失败的扩展（软失败被拦）：" >&2
  grep -E "^(Failed to build these modules|Could not build these modules):" "$WORK/build.log" | tail -5 >&2
  exit 1
fi

echo "== make install (DESTDIR)"
rm -rf "$WORK/dest"
make install DESTDIR="$WORK/dest" > "$WORK/install.log" 2>&1

DEST="$WORK/dest"
STDLIB="$(find "$DEST" -type d -name "python$SOVER" -path '*/lib/*' | head -1)"
[ -n "$STDLIB" ] || { echo "错误：安装树里没找到标准库目录 python$SOVER。" >&2; exit 1; }
# libpython 直接取构建目录里重链后的单文件（SONAME=文件名，是设备 dlopen 的正主）；
# 安装树里的 .so.1.0 形态文件名与 SONAME 不一致，不采用。
[ -f "$PWD/libpython$SOVER.so" ] || { echo "错误：构建目录里没找到重链后的 libpython$SOVER.so。" >&2; exit 1; }

echo "== 打包（产物五件 → $OUT_DIR）"

# 1) libpython3.13.so（strip）
cp -f "$PWD/libpython$SOVER.so" "$OUT_DIR/libpython$SOVER.so"
"$STRIP" --strip-unneeded "$OUT_DIR/libpython$SOVER.so" 2>/dev/null || true

# 2) 标准库 zip（存储模式 -0；排除清单照调研档 §3.3 第 6 步）
rm -f "$OUT_DIR/python${SOVER/./}.zip"
( cd "$STDLIB" && zip -qr0 "$OUT_DIR/python${SOVER/./}.zip" . \
    -x 'test/*' -x 'idlelib/*' -x 'turtledemo/*' -x 'tkinter/*' -x 'lib2to3/*' \
    -x 'ensurepip/*' -x 'lib-dynload/*' -x '__pycache__/*' -x '*.pyc' -x 'config-*/*' )

# 3) C 扩展模块（全部带 DT_NEEDED libpython；只有应用 lib 目录 .so 可被设备 dlopen）
# 收集源 = 构建树 Modules/（第二遍重链后的正主产物）。第九轮实锤（run 42277411840）：
# _ssl/_hashlib/_ctypes 编出且重链成功、MODULE_*_STATE=yes，但 make install 的
# sharedinstall 未把它们装进 lib-dynload（其余 40+ 在场）；故不以 lib-dynload 为源，
# lib-dynload 计数仅作证据打印（差距根因见自检失败分支 dump 的 install.log）。
rm -rf "$OUT_DIR/modules"
mkdir -p "$OUT_DIR/modules"
BLD="$WORK/Python-$PY_VERSION"
cp -f "$BLD/Modules/"*"$EXT_SUFFIX" "$OUT_DIR/modules/" 2>/dev/null \
  || { echo "错误：构建树 Modules/ 里没有任何 *$EXT_SUFFIX 扩展，重链步骤可能未生效。" >&2; exit 1; }
echo "（证据）lib-dynload=$(ls "$STDLIB"/lib-dynload/*"$EXT_SUFFIX" 2>/dev/null | wc -l) 个，构建树=$(ls "$BLD/Modules/"*"$EXT_SUFFIX" | wc -l) 个"
EXT_COUNT=0
for f in "$OUT_DIR/modules"/*"$EXT_SUFFIX"; do
  [ -f "$f" ] && { "$STRIP" --strip-unneeded "$f" 2>/dev/null || true; EXT_COUNT=$((EXT_COUNT+1)); } || true
done
# Guncat 3.12 基线为 56 个扩展；禁 15 模块后 3.13 应仍有 40+，低于 10 视为半成品
if [ "$EXT_COUNT" -lt 10 ]; then
  echo "错误：C 扩展仅 $EXT_COUNT 个（预期 40+，下限 10），构建不完整。" >&2
  exit 1
fi

# 4) 自编 libz.so（zlib/binascii 扩展 NEEDED libz.so，OHOS 无系统侧可用实现，随包自带）
if [ ! -d "$WORK/zlib-$ZLIB_VERSION" ]; then
  [ -s "$WORK/zlib-$ZLIB_VERSION.tar.gz" ] || curl -fL --retry 3 -m 600 \
    -o "$WORK/zlib-$ZLIB_VERSION.tar.gz" \
    "https://codeload.github.com/madler/zlib/tar.gz/refs/tags/v$ZLIB_VERSION"
  tar xzf "$WORK/zlib-$ZLIB_VERSION.tar.gz" -C "$WORK"
fi
ZL="$WORK/zlib-$ZLIB_VERSION"
"$CC" -O2 -fPIC -shared -Wl,-soname,libz.so -o "$OUT_DIR/libz.so" \
  "$ZL/adler32.c" "$ZL/compress.c" "$ZL/crc32.c" "$ZL/deflate.c" "$ZL/gzclose.c" \
  "$ZL/gzlib.c" "$ZL/gzread.c" "$ZL/gzwrite.c" "$ZL/inflate.c" "$ZL/infback.c" \
  "$ZL/inftrees.c" "$ZL/inffast.c" "$ZL/trees.c" "$ZL/uncompr.c" "$ZL/zutil.c" \
  >> "$WORK/build.log" 2>&1
"$STRIP" --strip-unneeded "$OUT_DIR/libz.so" 2>/dev/null || true

# 5) build-log.txt（configure/build/install 三段日志合一，供排障与构建取证）
cat "$WORK/configure.log" "$WORK/build.log" "$WORK/install.log" > "$OUT_DIR/build-log.txt"

# 6) 门 2 形态：依赖基座库随产物（设备无系统侧实现，_ssl/_ctypes 的 DT_NEEDED 靠它们）
if [ -n "$PY_DEPS_PREFIX" ]; then
  rm -rf "$OUT_DIR/deps-libs"
  mkdir -p "$OUT_DIR/deps-libs"
  for lib in libssl.so.3 libcrypto.so.3 libffi.so.8; do
    if [ ! -s "$PY_DEPS_PREFIX/lib/$lib" ]; then
      echo "错误：基座库缺失：$PY_DEPS_PREFIX/lib/$lib（先跑 build-native-deps.sh）。" >&2
      exit 1
    fi
    cp -f "$PY_DEPS_PREFIX/lib/$lib" "$OUT_DIR/deps-libs/"
    "$STRIP" --strip-unneeded "$OUT_DIR/deps-libs/$lib" 2>/dev/null || true
  done
  # 门 2 自检：_ssl/_hashlib/_ctypes 必须在场（解禁失败的静默跳过在此拦截）。
  # 匹配用精确文件名 $mod$EXT_SUFFIX——EXT_SUFFIX 自带前导点（.cpython-313.so），
  # 旧写法 "$mod."*"$EXT_SUFFIX" 展开成 _ssl.*.cpython-313.so，与实际文件名
  # _ssl.cpython-313.so 永不匹配 = 恒假自检（第 8~10 轮三连红的真凶，扩展实际
  # 一直在场：lib-dynload=52=构建树，第十轮证据行实锤）
  for mod in _ssl _hashlib _ctypes; do
    if [ ! -e "$OUT_DIR/modules/$mod$EXT_SUFFIX" ]; then
      echo "错误：扩展 $mod 未编出（deps 形态下应已解禁）。诊断证据：" >&2
      echo "== Modules/ 实际编出的扩展（$EXT_SUFFIX）==" >&2
      ( cd "$WORK/Python-$PY_VERSION" 2>/dev/null && ls Modules/*"$EXT_SUFFIX" 2>/dev/null | wc -l \
        && ls Modules/*"$EXT_SUFFIX" 2>/dev/null | head -10 ) >&2 || true
      echo "== Makefile 模块态 ==" >&2
      grep -E '^(MODULE__SSL_STATE|MODULE__HASHLIB_STATE|MODULE__CTYPES_STATE|MODULE__SSL__DEPS)' \
        "$WORK/Python-$PY_VERSION/Makefile" >&2 || true
      echo "== install.log 里 sharedinstall/_ssl/lib-dynload 相关行 ==" >&2
      grep -n -i -E "sharedinstall|_ssl|_hashlib|_ctypes|lib-dynload|Failed to build|Could not build" \
        "$WORK/install.log" 2>/dev/null | head -40 >&2 || true
      echo "== install.log 里 _ssl 装载行上下文 ==" >&2
      grep -n -B2 -A2 '_ssl\.' "$WORK/install.log" 2>/dev/null | head -20 >&2 || true
      echo "== build.log 里 ssl/ffi/ctypes/WARNING/renaming 相关行 ==" >&2
      grep -n -i -E "ssl|ffi|ctypes|warning|renaming|failed" "$WORK/build.log" | tail -40 >&2 || true
      echo "== build.log 尾部 40 行 ==" >&2
      tail -40 "$WORK/build.log" >&2 || true
      exit 1
    fi
  done

  # 7) host-bundle：目标 python 可执行 + include 树（包构建 job 的 qemu 环境要
  #    「能在构建机上运行的目标解释器」跑 setup.py/meson 内省，C 编译要 Python.h/pyconfig.h）
  # 三输入全部构建树优先（第一遍交叉链接/配置的正主）：第十一轮实锤 install 树未装出
  # bin/python3.13（根因证据见失败分支 dump），不再绕道安装树。
  rm -rf "$OUT_DIR/host-bundle"
  mkdir -p "$OUT_DIR/host-bundle/bin" "$OUT_DIR/host-bundle/lib" "$OUT_DIR/host-bundle/include"
  # 可执行取三候选（第十二轮 dump 实锤：构建树可执行名是 python 无版本号——install -c
  # python → bin/python3.13 才改名；安装树路径带 usr/local 层）。构建树正主优先。
  HB_PY=""
  for cand in "$PWD/python" "$DEST/usr/local/bin/python$SOVER" "$DEST/bin/python$SOVER"; do
    if [ -x "$cand" ]; then HB_PY="$cand"; break; fi
  done
  if [ -z "$HB_PY" ]; then
    echo "错误：三候选都没有可执行 python（host-bundle 无法组装）。诊断：" >&2
    echo "== 构建树顶层 python* ==" >&2
    ls -la "$PWD"/python* 2>/dev/null >&2 || true
    echo "== 安装树 bin 目录实况 ==" >&2
    ls -la "$DEST/usr/local/bin/" "$DEST/bin/" 2>/dev/null >&2 || true
    echo "== install.log 里可执行安装段 ==" >&2
    grep -n -E "install -c (python|.*python3\.13)" "$WORK/install.log" 2>/dev/null | head -10 >&2 || true
    exit 1
  fi
  cp -f "$HB_PY" "$OUT_DIR/host-bundle/bin/python$SOVER"
  cp -f "$PWD/libpython$SOVER.so" "$OUT_DIR/host-bundle/lib/libpython$SOVER.so"
  if [ -d "$DEST/include/python$SOVER" ]; then
    cp -r "$DEST/include/python$SOVER" "$OUT_DIR/host-bundle/include/python$SOVER"
  else
    # 兜底：构建树 Include/ + pyconfig.h 组装（与安装树 inclinstall 等价内容）
    mkdir -p "$OUT_DIR/host-bundle/include/python$SOVER"
    cp -r "$PWD/Include/." "$OUT_DIR/host-bundle/include/python$SOVER/"
    cp -f "$PWD/pyconfig.h" "$OUT_DIR/host-bundle/include/python$SOVER/"
  fi
  # 目标侧 python3 符号链接形态（部分工具按 python3 调用）一并带上
  ln -sf "python$SOVER" "$OUT_DIR/host-bundle/bin/python3"
fi

# ---- 产物自校验（五件在场 + 非零字节）----
for f in "libpython$SOVER.so" "python${SOVER/./}.zip" "libz.so" "build-log.txt"; do
  if [ ! -s "$OUT_DIR/$f" ]; then
    echo "错误：产物缺失或为空：$OUT_DIR/$f。" >&2
    exit 1
  fi
done

# ---- 打成单一 tarball（Actions 单文件上传最快，U3 落位时解开）----
# 门 2 形态 tarball 名带 -g2 尾缀（与门 0 artifact 区分，防拉错产物）
TAR_SUFFIX="aarch64"
TAR_EXTRA=()
if [ -n "$PY_DEPS_PREFIX" ]; then
  TAR_SUFFIX="aarch64-g2"
  TAR_EXTRA=("deps-libs" "host-bundle")
fi
TARBALL="$OUT_DIR/cpython-ohos-$PY_VERSION-$TAR_SUFFIX.tar.gz"
( cd "$OUT_DIR" && tar -czf "$TARBALL" \
    "libpython$SOVER.so" "python${SOVER/./}.zip" "libz.so" "build-log.txt" modules "${TAR_EXTRA[@]}" )
[ -s "$TARBALL" ] || { echo "错误：产物 tarball 生成失败：$TARBALL。" >&2; exit 1; }

echo "== 完成，产物五件 + tarball："
ls -l "$OUT_DIR/libpython$SOVER.so" "$OUT_DIR/python${SOVER/./}.zip" \
       "$OUT_DIR/libz.so" "$OUT_DIR/build-log.txt" "$TARBALL" | awk '{printf "%12d B  %s\n", $5, $9}'
if [ -n "$PY_DEPS_PREFIX" ]; then
  ls -l "$OUT_DIR/deps-libs"/* | awk '{printf "%12d B  %s\n", $5, $9}'
fi
echo "扩展模块：$EXT_COUNT 个（$OUT_DIR/modules/）"
