#!/usr/bin/env bash
# 门 2 包构建：28 包中的 24 件（15 纯 Python + 9 C/C++）交叉编译/装填到 OHOS aarch64
# 三层产物树（site-pkgs / extras / libs），供主工程 rawfile 双 zip + entry/libs 落位。
# Rust 三件（cryptography/pydantic-core/rpds-py）与 pypdfium2 属门 3，不在本脚本。
#
# Attribution: qemu+Alpine 目标解释器、meson cross file、setup.py 交叉形态、双层布局
#   与 sitecustomize 兜底 finder 机制取自 zhubowen-bot/Guncat-Work-for-hmos（Apache-2.0）
#   tooling/python/{build-numpy,build-pandas,build-pillow,build-matplotlib,build-lxml,
#   build-misc}-ohos.sh 与 local-pkgs/sitecustomize.py，取用日期 2026-11-07，
#   按本项目工厂环境变量与产物树约定改造；两处主动增强：
#   ① LDSHARED/link_args 预防性带 -Wl,--no-as-needed -lpython3.13（Guncat 真机 168 个
#     .so 缺 DT_NEEDED 被重链的教训，构建期直接带上省事后重链）；
#   ② 包清单与版本以 scripts/python-runtime/manifest.json 为冻结单源，本脚本内为副本。
#
# 机制要点（Guncat 真机实证，同门 0 脚本头注释 1~3 条 + 包构建专属）：
#   · setup.py/meson 内省须跑「目标解释器」—— Alpine minirootfs + qemu-aarch64 包装；
#   · hvigor 只收 libs 里的 .so 丢 .py —— C 包拆两层：.py/数据进 extras（真机解压成
#     真实目录；zipimport 下 os.path.exists 恒 False 的包如 tzdata 也必须进 extras）、
#     .so 连包目录树平铺 libs；
#   · 两层合体靠 extras 里的 sitecustomize.py（sys.meta_path 末尾兜底 finder，只对
#     「父包已加载、.so 不在父包目录」生效）；PYTHONPATH 铁则 = stdlib.zip : site-
#     packages.zip : extras目录 : libs（纯 py 层永远在 libs 之前）。
#
# 用法（GitHub Actions ubuntu；STAGE 决定跑到哪段，可单段重跑）:
#   SDK_NATIVE=<native 目录> G2_DIR=<g2 tarball 解开处> PY_DEPS_PREFIX=<基座 prefix> \
#   OUT_DIR=<三层产物树输出> STAGE=rootfs|pure|regex|cffi|kiwisolver|pillow|lxml|\
#   numpy|contourpy|pandas|matplotlib|bundle|verify bash build-packages.sh
set -euo pipefail

# ---- 版本冻结副本（单源 = scripts/python-runtime/manifest.json，2026-11-06 冻结）----
V_pip="26.3"                 V_setuptools="84.2.1"      V_wheel="0.48.0"
V_flit_core="4.2.0"          V_packaging="26.3"         V_pyparsing="3.3.3"
V_six="1.17.0"               V_et_xmlfile="2.0.0"       V_openpyxl="3.1.5"
V_python_dateutil="4.0.0"    V_typing_extensions="4.16.0" V_tzdata="2026.6"
V_fonttools="4.68.0"         V_cycler="0.12.1"          V_pycparser="3.12"
V_regex="2026.9.29"          V_cffi="2.1.1"             V_kiwisolver="1.5.1"
V_pillow="13.0.0"            V_lxml="6.1.3"             V_numpy="2.5.4"
V_contourpy="1.4.0"          V_pandas="3.1.1"           V_matplotlib="3.11.2"
CYTHON_VERSION="3.1.3"       # 目标侧 Cython（numpy/pandas/contourpy 生成期）

# ---- 环境变量 ----
SDK_NATIVE="${SDK_NATIVE:-}"
G2_DIR="${G2_DIR:-}"          # g2 tarball 解开处（host-bundle/ modules/ deps-libs/ …）
PY_DEPS_PREFIX="${PY_DEPS_PREFIX:-}"
OUT_DIR="${OUT_DIR:-$PWD/pkg-out}"
WORK="${WORK:-$HOME/ohos-py-pkgs}"
STAGE="${STAGE:-all}"
ROOTFS="$WORK/alpine-a64"

# ---- 外部状态校验（P0-1）----
[ -n "$SDK_NATIVE" ] || { echo "错误：未设置 SDK_NATIVE。" >&2; exit 1; }
[ -d "$SDK_NATIVE" ] || { echo "错误：SDK_NATIVE 不存在：$SDK_NATIVE。" >&2; exit 1; }
SYSROOT="$SDK_NATIVE/sysroot"
LLVM_BIN="$SDK_NATIVE/llvm/bin"
CLANG="$LLVM_BIN/aarch64-unknown-linux-ohos-clang"
CLANGXX="$LLVM_BIN/aarch64-unknown-linux-ohos-clang++"
STRIP="$LLVM_BIN/llvm-strip"
for f in "$CLANG" "$CLANGXX" "$STRIP"; do
  [ -e "$f" ] || { echo "错误：SDK 布局缺文件：$f。" >&2; exit 1; }
done
for tool in curl tar make ninja qemu-aarch64-static pkg-config; do
  command -v "$tool" >/dev/null 2>&1 || { echo "错误：宿主缺少命令：$tool（workflow 应预装）。" >&2; exit 1; }
done
if [ "$STAGE" != "rootfs" ] && [ ! -x "$ROOTFS/run-python.sh" ]; then
  echo "错误：rootfs 未就绪（$ROOTFS/run-python.sh 不存在）——先跑 STAGE=rootfs。" >&2
  exit 1
fi
mkdir -p "$WORK" "$OUT_DIR/site-pkgs" "$OUT_DIR/extras" "$OUT_DIR/libs"

RUN_PY="$ROOTFS/run-python.sh"
RUN_CY="$ROOTFS/run-cython.sh"
TGT_SITE="$ROOTFS/py/site"          # 目标侧 site（构建依赖 + 已编包的完整树，供后续包内省）
TGT_LIBS="$ROOTFS/py/ext"           # 目标侧扩展/依赖库平铺目录
PYINC="$ROOTFS/usr/local/include/python3.13"
PYLIB="$ROOTFS/usr/local/lib"

want() { [ "$STAGE" = "all" ] || [ "$STAGE" = "$1" ]; }

# ---- 记录红绿清单（bundle 汇总；numpy 红 = 硬失败即止损判据）----
STATUS_FILE="$WORK/pkg-status.txt"
touch "$STATUS_FILE"
mark() { echo "$1 $2" >> "$STATUS_FILE"; echo "== $1：$2"; }

fetch_sdist() {  # pkg ver —— 从 PyPI JSON API 取 sdist 并解包，输出目录名
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
    # sdist 顶层目录名可能有差异，实测对齐（sed -n 1p 全量读流，无 head 的 SIGPIPE 141 坑）
    [ -d "$dir" ] || { local got; got=$(python3 -c \
      "import tarfile;print(tarfile.open('$dir.tar.gz').getnames()[0].split('/')[0])"); mv "$got" "$dir"; }
  fi
  echo "$WORK/$dir"
}

# ================================================================
# STAGE rootfs：Alpine + 目标解释器 + wrapper + 目标侧构建依赖
# ================================================================
if want rootfs; then
  echo "== [rootfs] Alpine minirootfs + 目标 python 落位"
  [ -n "$G2_DIR" ] || { echo "错误：rootfs 阶段需要 G2_DIR（g2 tarball 解开处）。" >&2; exit 1; }
  if [ ! -x "$ROOTFS/lib/ld-musl-aarch64.so.1" ]; then
    rm -rf "$ROOTFS"; mkdir -p "$ROOTFS"
    curl -fsSL -o "$WORK/alpine-mini.tar.gz" \
      https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/aarch64/alpine-minirootfs-3.20.3-aarch64.tar.gz
    tar xzf "$WORK/alpine-mini.tar.gz" -C "$ROOTFS"
  fi
  mkdir -p "$ROOTFS/usr/local/bin" "$ROOTFS/usr/local/lib" "$ROOTFS/usr/local/include" \
           "$ROOTFS/py/site" "$ROOTFS/py/ext"
  cp -f "$G2_DIR/host-bundle/bin/python3.13" "$ROOTFS/usr/local/bin/"
  cp -f "$G2_DIR/host-bundle/lib/libpython3.13.so" "$ROOTFS/usr/local/lib/"
  rm -rf "$ROOTFS/usr/local/include/python3.13"
  cp -r "$G2_DIR/host-bundle/include/python3.13" "$ROOTFS/usr/local/include/python3.13"
  cp -f "$G2_DIR/python313.zip" "$ROOTFS/py/"
  cp -f "$G2_DIR/modules/"*.so "$TGT_LIBS/"
  cp -f "$G2_DIR/libz.so" "$TGT_LIBS/"
  for lib in "$G2_DIR"/deps-libs/*.so*; do cp -f "$lib" "$TGT_LIBS/"; done
  # numpy 等 C++ 扩展的 DT_NEEDED libc++_shared.so（OHOS clang++ 共享 libc++；bundle 段同件随包，
  # 第十跑探针实 qemu 构建期装载面也缺——不拷则 import/pandas 内省必挂）
  cp -f "$SDK_NATIVE/llvm/lib/aarch64-linux-ohos/libc++_shared.so" "$TGT_LIBS/"

  # qemu 冒烟环境的符号差集存根（Guncat 同法）：Alpine musl 与 OHOS musl 的差集——
  # backtrace 族（OHOS libc 有、标准 musl 无）+ __fd_chk（OHOS musl 私有 fd 加固符号，
  # select 扩展引用、sysroot libc 供给；首跑实 qemu relocation 失败）。import 冒烟只需
  # 符号可解析，不触发调用语义
  if [ ! -f "$TGT_LIBS/libexecinfo_stub.so" ]; then
    cat > "$WORK/execinfo-stub.c" <<'EOF'
#define _GNU_SOURCE
#include <stddef.h>
#include <stdarg.h>
#include <string.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/stat.h>
/* qemu 差集存根（Alpine musl 与 OHOS musl 的符号差集，真机 libc 全供给，仅冒烟兜底）：
   backtrace 族 + __fd_chk + OHOS fortify 加固符号族（签名 = sysroot fortify 头逐条
   实读；第八轮起 __strlen_chk/__open_chk 逐个冒，一次写齐 27 件——转发丢检查参数，
   转发调用加括号禁 fortify 宏再展开成自递归；ppoll/strnlen/memrchr 手写原型） */
int ppoll(struct pollfd *, nfds_t, const struct timespec *, const sigset_t *);
size_t strnlen(const char *, size_t);
void *memrchr(const void *, int, size_t);
int backtrace(void **b, int s) { (void) b; (void) s; return 0; }
char **backtrace_symbols(void *const *b, int s) { (void) b; (void) s; return NULL; }
void backtrace_symbols_fd(void *const *b, int s, int fd) { (void) b; (void) s; (void) fd; }
int __fd_chk(int fd) { return fd; }
int __open_chk(const char *p, int f) { return (open)(p, f); }
int __openat_chk(int d, const char *p, int f) { return (openat)(d, p, f); }
int __poll_chk(struct pollfd *f, nfds_t n, int t, size_t bos) { (void)bos; return (poll)(f, n, t); }
int __ppoll_chk(struct pollfd *f, nfds_t n, const struct timespec *ts, const sigset_t *sm, size_t bos) { (void)bos; return ppoll(f, n, ts, sm); }
mode_t __umask_chk(mode_t m) { return (umask)(m); }
char *__fgets_chk(char *b, int s, FILE *fp, size_t bos) { (void)bos; return (fgets)(b, s, fp); }
char *__getcwd_chk(char *b, size_t s, size_t bos) { (void)bos; return (getcwd)(b, s); }
size_t __fread_chk(void *p, size_t sz, size_t n, FILE *fp, size_t bos) { (void)bos; return (fread)(p, sz, n, fp); }
size_t __fwrite_chk(const void *p, size_t sz, size_t n, FILE *fp, size_t bos) { (void)bos; return (fwrite)(p, sz, n, fp); }
ssize_t __read_chk(int fd, void *b, size_t n, size_t bos) { (void)bos; return (read)(fd, b, n); }
ssize_t __write_chk(int fd, const void *b, size_t n, size_t bos) { (void)bos; return (write)(fd, b, n); }
ssize_t __pread_chk(int fd, void *b, size_t n, off_t o, size_t bos) { (void)bos; return (pread)(fd, b, n, o); }
ssize_t __pwrite_chk(int fd, const void *b, size_t n, off_t o, size_t bos) { (void)bos; return (pwrite)(fd, b, n, o); }
ssize_t __recv_chk(int fd, void *b, size_t n, size_t bos, int f) { (void)bos; return (recv)(fd, b, n, f); }
ssize_t __recvfrom_chk(int fd, void *b, size_t n, size_t bos, int f, struct sockaddr *a, socklen_t *l) { (void)bos; return (recvfrom)(fd, b, n, f, a, l); }
ssize_t __send_chk(int fd, const void *b, size_t n, size_t bos, int f) { (void)bos; return (send)(fd, b, n, f); }
ssize_t __sendto_chk(int fd, const void *b, size_t n, size_t bos, int f, const struct sockaddr *a, socklen_t l) { (void)bos; return (sendto)(fd, b, n, f, a, l); }
ssize_t __readlink_chk(const char *p, char *b, size_t s, size_t bos) { (void)bos; return (readlink)(p, b, s); }
ssize_t __readlinkat_chk(int d, const char *p, char *b, size_t s, size_t bos) { (void)bos; return (readlinkat)(d, p, b, s); }
char *__strchr_chk(const char *p, int c, size_t bos) { (void)bos; return (strchr)(p, c); }
char *__strrchr_chk(const char *p, int c, size_t bos) { (void)bos; return (strrchr)(p, c); }
size_t __strlcat_chk(char *d, const char *s, size_t n, size_t bos) { (void)bos; return (strlcat)(d, s, n); }
size_t __strlcpy_chk(char *d, const char *s, size_t n, size_t bos) { (void)bos; return (strlcpy)(d, s, n); }
size_t __strlen_chk(const char *s, size_t n) { return strnlen(s, n); }
void *__memchr_chk(const void *s, int c, size_t n, size_t bos) { (void)bos; return (memchr)(s, c, n); }
void *__memrchr_chk(const void *s, int c, size_t n, size_t bos) { (void)bos; return memrchr(s, c, n); }
/* __builtin___ 系外部符号形态（编译器未内联时落 PLT——第九轮 __memcpy_chk 实锤）；
   snprintf/sprintf 系 variadic 用 va 版承接（glibc 惯例含 flag/sl 两参） */
void *__memcpy_chk(void *d, const void *s, size_t n, size_t dl) { (void)dl; return (memcpy)(d, s, n); }
void *__memmove_chk(void *d, const void *s, size_t n, size_t dl) { (void)dl; return (memmove)(d, s, n); }
void *__mempcpy_chk(void *d, const void *s, size_t n, size_t dl) { (void)dl; return (mempcpy)(d, s, n); }
void *__memset_chk(void *d, int c, size_t n, size_t dl) { (void)dl; return (memset)(d, c, n); }
char *__stpcpy_chk(char *d, const char *s, size_t dl) { (void)dl; return (stpcpy)(d, s); }
char *__stpncpy_chk(char *d, const char *s, size_t n, size_t dl) { (void)dl; return (stpncpy)(d, s, n); }
char *__strcat_chk(char *d, const char *s, size_t dl) { (void)dl; return (strcat)(d, s); }
char *__strcpy_chk(char *d, const char *s, size_t dl) { (void)dl; return (strcpy)(d, s); }
char *__strncat_chk(char *d, const char *s, size_t n, size_t dl) { (void)dl; return (strncat)(d, s, n); }
char *__strncpy_chk(char *d, const char *s, size_t n, size_t dl) { (void)dl; return (strncpy)(d, s, n); }
int __snprintf_chk(char *str, size_t size, int flag, size_t sl, const char *fmt, ...) {
  va_list ap; va_start(ap, fmt);
  int r = (vsnprintf)(str, size, fmt, ap);
  va_end(ap); (void)flag; (void)sl; return r;
}
int __sprintf_chk(char *str, int flag, size_t sl, const char *fmt, ...) {
  va_list ap; va_start(ap, fmt);
  int r = (vsprintf)(str, fmt, ap);
  va_end(ap); (void)flag; (void)sl; return r;
}
int __vsnprintf_chk(char *str, size_t size, int flag, size_t sl, const char *fmt, va_list ap) { (void)flag; (void)sl; return (vsnprintf)(str, size, fmt, ap); }
int __vsprintf_chk(char *str, int flag, size_t sl, const char *fmt, va_list ap) { (void)flag; (void)sl; return (vsprintf)(str, fmt, ap); }
EOF
    "$CLANG" --sysroot="$SYSROOT" -shared -fPIC -O1 -o "$TGT_LIBS/libexecinfo_stub.so" "$WORK/execinfo-stub.c"
  fi

  cat > "$ROOTFS/run-python.sh" <<EOF
#!/bin/sh
export PYTHONHOME=$ROOTFS/usr/local
# 调用方（meson env 包装）传的 PYTHONPATH 前置保留——第七跑实锤 numpy 生成器
# env PYTHONPATH=<src>/numpy/_core 被 export 无条件覆盖 ⇒ code_generators 找不到
export PYTHONPATH=\${PYTHONPATH:+\$PYTHONPATH:}$ROOTFS/py/python313.zip:$TGT_SITE:$TGT_LIBS
export LD_LIBRARY_PATH=$PYLIB:$TGT_LIBS
export LD_PRELOAD=$TGT_LIBS/libexecinfo_stub.so
exec qemu-aarch64-static -L $ROOTFS $ROOTFS/usr/local/bin/python3.13 "\$@"
EOF
  cat > "$ROOTFS/run-cython.sh" <<EOF
#!/bin/sh
export PYTHONHOME=$ROOTFS/usr/local
export PYTHONPATH=\${PYTHONPATH:+\$PYTHONPATH:}$ROOTFS/py/python313.zip:$TGT_SITE:$TGT_LIBS
export LD_LIBRARY_PATH=$PYLIB:$TGT_LIBS
export LD_PRELOAD=$TGT_LIBS/libexecinfo_stub.so
exec qemu-aarch64-static -L $ROOTFS $ROOTFS/usr/local/bin/python3.13 -m cython "\$@"
EOF
  chmod +x "$ROOTFS"/run-python.sh "$ROOTFS"/run-cython.sh

  # 自检：目标解释器可跑、版本对、扩展可 import（rootfs 不通则后面全白搭）
  "$RUN_PY" -c "import sys, zlib, ssl, ctypes, ctypes.util; print('python', sys.version.split()[0], '| zlib/ssl/ctypes OK')" \
    || { echo "错误：目标解释器冒烟失败（查上方 qemu 输出）。" >&2; exit 1; }

  # 目标侧构建依赖（纯 py wheel 解进 TGT_SITE）：setuptools/wheel/packaging 供 setup.py，
  # Cython 供 run-cython，pybind11 头供 contourpy/matplotlib，cppy 供 kiwisolver，
  # setuptools_scm 供 matplotlib meson.build 的 run_command 内省，
  # versioneer 供 pandas generate_version.py（第八跑实锤目标解释器 import 失败），
  # meson-python 供 contourpy build 期查 importlib.metadata 版本（第十跑实锤目标侧缺 dist-info）
  if [ ! -d "$TGT_SITE/setuptools" ]; then
    for dep in "setuptools==$V_setuptools" "wheel==$V_wheel" "packaging==$V_packaging" \
               "Cython==$CYTHON_VERSION" "pybind11==3.0.1" "cppy==1.3.0" \
               "setuptools_scm==9.2.2" "flit-core==$V_flit_core" "versioneer==0.29" \
               "meson-python==0.22.1"; do
      python3 -m pip download "${dep%%=*}==${dep##*=}" --no-deps --only-binary=:all: \
        --python-version 3.13 --implementation py --abi none --platform any \
        -d "$WORK/tgt-whl" --quiet
    done
    python3 - "$WORK/tgt-whl" "$TGT_SITE" <<'PY'
import sys, zipfile, glob
for w in glob.glob(sys.argv[1] + '/*.whl'):
    with zipfile.ZipFile(w) as z:
        z.extractall(sys.argv[2])
PY
  fi
  # core→heavy 的 TGT_SITE 交接（yml 传 TGT_SITE_TAR 指向 core 的 tgt-site.tar.gz）：
  # 恢复必须在本段自举 rm -rf "$ROOTFS" 之后——第九跑实锤 yml 先恢复、自举连带清掉 py/site，
  # wheel 循环重装（日志 pip notice 实锤）而 numpy 等已编树蒸发 ⇒ pandas 内省必失败。
  # 放 wheel 解包之后 = core 终态覆盖 wheel 初装态，顺序即正确性。
  if [ -n "${TGT_SITE_TAR:-}" ] && [ -f "$TGT_SITE_TAR" ]; then
    tar -xzf "$TGT_SITE_TAR" -C "$ROOTFS/py"
    echo "== heavy 探针：TGT_SITE=$(ls "$TGT_SITE" | tr '\n' ' ')" >&2
    "$RUN_PY" -c "import sys, numpy; print('probe-ok', numpy.__version__, file=sys.stderr)" \
      || echo "!! heavy 探针失败：恢复态 numpy 不可 import（装载链断了）" >&2
  fi
  mark rootfs "OK（python3.13 + zlib/ssl/ctypes 冒烟过）"
fi

# ================================================================
# STAGE pure：纯 Python 15 件 vendor（tzdata 落 extras 数据层）
# ================================================================
if want pure; then
  echo "== [pure] 纯 Python 15 件 vendor"
  PURE_ALL="pip setuptools wheel flit-core packaging pyparsing six et-xmlfile openpyxl \
python-dateutil typing-extensions tzdata fonttools cycler pycparser"
  for pkg in $PURE_ALL; do
    var="V_$(echo "$pkg" | tr - _)"
    ver="${!var}"
    dst="$OUT_DIR/site-pkgs"
    [ "$pkg" = "tzdata" ] && dst="$OUT_DIR/extras"   # 数据文件包进 extras（真实目录语义）
    if [ -d "$dst/$(echo "$pkg" | tr - _)" ] || [ -d "$dst/$pkg" ]; then
      echo "  跳过 $pkg $ver（已在场）"; continue
    fi
    rm -rf "$WORK/pure-whl"; mkdir -p "$WORK/pure-whl"
    python3 -m pip download "$pkg==$ver" --no-deps --only-binary=:all: \
      --python-version 3.13 --implementation py --abi none --platform any \
      -d "$WORK/pure-whl" --quiet
    python3 - "$WORK/pure-whl" "$dst" <<'PY'
import sys, zipfile, glob
for w in glob.glob(sys.argv[1] + '/*.whl'):
    with zipfile.ZipFile(w) as z:
        z.extractall(sys.argv[2])
PY
    echo "  $pkg $ver → $dst"
  done
  mark pure "OK（15 件；tzdata 在 extras）"
fi

# ================================================================
# setuptools 系公共形态（qemu 跑 setup.py，LDSHARED 预防性带 DT_NEEDED libpython）
# ================================================================
setup_env() {
  export CC="$CLANG"
  export CXX="$CLANGXX"
  export AR="$LLVM_BIN/llvm-ar"
  # ★ -Wl,--no-as-needed -lpython3.13：Guncat 真机 168 .so 缺 DT_NEEDED 的教训，
  #   链接期直接带上（libpython 在 PYLIB，设备运行期由应用 lib 目录解析同名文件）
  export LDSHARED="$CLANG -shared -fuse-ld=lld -L$PYLIB -Wl,--no-as-needed -lpython3.13"
  export CFLAGS="-O2 -fPIC -I$PYINC -I$PY_DEPS_PREFIX/include"
  export CXXFLAGS="-O2 -fPIC -I$PYINC -I$PY_DEPS_PREFIX/include"
  export LDFLAGS="-fuse-ld=lld -L$PYLIB -L$PY_DEPS_PREFIX/lib"
  # lxml 等 setup.py 的 pkg-config 探测（libxml2/libxslt 在基座 prefix；首跑实锤
  # setup 段缺这两行 → 「Please make sure the libxml2 and libxslt development
  # packages are installed」）
  export PKG_CONFIG_LIBDIR="$WORK/pkgconfig:$PY_DEPS_PREFIX/lib/pkgconfig"
  # pybind11 的 .pc 随 wheel 落在 TGT_SITE 包树内（pybind11/share/pkgconfig，prefix 可重定位）
  # ——不进搜索路径则 contourpy/matplotlib 的 meson 探测必失败（第八跑实锤）
  export PKG_CONFIG_PATH="$WORK/pkgconfig:$TGT_SITE/pybind11/share/pkgconfig"
  export MAX_CONCURRENCY="$(nproc)"
}

# build_setup_pkg <名> <版本> [额外 setup.py 参数…]
# 产物拆两层：源码树包目录的 *.so → libs/<包树>；其余（.py/数据）→ extras/<包树>；
# 同时整树拷进 TGT_SITE 供后续包构建期 import。
build_setup_pkg() {
  local name="$1" ver="$2"; shift 2
  local dir
  dir="$(fetch_sdist "$name" "$ver")"
  local top
  top=$(basename "$dir")
  (
    cd "$dir"
    setup_env
    rm -rf build
    # build_clib 必须显式列命令：build_ext 只从 build_clib「借」库名与 -L 目录（get_finalized_command
    # 仅定参不执行），setup 级 libraries= 声明的静态库要 build_clib 真跑才生成——第六跑实锤
    # pillow 13 的 libpil_imaging_mode.a 缺席致 ld.lld unable to find library；无 libraries= 的包空跑无害
    "$RUN_PY" setup.py build_clib build_ext --inplace "$@" > "$WORK/$top-build.log" 2>&1
  ) || {
    mark "$name" "红（构建失败，日志 $WORK/$top-build.log）"
    echo "== $name build.log 尾 40 行 ==" >&2
    tail -40 "$WORK/$top-build.log" >&2 || true
    return 1
  }
  python3 - "$dir" "$OUT_DIR" "$name" "$TGT_SITE" <<'PY'
import os, shutil, sys
src, out, name, tgt = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
# import 名 ≠ 项目名走别名表（pillow→PIL，第七跑实锤定位器找不到包目录；其余包两名一致）
alias = {'pillow': 'PIL'}
want = alias.get(name.lower(), name.lower().replace('-', '_')).lower()
# 定位包目录（setup.py 同级的 src/<pkg>/ 或 <pkg>/）
pkg_dirs = []
for root, dirs, _ in os.walk(src):
    rel = os.path.relpath(root, src)
    parts = rel.split(os.sep)
    if (parts[0] == 'src' and len(parts) == 2) or len(parts) == 1:
        for d in list(dirs):
            init = os.path.join(root, d, '__init__.py')
            if os.path.exists(init) and d.lower().replace('-', '_') == want:
                pkg_dirs.append(os.path.join(root, d))
    dirs[:] = [d for d in dirs if d not in ('build', 'dist', '__pycache__', '.git')]
if not pkg_dirs:
    print('错误：找不到包目录', name); sys.exit(1)
pd = pkg_dirs[0]
# 0) 顶层扩展 .so 平铺（不属于任何包目录的模块，如 cffi 的 _cffi_backend，只拷包目录
#    会整个丢掉——第十三跑实锤）。候选 = 源码根 + src/（package_dir={"":"src"} 的包把顶层
#    扩展 inplace 到 src/ 而非源码根——cffi 1.17.1 即此形态，第十四跑实锤根目录无 .so）
os.makedirs(os.path.join(out, 'libs'), exist_ok=True)
top_exts = []
for base in (src, os.path.join(src, 'src')):
    if not os.path.isdir(base):
        continue
    for f in sorted(os.listdir(base)):
        p = os.path.join(base, f)
        if f.endswith('.so') and os.path.isfile(p):
            top_exts.append(p)
            shutil.copy2(p, os.path.join(out, 'libs', f))
            # TGT_SITE 根同步（后续包构建期 import 该顶层模块要用）
            shutil.copy2(p, os.path.join(tgt, f))
            print('顶层扩展平铺', f)
# 1) .so 树 → libs（包目录形态保留）
dst_libs = os.path.join(out, 'libs', os.path.basename(pd))
shutil.rmtree(dst_libs, ignore_errors=True)
shutil.copytree(pd, dst_libs, ignore=shutil.ignore_patterns('__pycache__'))
# 2) 全树去 .so → extras
dst_extras = os.path.join(out, 'extras', os.path.basename(pd))
shutil.rmtree(dst_extras, ignore_errors=True)
shutil.copytree(pd, dst_extras, ignore=shutil.ignore_patterns('__pycache__'))
for root, dirs, files in os.walk(dst_extras):
    for f in files:
        if f.endswith('.so') or f.endswith(('.pyx', '.pxd', '.c', '.h')):
            os.remove(os.path.join(root, f))
# 3) 完整树 → TGT_SITE（后续包构建期 import 用）
dst_tgt = os.path.join(tgt, os.path.basename(pd))
shutil.rmtree(dst_tgt, ignore_errors=True)
shutil.copytree(pd, dst_tgt, ignore=shutil.ignore_patterns('__pycache__'))
print('已拆层', name)
PY
  find "$OUT_DIR/libs/$(echo "$name" | tr - _)" "$OUT_DIR/libs/$name" -name '*.so' -exec "$STRIP" --strip-unneeded {} \; 2>/dev/null || true
  mark "$name" "绿"
}

if want regex; then
  build_setup_pkg regex "$V_regex" || true
fi
if want cffi; then
  # cffi 构建要 pycparser（纯 py 已在 TGT_SITE——setup.py 在目标解释器里跑时可见）
  build_setup_pkg cffi "$V_cffi" || true
fi
if want kiwisolver; then
  build_setup_pkg kiwisolver "$V_kiwisolver" || true
fi
if want pillow; then
  # JPEG/PNG/ZLIB_ROOT 必须在 build_setup_pkg 的构建子进程里可见——直接 export（勿用子 shell）
  export JPEG_ROOT="$PY_DEPS_PREFIX" PNG_ROOT="$PY_DEPS_PREFIX" ZLIB_ROOT="$PY_DEPS_PREFIX"
  # pillow 必须从 PyPI sdist 取（与 lxml 同理：GitHub 树要现场 Cython 生成）
  # --disable-platform-guessing 防 host 的 /usr/include 混入（Guncat 实证坑）
  if build_setup_pkg pillow "$V_pillow" --disable-platform-guessing; then
    for lib in libjpeg.so.62 libpng16.so.16; do
      cp -f "$PY_DEPS_PREFIX/lib/$lib" "$OUT_DIR/libs/"
      "$STRIP" --strip-unneeded "$OUT_DIR/libs/$lib" 2>/dev/null || true
    done
  fi
  unset JPEG_ROOT PNG_ROOT ZLIB_ROOT
fi
if want lxml; then
  if build_setup_pkg lxml "$V_lxml"; then
    for lib in libxml2.so.2 libxslt.so.1 libexslt.so.0; do
      cp -f "$PY_DEPS_PREFIX/lib/$lib" "$OUT_DIR/libs/"
      "$STRIP" --strip-unneeded "$OUT_DIR/libs/$lib" 2>/dev/null || true
    done
  fi
fi

# ================================================================
# meson 系公共形态（vendored/宿主 meson + cross file，目标解释器做内省）
# ================================================================
MESON_CROSS="$WORK/cross-pkgs.txt"
write_cross_file() {
  mkdir -p "$WORK/pkgconfig"
  # numpy 系 vendored meson 的 cython 语言探测只认 PATH（cross file 的 [binaries]
  # cython 条目不进探测列表，首跑实锤 Unknown compiler(s): [['cython'],['cython3']]）
  # ——把 run-cython.sh 链接成 PATH 可见的 cython，build_meson_pkg 子 shell 前置此目录
  mkdir -p "$WORK/bin"
  ln -sf "$RUN_CY" "$WORK/bin/cython"
  cat > "$WORK/pkgconfig/python-3.13.pc" <<EOF
prefix=$ROOTFS/usr/local
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include/python3.13

Name: Python
Description: Python library
Version: 3.13
Libs: -L\${libdir} -lpython3.13
Cflags: -I\${includedir}
EOF
  for n in python3 python3-embed python-3.13-embed; do
    cp -f "$WORK/pkgconfig/python-3.13.pc" "$WORK/pkgconfig/$n.pc"; done
  cat > "$MESON_CROSS" <<EOF
[binaries]
c = '$CLANG'
cpp = '$CLANGXX'
ar = '$LLVM_BIN/llvm-ar'
strip = '$STRIP'
pkgconfig = '/usr/bin/pkg-config'
python = '$RUN_PY'
cython = '$RUN_CY'

[host_machine]
system = 'linux'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'

[properties]
needs_exe_wrapper = true
longdouble_format = 'IEEE_QUAD_LE'
# ★ DT_NEEDED libpython 预防（同 setuptools 系注释）
c_link_args = ['-L$PYLIB', '-Wl,--no-as-needed', '-lpython3.13', '-L$PY_DEPS_PREFIX/lib']
cpp_link_args = ['-L$PYLIB', '-Wl,--no-as-needed', '-lpython3.13', '-L$PY_DEPS_PREFIX/lib']
c_args = ['-I$PY_DEPS_PREFIX/include', '-I$PYINC']
cpp_args = ['-I$PY_DEPS_PREFIX/include', '-I$PYINC']
EOF
}

# meson 入口：numpy 用自带 vendored meson（features 模块私有依赖），其余用宿主 meson
meson_cmd() {  # <源码目录>
  local src="$1"
  if [ -f "$src/vendored-meson/meson/meson.py" ]; then
    echo "python3 $src/vendored-meson/meson/meson.py"
  else
    echo "meson"
  fi
}

# build_meson_pkg <名> <版本> [额外 meson 选项…]
# 产物拆层同 setuptools 系（install 树的 site-packages/<pkg> 为源）。
build_meson_pkg() {
  local name="$1" ver="$2"; shift 2
  local dir
  dir="$(fetch_sdist "$name" "$ver")"
  local top
  top=$(basename "$dir")
  local mc
  mc="$(meson_cmd "$dir")"
  write_cross_file
  (
    cd "$dir"
    export PATH="$WORK/bin:$PATH"
    rm -rf builddir
    # 内联 env 曾与 setup_env 双源漂移（第九跑实锤 setup_env 加了 pybind11 路径此处没跟，
    # meson 探测仍红）——改引 setup_env 的同名展开，保单源；此处必须留 PKG_CONFIG_ALLOW_CROSS
    PKG_CONFIG_LIBDIR="$WORK/pkgconfig:$PY_DEPS_PREFIX/lib/pkgconfig" \
    PKG_CONFIG_PATH="$WORK/pkgconfig:$TGT_SITE/pybind11/share/pkgconfig" PKG_CONFIG_ALLOW_CROSS=1 \
      $mc setup builddir --cross-file "$MESON_CROSS" \
      --prefix="$WORK/meson-prefix-$top" -Dbuildtype=release "$@" \
      > "$WORK/$top-meson-setup.log" 2>&1
    $mc compile -C builddir -j "$(nproc)" > "$WORK/$top-meson-build.log" 2>&1
    rm -rf "$WORK/meson-dest-$top"
    DESTDIR="$WORK/meson-dest-$top" $mc install -C builddir > "$WORK/$top-meson-install.log" 2>&1
  ) || {
    mark "$name" "红（meson 失败：setup/build/install 三段日志在 $WORK/$top-meson-*.log）"
    for ph in setup build install; do
      echo "== $name meson-$ph.log 尾 30 行 ==" >&2
      tail -30 "$WORK/$top-meson-$ph.log" >&2 2>/dev/null || true
    done
    return 1
  }
  python3 - "$WORK/meson-dest-$top" "$OUT_DIR" "$name" "$TGT_SITE" "$STRIP" <<'PY'
import glob, os, shutil, subprocess, sys
dest, out, name, tgt, strip = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
sps = glob.glob(os.path.join(dest, '**', 'site-packages'), recursive=True)
if not sps:
    print('错误：install 树无 site-packages'); sys.exit(1)
sp = sps[0]
import_name = name.replace('-', '_')
src_pkg = None
for cand in (os.path.join(sp, import_name), os.path.join(sp, name)):
    if os.path.isdir(cand):
        src_pkg = cand; break
if src_pkg is None:
    print('错误：install 树里找不到包目录', name, os.listdir(sp)); sys.exit(1)
base = os.path.basename(src_pkg)
dst_libs = os.path.join(out, 'libs', base)
shutil.rmtree(dst_libs, ignore_errors=True)
shutil.copytree(src_pkg, dst_libs, ignore=shutil.ignore_patterns('__pycache__'))
for root, dirs, files in os.walk(dst_libs):
    for f in files:
        if f.endswith('.so'):
            subprocess.run([strip, '--strip-unneeded', os.path.join(root, f)],
                           capture_output=True)
dst_extras = os.path.join(out, 'extras', base)
shutil.rmtree(dst_extras, ignore_errors=True)
shutil.copytree(src_pkg, dst_extras, ignore=shutil.ignore_patterns('__pycache__'))
for root, dirs, files in os.walk(dst_extras):
    for f in files:
        if f.endswith('.so') or f.endswith(('.pyx', '.pxd')):
            os.remove(os.path.join(root, f))
dst_tgt = os.path.join(tgt, base)
shutil.rmtree(dst_tgt, ignore_errors=True)
shutil.copytree(src_pkg, dst_tgt, ignore=shutil.ignore_patterns('__pycache__'))
print('已拆层', name)
PY
  mark "$name" "绿"
}

if want numpy; then
  # 止损线判据（方案 §6.1 闲 1）：numpy 不绿即整批停——这里失败不吞，硬退
  # BLAS=none 首版（OpenBLAS 接入第二轮重编；真机 BLAS=none 性能面登记）
  if ! build_meson_pkg numpy "$V_numpy" -Dblas=none -Dlapack=none -Dallow-noblas=true; then
    echo "错误：numpy 构建失败 —— 门 2 止损线命中（方案 §6.1 闲 1），整批停机登记。" >&2
    exit 3
  fi
  # 探针（第九跑 heavy 段 pandas 内省 import numpy 失败但 tgt-site 树完整，矛盾待定位）：
  # core 侧拆层完成后立即用同一 run-python.sh 冒烟 import，对照 heavy 段结果二分归因
  echo "== numpy 探针：run-python.sh -c 'import numpy'" >&2
  "$RUN_PY" -c "import sys, numpy; print('probe-ok', numpy.__version__, numpy.get_include(), file=sys.stderr)" \
    || echo "!! 探针失败：core 侧 TGT_SITE 的 numpy 不可 import（与 heavy 段同病 = 树本身问题）" >&2
fi
if want contourpy; then
  build_meson_pkg contourpy "$V_contourpy" || true
fi
if want pandas; then
  # pandas 的 Cython cimport numpy 找不到 .pxd —— 把 TGT_SITE 里 numpy 的 .pxd 按树形
  # 复制到 pandas 源码根（Guncat 同法：只拷 *.pxd，整树拷会污染源码根）
  dir="$(fetch_sdist pandas "$V_pandas")"
  if [ -d "$TGT_SITE/numpy" ] && [ ! -e "$dir/numpy" ]; then
    ( cd "$TGT_SITE/numpy" && find . -name '*.pxd' | while read -r f; do
        mkdir -p "$dir/numpy/$(dirname "$f")"
        cp -f "$TGT_SITE/numpy/$f" "$dir/numpy/$f"
      done )
  fi
  build_meson_pkg pandas "$V_pandas" || true
fi
if want matplotlib; then
  # freetype/qhull 走基座 pkg-config（-Dsystem-*=true 防 meson 拉 subproject）
  # setuptools_scm 版本探测已在目标侧 site；若 run_command 失败按日志把 meson.build
  # 版本行换字面版本号（Guncat 坑 3，迭代时处置）
  if build_meson_pkg matplotlib "$V_matplotlib" -Dsystem-freetype=true -Dsystem-qhull=true; then
    for lib in libfreetype.so.6 libqhull_r.so.8.0; do
      cp -f "$PY_DEPS_PREFIX/lib/$lib" "$OUT_DIR/libs/"
      "$STRIP" --strip-unneeded "$OUT_DIR/libs/$lib" 2>/dev/null || true
    done
    # mpl_toolkits 随 extras（Guncat：漏了 3D 投影不可用）
    :
  fi
fi

# ================================================================
# STAGE bundle：汇总 + sitecustomize + CPython 扩展/依赖库平铺 + 字节数表
# ================================================================
if want bundle; then
  echo "== [bundle] 汇总三层树"
  [ -n "$G2_DIR" ] || { echo "错误：bundle 需要 G2_DIR。" >&2; exit 1; }
  # CPython 扩展全家 + libz + deps-libs 平铺进 libs（与包 .so 树同目录——设备 dlopen 面）
  cp -fn "$G2_DIR/modules/"*.so "$OUT_DIR/libs/" 2>/dev/null || true
  cp -fn "$G2_DIR/libz.so" "$OUT_DIR/libs/" 2>/dev/null || true
  for lib in "$G2_DIR"/deps-libs/*.so*; do cp -fn "$lib" "$OUT_DIR/libs/" 2>/dev/null || true; done
  # 基座运行库（pillow/lxml/matplotlib/OpenBLAS 的 DT_NEEDED 对象）随包平铺
  for lib in libpng16.so.16 libjpeg.so.62 libxml2.so.2 libxslt.so.1 libexslt.so.0 \
             libfreetype.so.6 libqhull_r.so.8.0 libopenblas.so; do
    [ -s "$PY_DEPS_PREFIX/lib/$lib" ] && cp -fn "$PY_DEPS_PREFIX/lib/$lib" "$OUT_DIR/libs/" || true
  done
  # numpy.fft 的 pocketfft 是 C++（Guncat：libc++_shared.so 随包）
  if [ -f "$SDK_NATIVE/llvm/lib/aarch64-linux-ohos/libc++_shared.so" ]; then
    cp -fn "$SDK_NATIVE/llvm/lib/aarch64-linux-ohos/libc++_shared.so" "$OUT_DIR/libs/"
    "$STRIP" --strip-unneeded "$OUT_DIR/libs/libc++_shared.so" 2>/dev/null || true
  fi
  # sitecustomize：双层布局合体 finder（Guncat local-pkgs/sitecustomize.py 改 3.13 判据）
  cat > "$OUT_DIR/extras/sitecustomize.py" <<'EOF'
"""纯 Python 包在数据目录、C 扩展在应用 lib 目录的两半合体（Guncat Apache-2.0 机制，3.13 适配）。

hvigor 打包只保留 libs/ 里的 .so（.py 被丢），C 扩展包只能拆两层：.py/数据进 extras
（首启解压成真实目录），.so 留 libs。默认 import 找不到这种跨目录的包——本 finder 挂
sys.meta_path 末尾兜底：只对「父包已加载、但 .so 不在父包目录」的情况生效。
"""
from __future__ import annotations

import importlib.machinery
import importlib.util
import os
import sys


def _looks_like_libdir(path: str) -> bool:
    try:
        names = os.listdir(path)
    except OSError:
        return False
    if "libpython3.13.so" in names:
        return True
    # 后缀必须按运行解释器自身的 EXTENSION_SUFFIXES 判——第十二跑实锤硬编码 GNU 三元组
    # （cpython-313-aarch64-linux-gnu.so）与 g2 实际命名（cpython-313.so 无三元组）错位，
    # _LIBDIR 恒空 → finder 整个不装 → 双层布局的 C 扩展全断
    return any(n.endswith(tuple(importlib.machinery.EXTENSION_SUFFIXES)) for n in names)


def _find_libdir() -> str:
    candidates = [e for e in sys.path if e and os.path.isdir(e) and _looks_like_libdir(e)]
    return candidates[0] if candidates else ""


_LIBDIR = _find_libdir()
if _LIBDIR and _LIBDIR not in sys.path:
    sys.path.append(_LIBDIR)


class _LibsExtensionFinder:
    """按完整模块名在 lib 目录里找扩展模块（PathFinder 失败后的兜底）。"""

    @staticmethod
    def find_spec(fullname, path=None, target=None):
        if not _LIBDIR or not path:
            return None
        parts = fullname.split(".")
        base = os.path.join(_LIBDIR, *parts)
        for suffix in importlib.machinery.EXTENSION_SUFFIXES:
            candidate = base + suffix
            if os.path.isfile(candidate):
                loader = importlib.machinery.ExtensionFileLoader(fullname, candidate)
                return importlib.util.spec_from_file_location(fullname, candidate, loader=loader)
        return None

    @staticmethod
    def invalidate_caches():
        return None


if _LIBDIR:
    if not any(getattr(f, "__name__", "") == "_LibsExtensionFinder" for f in sys.meta_path):
        sys.meta_path.append(_LibsExtensionFinder())
EOF
  # 产出 site-packages.zip 与 extras.zip（均 -0 存储，机制坑 C）
  ( cd "$OUT_DIR/site-pkgs" && rm -f "$OUT_DIR/site-packages.zip" && zip -qr0 "$OUT_DIR/site-packages.zip" . )
  ( cd "$OUT_DIR/extras" && find . -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null || true
    rm -f "$OUT_DIR/extras.zip" && zip -qr0 "$OUT_DIR/extras.zip" . )
  echo "== 三层产物字节数表"
  ls -l "$OUT_DIR/site-packages.zip" "$OUT_DIR/extras.zip" | awk '{printf "%12d B  %s\n", $5, $9}'
  echo "libs/ .so 数：$(find "$OUT_DIR/libs" -name '*.so*' | wc -l)"
  echo "== 包红绿清单："
  cat "$STATUS_FILE"
  mark bundle "OK"
fi

# ================================================================
# STAGE verify：qemu 按真机布局组装并冒烟（构建绿 ≠ 可用，此为打包前门槛）
# ================================================================
if want verify; then
  echo "== [verify] 按真机布局冒烟（stdlib.zip : site-packages.zip : extras : libs）"
  VWORK="$WORK/verify-env"
  rm -rf "$VWORK"; mkdir -p "$VWORK/site" "$VWORK/extras" "$VWORK/libs"
  cp -f "$OUT_DIR/site-packages.zip" "$VWORK/"
  ( cd "$VWORK/extras" && unzip -qo "$OUT_DIR/extras.zip" )
  cp -fr "$OUT_DIR/libs/"* "$VWORK/libs/"
  cat > "$VWORK/run-verify.sh" <<EOF
#!/bin/sh
export PYTHONHOME=$ROOTFS/usr/local
export PYTHONPATH=$ROOTFS/py/python313.zip:$VWORK/site-packages.zip:\$PWD/extras:\$PWD/libs
# \$PWD 必须运行期展开——第十一跑实锤写入期展开成仓库根（不存在的 libs），ld.so 落默认路径
# 加载 alpine minirootfs 自带旧 libcrypto（apk-tools 依赖）⇒ _ssl 重定位 COMP_get_type 失败
export LD_LIBRARY_PATH=\$PWD/libs
export LD_PRELOAD=$ROOTFS/py/ext/libexecinfo_stub.so
exec qemu-aarch64-static -L $ROOTFS $ROOTFS/usr/local/bin/python3.13 "\$@"
EOF
  chmod +x "$VWORK/run-verify.sh"
  # PYTHONPATH 顺序铁则（Guncat 实证）：stdlib.zip : site-packages.zip : extras : libs
  # —— 纯 py 层永远在 libs 之前，否则 import 命中 libs 里只有 .so 的空壳目录
  cat > "$VWORK/smoke_all.py" <<'EOF'
import sys
ok = []
def check(name, fn):
    r = fn()
    # 旧版只把调用次数计入 ok：函数返回 False/None/0 也照样 print("ok") 并凑满 17 项
    # ——恒绿判据（本轮自检发现）。逐项判真值，假值立即抛 → qemu 进程非零 → exit 4
    if not r:
        raise AssertionError(name + " 返回假值：" + repr(r))
    ok.append((name, r))
    print("ok", name, r)
def _stdlib_exts():
    import zlib, ssl, ctypes  # noqa: F401（sqlite3 未编，不在 28 包闭包——Guncat 有、本项目未供给）
    return ssl.OPENSSL_VERSION
def _png_roundtrip():
    from PIL import Image
    import io
    img = Image.new("RGB", (32, 32), (255, 0, 0))
    buf = io.BytesIO(); img.save(buf, "PNG"); buf.seek(0)
    return Image.open(buf).size
def _mpl_png():
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    fig, ax = plt.subplots()
    ax.plot([1, 2, 3], [1, 4, 9])
    fig.savefig("/tmp/mpl-smoke.png", dpi=40)
    import os
    return os.path.getsize("/tmp/mpl-smoke.png") > 0
def _cffi():
    import cffi
    return cffi.FFI().sizeof("int")
def _lxml_etree():
    # __import__("lxml.etree") 返回顶层 lxml 包而非子模块（第十五跑实锤 lxml-parse 报
    # 'lxml' has no attribute 'fromstring'——冒烟脚本自身缺陷，非产品问题）
    from importlib import import_module
    return import_module("lxml.etree")
check("zlib-ssl-ctypes", _stdlib_exts)
check("openpyxl", lambda: __import__("openpyxl").__version__)
check("dateutil", lambda: __import__("dateutil").__version__)
check("fonttools", lambda: __import__("fontTools").version)
check("numpy", lambda: __import__("numpy").__version__)
check("numpy-arange-sum", lambda: __import__("numpy").arange(12).reshape(3, 4).sum())
check("pandas", lambda: __import__("pandas").__version__)
check("pandas-groupby", lambda: int(__import__("pandas").DataFrame(
    {"c": ["a", "b", "a"], "v": [1, 2, 3]}).groupby("c")["v"].sum()["a"]))
check("pillow", lambda: __import__("PIL").__version__)
check("pillow-png-roundtrip", lambda: _png_roundtrip())
check("regex-han", lambda: bool(__import__("regex").search(r"\p{Han}+", "中文测试")))
check("cffi-ffi-sizeof", lambda: _cffi())
check("kiwisolver", lambda: __import__("kiwisolver").__version__)
check("contourpy", lambda: __import__("contourpy").__version__)
check("matplotlib-agg", lambda: _mpl_png())
check("lxml-xpath", lambda: _lxml_etree().__version__)
check("lxml-parse", lambda: _lxml_etree().fromstring(b"<a x='1'/>").get("x"))
if len(ok) != 17:
    raise SystemExit("SMOKE-FAIL 仅 %d 项通过，应有 17 项" % len(ok))
print("SMOKE-OK", len(ok), "items passed")
EOF
  ( cd "$VWORK" && ./run-verify.sh smoke_all.py ) \
    || { echo "错误：qemu 冒烟失败（真机布局下有包不可用）——见上方 FAIL 行。" >&2; exit 4; }
  mark verify "OK"
fi

echo "== build-packages.sh [$STAGE] 完成"
