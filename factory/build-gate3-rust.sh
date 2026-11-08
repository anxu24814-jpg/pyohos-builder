#!/usr/bin/env bash
# 门 3 Rust 三件构建：cryptography 50.0.2 / pydantic-core 2.50.4 / rpds-py 2026.9.1
# 交叉编译到 OHOS aarch64（Rust target = aarch64-unknown-linux-ohos，注意带 unknown）。
#
# 路线依据（2026-11-08 调研定稿）：
#   · Rust 官方 Tier 2（with host tools），rustup 直装（1.78 起晋级，rust-lang PR #120585）；
#   · maturin 无 OHOS 专属支持，但对未知三元组兜底按 Linux 处理——
#     `maturin build --target aarch64-unknown-linux-ohos --compatibility linux` 可用
#     （先例：CSDN 鸿蒙PC cryptography 44 移植 + SSRVodka/oh-edu-pkgs setup2.sh 环境变量全集）；
#   · 全程宿主侧构建：pyo3 build script 不能执行目标解释器，交叉内省全走
#     PYO3_CROSS_* 环境变量 + _sysconfigdata 文件（qemu 不进构建链，只作构建后探针）；
#   · cryptography 50.0.2 的 openssl-sys 恰不带 vendored feature——OPENSSL_DIR 直接对接
#     基座 OpenSSL 3.5.4 prefix（build-native-deps.sh 产物）；其 cffi 生成步在宿主
#     Python 跑（PYO3_PYTHON），_openssl.c 由 cc crate 交叉编译（CC/CFLAGS 环境变量）。
#
# 产物拆层同门 2 语义：*.so → OUT_DIR/libs/<包树>（顶层扩展平铺）；
# .py / dist-info → OUT_DIR/extras/<包树>；整树 → TGT_SITE（后续包内省与探针）。
#
# 用法（STAGE 可单段重跑；依赖门 2 rootfs 与 cffi 段已在场——yml 先跑
#   build-packages.sh 的 rootfs + cffi 两段，本脚本不做 rootfs 自举）：
#   SDK_NATIVE=… G2_DIR=… PY_DEPS_PREFIX=… OUT_DIR=… WORK=… \
#   STAGE=rust-setup|rpds|pydantic-core|cryptography|verify3 bash build-gate3-rust.sh
set -euo pipefail

# ---- 版本冻结副本（单源 = scripts/python-runtime/manifest.json，2026-11-06 冻结）----
V_cryptography="50.0.2"    V_pydantic_core="2.50.4"    V_rpds_py="2026.9.1"
V_typing_extensions="4.16.0"   # pydantic_core 顶层 import；真机侧在 site-packages.zip
RUST_TARGET="aarch64-unknown-linux-ohos"   # rustc/rustup 侧三元组（带 unknown）
OHOS_TRIPLE="aarch64-linux-ohos"           # clang 侧三元组（不带）

# ---- 环境变量 ----
SDK_NATIVE="${SDK_NATIVE:-}"
G2_DIR="${G2_DIR:-}"          # g2 tarball 解开处（host-bundle/ python313.zip …）
PY_DEPS_PREFIX="${PY_DEPS_PREFIX:-}"
OUT_DIR="${OUT_DIR:-$PWD/gate3-out}"
WORK="${WORK:-$HOME/ohos-py-pkgs}"   # 与门 2 同 WORK：共享 rootfs / TGT_SITE / fetch 缓存
STAGE="${STAGE:-all}"
ROOTFS="$WORK/alpine-a64"

# ---- 外部状态校验（P0-1）----
[ -n "$SDK_NATIVE" ] || { echo "错误：未设置 SDK_NATIVE。" >&2; exit 1; }
[ -d "$SDK_NATIVE" ] || { echo "错误：SDK_NATIVE 不存在：$SDK_NATIVE。" >&2; exit 1; }
[ -n "$G2_DIR" ] || { echo "错误：未设置 G2_DIR。" >&2; exit 1; }
[ -d "$G2_DIR/host-bundle" ] || { echo "错误：G2_DIR 布局缺 host-bundle：$G2_DIR。" >&2; exit 1; }
SYSROOT="$SDK_NATIVE/sysroot"
LLVM_BIN="$SDK_NATIVE/llvm/bin"
CLANG="$LLVM_BIN/aarch64-unknown-linux-ohos-clang"
CLANGXX="$LLVM_BIN/aarch64-unknown-linux-ohos-clang++"
for f in "$CLANG" "$CLANGXX" "$LLVM_BIN/llvm-ar"; do
  [ -e "$f" ] || { echo "错误：SDK 布局缺文件：$f。" >&2; exit 1; }
done
for tool in curl tar rustc cargo maturin python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "错误：宿主缺少命令：$tool（workflow 应预装）。" >&2; exit 1; }
done
[ -x "$ROOTFS/run-python.sh" ] || {
  echo "错误：rootfs 未就绪——先跑 build-packages.sh 的 STAGE=rootfs。" >&2; exit 1; }
mkdir -p "$WORK" "$OUT_DIR/extras" "$OUT_DIR/libs"

RUN_PY="$ROOTFS/run-python.sh"
TGT_SITE="$ROOTFS/py/site"
PYINC="$ROOTFS/usr/local/include/python3.13"
CROSS_DIR="$WORK/pyo3-cross"     # PYO3 交叉内省目录（libpython + _sysconfigdata + include）

want() { [ "$STAGE" = "all" ] || [ "$STAGE" = "$1" ]; }

STATUS_FILE="$WORK/pkg-status.txt"
touch "$STATUS_FILE"
mark() { echo "$1 $2" >> "$STATUS_FILE"; echo "== $1：$2"; }

fetch_sdist() {  # pkg ver —— 从 PyPI JSON API 取 sdist 并解包，输出目录名（与门 2 同款）
  local pkg="$1" ver="$2" dir
  dir="$pkg-$ver"
  cd "$WORK"
  if [ ! -d "$dir" ]; then
    local url
    url=$(curl -sf "https://pypi.org/pypi/$pkg/$ver/json" | python3 -c \
      "import sys,json;d=json.load(sys.stdin);print([u['url'] for u in d['urls'] if u['packagetype']=='sdist'][0])")
    [ -n "$url" ] || { echo "错误：PyPI 取不到 $pkg $ver 的 sdist。" >&2; return 1; }
    curl -fsSL -o "$dir.tar.gz" "$url"
    tar xzf "$dir.tar.gz"
    [ -d "$dir" ] || { local got; got=$(python3 -c \
      "import tarfile;print(tarfile.open('$dir.tar.gz').getnames()[0].split('/')[0])"); mv "$got" "$dir"; }
  fi
  echo "$WORK/$dir"
}

# ================================================================
# STAGE rust-setup：target 安装 + PYO3 交叉内省目录（其余段的前置）
# ================================================================
if want rust-setup; then
  echo "== [rust-setup] rustup target + pyo3-cross 内省目录"
  rustup target add "$RUST_TARGET"
  rustup target list --installed | grep -qx "$RUST_TARGET" \
    || { echo "错误：rustup 未装 target $RUST_TARGET。" >&2; exit 1; }
  echo "  rustc $(rustc --version)"

  # 内省目录：libpython + _sysconfigdata（stdlib zip 根平铺，maturin/pyo3 在
  # PYO3_CROSS_LIB_DIR 递归找 _sysconfigdata*.py 读 EXT_SUFFIX 等）+ Python 头
  mkdir -p "$CROSS_DIR/lib" "$CROSS_DIR/include"
  if [ ! -f "$CROSS_DIR/lib/libpython3.13.so" ]; then
    cp -f "$G2_DIR/host-bundle/lib/libpython3.13.so" "$CROSS_DIR/lib/"
  fi
  if ! ls "$CROSS_DIR/lib"/_sysconfigdata*.py >/dev/null 2>&1; then
    rm -rf "$WORK/zip-out"; mkdir -p "$WORK/zip-out"
    unzip -oq "$G2_DIR/python313.zip" '*_sysconfigdata*' -d "$WORK/zip-out"
    find "$WORK/zip-out" -name '_sysconfigdata*.py' -exec cp -f {} "$CROSS_DIR/lib/" \;
  fi
  ls "$CROSS_DIR/lib"/_sysconfigdata*.py >/dev/null \
    || { echo "错误：_sysconfigdata 未取到（查 $G2_DIR/python313.zip）。" >&2; exit 1; }
  rm -rf "$CROSS_DIR/include/python3.13"
  cp -r "$G2_DIR/host-bundle/include/python3.13" "$CROSS_DIR/include/python3.13"
  ls "$CROSS_DIR/include/python3.13/Python.h" >/dev/null \
    || { echo "错误：交叉内省目录缺 Python.h。" >&2; exit 1; }
  echo "  内省目录 $CROSS_DIR：$(ls "$CROSS_DIR/lib" | tr '\n' ' ')"

  # 宿主侧 cryptography 构建依赖：cffi 生成步在宿主 Python 跑（emit_c_code 出 _openssl.c）
  python3 -c "import cffi; print('  host cffi', cffi.__version__)" \
    || { echo "错误：宿主缺 cffi（cryptography cffi 生成步需要）。" >&2; exit 1; }

  # TGT_SITE 补 typing_extensions（pydantic_core __init__ 顶层 import；真机侧该包在
  # site-packages.zip，本 job 的 qemu TGT_SITE 没有——第二轮实锤 ModuleNotFoundError）
  if [ ! -d "$TGT_SITE/typing_extensions" ]; then
    rm -rf "$WORK/te-whl"; mkdir -p "$WORK/te-whl"
    python3 -m pip download "typing-extensions==$V_typing_extensions" --no-deps \
      --only-binary=:all: --python-version 3.13 --implementation py --abi none \
      --platform any -d "$WORK/te-whl" --quiet
    python3 - "$WORK/te-whl" "$TGT_SITE" <<'PY'
import sys, zipfile, glob
w = glob.glob(sys.argv[1] + '/*.whl')[0]
with zipfile.ZipFile(w) as z:
    z.extractall(sys.argv[2])
print('  typing_extensions → TGT_SITE')
PY
  fi
  mark rust-setup "OK（target $RUST_TARGET + 内省目录就绪）"
fi

# rust 交叉环境（maturin 调 cargo 的全部接线）
rust_env() {
  export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_OHOS_LINKER="$CLANG"
  export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_OHOS_AR="$LLVM_BIN/llvm-ar"
  # cc-rs（cryptography 的 _openssl.c 交叉编译走这里）——rustc 平台页要求 -D__MUSL__
  export "CC_${RUST_TARGET//-/_}"="$CLANG"
  export "CXX_${RUST_TARGET//-/_}"="$CLANGXX"
  export "CFLAGS_${RUST_TARGET//-/_}"="--target=$OHOS_TRIPLE --sysroot=$SYSROOT -D__MUSL__ -O2 -fPIC -I$PYINC"
  export "CXXFLAGS_${RUST_TARGET//-/_}"="--target=$OHOS_TRIPLE --sysroot=$SYSROOT -D__MUSL__ -O2 -fPIC -I$PYINC"
  export PYO3_CROSS=1
  export PYO3_CROSS_PYTHON_VERSION=3.13
  export PYO3_CROSS_LIB_DIR="$CROSS_DIR/lib"
  export PYO3_CROSS_INCLUDE_DIR="$CROSS_DIR/include/python3.13"
  # DT_NEEDED libpython 预防性带上（Guncat 真机 168 .so 缺 DT_NEEDED 教训，门 2 LDSHARED 同款）
  export RUSTFLAGS="-C link-arg=-Wl,--no-as-needed -C link-arg=-lpython3.13 -C link-arg=-L$CROSS_DIR/lib"
}

# maturin_pkg <项目名> <版本> —— sdist → maturin 交叉构建 → wheel 解包拆层 + qemu 探针
maturin_pkg() {
  local name="$1" ver="$2"
  local dir top
  dir="$(fetch_sdist "$name" "$ver")"
  top=$(basename "$dir")
  [ -f "$CROSS_DIR/lib/libpython3.13.so" ] || {
    echo "错误：先跑 STAGE=rust-setup。" >&2; exit 1; }
  local whl_dir="$WORK/g3-whl/$top"
  rm -rf "$whl_dir"; mkdir -p "$whl_dir"
  (
    cd "$dir"
    rust_env
    { echo "== env 快照（cffi 供给诊断，build.rs 将继承）=="
      env | grep -E '^(PYO3|OPENSSL_DIR|PYTHONPATH|CARGO_TARGET_AARCH)' | sort; } \
      > "$WORK/$top-maturin.log"
    maturin build --target "$RUST_TARGET" --release \
      --compatibility linux -o "$whl_dir" >> "$WORK/$top-maturin.log" 2>&1
  ) || {
    mark "$name" "红（maturin 失败，日志 $WORK/$top-maturin.log）"
    echo "== $top maturin.log 尾 40 行 ==" >&2
    tail -40 "$WORK/$top-maturin.log" >&2 || true
    return 1
  }
  ls "$whl_dir"/*.whl >/dev/null || {
    mark "$name" "红（未产出 wheel，日志 $WORK/$top-maturin.log）"; return 1; }
  echo "  wheel：$(cd "$whl_dir" && ls *.whl)"

  # 拆层（wheel 解包树：*.so → libs 包树/顶层平铺；.py+dist-info → extras；整树 → TGT_SITE）
  rm -rf "$WORK/g3-unpack/$top"; mkdir -p "$WORK/g3-unpack/$top"
  python3 - "$whl_dir" "$WORK/g3-unpack/$top" <<'PY'
import sys, zipfile, glob
w = glob.glob(sys.argv[1] + '/*.whl')[0]
with zipfile.ZipFile(w) as z:
    z.extractall(sys.argv[2])
PY
  python3 - "$WORK/g3-unpack/$top" "$OUT_DIR" "$TGT_SITE" "$name" <<'PY'
import os, shutil, sys
src, out, tgt, name = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
for root, dirs, files in os.walk(src):
    rel = os.path.relpath(root, src)
    for f in files:
        p = os.path.join(root, f)
        # dist-info 原样进 extras（运行期 importlib.metadata 查询面）与 TGT_SITE
        if f.endswith('.so'):
            dst = os.path.join(out, 'libs', rel, f)
        else:
            dst = os.path.join(out, 'extras', rel, f)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy2(p, dst)
        tdst = os.path.join(tgt, rel, f)
        os.makedirs(os.path.dirname(tdst), exist_ok=True)
        shutil.copy2(p, tdst)
        if rel == '.' and f.endswith('.so'):
            print('顶层扩展平铺', f)
print('已拆层', name)
PY
  mark "$name" "OK（$ver）"
}

# ================================================================
# STAGE rpds（依赖树最简，链路首验——调研建议顺序：rpds → pydantic-core → cryptography）
# ================================================================
if want rpds; then
  echo "== [rpds] rpds-py $V_rpds_py"
  maturin_pkg rpds-py "$V_rpds_py"
  "$RUN_PY" -c "import rpds; from importlib.metadata import version; m = rpds.HashTrieMap(a=1); assert m['a'] == 1; print('probe-ok rpds', version('rpds-py'))" \
    || { mark rpds "红（qemu 探针失败）"; exit 1; }
fi

# ================================================================
# STAGE pydantic-core（版本特化构建：PYO3_CROSS_PYTHON_VERSION 消歧）
# ================================================================
if want pydantic-core; then
  echo "== [pydantic-core] pydantic-core $V_pydantic_core"
  maturin_pkg pydantic-core "$V_pydantic_core"
  "$RUN_PY" -c "import pydantic_core; from importlib.metadata import version; print('probe-ok pydantic_core', version('pydantic-core'))" \
    || { mark pydantic-core "红（qemu 探针失败）"; exit 1; }
fi

# ================================================================
# STAGE cryptography（三语言混合构建步 + OPENSSL_DIR 对接基座；import 链需 cffi）
# ================================================================
if want cryptography; then
  echo "== [cryptography] cryptography $V_cryptography"
  [ -d "$TGT_SITE/cffi" ] || { echo "错误：TGT_SITE 缺 cffi——先跑 build-packages.sh 的 STAGE=cffi。" >&2; exit 1; }
  export OPENSSL_DIR="$PY_DEPS_PREFIX"
  # build_openssl.py 的 cffi 供给（第五轮 version mismatch 实锤定案：build.rs 的
  # Command 跑的是系统 /usr/bin/python3【3.12】——PYO3_PYTHON env 传不进 build script，
  # 且 PYTHONPATH 喂 3.13 的 cffi py 部分给 3.12 会与系统 _cffi_backend 1.16 错位）。
  # 修 = ① 给 3.12 装配套 cffi>=2.0（py 部分 + cp312 _cffi_backend 同源同版）；
  #       ② 源码树 .cargo/config.toml [env] 硬钉 PYO3_PYTHON（cargo 官方注入通道）；
  #       ③ PYTHONPATH 不设（3.13/3.12 混喂 = 错位源，撤）
  /usr/bin/python3 -m pip install --quiet --break-system-packages --force-reinstall \
      'cffi>=2.0' 'setuptools' \
    || sudo /usr/bin/python3 -m pip install --quiet --break-system-packages \
      --force-reinstall 'cffi>=2.0' 'setuptools' \
    || { echo "错误：/usr/bin/python3 装 cffi 未成——build.rs 用它必红。" >&2; exit 1; }
  /usr/bin/python3 -c 'import cffi; from importlib.metadata import version; \
assert version("cffi") == cffi.__version__, "cffi 双版本残留"; \
print("  3.12 cffi 就绪", cffi.__version__)' \
    || { echo "错误：/usr/bin/python3 的 cffi 版本错位（dist-packages 1.16 残留）。" >&2; exit 1; }
  mkdir -p "$WORK/cryptography-$V_cryptography/.cargo"
  printf '[env]\nPYO3_PYTHON = "%s"\n' "$(command -v python3)" \
    > "$WORK/cryptography-$V_cryptography/.cargo/config.toml"
  echo "  [env] 已钉：PYO3_PYTHON = $(command -v python3)"
  maturin_pkg cryptography "$V_cryptography"
  # AESGCM 往返（libcrypto 链 + cffi 生成面同验；避免拉 ssl 深链）
  "$RUN_PY" -c "
import os
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from importlib.metadata import version
k = AESGCM.generate_key(bit_length=256)
ct = AESGCM(k).encrypt(b'n', b'smoke', b'ad')
assert AESGCM(k).decrypt(b'n', ct, b'ad') == b'smoke'
print('probe-ok cryptography', version('cryptography'))" \
    || { mark cryptography "红（qemu 探针失败）"; exit 1; }
fi

# ================================================================
# STAGE verify3：三件 import + 功能冒烟（真机四层 zip 布局的装载验证归闸②③合并验；
# 本段证「.so 在 qemu OHOS-musl 兼容层可装载 + 功能正确」，布局 = TGT_SITE 整树直供）
# ================================================================
if want verify3; then
  echo "== [verify3] Rust 三件冒烟（TGT_SITE 布局）"
  "$RUN_PY" - <<'PY' || { echo "错误：verify3 冒烟失败。" >&2; exit 4; }
import rpds, pydantic_core
from importlib.metadata import version
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
assert rpds.HashTrieMap(a=1)['a'] == 1
k = AESGCM.generate_key(bit_length=256)
ct = AESGCM(k).encrypt(b'n', b'smoke', b'ad')
assert AESGCM(k).decrypt(b'n', ct, b'ad') == b'smoke'
print("SMOKE-OK gate3-rust 3 items:", version('rpds-py'), version('pydantic-core'))
PY
  mark verify3 "OK（3 items passed）"
fi

echo "== build-gate3-rust.sh [$STAGE] 完成"
