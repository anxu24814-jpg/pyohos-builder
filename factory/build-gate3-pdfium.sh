#!/usr/bin/env bash
# 门 3 PDFium 域构建：自交叉编译 PDFium C++ 库 + pypdfium2 5.14.0 纯 Python 绑定打包。
#
# 路线依据（2026-11-08 调研定稿，「借 bblanchon 参数自走 gn 正统路线」）：
#   · depot_tools + gclient sync（checkout_configuration=minimal 省 V8/语料）；
#   · args.gn 按 bblanchon/pdfium-binaries 05-configure.sh 模板裁剪：
#     target_os="linux" + target_cpu="arm64"（无 ohos 值）+ 无 V8/XFA/Skia/PA；
#   · triple 覆盖 = sed 改 build/config/compiler_cpu_abi.gn 的 aarch64-linux-gnu
#     → aarch64-linux-ohos（2026 年该硬编码自 compiler/BUILD.gn 迁入此文件）；
#   · 编译器用 pdfium 自带上游 clang（third_party/llvm-build，LLVM15 起上游可解析
#     OHOS triple），sysroot 指 OHOS SDK——不用 SDK clang 15（与 2026 Chromium 构建的
#     新 clang 特性潜在不兼容，调研 B 方案）；
#   · pypdfium2 打包零阻力：官方 wheel 取 bindings.py/py 树（bindings 面与默认
#     args〔无 V8/XFA/SKIA〕的 -D 集一致），换自编 libpdfium.so；.so 与 bindings.py
#     同目录进 extras 树（pypdfium2_raw 的 ctypes 加载默认找同目录 ./libpdfium.so）。
#
# 产物拆层特例：libpdfium.so 不进 libs 层、随 pypdfium2_raw/ 包树进 extras（加载路径
# 依赖同目录相对路径）；hvigor 打包只收 libs 的 .so 与本特例无冲突（extras 是 rawfile
# 资产 zip，真机首用解压成真实目录，ctypes 从该目录装载）。
#
# 用法（STAGE 可单段重跑；依赖门 2 rootfs 在场）：
#   SDK_NATIVE=… G2_DIR=… OUT_DIR=… WORK=… \
#   STAGE=pdfium-sync|pdfium-build|pypdfium2|verify-pdf bash build-gate3-pdfium.sh
set -euo pipefail

# ---- 版本冻结副本（单源 = scripts/python-runtime/manifest.json）----
V_pypdfium2="5.14.0"
PDFIUM_BRANCH_FALLBACK="chromium/8138"   # pypdfium2 version.json 读不出时的兜底分支
BBLANCHON_RAW="https://raw.githubusercontent.com/bblanchon/pdfium-binaries/master"

# ---- 环境变量 ----
SDK_NATIVE="${SDK_NATIVE:-}"
G2_DIR="${G2_DIR:-}"
OUT_DIR="${OUT_DIR:-$PWD/gate3-out}"
WORK="${WORK:-$HOME/ohos-py-pkgs}"   # 与门 2 同 WORK：共享 rootfs
STAGE="${STAGE:-all}"
ROOTFS="$WORK/alpine-a64"
PDF_SRC="$WORK/pdfium"               # pdfium checkout 根（gclient 主仓）
PDF_OUT="$PDF_SRC/out/ohos"

# ---- 外部状态校验（P0-1）----
[ -n "$SDK_NATIVE" ] || { echo "错误：未设置 SDK_NATIVE。" >&2; exit 1; }
[ -d "$SDK_NATIVE/sysroot" ] || { echo "错误：SDK_NATIVE 布局缺 sysroot。" >&2; exit 1; }
[ -n "$G2_DIR" ] || { echo "错误：未设置 G2_DIR。" >&2; exit 1; }
for tool in curl tar git ninja python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "错误：宿主缺少命令：$tool。" >&2; exit 1; }
done
if [ "$STAGE" != "pdfium-sync" ] && [ ! -d "$PDF_SRC/build" ]; then
  echo "错误：pdfium 源码未就绪——先跑 STAGE=pdfium-sync。" >&2; exit 1
fi
[ -x "$ROOTFS/run-python.sh" ] || {
  echo "错误：rootfs 未就绪——先跑 build-packages.sh 的 STAGE=rootfs。" >&2; exit 1; }
mkdir -p "$WORK" "$OUT_DIR/extras" "$OUT_DIR/libs"

RUN_PY="$ROOTFS/run-python.sh"
TGT_SITE="$ROOTFS/py/site"
SYSROOT="$SDK_NATIVE/sysroot"

want() { [ "$STAGE" = "all" ] || [ "$STAGE" = "$1" ]; }

STATUS_FILE="$WORK/pkg-status.txt"
touch "$STATUS_FILE"
mark() { echo "$1 $2" >> "$STATUS_FILE"; echo "== $1：$2"; }

# ================================================================
# STAGE pdfium-sync：depot_tools + gclient sync + triple patch
# ================================================================
if want pdfium-sync; then
  echo "== [pdfium-sync] depot_tools + gclient sync"
  export PATH="$WORK/depot_tools:$PATH"
  if [ ! -d "$WORK/depot_tools" ]; then
    git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git "$WORK/depot_tools"
  fi
  command -v gclient >/dev/null 2>&1 || { echo "错误：gclient 不可用。" >&2; exit 1; }

  # pypdfium2 期望的 pdfium 版本（bindings 面与库版本对齐的锚点）：sdist 的
  # pypdfium2_raw/version.json 带 V_PDFIUM（bblanchon 分支名形态 chromium/NNNN）；
  # 读不出走兜底分支并警示。
  PDFIUM_REV="$PDFIUM_BRANCH_FALLBACK"
  rm -rf "$WORK/pdfium-ver-probe"; mkdir -p "$WORK/pdfium-ver-probe"
  VURL=$(curl -sf "https://pypi.org/pypi/pypdfium2/$V_pypdfium2/json" | python3 -c \
    "import sys,json;d=json.load(sys.stdin);print([u['url'] for u in d['urls'] if u['packagetype']=='sdist'][0])" 2>/dev/null || true)
  if [ -n "$VURL" ]; then
    curl -fsSL -o "$WORK/pdfium-ver-probe/s.tar.gz" "$VURL"
    REV_PROBED=$(tar -xzf "$WORK/pdfium-ver-probe/s.tar.gz" -C "$WORK/pdfium-ver-probe" \
      && find "$WORK/pdfium-ver-probe" -name version.json -exec python3 -c \
      "import json,sys;d=json.load(open(sys.argv[1]));print(d.get('V_PDFIUM',''))" {} \; 2>/dev/null || true)
    if [ -n "$REV_PROBED" ]; then PDFIUM_REV="$REV_PROBED"; else
      echo "  !! version.json 未读到 V_PDFIUM，走兜底分支 $PDFIUM_REV"; fi
  fi
  echo "  pdfium 目标版本：$PDFIUM_REV"

  if [ ! -d "$PDF_SRC/.git" ]; then
    mkdir -p "$WORK/pdfium-wrap" && cd "$WORK/pdfium-wrap"
    # minimal 检出（省 V8/测试语料，bblanchon 02-checkout.sh 同款 --custom-var）
    gclient config --unmanaged --custom-var "checkout_configuration=minimal" \
      "https://pdfium.googlesource.com/pdfium.git"
    gclient sync --no-history --shallow --revision "pdfium@refs/heads/$PDFIUM_REV" \
      || gclient sync --no-history --shallow   # 分支名不通时退 HEAD
    mv pdfium "$PDF_SRC" 2>/dev/null || true
  fi
  [ -d "$PDF_SRC/build" ] || { echo "错误：pdfium checkout 缺 build/ 目录。" >&2; exit 1; }
  ( cd "$PDF_SRC" && git log -1 --format="  pdfium @ %h %cd" --date=short )

  # triple patch：compiler_cpu_abi.gn 的 linux-arm64 硬编码 gnu 三元组 → ohos
  ABI_GN="$PDF_SRC/build/config/compiler_cpu_abi.gn"
  [ -f "$ABI_GN" ] || { echo "错误：找不到 $ABI_GN（上游又迁移了？）。" >&2; exit 1; }
  if ! grep -q 'aarch64-linux-ohos' "$ABI_GN"; then
    sed -i 's/aarch64-linux-gnu/aarch64-linux-ohos/g' "$ABI_GN"
    echo "  triple 已覆盖：$(grep -c 'aarch64-linux-ohos' "$ABI_GN") 处"
  fi

  # bblanchon 三 patch（版本漂移致不适用则跳过并警示，现场修）
  ( cd "$PDF_SRC"
    for p in shared_library public_headers clang_rt; do
      if curl -sf "$BBLANCHON_RAW/patches/$p.patch" -o "$WORK/$p.patch"; then
        if patch -p1 --dry-run --forward < "$WORK/$p.patch" >/dev/null 2>&1; then
          patch -p1 --forward < "$WORK/$p.patch" >/dev/null \
            && echo "  patch 应用：$p"
        else
          echo "  !! patch 不适用（跳过）：$p——若构建红先查这里"
        fi
      fi
    done )

  # libc++ rune 表注入（首轮实锤：OHOS musl 无 glibc/BSD ctype 位掩码，__locale 的
  # alpha/digit/punct/mask 全 undeclared + 提示 define _LIBCPP_PROVIDES_DEFAULT_RUNE_TABLE
  # ——libc++ 内置默认 rune 表开关，经 -nostdinc++ 锚点随 libc++ flags 全局带上）
  CXX_GN="$PDF_SRC/build/config/c++/BUILD.gn"
  [ -f "$CXX_GN" ] || { echo "错误：找不到 $CXX_GN。" >&2; exit 1; }
  if ! grep -q '_LIBCPP_PROVIDES_DEFAULT_RUNE_TABLE' "$CXX_GN"; then
    echo "  注入锚点上下文（自证）："
    grep -n -- '-nostdinc++' "$CXX_GN" | head -3
    sed -i 's/"-nostdinc++",/"-nostdinc++", "-D_LIBCPP_PROVIDES_DEFAULT_RUNE_TABLE",/' "$CXX_GN"
    grep -q '_LIBCPP_PROVIDES_DEFAULT_RUNE_TABLE' "$CXX_GN" \
      || { echo "错误：rune 表宏注入失败（-nostdinc++ 锚点形态变了）。" >&2; exit 1; }
    echo "  rune 表宏已注入 $(grep -c '_LIBCPP_PROVIDES_DEFAULT_RUNE_TABLE' "$CXX_GN") 处"
  fi
  mark pdfium-sync "OK（pdfium 源 + triple patch + rune 表宏就绪）"
fi

# ================================================================
# STAGE pdfium-build：args.gn + gn gen + ninja → libpdfium.so + readelf 校验
# ================================================================
if want pdfium-build; then
  echo "== [pdfium-build] gn gen + ninja"
  export PATH="$WORK/depot_tools:$PATH"
  mkdir -p "$PDF_OUT"
  cat > "$PDF_OUT/args.gn" <<EOF
target_os = "linux"
target_cpu = "arm64"
is_debug = false
pdf_is_standalone = true
is_component_build = false
pdf_enable_v8 = false
pdf_enable_xfa = false
pdf_use_skia = false
pdf_use_partition_alloc = false
treat_warnings_as_errors = false
clang_use_chrome_plugins = false
use_sysroot = false
use_glib = false
target_sysroot = "$SYSROOT"
EOF
  ( cd "$PDF_SRC" && gn gen "$PDF_OUT" ) || { mark pdfium "红（gn gen 失败）"; exit 1; }

  # 链接供给修补（第三轮实锤：1172 编译全过、SOLINK 三类缺件——pdfium 自带 clang 24
  # 按 OHOS triple 找 builtins 无该目录名 + glibc 布局假设找 crtbeginS/crtendS + 静态
  # libc++ 链带 -l:libunwind.a）。SDK clang 15 resource lib 有全套 aarch64-linux-ohos
  # 供给，拷贝顶名；unwind 引用定位后删除（undefined 再回看）。
  CLANG_RES=$(ls -d "$PDF_SRC"/third_party/llvm-build/Release+Asserts/lib/clang/*/lib | head -1)
  SDK_RES=$(ls -d "$SDK_NATIVE"/llvm/lib/clang/*/lib | head -1)
  [ -d "$SDK_RES/aarch64-linux-ohos" ] || { echo "错误：SDK resource lib 缺 aarch64-linux-ohos。" >&2; exit 1; }
  mkdir -p "$CLANG_RES/aarch64-linux-ohos" "$SYSROOT/usr/lib/aarch64-linux-ohos"
  for f in libclang_rt.builtins.a; do
    cp -f "$SDK_RES/aarch64-linux-ohos/$f" "$CLANG_RES/aarch64-linux-ohos/$f"
  done
  # CRT 顶名（SDK 的 clang_rt.crtbegin.o / crtend.o〔无 lib 前缀〕→ glibc 场景四个名）
  for base in crtbeginS crtbegin crtendS crtend; do
    src_f=clang_rt.crtbegin.o
    case "$base" in crtend*) src_f=clang_rt.crtend.o ;; esac
    cp -f "$SDK_RES/aarch64-linux-ohos/$src_f" "$CLANG_RES/aarch64-linux-ohos/$base.o"
    cp -f "$SDK_RES/aarch64-linux-ohos/$src_f" "$SYSROOT/usr/lib/aarch64-linux-ohos/$base.o"
  done
  echo "  链接供给已补：$(ls "$CLANG_RES/aarch64-linux-ohos/" | tr '\n' ' ')"
  # pipefail 实锤：grep|head 被提前关管道（SIGPIPE）即杀脚本（第四轮 0.7s 静默 exit，
  # ninja 根本没跑）——|| true 包裹；且注入点不在 build/ 下（第五轮「未找到」而链接仍要
  # 它）——改供给法：SDK llvm/lib/aarch64-linux-ohos/ 有现成 libunwind.a，拷进
  # sysroot 标准搜索位（ld -l: 命中），grep 降级为纯定位信息
  cp -f "$SDK_NATIVE/llvm/lib/aarch64-linux-ohos/libunwind.a" \
    "$SYSROOT/usr/lib/aarch64-linux-ohos/libunwind.a"
  echo "  libunwind.a 已供给（SDK → sysroot lib）"
  UW_FILES=$( { grep -rln -- '-l:libunwind.a' "$PDF_SRC" 2>/dev/null --exclude-dir=out || true; } | head -3)
  echo "  libunwind 引用位（定位信息）：${UW_FILES:-未找到}"

  ( cd "$PDF_SRC" && ninja -C "$PDF_OUT" pdfium ) \
    || { mark pdfium "红（ninja 失败，日志见上）"; exit 1; }
  ls -l "$PDF_OUT/libpdfium.so" >/dev/null \
    || { mark pdfium "红（未产出 libpdfium.so——shared_library 目标缺席？查 patch 应用记录）"; exit 1; }
  file "$PDF_OUT/libpdfium.so" | grep -q 'ARM aarch64' \
    || { mark pdfium "红（产物非 aarch64）"; exit 1; }
  echo "  产物：$(ls -l "$PDF_OUT/libpdfium.so" | awk '{print $5}') B"
  echo "  DT_NEEDED："
  ( command -v readelf >/dev/null && readelf -d "$PDF_OUT/libpdfium.so" | grep NEEDED ) || true
  mark pdfium-build "OK（libpdfium.so aarch64）"
fi

# ================================================================
# STAGE pypdfium2：官方 wheel 取 bindings/py 树 + 自编 .so 入包 + 拆层
# ================================================================
if want pypdfium2; then
  echo "== [pypdfium2] $V_pypdfium2 打包（bindings 换自编 PDFium）"
  [ -f "$PDF_OUT/libpdfium.so" ] || { echo "错误：先跑 STAGE=pdfium-build。" >&2; exit 1; }
  # 逐段跑时 sync 段的 PDFIUM_REV 不在本进程（第六轮 unbound variable 实锤）——兜底
  PDFIUM_REV="${PDFIUM_REV:-$PDFIUM_BRANCH_FALLBACK}"
  rm -rf "$WORK/pdfium-whl"; mkdir -p "$WORK/pdfium-whl"
  # 取本机平台 wheel（bindings.py 与 py 树跨平台同构；内嵌 libpdfium 二进制弃用换自编）
  python3 -m pip download "pypdfium2==$V_pypdfium2" --no-deps --only-binary=:all: \
    -d "$WORK/pdfium-whl" --quiet
  ls "$WORK/pdfium-whl"/*.whl >/dev/null \
    || { mark pypdfium2 "红（wheel 取不到）"; exit 1; }
  rm -rf "$WORK/pdfium-unpack"; mkdir -p "$WORK/pdfium-unpack"
  python3 - "$WORK/pdfium-whl" "$WORK/pdfium-unpack" <<'PY'
import sys, zipfile, glob
w = glob.glob(sys.argv[1] + '/*.whl')[0]
with zipfile.ZipFile(w) as z:
    z.extractall(sys.argv[2])
PY
  # 换二进制：自编 libpdfium.so 落 pypdfium2_raw/（与 bindings.py 同目录 = 其 ctypes
  # 相对加载位）；其余原样。整包树进 extras（含 .so——本域特例）与 TGT_SITE。
  # 另读 wheel 自带 version.json 的 V_PDFIUM 与构建分支比对（错位 = bindings 面与库
  # API 漂移风险，只警示不阻断——闸②③真机验兜底）
  python3 - "$WORK/pdfium-unpack" "$PDFIUM_REV" <<'PY' || true
import json, os, sys
vj = os.path.join(sys.argv[1], 'pypdfium2_raw', 'version.json')
if os.path.exists(vj):
    v = json.load(open(vj)).get('V_PDFIUM', '')
    tag = "" if v == sys.argv[2] else "  !! 错位警示"
    print(f"  wheel V_PDFIUM={v} | 构建分支={sys.argv[2]}{tag}")
else:
    print("  !! wheel 无 version.json（跳过比对）")
PY
  cp -f "$PDF_OUT/libpdfium.so" "$WORK/pdfium-unpack/pypdfium2_raw/libpdfium.so"
  python3 - "$WORK/pdfium-unpack" "$OUT_DIR" "$TGT_SITE" <<'PY'
import os, shutil, sys
src, out, tgt = sys.argv[1], sys.argv[2], sys.argv[3]
for top in ('pypdfium2', 'pypdfium2_raw'):
    s = os.path.join(src, top)
    if not os.path.isdir(s):
        continue
    d1 = os.path.join(out, 'extras', top)
    d2 = os.path.join(tgt, top)
    shutil.rmtree(d1, ignore_errors=True); shutil.copytree(s, d1, ignore=shutil.ignore_patterns('__pycache__'))
    shutil.rmtree(d2, ignore_errors=True); shutil.copytree(s, d2, ignore=shutil.ignore_patterns('__pycache__'))
    print('已落位', top, '→ extras + TGT_SITE（.so 随包，加载路径同目录特例）')
PY
  # dist-info 同步（importlib.metadata 面）
  if [ -d "$WORK/pdfium-unpack/pypdfium2-$V_pypdfium2.dist-info" ]; then
    cp -r "$WORK/pdfium-unpack/pypdfium2-$V_pypdfium2.dist-info" "$OUT_DIR/extras/"
    cp -r "$WORK/pdfium-unpack/pypdfium2-$V_pypdfium2.dist-info" "$TGT_SITE/"
  fi
  mark pypdfium2 "OK（$V_pypdfium2 + 自编 libpdfium.so）"
fi

# ================================================================
# STAGE verify-pdf：qemu 冒烟（import + 新建空文档 + 页面操作）
# ================================================================
if want verify-pdf; then
  echo "== [verify-pdf] pypdfium2 冒烟（TGT_SITE 布局）"
  "$RUN_PY" - <<'PY' || { echo "错误：verify-pdf 冒烟失败。" >&2; exit 4; }
import pypdfium2 as pdfium
pdf = pdfium.PdfDocument.new()
page = pdf.new_page(200, 100)
assert len(pdf) == 1
ver = getattr(pdfium, "V_PYPDFIUM2", None) or pdfium.version.V_PYPDFIUM2
print("SMOKE-OK gate3-pdfium: pages =", len(pdf), "| pypdfium2", ver)
PY
  mark verify-pdf "OK（new doc + new page）"
fi

echo "== build-gate3-pdfium.sh [$STAGE] 完成"
