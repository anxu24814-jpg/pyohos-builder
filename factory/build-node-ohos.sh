#!/usr/bin/env bash
# 门 0 构建脚本：交叉编译 Node v24.22.3 → OHOS aarch64 的 libnode.so（--shared 嵌入形态）
# + npm 文件集 + 嵌入头文件集，产物六件自校验（任务书 docs/任务书-鸿蒙Node运行时门0-20261121.md
# §3/§4 U2.3/§7 判据全命令化）。
#
# 配方出处：lzzhij/harmonyos-node-notes（CC BY 4.0）真机先例配方，经
# docs/调研-鸿蒙Node运行时构建路线-20261120.md §3.1 原文核对；骨架抄本项目
# scripts/python-runtime/factory/build-native-deps.sh（ERR trap + 分段 + 自校验风格）。
# 注意：先例配方的 --v8-disable-temporal-support 在 v24.22.3 已无此开关——configure 将
# 未知参透传给 gyp 直接硬红（首跑 run 44776777547 实锤，2026-11-21 修），已从配方删除；
# Temporal 支持在 v24 系现为树内默认态，无需开关。
#
# yml 只做取 SDK/源码与调本脚本（build-node.yml）；本脚本承担任务书 §4 步骤 b（探针）、
# d（configure+make）、e（产物六件）、f（runner 校验）。
#
# 用法（GitHub Actions ubuntu-24.04）:
#   SDK_NATIVE=<Linux SDK 的 native 目录> \
#   NODE_SRC=<解压后的 node 源码树> \
#   OUT_DIR=<产物输出目录> \
#   NODE_TARBALL_SHA256=<源码 tarball 的 sha256（yml 下载步实算，进 manifest）> \
#   bash factory/build-node-ohos.sh
set -euo pipefail

# ---- 冻结版本（单源 = scripts/node-runtime/manifest.json，此处为冻结副本）----
NODE_VERSION="24.22.3"
NPM_VERSION_FALLBACK="11.19.1"     # 仅 deps/npm/package.json 读不出时兜底
EPOCH="g1"
ARTIFACT_BASE="node-ohos-${NODE_VERSION}-aarch64-${EPOCH}"

# ---- 环境变量 ----
SDK_NATIVE="${SDK_NATIVE:-}"
NODE_SRC="${NODE_SRC:-}"
OUT_DIR="${OUT_DIR:-}"
NODE_TARBALL_SHA256="${NODE_TARBALL_SHA256:-}"
LOGS=""  # 在外部状态校验后初始化（logs 挂在 OUT_DIR 下，随 artifact 留诊断面）

# ---- 外部状态校验（P0-1）----
if [ -z "$SDK_NATIVE" ] || [ -z "$NODE_SRC" ] || [ -z "$OUT_DIR" ]; then
  echo "错误：未设置 SDK_NATIVE / NODE_SRC / OUT_DIR 环境变量（见文件头注释用法）。" >&2
  exit 1
fi
for d in "$SDK_NATIVE" "$NODE_SRC"; do
  if [ ! -d "$d" ]; then
    echo "错误：目录不存在：$d。" >&2
    exit 1
  fi
done
if [ ! -f "$NODE_SRC/src/node_version.h" ]; then
  echo "错误：$NODE_SRC 不是 node 源码树（缺 src/node_version.h）——yml 取源码步应已解压并核对版本。" >&2
  exit 1
fi
for tool in python3 make gcc g++ tar file sha256sum; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "错误：宿主缺少命令：$tool。" >&2
    exit 1
  fi
done

mkdir -p "$OUT_DIR" "$OUT_DIR/logs"
LOGS="$OUT_DIR/logs"

# ---- ERR trap：任一步失败即打印最新日志尾 30 行（build-native-deps.sh 同款）----
on_err() {
  local latest
  latest=$(ls -t "$LOGS" 2>/dev/null | head -1)
  if [ -n "$latest" ]; then
    echo "==== 构建失败，$latest 尾部 30 行 ====" >&2
    tail -30 "$LOGS/$latest" >&2 || true
  fi
}
trap on_err ERR

log() { echo "== $* "; }

# ================= b. 探针步（llvm 目录布局 + clang 版本 + 包装器定位）=================
# SDK 布局预期 = Python 工厂实测 native/llvm/（无版本号段，build-native-deps.sh:62-63）；
# lzzhij 先例布局含 llvm-19（带版本号段）——两种都探，实测定路径（ohos-node-doctor 无
# SDK 布局判据，其体检对象是工程产物而非 SDK，见 yml 头注释 doctor 结论）。
LLVM_DIR=""
if [ -d "$SDK_NATIVE/llvm" ] && [ -d "$SDK_NATIVE/llvm/bin" ]; then
  LLVM_DIR="$SDK_NATIVE/llvm"
else
  for d in "$SDK_NATIVE"/llvm-*/bin; do
    if [ -d "$d" ]; then LLVM_DIR="${d%/bin}"; break; fi
  done
fi
if [ -z "$LLVM_DIR" ] || [ ! -d "$LLVM_DIR/bin" ]; then
  echo "错误：$SDK_NATIVE 下未找到 llvm 或 llvm-* 目录（布局意外）。实际内容：" >&2
  ls -la "$SDK_NATIVE" >&2 || true
  exit 1
fi
LLVM_BIN="$LLVM_DIR/bin"
CLANG="$LLVM_BIN/aarch64-unknown-linux-ohos-clang"
CLANGXX="$LLVM_BIN/aarch64-unknown-linux-ohos-clang++"
READELF="$LLVM_BIN/llvm-readelf"
NM="$LLVM_BIN/llvm-nm"
for f in "$CLANG" "$CLANGXX" "$READELF" "$NM" "$LLVM_BIN/llvm-strip"; do
  if [ ! -e "$f" ]; then
    echo "错误：SDK llvm 布局不完整，缺少：$f。" >&2
    exit 1
  fi
done

CLANG_VERSION="$("$CLANG" --version | head -1)"
log "探针：llvm 目录 = $LLVM_DIR"
log "探针：clang 版本 = $CLANG_VERSION"

# 探针结果写 node-build-env.txt（随 artifact 上传，任务书 §4 U2.2.b）
SYSROOT="$SDK_NATIVE/sysroot"
cat > "$OUT_DIR/node-build-env.txt" <<EOF
node-ohos build env probe (${ARTIFACT_BASE})
date(utc)        = $(date -u '+%Y-%m-%d %H:%M:%S')
runner           = $(uname -a)
nproc            = $(nproc)
disk-free(out)   = $(df -h "$OUT_DIR" | tail -1 | awk '{print $4}')
sdk-native       = $SDK_NATIVE
llvm-dir         = $LLVM_DIR
clang-version    = $CLANG_VERSION
clang-wrapper    = $CLANG
clangxx-wrapper  = $CLANGXX
sysroot          = $SYSROOT
sysroot-exists   = $([ -d "$SYSROOT" ] && echo yes || echo no)
libcxx-shared    = $([ -f "$LLVM_DIR/lib/aarch64-linux-ohos/libc++_shared.so" ] && echo "$LLVM_DIR/lib/aarch64-linux-ohos/libc++_shared.so" || echo MISSING)
node-src         = $NODE_SRC
EOF
cat "$OUT_DIR/node-build-env.txt"

# build-log.txt 开篇（诊断面：clang 版本 + configure 全参回显 + 构建日志尾，任务书 §3 #6）
{
  echo "==== node-ohos build log (${ARTIFACT_BASE}) ===="
  echo "date(utc)  = $(date -u '+%Y-%m-%d %H:%M:%S')"
  echo "clang      = $CLANG_VERSION"
  cat "$OUT_DIR/node-build-env.txt"
} > "$OUT_DIR/build-log.txt"

# 版本三行回显（yml 已 grep 过，脚本侧再核一遍防中途换树）
log "node 源码版本头："
grep -E '#define NODE_(MAJOR|MINOR|PATCH)_VERSION' "$NODE_SRC/src/node_version.h" | tee -a "$OUT_DIR/build-log.txt"

# ---- 门0补丁1（run 44778328727 实锤 + 本机 clang 15.0.4 复现；run 44779847011 修条件判据）----
# OHOS clang 15 不认 target("arch=armv8-a+aes+crc") 属性串（警告后忽略）→ CRC 内建在无 +crc
# 特性位的函数上发出 → 后端 "Cannot select: intrinsic %llvm.aarch64.crc32b" = ICE（exit 70）。
# 修 = zlib_arm_crc32 目标的 -march=armv8-a+aes+crc cflags 条件从「非 win 且非 clang」改为
# 「非 win 且 arm64」（gyp 自带同款 gcc 路径，zlib.gyp:72-74）——逐目标生效，不污染全局 march
# （全局 +crc 会放出基线 armv8 设备不可执行的指令，禁）。本机已验证：同 flags 下
# 「属性被忽略 + -march=armv8-a+crc+aes」可编译出 .o（2026-11-21 /d/temp/zlib-probe）。
# 三轮教训：条件判据勿依赖 gyp 的 OS 值——OHOS 性来自编译器 triple，gyp 层 OS=linux，
# `OS=="openharmony"` 永不命中（run 44779847011 实锤）；target_arch=="arm64" 才稳定可用。
log "门0补丁1：zlib_arm_crc32 目标 cflags 条件改为 target_arch 判据"
python3 - "$NODE_SRC/deps/zlib/zlib.gyp" <<'PYEOF' | tee -a "$OUT_DIR/build-log.txt"
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
old = """'OS!="win" and clang==0', {"""
new = """'OS!="win" and target_arch=="arm64"', {"""
n = s.count(old)
if n != 1:
    print(f"错误：zlib.gyp 条件串命中 {n} 次（预期恰 1），补丁不落地。")
    sys.exit(1)
open(p, 'w', encoding='utf-8').write(s.replace(old, new))
print("补丁已落地：zlib_arm_crc32 cflags 条件 = 非 win 且 arm64（-march=armv8-a+aes+crc）")
PYEOF
# 同族风险探查：全 deps 树还有多少 arch=armv8 属性位（不设闸，只回显——后续若再 ICE 按此归因）。
# 已核：v8_zlib 目标源清单只编 crc32.c 软件路径，deps/v8/third_party/zlib/crc32_simd.c
# 不在 node 构建图（tools/v8_gypfiles/v8.gyp v8_zlib sources 实查），无需补丁。
echo "---- deps 树内 target(\"arch=armv8 属性位探查（前 10 处）----" | tee -a "$OUT_DIR/build-log.txt"
grep -rn 'target("arch=armv8' "$NODE_SRC/deps" --include='*.c' --include='*.cc' --include='*.h' 2>/dev/null | head -10 | tee -a "$OUT_DIR/build-log.txt" || true

# ---- 门0补丁2（run 44782745171 实锤 + 本机 clang 15.0.4 复现）----
# OHOS SDK libc++（clang 15 配套头）缺 C++20 ranges 算法八件（find_if/find_if_not/replace/
# stable_sort/any_of/all_of/lower_bound/binary_search 全不在，本机逐件探针实证）→ node v24 的
# deps/ada 42 处 std::ranges:: 调用全红（首错 find_if，stable_sort 级联 lambda 捕获错）。
# 修 = ada.h 尾部 include 后注入等价 shim（经典算法 + identity 投影；容器入参形态覆盖全部
# 调用点，唯一投影调用 = ada.cpp:5976 lower_bound 四参式已支持）；__clang_major__<16 守卫，
# 未来 llvm>=19 工具链整块跳过防重定义。向 std 命名空间注入属冻结工具链构建兜底（登记 manifest）。
log "门0补丁2：ada.h 注入 ranges 八件 shim"
python3 - "$NODE_SRC/deps/ada/ada.h" <<'PYEOF2' | tee -a "$OUT_DIR/build-log.txt"
import sys
p = sys.argv[1]
lines = open(p, encoding='utf-8').read().split('\n')
if any('NODE-OHOS GATE0 PATCH2' in l for l in lines):
    print("补丁2已在场（幂等跳过）"); sys.exit(0)
# 插入点 = 首个 std::ranges:: 用点之前的最后一个 #include 之后（ada.h 单头 include 散布，
# 「最后一个 include」在用点之后会注入太晚——首轮本地验证实锤）
use_idx = [i for i, l in enumerate(lines) if 'std::ranges::' in l]
if not use_idx:
    print("错误：ada.h 内未找到 std::ranges:: 用点（上游结构变化？）"); sys.exit(1)
first_use = min(use_idx)
pre_incs = [i for i, l in enumerate(lines[:first_use]) if l.startswith('#include')]
last_inc = pre_incs[-1] if pre_incs else 0
shim = '''
// ===== NODE-OHOS GATE0 PATCH2: std::ranges shim for OHOS SDK libc++ (clang 15) =====
// OHOS SDK libc++ lacks C++20 ranges algorithms (find_if/find_if_not/replace/stable_sort/
// any_of/all_of/lower_bound/binary_search all missing, probed 2026-11-21). Equivalent classic
// implementations below; container-argument forms cover all ada call sites (the only
// projected call is lower_bound 4-arg at ada.cpp combining-marks lookup). Skipped
// entirely on clang>=16 where real std::ranges exists (avoid redefinition).
// Gate0 patch7 mutual exclusion: when the global ranges shim header is -include'd
// (it defines NODE_OHOS_RANGES_ALGO_SHIM and provides a superset), skip this block.
#ifndef NODE_OHOS_RANGES_ALGO_SHIM
#if __clang_major__ < 16
#include <functional>
namespace std { namespace ranges {
template <class R, class Pred, class Proj = std::identity>
auto find_if(R&& r, Pred pred, Proj proj = {}) {
  using std::begin; using std::end;
  auto first = begin(r); const auto last = end(r);
  for (; first != last; ++first)
    if (std::invoke(pred, std::invoke(proj, *first))) return first;
  return first;
}
template <class R, class Pred, class Proj = std::identity>
auto find_if_not(R&& r, Pred pred, Proj proj = {}) {
  using std::begin; using std::end;
  auto first = begin(r); const auto last = end(r);
  for (; first != last; ++first)
    if (!std::invoke(pred, std::invoke(proj, *first))) return first;
  return first;
}
template <class R, class Pred, class Proj = std::identity>
bool any_of(R&& r, Pred pred, Proj proj = {}) {
  using std::begin; using std::end;
  for (auto first = begin(r), last = end(r); first != last; ++first)
    if (std::invoke(pred, std::invoke(proj, *first))) return true;
  return false;
}
template <class R, class Pred, class Proj = std::identity>
bool all_of(R&& r, Pred pred, Proj proj = {}) {
  using std::begin; using std::end;
  for (auto first = begin(r), last = end(r); first != last; ++first)
    if (!std::invoke(pred, std::invoke(proj, *first))) return false;
  return true;
}
template <class R, class T, class U>
void replace(R&& r, const T& old_value, const U& new_value) {
  using std::begin; using std::end;
  for (auto it = begin(r), e = end(r); it != e; ++it)
    if (*it == old_value) *it = new_value;
}
template <class R, class Comp = std::less<>, class Proj = std::identity>
void stable_sort(R&& r, Comp comp = {}, Proj proj = {}) {
  using std::begin; using std::end;
  std::stable_sort(begin(r), end(r), [&](auto&& a, auto&& b) {
    return std::invoke(comp, std::invoke(proj, a), std::invoke(proj, b));
  });
}
template <class R, class T, class Comp = std::less<>, class Proj = std::identity>
auto lower_bound(R&& r, const T& value, Comp comp = {}, Proj proj = {}) {
  using std::begin; using std::end;
  return std::lower_bound(begin(r), end(r), value, [&](const auto& a, const auto& b) {
    return std::invoke(comp, std::invoke(proj, a), b);
  });
}
template <class R, class T>
bool binary_search(R&& r, const T& value) {
  using std::begin; using std::end;
  return std::binary_search(begin(r), end(r), value);
}
}}  // namespace std::ranges
#endif  // __clang_major__ < 16
#endif  // NODE_OHOS_RANGES_ALGO_SHIM
// ===== end NODE-OHOS GATE0 PATCH2 ====='''
lines.insert(last_inc + 1, shim)
open(p, 'w', encoding='utf-8').write('\n'.join(lines))
print(f"补丁2已落地：ada.h 第 {last_inc + 1} 行（最后 #include 之后）注入 ranges 八件 shim")
PYEOF2

# ---- 门0补丁3（run 44786163438 实锤）----
# node.gyp:546-549 ['OS=="linux" and clang==1' → libraries:['-latomic']]——gyp 层 OS=linux
# 必中此条件，而 OHOS musl sysroot 不提供 libatomic（aarch64 原子操作内联 + compiler-rt
# builtins 兜底，无需 libatomic）→ 目标侧链接 nop/overlapped-checker 时 ld.lld 报
# unable to find library -latomic。修 = 原位清空该 libraries 项（全 node.gyp 唯一命中）。
log "门0补丁3：node.gyp 去 -latomic（musl 无此库且不需要）"
python3 - "$NODE_SRC/node.gyp" <<'PYEOF3' | tee -a "$OUT_DIR/build-log.txt"
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
old = """'libraries': ['-latomic'],"""
new = """'libraries': [],  # node-ohos GATE0 PATCH3: musl 无 libatomic（aarch64 原子内联），去 -latomic"""
n = s.count(old)
if n != 1:
    print(f"错误：node.gyp -latomic 条目命中 {n} 次（预期恰 1），补丁不落地。")
    sys.exit(1)
open(p, 'w', encoding='utf-8').write(s.replace(old, new))
print("补丁已落地：node.gyp linux+clang 分支去 -latomic")
PYEOF3

# ================= d. configure + make =================
# CC/CXX 注入：-fno-emulated-tls 编译与链接两处生效。经自建包装器注入（configure.py 对
# CC 值做单可执行处理，直接内联参数有解析风险——build-cpython-ohos.sh:93-106 包装器
# 思路同源）；包装器 exec SDK 官方 wrapper（内联 --target/--sysroot/-D__MUSL__，
# build-native-deps.sh:62-63）再追加 -fno-emulated-tls。
#
# ---- 门0补丁4（run 44788351099 目标侧红实锤；v4 修订 = run 44795703343 host 歧义实锤）----
# V8 13.6 的 vector.h:296 用 C++23 的 std::make_unique_for_overwrite（P1132）。
# 仅目标侧缺（OHOS libc++/clang15 无此函数）；host 侧 gcc13 libstdc++ 自带真函数
# （gnu++20 下特性宏未定义但函数可见——注入 shim 反致重载歧义，故 host 只剥旗不注入）。
# 修 = compat 头经 -include 注入目标侧 CXX 包装器；CXX_host 另行显式设为宿主 gcc
# 包装器（此前未显式设存在 host 工具被 OHOS clang 接管成 aarch64、后续 mksnapshot
# 执行撞 exec-format 墙的隐患）。特性宏守卫，新工具链原生在场时整块跳过防撞车。
COMPAT_H="$OUT_DIR/cc-wrappers/compat.h"
mkdir -p "$OUT_DIR/cc-wrappers"
cat > "$COMPAT_H" <<'COMPATEOF'
// NODE-OHOS GATE0 PATCH4: C++23 std::make_unique_for_overwrite shim (P1132)
// V8 13.6 vector.h 使用之；仅注入目标侧（OHOS libc++/clang15 缺此件；host gcc13
// 自带真函数且特性宏在 gnu++20 未定义，注入会重载歧义——run 44795703343）。
#ifndef NODE_OHOS_COMPAT_H
#define NODE_OHOS_COMPAT_H
#include <memory>
#include <type_traits>
#if !defined(__cpp_lib_make_unique_for_overwrite) || __cpp_lib_make_unique_for_overwrite < 202102L
namespace std {
template <class T>
std::enable_if_t<!std::is_array_v<T>, std::unique_ptr<T>>
make_unique_for_overwrite() { return std::unique_ptr<T>(new T); }
template <class T>
std::enable_if_t<std::is_unbounded_array_v<T>, std::unique_ptr<T>>
make_unique_for_overwrite(std::size_t n) {
  return std::unique_ptr<T>(new std::remove_extent_t<T>[n]);
}
}  // namespace std
#endif
#endif  // NODE_OHOS_COMPAT_H
COMPATEOF
echo "门0补丁4：compat.h（make_unique_for_overwrite shim）已写入 $COMPAT_H" | tee -a "$OUT_DIR/build-log.txt"

# ---- 门0补丁7（run 44896391564 暴露 node src ranges 面 + 本机 14/15 文件语法扫验证）----
# node 自身 src/ 的 ranges/views 用面（构建图内，examples/test 不编）：算法 7 种 23 用点
# （find/find_if/sort/reverse/for_each/any_of/all_of）+ 视图 6 处（补丁8 改写）。算法走
# 全局 shim 头（ada 八件投影形态 + 基础形态并集 12 件），经 -include 注入目标侧 CXX——
# 与补丁2（ada.h 内嵌八件）经 NODE_OHOS_RANGES_ALGO_SHIM 互斥宏防同单元双注入。
# 守卫 = __cpp_lib_ranges < 202202L（OHOS libc++15 未定义该宏、本机 PASS 序列实证）。
# host 侧不注入（gcc13 自带真 ranges，且特性宏 gnu++20 下未定义会重载歧义——同补丁4教训）。
RANGES_H="$OUT_DIR/cc-wrappers/node-ohos-ranges.h"
cat > "$RANGES_H" <<'RANGESEOF'
// NODE-OHOS GATE0 PATCH7: std::ranges algorithms shim (classic equivalents)
// OHOS SDK libc++ (clang 15) lacks C++20 ranges algorithms; node src + ada use
// them. Injected via -include to target-side CXX wrapper only (host gcc13 has
// real ranges; and its feature macro is absent in gnu++20 -> redefinition).
// Feature-macro guarded: toolchains with __cpp_lib_ranges >= 202202L skip all.
// Mutual-exclusion macro NODE_OHOS_RANGES_ALGO_SHIM also guards ada.h patch2
// (same-unit double injection would collide).
#ifndef NODE_OHOS_RANGES_SHIM_H
#define NODE_OHOS_RANGES_SHIM_H
#if !defined(__cpp_lib_ranges) || __cpp_lib_ranges < 202202L
#define NODE_OHOS_RANGES_ALGO_SHIM
#include <algorithm>
#include <functional>
#include <iterator>
#include <utility>

namespace std { namespace ranges {

// ---- ada.h patch2 八件（投影形态，逐字迁移自已验证 shim）----
template <class R, class Pred, class Proj = std::identity>
auto find_if(R&& r, Pred pred, Proj proj = {}) {
  using std::begin; using std::end;
  auto first = begin(r); const auto last = end(r);
  for (; first != last; ++first)
    if (std::invoke(pred, std::invoke(proj, *first))) return first;
  return first;
}
template <class R, class Pred, class Proj = std::identity>
auto find_if_not(R&& r, Pred pred, Proj proj = {}) {
  using std::begin; using std::end;
  auto first = begin(r); const auto last = end(r);
  for (; first != last; ++first)
    if (!std::invoke(pred, std::invoke(proj, *first))) return first;
  return first;
}
template <class R, class Pred, class Proj = std::identity>
bool any_of(R&& r, Pred pred, Proj proj = {}) {
  using std::begin; using std::end;
  auto first = begin(r); const auto last = end(r);
  for (; first != last; ++first)
    if (std::invoke(pred, std::invoke(proj, *first))) return true;
  return false;
}
template <class R, class Pred, class Proj = std::identity>
bool all_of(R&& r, Pred pred, Proj proj = {}) {
  using std::begin; using std::end;
  auto first = begin(r); const auto last = end(r);
  for (; first != last; ++first)
    if (!std::invoke(pred, std::invoke(proj, *first))) return false;
  return true;
}
template <class R, class T, class U, class Proj = std::identity>
void replace(R&& r, const T& old_value, const U& new_value, Proj proj = {}) {
  using std::begin; using std::end;
  auto first = begin(r); const auto last = end(r);
  for (; first != last; ++first)
    if (std::invoke(proj, *first) == old_value) *first = new_value;
}
template <class R, class Comp = std::less<>, class Proj = std::identity>
void stable_sort(R&& r, Comp comp = {}, Proj proj = {}) {
  using std::begin; using std::end;
  std::stable_sort(begin(r), end(r), [&](auto&& a, auto&& b) {
    return std::invoke(comp, std::invoke(proj, a), std::invoke(proj, b));
  });
}
template <class R, class T, class Comp = std::less<>, class Proj = std::identity>
auto lower_bound(R&& r, const T& value, Comp comp = {}, Proj proj = {}) {
  using std::begin; using std::end;
  auto first = begin(r); const auto last = end(r);
  auto count = std::distance(first, last);
  while (count > 0) {
    auto step = count / 2;
    auto it = std::next(first, step);
    if (std::invoke(comp, std::invoke(proj, *it), value)) {
      first = std::next(it);
      count -= step + 1;
    } else {
      count = step;
    }
  }
  return first;
}
template <class R, class T, class Comp = std::less<>, class Proj = std::identity>
bool binary_search(R&& r, const T& value, Comp comp = {}, Proj proj = {}) {
  auto it = std::ranges::lower_bound(r, value, comp, proj);
  using std::end;
  return it != end(r) && !std::invoke(comp, value, std::invoke(proj, *it));
}

// ---- node src 基础形态 ----
template <class R, class T>
auto find(R&& r, const T& value) {
  using std::begin; using std::end;
  return std::find(begin(r), end(r), value);
}
template <class R, class Comp = std::less<>>
void sort(R&& r, Comp comp = {}) {
  using std::begin; using std::end;
  std::sort(begin(r), end(r), comp);
}
template <class R>
void reverse(R&& r) {
  using std::begin; using std::end;
  std::reverse(begin(r), end(r));
}
template <class R, class F, class Proj = std::identity>
void for_each(R&& r, F f, Proj proj = {}) {
  using std::begin; using std::end;
  auto first = begin(r); const auto last = end(r);
  for (; first != last; ++first) f(std::invoke(proj, *first));
}

}}  // namespace std::ranges
#endif  // __cpp_lib_ranges
#endif  // NODE_OHOS_RANGES_SHIM_H
RANGESEOF
echo "门0补丁7：node-ohos-ranges.h（算法 12 件 shim）已写入 $RANGES_H" | tee -a "$OUT_DIR/build-log.txt"

WRAP_DIR="$OUT_DIR/cc-wrappers"
mkdir -p "$WRAP_DIR"
cat > "$WRAP_DIR/ohos-node-cc" <<EOF
#!/usr/bin/env bash
exec "$CLANG" -fno-emulated-tls "\$@"
EOF
cat > "$WRAP_DIR/ohos-node-cxx" <<EOF
#!/usr/bin/env bash
# 补丁4注入形态：仅真编译（args 含 -c）才 -include compat.h——configure 探针用 -E -P
# 预处理宏清单，-include 会把头展开塞进探针输出污染版本 token（run 44791951794 实锤
# ValueError int('clang')）；链接步亦无需 include。
# 真编译另加 -ferror-limit=0：轮 22 的 mark-compact.cc 触顶 clang 默认 20 错上限
# （-k 下同 TU 后续独立错误被截断），关限让失败轮一次给出完整错误面（C++ 单一 TU
# 内错误数有限，日志膨胀可接受）。
for a in "\$@"; do
  case "\$a" in -c) exec "$CLANGXX" -fno-emulated-tls -ferror-limit=0 -include "$COMPAT_H" -include "$RANGES_H" "\$@";; esac
done
exec "$CLANGXX" -fno-emulated-tls "\$@"
EOF
# host 工具链：宿主 cc/c++（x86_64 本机编译，供 mksnapshot 等可执行件），不注入
# compat 头（gcc13 自带真函数，见补丁4 注释）+ **target 旗过滤器**——gyp 的
# target_arch=="arm64" 条件旗（-mbranch-protection 等）会泄进 host 编译（toolset 无关、
# 全局条件），x86 gcc 不认（run 44792901291 实锤）；顺带证实补丁4 前 host 工具一直被
# OHOS clang 接管成 aarch64（能吃 arm 旗但产物不可执行，mksnapshot 必挂 exec-format）。
cat > "$WRAP_DIR/ohos-host-cxx" <<'HOSTEOF'
#!/usr/bin/env bash
# node-ohos host CXX 包装器：剥 target 侧旗（AArch64 专用，x86 gcc 不认）。
# 不注入 compat.h——gcc13 libstdc++ 自带 make_unique_for_overwrite 真函数，而特性宏
# __cpp_lib_make_unique_for_overwrite 在 gnu++20 下未定义，注入 shim 反致重载歧义
# （run 44795703343 实锤 code-generator.cc ambiguous）。
args=()
for a in "$@"; do
  case "$a" in
    -mbranch-protection=*|-march=armv8*) ;;        # target 旗，host 剥除
    -fno-emulated-tls) ;;                          # target 侧 TLS 形态旗，host 剥除
    *) args+=("$a") ;;
  esac
done
exec c++ "${args[@]}"
HOSTEOF
cat > "$WRAP_DIR/ohos-host-cc" <<'HOSTCCEOF'
#!/usr/bin/env bash
# node-ohos host CC 包装器：剥 target 侧旗（同 ohos-host-cxx；C 编译无需 compat 头）
args=()
for a in "$@"; do
  case "$a" in
    -mbranch-protection=*|-march=armv8*|-fno-emulated-tls) ;;
    *) args+=("$a") ;;
  esac
done
exec cc "${args[@]}"
HOSTCCEOF
chmod +x "$WRAP_DIR/ohos-host-cxx" "$WRAP_DIR/ohos-host-cc"
chmod +x "$WRAP_DIR/ohos-node-cc" "$WRAP_DIR/ohos-node-cxx" "$WRAP_DIR/ohos-host-cxx"
export CC="$WRAP_DIR/ohos-node-cc"
export CXX="$WRAP_DIR/ohos-node-cxx"
export CC_host="$WRAP_DIR/ohos-host-cc"
export CXX_host="$WRAP_DIR/ohos-host-cxx"

# ---- 门0补丁5（run 44865919999 实锤 + 本机 OHOS clang 15.0.4 复现终验）----
# V8 13.6 handle 系统在 5 文件里用「模板模板参数 + requires 约束」形态声明返回类型
# `HandleType<T>::MaybeType`（无 typename）——上游靠 C++20 relaxed typename（P0634）放行，
# OHOS clang 15 对该复杂路径支持不全报 missing 'typename'（v8_initializers_slow 的
# js-to-wasm-tq-csa.o 首爆，20 错上限）。修 = 原位补 typename（标准永远合法、前向兼容，
# 无需特性宏守卫）。全树扫描闭环：恰 22 处、5 文件、无其他别名/模板名变体（2026-11-21
# 本机对 v24.22.3 官方包全树 grep；MaybeType 全部经 HandleType，参数位置零用点）。
log "门0补丁5：V8 handle 系 5 文件 22 处依赖返回类型补 typename"
python3 - "$NODE_SRC" <<'PYEOF5' | tee -a "$OUT_DIR/build-log.txt"
import re, sys
root = sys.argv[1]
files = [
    'deps/v8/src/heap/factory-base.cc',
    'deps/v8/src/heap/factory-base.h',
    'deps/v8/src/objects/objects.h',
    'deps/v8/src/objects/ordered-hash-table.cc',
    'deps/v8/src/objects/ordered-hash-table.h',
]
pat = re.compile(r'(?<!typename )HandleType<([A-Za-z]+)>::MaybeType')
total = 0
for rel in files:
    p = f'{root}/{rel}'
    s = open(p, encoding='utf-8').read()
    s2, n = pat.subn(lambda m: 'typename HandleType<' + m.group(1) + '>::MaybeType', s)
    if n == 0:
        print(f'错误：{rel} 零命中（上游结构变化？）'); sys.exit(1)
    open(p, 'w', encoding='utf-8').write(s2)
    print(f'{rel}: {n} 处'); total += n
if total != 22:
    print(f'错误：合计 {total} 处 != 预期 22（上游结构变化？）'); sys.exit(1)
print(f'补丁5已落地：5 文件合计 {total} 处 typename')
PYEOF5

# ---- 门0补丁5续（run 44896391564 实锤 mark-compact.h:344 + 全形态扫描预防 3 处）----
# P0634 族另一形态：非模板类的成员函数模板里「类模板实例::嵌套类型」作参数/返回/局部声明
# 无 typename（上游靠 C++20 relaxed typename 放行）。实锤 2 = mark-compact.h/cc 的
# WeakObjectWorklist<TObjectAndSlot>::Local；预防 3 = turboshaft-graph-interface 的
# BrTableAnalysis<ValidationTag>::CaseVector、node_platform 的 TaskQueue<T>::PriorityQueue
# ×2（跨类依赖名同形态必暴露）。全形态扫描闭环（声明位置 X<T>::Y 无 typename 用点人审
# 28+92 行，真缺仅此 5 处；具体类型实参/已有 typename/类内自身实例化均排除）。
log "门0补丁5续：依赖名 typename 5 处（实锤 2 + 预防 3）"
python3 - "$NODE_SRC" <<'PYEOF5B' | tee -a "$OUT_DIR/build-log.txt"
import sys
root = sys.argv[1]
edits = [
    ('deps/v8/src/heap/mark-compact.h',
     '      WeakObjects::WeakObjectWorklist<TObjectAndSlot>::Local& worklist,',
     '      typename WeakObjects::WeakObjectWorklist<TObjectAndSlot>::Local& worklist,'),
    ('deps/v8/src/heap/mark-compact.cc',
     '    WeakObjects::WeakObjectWorklist<TObjectAndSlot>::Local& worklist,',
     '    typename WeakObjects::WeakObjectWorklist<TObjectAndSlot>::Local& worklist,'),
    ('deps/v8/src/wasm/turboshaft-graph-interface.cc',
     '                   const BrTableAnalysis<ValidationTag>::CaseVector& cases)',
     '                   const typename BrTableAnalysis<ValidationTag>::CaseVector& cases)'),
    ('src/node_platform.cc',
     'TaskQueue<T>::PriorityQueue TaskQueue<T>::Locked::PopAll() {',
     'typename TaskQueue<T>::PriorityQueue TaskQueue<T>::Locked::PopAll() {'),
    ('src/node_platform.cc',
     '  TaskQueue<T>::PriorityQueue result;',
     '  typename TaskQueue<T>::PriorityQueue result;'),
]
for rel, old, new in edits:
    p = f'{root}/{rel}'
    s = open(p, encoding='utf-8').read()
    n = s.count(old)
    if n != 1:
        print(f'错误：{rel} 命中 {n} != 1（上游结构变化？）'); sys.exit(1)
    open(p, 'w', encoding='utf-8').write(s.replace(old, new))
    print(f'{rel}: 补 typename OK')
print('补丁5续已落地：5 处 typename（实锤 2 + 预防 3）')
PYEOF5B

# ---- 门0补丁6（run 44875780751 实锤 + 本机 OHOS clang 15.0.4 验证推过改写点）----
# V8 自身 3 文件 4 处用 std::ranges/std::views（补丁2 shim 只注入 ada.h，V8 头不带）：
# transitions-inl.h / descriptor-array-inl.h 的「ranges::lower_bound(views::iota, 投影)」
# 与 maglev-inlining.h 的 ranges::find_if / max_element。修 = 源级改写经典等价形态
# （二分手写循环维持 iota-end 解引用安全语义：end=0 时得 0；find_if/max_element 用
# begin/end 两迭代器式，<algorithm> 已在场）。全树扫描闭环：ada 外 ranges/views 用面
# 恰 3 文件 4 处（2026-11-21 本机对 v24.22.3 官方包 grep）。
log "门0补丁6：V8 3 文件 4 处 ranges/views 改写经典等价形态"
python3 - "$NODE_SRC" <<'PYEOF6' | tee -a "$OUT_DIR/build-log.txt"
import sys
root = sys.argv[1]
edits = [
    ('deps/v8/src/objects/transitions-inl.h',
     '''  int i = *std::ranges::lower_bound(std::views::iota(0, end), hash,
                                    std::less<>(), [&](int i) {
                                      Tagged<Name> entry = GetKey(i);
                                      return entry->hash();
                                    });''',
     '''  int lo = 0, hi = end;
  while (lo < hi) {
    int mid = lo + (hi - lo) / 2;
    if (GetKey(mid)->hash() < hash) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  int i = lo;'''),
    ('deps/v8/src/objects/descriptor-array-inl.h',
     '''  int number = *std::ranges::lower_bound(std::views::iota(0, end), hash,
                                         std::less<>(), [&](int i) {
                                           Tagged<Name> entry = GetSortedKey(i);
                                           return entry->hash();
                                         });''',
     '''  int lo = 0, hi = end;
  while (lo < hi) {
    int mid = lo + (hi - lo) / 2;
    if (GetSortedKey(mid)->hash() < hash) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  int number = lo;'''),
    ('deps/v8/src/maglev/maglev-inlining.h',
     '''            ? std::ranges::find_if(graph_->inlineable_calls(),
                                   [](auto* site) { return site != nullptr; })
            : std::ranges::max_element(
                  graph_->inlineable_calls(),
                  [](const MaglevCallSiteInfo* info1,
                     const MaglevCallSiteInfo* info2) {''',
     '''            ? std::find_if(graph_->inlineable_calls().begin(),
                           graph_->inlineable_calls().end(),
                           [](auto* site) { return site != nullptr; })
            : std::max_element(
                  graph_->inlineable_calls().begin(),
                  graph_->inlineable_calls().end(),
                  [](const MaglevCallSiteInfo* info1,
                     const MaglevCallSiteInfo* info2) {'''),
]
for rel, old, new in edits:
    p = f'{root}/{rel}'
    s = open(p, encoding='utf-8').read()
    n = s.count(old)
    if n != 1:
        print(f'错误：{rel} 命中 {n} 处 != 1（上游结构变化？）'); sys.exit(1)
    open(p, 'w', encoding='utf-8').write(s.replace(old, new))
    print(f'{rel}: 改写 OK')
print('补丁6已落地：3 文件改写完成')
PYEOF6

# ---- 门0补丁8（node src 视图 6 处经典改写；本机 14/15 文件语法扫 PASS，2026-11-21）----
# 视图不 shim（elements_view/keys_view/ref_view/subrange/views::split/values/keys 需真视图
# 类，改写更稳）：util.h+util-inl.h 的 elements_view 重载泛型化（std::get<U> 取元素，
# 真实调用链 = node_builtins.cc:674 经 GetBuiltinIds 传入）；node_builtins 返回类型改
# vector<string>（消费点 auto+范围 for 兼容）；node_options-inl 的 for_each(subrange|
# values) 改经典 for（it->second）；两处 views::split 改经典 find 分割循环（空串时 1 个
# 空段，与 P2210 语义一致）。
log "门0补丁8：node src 视图 6 处经典改写（9 段替换）"
python3 - "$NODE_SRC" <<'PYEOF8' | tee -a "$OUT_DIR/build-log.txt"
import sys
root = sys.argv[1]
edits = [
    ('src/util.h',
     '''inline v8::MaybeLocal<v8::Value> ToV8Value(
    v8::Local<v8::Context> context,
    const std::ranges::elements_view<T, U>& vec,
    v8::Isolate* isolate = nullptr);''',
     '''inline v8::MaybeLocal<v8::Value> ToV8Value(
    v8::Local<v8::Context> context,
    const T& vec,
    v8::Isolate* isolate = nullptr);'''),
    ('src/util-inl.h',
     '''v8::MaybeLocal<v8::Value> ToV8Value(v8::Local<v8::Context> context,
                                    const std::ranges::elements_view<T, U>& vec,
                                    v8::Isolate* isolate) {''',
     '''v8::MaybeLocal<v8::Value> ToV8Value(v8::Local<v8::Context> context,
                                    const T& vec,
                                    v8::Isolate* isolate) {'''),
    ('src/util-inl.h',
     '''    if (!ToV8Value(context, *it, isolate).ToLocal(&arr[i]))
      return v8::MaybeLocal<v8::Value>();
    std::advance(it, 1);
  }

  return handle_scope.Escape(v8::Array::New(isolate, arr.out(), arr.length()));
}

template <typename T, typename U>
v8::MaybeLocal<v8::Value> ToV8Value(v8::Local<v8::Context> context,
                                    const std::unordered_map<T, U>& map,''',
     '''    if (!ToV8Value(context, std::get<U>(*it), isolate).ToLocal(&arr[i]))
      return v8::MaybeLocal<v8::Value>();
    std::advance(it, 1);
  }

  return handle_scope.Escape(v8::Array::New(isolate, arr.out(), arr.length()));
}

template <typename T, typename U>
v8::MaybeLocal<v8::Value> ToV8Value(v8::Local<v8::Context> context,
                                    const std::unordered_map<T, U>& map,'''),
    ('src/node_builtins.h',
     '''  [[nodiscard]] std::ranges::keys_view<
      std::ranges::ref_view<const BuiltinSourceMap>>
  GetBuiltinIds() const;''',
     '''  [[nodiscard]] std::vector<std::string> GetBuiltinIds() const;'''),
    ('src/node_builtins.cc',
     '''std::ranges::keys_view<std::ranges::ref_view<const BuiltinSourceMap>>
BuiltinLoader::GetBuiltinIds() const {
  return std::views::keys(*source_.read());
}''',
     '''std::vector<std::string> BuiltinLoader::GetBuiltinIds() const {
  auto source = source_.read();
  std::vector<std::string> ids;
  ids.reserve(source->size());
  for (const auto& entry : *source) {
    ids.push_back(entry.first);
  }
  return ids;
}'''),
    ('src/node_options-inl.h',
     '''      auto [f, l] = implications_.equal_range(implied_name);
      std::ranges::for_each(std::ranges::subrange(f, l) | std::views::values,
                            [&](const auto& value) {
                              if (value.type == kV8Option) {
                                v8_args->push_back(value.name);
                              } else {
                                *value.target_field->template Lookup<bool>(
                                    options) = value.target_value;
                              }
                            });''',
     '''      auto [f, l] = implications_.equal_range(implied_name);
      for (auto it = f; it != l; ++it) {
        const auto& value = it->second;
        if (value.type == kV8Option) {
          v8_args->push_back(value.name);
        } else {
          *value.target_field->template Lookup<bool>(options) =
              value.target_value;
        }
      }'''),
    ('src/node_options.cc',
     '''  using std::operator""sv;
  auto entries = std::views::split(inspect_publish_uid_string, ","sv);
  inspect_publish_uid.console = false;
  inspect_publish_uid.http = false;
  for (const auto& entry : entries) {
    std::string_view destination(entry.data(), entry.size());''',
     '''  using std::operator""sv;
  std::string_view entries_str = inspect_publish_uid_string;
  inspect_publish_uid.console = false;
  inspect_publish_uid.http = false;
  size_t pos = 0;
  while (pos <= entries_str.size()) {
    size_t comma = entries_str.find(',', pos);
    std::string_view destination =
        entries_str.substr(pos, comma == std::string_view::npos
                                    ? std::string_view::npos
                                    : comma - pos);'''),
    ('src/node_options.cc',
     '''    } else {
      errors->emplace_back("--inspect-publish-uid destination can be "
                           "stderr or http");
    }''',
     '''    } else {
      errors->emplace_back("--inspect-publish-uid destination can be "
                           "stderr or http");
    }
    if (comma == std::string_view::npos) break;
    pos = comma + 1;'''),
    ('src/tracing/agent_legacy.cc',
     '''  using std::operator""sv;
  auto parts = std::views::split(categories, ","sv);

  std::set<std::string> categories_set;
  for (const auto& s : parts) {
    categories_set.emplace(std::string(s.data(), s.size()));
  }''',
     '''  std::string_view parts_str = categories;
  std::set<std::string> categories_set;
  size_t pos = 0;
  while (pos <= parts_str.size()) {
    size_t comma = parts_str.find(',', pos);
    categories_set.emplace(std::string(
        parts_str.substr(pos, comma == std::string_view::npos
                                  ? std::string_view::npos
                                  : comma - pos)));
    if (comma == std::string_view::npos) break;
    pos = comma + 1;
  }'''),
]
for rel, old, new in edits:
    p = f'{root}/{rel}'
    s = open(p, encoding='utf-8').read()
    n = s.count(old)
    if n != 1:
        print(f'错误：{rel} 命中 {n} != 1（上游结构变化？）'); sys.exit(1)
    open(p, 'w', encoding='utf-8').write(s.replace(old, new))
    print(f'{rel}: 改写 OK')
print('补丁8已落地：6 处视图改写（9 段）完成')
PYEOF8

# ---- 门0补丁9（run 44911644273 实锤 value-type.h:701 + 本机编译验证通过；v2 修订 =
#      run 44924561530 实锤 wasm-disassembler 误伤，该文件完全跳过）----
# V8 wasm 强类型索引 TypeIndex 族是聚合（无构造函数），源码用函数式转换 TypeIndex(expr)
# 与 TypeIndex({x})——靠 C++20 聚合括号初始化（P0960）放行，OHOS clang 15 支持不全报
# "no matching conversion for functional-style cast"。修 = 开圆改花、配对闭圆改花、
# 内部零改动（T(x)→T{x}、T({x})→T{{x}}，聚合嵌套初始化所有标准合法、前向兼容）。
# 全树扫描闭环：真构造恰 29 处 3 文件（wasm-interpreter 24 + runtime 4 + value-type.h 1）。
# 两类误伤排除（教训）：①function-body-decoder-impl.h 的 6 处 ios.TypeIndex(imm,...)
# 是成员函数调用（前置 . / -> 排除）；②wasm-disassembler.cc 有同名成员函数「TypeIndex」
# ——定义签名 void TypeIndex(TypeIndexImmediate&) 与裸调用 TypeIndex(imm.struct_imm)
# 都会被替换器误伤（run 44924561530 host 侧实锤），该文件上游已用花括号、完全跳过。
log "门0补丁9：TypeIndex 族聚合括号初始化 29 处改花括号（v2：disassembler 跳过）"
python3 - "$NODE_SRC" <<'PYEOF9' | tee -a "$OUT_DIR/build-log.txt"
import sys
root = sys.argv[1]
names = ['ModuleTypeIndex', 'CanonicalTypeIndex', 'TypeIndex']  # 长名优先
files = [
    'deps/v8/src/wasm/value-type.h',
    'deps/v8/src/wasm/interpreter/wasm-interpreter.cc',
    'deps/v8/src/wasm/interpreter/wasm-interpreter-runtime.cc',
]
grand = 0
for rel in files:
    p = f'{root}/{rel}'
    s = open(p, encoding='utf-8').read()
    count = 0
    for name in names:
        idx = 0
        while True:
            pos = s.find(name + '(', idx)
            if pos < 0:
                break
            prev = s[pos - 1] if pos else ''
            # 成员调用（ios.TypeIndex( / ptr->TypeIndex(）与标识符邻接均跳过
            if prev in '.>' or prev.isalnum() or prev == '_':
                idx = pos + 1
                continue
            depth = 0
            i = pos + len(name)
            while i < len(s):
                if s[i] == '(':
                    depth += 1
                elif s[i] == ')':
                    depth -= 1
                    if depth == 0:
                        break
                i += 1
            if depth != 0:
                print(f'错误：{rel} 括号不配对'); sys.exit(1)
            s = s[:pos + len(name)] + '{' + s[pos + len(name) + 1:i] + '}' + s[i + 1:]
            count += 1
            idx = pos + len(name) + 1
    open(p, 'w', encoding='utf-8').write(s)
    print(f'{rel}: {count} 处')
    grand += count
if grand != 29:
    print(f'错误：合计 {grand} 处 != 预期 29（上游结构变化？）'); sys.exit(1)
print(f'补丁9已落地：3 文件合计 {grand} 处聚合花括号化')
PYEOF9

# ---- 门0补丁10（run 44975912114 实锤 external-entity-table.h:51-53）----
# P0634 又一形态：using 别名声明右侧的依赖类型名。类模板
# ExternalEntityTable<Entry,size> 内 `using Base = SegmentedTable<Entry,size>`（Base 依赖），
# 其 Base::FreelistHead / Base::Segment / Base::WriteIterator 三处落在别名声明位置，
# OHOS clang 15 不做 relaxed-typename 推断 → missing 'typename' prior to dependent
# type name（setup-isolate-full.o 与 v8_initializers_slow 两 TU 同红，9 errors）。
# 修 = 原位补 typename（标准永远合法、前向兼容）。
# 反向排除（人审勿盲修）：code-pointer-table.h:133 与 js-dispatch-table.h:201 有同字面
# `using Space = Base::SpaceWithBlackAllocationSupport;`，但那两处外层类非模板、Base 实参
# 为具体类型（CodePointerTableEntry / JSDispatchEntry），非依赖——补 typename 即编译错，
# 本机 clang 15.0.4 负例/正例双向验证过（2026-11-22 /d/temp/p10-probe）。
log "门0补丁10：别名声明位置依赖名 3 处补 typename（external-entity-table.h）"
python3 - "$NODE_SRC" <<'PYEOF10' | tee -a "$OUT_DIR/build-log.txt"
import sys
root = sys.argv[1]
rel = 'deps/v8/src/sandbox/external-entity-table.h'
p = f'{root}/{rel}'
s = open(p, encoding='utf-8').read()
pairs = [
    ('using FreelistHead = Base::FreelistHead;',
     'using FreelistHead = typename Base::FreelistHead;'),
    ('using Segment = Base::Segment;',
     'using Segment = typename Base::Segment;'),
    ('using WriteIterator = Base::WriteIterator;',
     'using WriteIterator = typename Base::WriteIterator;'),
]
for old, new in pairs:
    n = s.count(old)
    if n != 1:
        print(f'错误：{rel} 命中 {n} != 1（{old}，上游结构变化？）'); sys.exit(1)
    s = s.replace(old, new)
open(p, 'w', encoding='utf-8').write(s)
print(f'{rel}: 3 处 typename 补齐')
print('补丁10已落地：3 处别名声明依赖名修饰完成')
PYEOF10

# ---- 门0补丁11（run 44987355713 实锤 list.h:150 + 本机全目录/最小复现双验证）----
# P0634 第 7 形态：模板元编程库里的依赖类型名后缀 ::type（元函数结果类型）未写 typename。
# ①deps/v8/src/base/template-meta-programming/list.h 6 处（fold_right_impl/fold_right1_impl
#   的 using type = F<Head, 元函数::type>::type 两层 + insert_at_t/insert_at1_t/
#   fold_right_t/fold_right1_t 四个别名右侧 ::type）；②compiler/turboshaft/assembler.h
#   3 处（ReducerStack<ReducerList> 内 reducer_list_insert_at / reducer_list_to_stack 的 ::type）。
# OHOS clang 15 在「别名声明右侧 + 类型是依赖名」该路径不放松 typename（CI 报 5 处，本机
# -include 四头编译细化出 list.h 6 处含 CI 未报的 137 行；同目录 common/functional/
#   string-literal 三头零错）。修 = 原位补 typename（标准永远合法）。
# 反向排除（67 处候选人审勿盲修）：maglev-ir.cc 59 + baseline-compiler.cc 3 三处
# CallInterfaceDescriptorFor<Builtin::k...>::type（Builtin 枚举值具体实参）+
# mutex.h/condition-variable.h 3 处 LazyStaticInstance<Mutex,...>::type（具体类实参）
# ——实参皆非依赖，补 typename 是编译错，不动。
log "门0补丁11：TMP 元函数 ::type 依赖名 9 处补 typename（list.h 6 + assembler.h 3）"
python3 - "$NODE_SRC" <<'PYEOF11' | tee -a "$OUT_DIR/build-log.txt"
import sys
root = sys.argv[1]
edits = {
    'deps/v8/src/base/template-meta-programming/list.h': [
        ('      F<Head, typename fold_right_impl<F, T, list<Tail...>>::type>::type;',
         '      typename F<Head, typename fold_right_impl<F, T, list<Tail...>>::type>::type;'),
        ('      F<Head, typename fold_right1_impl<F, T, list1<Tail...>>::type>::type;',
         '      typename F<Head, typename fold_right1_impl<F, T, list1<Tail...>>::type>::type;'),
        ('using insert_at_t = insert_at<List, I, T>::type;',
         'using insert_at_t = typename insert_at<List, I, T>::type;'),
        ('using insert_at1_t = insert_at1<List1, I, T>::type;',
         'using insert_at1_t = typename insert_at1<List1, I, T>::type;'),
        ('using fold_right_t = fold_right<F, List, T>::type;',
         'using fold_right_t = typename fold_right<F, List, T>::type;'),
        ('using fold_right1_t = fold_right1<F, List1, T>::type;',
         'using fold_right1_t = typename fold_right1<F, List1, T>::type;'),
    ],
    'deps/v8/src/compiler/turboshaft/assembler.h': [
        ('      reducer_list_insert_at<ReducerList, base_index, GenericReducerBase>::type;',
         '      typename reducer_list_insert_at<ReducerList, base_index, GenericReducerBase>::type;'),
        ('      reducer_list_insert_at<WithGeneric, ep_index,\n                             EmitProjectionReducer>::type;',
         '      typename reducer_list_insert_at<WithGeneric, ep_index,\n                             EmitProjectionReducer>::type;'),
        ('  using type = reducer_list_to_stack<WithGenericAndEmitProjection,\n                                     StackBottom<ReducerList>>::type;',
         '  using type = typename reducer_list_to_stack<WithGenericAndEmitProjection,\n                                     StackBottom<ReducerList>>::type;'),
    ],
}
grand = 0
for rel, pairs in edits.items():
    p = f'{root}/{rel}'
    s = open(p, encoding='utf-8').read()
    for old, new in pairs:
        n = s.count(old)
        if n != 1:
            print(f'错误：{rel} 命中 {n} != 1（{old[:60]}，上游结构变化？）'); sys.exit(1)
        s = s.replace(old, new)
    open(p, 'w', encoding='utf-8').write(s)
    print(f'{rel}: {len(pairs)} 处')
    grand += len(pairs)
if grand != 9:
    print(f'错误：合计 {grand} != 9'); sys.exit(1)
print(f'补丁11已落地：2 文件合计 {grand} 处元函数 ::type 依赖名修饰完成')
PYEOF11

# ---- 门0补丁12（run 44993787875 实锤 assembler.h 5 处 + 依赖传播扫描扩面）----
# 补丁 10/11 之后，CI 的 assembler.h 又露出 5 处：IndexRange/Sequence 内的
# `using value_type = base::value_type;`（base = Range<T> 依赖别名，小写 base——
# 补丁10 的扫描正则只覆盖 Base|Super|Parent 大小写敏感形态，漏了这一族）+
# LoopLabelFor 的 `detail::LoopLabelForHelper<T>::type`。
# 本轮改用「依赖别名传播」机械扫描（别名表 + 模板参数集合，见 P6 自检笔记）重扫全树，
# 命中 16 处候选，人审后真依赖 10 处 3 文件一次收干：
#   ①assembler.h 5（value_type/iterator_type 各 2 + LoopLabelFor 1）
#   ②json/json-stringifier.cc 2（成员函数模板内 using StringChar = StringT::Char）
#   ③wasm/interpreter/wasm-interpreter.cc 3（Handlers<Compressed> 内 traits::* 三兄弟）
# 明确不改：interpreter-builtins-x64.cc 3 处（x64 目录不在 arm64 构建图）+
# mutex.h:103 与 zone-compact-set.h:317-318（Mutex/std 为具体名，扫描器模板参数提取误收）。
# 本机最小复现负例恰报 `missing 'typename' prior to dependent type name 'base::value_type'`
# （列号 22 与 CI assembler.h:197:22 一致）、正例零错。
log "门0补丁12：依赖别名限定 10 处补 typename（assembler.h 5 + json-stringifier 2 + wasm-interpreter 3）"
python3 - "$NODE_SRC" <<'PYEOF12' | tee -a "$OUT_DIR/build-log.txt"
import sys
root = sys.argv[1]
edits = {
    'deps/v8/src/compiler/turboshaft/assembler.h': [
        ('  using value_type = base::value_type;',
         '  using value_type = typename base::value_type;', 2),
        ('  using iterator_type = base::iterator_type;',
         '  using iterator_type = typename base::iterator_type;', 2),
        ('using LoopLabelFor = detail::LoopLabelForHelper<T>::type;',
         'using LoopLabelFor = typename detail::LoopLabelForHelper<T>::type;', 1),
    ],
    'deps/v8/src/json/json-stringifier.cc': [
        ('  using StringChar = StringT::Char;',
         '  using StringChar = typename StringT::Char;', 2),
    ],
    'deps/v8/src/wasm/interpreter/wasm-interpreter.cc': [
        ('  using slot_offset_t = traits::slot_offset_t;',
         '  using slot_offset_t = typename traits::slot_offset_t;', 1),
        ('  using memory_offset32_t = traits::memory_offset32_t;',
         '  using memory_offset32_t = typename traits::memory_offset32_t;', 1),
        ('  using memory_offset64_t = traits::memory_offset64_t;',
         '  using memory_offset64_t = typename traits::memory_offset64_t;', 1),
    ],
}
grand = 0
for rel, pairs in edits.items():
    p = f'{root}/{rel}'
    s = open(p, encoding='utf-8').read()
    for item in pairs:
        old, new, expect = item
        n = s.count(old)
        if n != expect:
            print(f'错误：{rel} 命中 {n} != {expect}（{old[:60]}，上游结构变化？）'); sys.exit(1)
        s = s.replace(old, new)
        grand += expect
    open(p, 'w', encoding='utf-8').write(s)
    print(f'{rel}: {sum(i[2] for i in pairs)} 处')
if grand != 10:
    print(f'错误：合计 {grand} != 10'); sys.exit(1)
print(f'补丁12已落地：3 文件合计 {grand} 处依赖别名限定补 typename')
PYEOF12

# ---- 门0补丁13（run 45011054163 实锤：-k 跑满暴露的全量 P0960 面）----
# P0960（C++20 聚合括号初始化）在「库函数中介」路径上的第二形态：补丁9 修的是直写
# T(x) 构造点，本轮露出的是经库转发再落地的构造——
#   Zone::New<T>(args...)  →  new (p) T(args...)
#   ZoneVector/SmallVector::emplace_back(args...) / std::vector::emplace_back(args...)
#   std::allocator_traits::construct → std::construct_at(p, args...)
# 这些路径把实参原样转发给括号初始化，clang 15 缺 P0960 即报 no matching constructor。
# 修 = 调用点先构造成花括号聚合临时再转发（emplace_back(T{a,b})），库函数收到单值走
# 拷贝/移动（C++17 保证省略，零开销），语义与原 P0960 逐字段一致；不改类型定义，保持
# 聚合（structured binding / 指派初始化不受波及）。
# 花括号比括号严格：窄化转换必须显式 static_cast（RecGroup.start_index int→uint32_t 一处）。
# 覆盖 12 处替换 8 文件：RecGroup 2 + BlockPatch 1 + MaglevCallerDetails 1 + MaglevCallSiteInfo 1
# + RunningLocalHeap 2（Linux/Darwin 双分支）+ UnpublishedWasmCode 2（开/闭行）+ ElidedStringPart
# 联合体 1 + ncrypto::Buffer 2。计数口径 = 文本替换对（不是逻辑构造点）。
log "门0补丁13：聚合构造点经库中介转发 12 处改花括号（8 文件）"
python3 - "$NODE_SRC" <<'PYEOF13' | tee -a "$OUT_DIR/build-log.txt"
import sys
root = sys.argv[1]
edits = {
    'deps/v8/src/wasm/wasm-module-builder.h': [
        ('    recursive_groups_.emplace_back(\n'
         '        current_recursive_group_start_,\n'
         '        static_cast<uint32_t>(types_.size()) - current_recursive_group_start_);',
         '    recursive_groups_.emplace_back(RecGroup{\n'
         '        static_cast<uint32_t>(current_recursive_group_start_),\n'
         '        static_cast<uint32_t>(types_.size()) - current_recursive_group_start_});', 1),
        ('    recursive_groups_.emplace_back(start, size);',
         '    recursive_groups_.emplace_back(RecGroup{start, size});', 1),
    ],
    'deps/v8/src/maglev/maglev-regalloc.cc': [
        ('    patches_.emplace_back(node_it_ - block->nodes().begin(), gap_move);',
         '    patches_.emplace_back(BlockPatch{node_it_ - block->nodes().begin(), gap_move});', 1),
    ],
    'deps/v8/src/maglev/maglev-graph-builder.cc': [
        ('  MaglevCallSiteInfo* call_site = zone()->New<MaglevCallSiteInfo>(\n'
         '      MaglevCallerDetails{\n'
         '          arguments, &generic_call->lazy_deopt_info()->top_frame(),\n'
         '          known_node_aspects().Clone(zone()), loop_effects_,\n'
         '          unobserved_context_slot_stores_, catch_details, IsInsideLoop(),\n'
         '          /* is_eager_inline */ false, call_frequency},\n'
         '      generic_call, feedback_cell, score);',
         '  MaglevCallSiteInfo* call_site = zone()->New<MaglevCallSiteInfo>(\n'
         '      MaglevCallSiteInfo{\n'
         '          MaglevCallerDetails{\n'
         '              arguments, &generic_call->lazy_deopt_info()->top_frame(),\n'
         '              known_node_aspects().Clone(zone()), loop_effects_,\n'
         '              unobserved_context_slot_stores_, catch_details, IsInsideLoop(),\n'
         '              /* is_eager_inline */ false, call_frequency},\n'
         '          generic_call, feedback_cell, score});', 1),
        ('  MaglevCallerDetails* caller_details = zone()->New<MaglevCallerDetails>(\n'
         '      arguments_vector, deopt_frame,\n'
         '      current_interpreter_frame_.known_node_aspects(), loop_effects_,\n'
         '      unobserved_context_slot_stores_, catch_block_details, IsInsideLoop(),\n'
         '      /* is_eager_inline */ true, call_frequency);',
         '  MaglevCallerDetails* caller_details = zone()->New<MaglevCallerDetails>(\n'
         '      MaglevCallerDetails{\n'
         '          arguments_vector, deopt_frame,\n'
         '          current_interpreter_frame_.known_node_aspects(), loop_effects_,\n'
         '          unobserved_context_slot_stores_, catch_block_details, IsInsideLoop(),\n'
         '          /* is_eager_inline */ true, call_frequency});', 1),
    ],
    'deps/v8/src/heap/safepoint.cc': [
        ('      running_local_heaps.emplace_back(local_heap, qos_override);',
         '      running_local_heaps.emplace_back(RunningLocalHeap{local_heap, qos_override});', 1),
        ('      running_local_heaps.emplace_back(local_heap);',
         '      running_local_heaps.emplace_back(RunningLocalHeap{local_heap});', 1),
    ],
    'deps/v8/src/wasm/wasm-code-manager.cc': [
        ('    generated_code.emplace_back(\n',
         '    generated_code.emplace_back(UnpublishedWasmCode{\n', 1),
        ('        std::move(result.assumptions));',
         '        std::move(result.assumptions)});', 1),
    ],
    'deps/v8/src/compiler/turboshaft/string-escape-analysis-reducer.h': [
        ('    ElidedStringPart(Kind kind, V<String> index) : data(index), kind(kind) {}',
         '    ElidedStringPart(Kind kind, V<String> index) : data{index}, kind(kind) {}', 1),
    ],
    'src/crypto/crypto_kmac.cc': [
        ('ncrypto::Buffer<const void>(key_data, key_size)',
         'ncrypto::Buffer<const void>{key_data, key_size}', 1),
        ('  if (!mac_ctx.update(ncrypto::Buffer<const void>(params.data.data(),\n'
         '                                                  params.data.size()))) {',
         '  if (!mac_ctx.update(ncrypto::Buffer<const void>{params.data.data(),\n'
         '                                                  params.data.size()})) {', 1),
    ],
}
grand = 0
for rel, pairs in edits.items():
    p = f'{root}/{rel}'
    s = open(p, encoding='utf-8').read()
    for item in pairs:
        old, new, expect = item
        n = s.count(old)
        if n != expect:
            print(f'错误：{rel} 命中 {n} != {expect}（{old[:60]!r}，上游结构变化？）'); sys.exit(1)
        s = s.replace(old, new)
        grand += expect
    open(p, 'w', encoding='utf-8').write(s)
    print(f'{rel}: {sum(i[2] for i in pairs)} 处')
if grand != 12:
    print(f'错误：合计 {grand} != 12'); sys.exit(1)
print(f'补丁13已落地：8 文件合计 {grand} 处聚合构造点花括号化')
PYEOF13

# ---- 门0补丁14（run 45011054163 实锤 maglev-ir.h:4372/4385/4402 ×14 TU 同一处）----
# P0634 第 9 形态：别名声明右侧的依赖成员模板限定名。maglev-ir.h 模板类
# CheckedNumberOrOddballToFloat64OrHoleyFloat64<Derived,FloatType> 内
#   using TaggedToFloat64ConversionTypeOffset =
#       Base::template NextBitField<TaggedToFloat64ConversionType, 2>;
# Base = FixedInputValueNodeT<1,Derived> 依赖、NextBitField 是 NodeBase 的 protected
# 别名模板成员 → clang 15 在该位置不认 Base::template ... 为类型名，报
# "expected a type / expected ';' after alias declaration"，连带 4372/4385 两处
# 使用点 undeclared identifier（14 个 TU 各报同一 6 行 = 头文件级）。
# 修 = 原位补 typename（typename nested-name-specifier template(opt) simple-template-id
# 是标准形，永远合法、前向兼容）。
# 明确不改：4479/4566/4598 三处同名字面是不依赖具体类（Base 实参已具体化）内的
# 无限定 NextBitField<...>，本机不报错，不动。
log "门0补丁14：依赖成员模板限定名 1 处补 typename（maglev-ir.h）"
python3 - "$NODE_SRC" <<'PYEOF14' | tee -a "$OUT_DIR/build-log.txt"
import sys
root = sys.argv[1]
rel = 'deps/v8/src/maglev/maglev-ir.h'
p = f'{root}/{rel}'
s = open(p, encoding='utf-8').read()
old = ('  using TaggedToFloat64ConversionTypeOffset =\n'
       '      Base::template NextBitField<TaggedToFloat64ConversionType, 2>;')
new = ('  using TaggedToFloat64ConversionTypeOffset =\n'
       '      typename Base::template NextBitField<TaggedToFloat64ConversionType, 2>;')
n = s.count(old)
if n != 1:
    print(f'错误：{rel} 命中 {n} != 1（上游结构变化？）'); sys.exit(1)
open(p, 'w', encoding='utf-8').write(s.replace(old, new))
print(f'{rel}: 1 处 typename 补齐')
print('补丁14已落地：依赖成员模板限定名修饰完成')
PYEOF14

# ---- 门0补丁15（run 45011054163 实锤 heap-visitor.h 200/203/207 × 51 errors 级联）----
# clang 15 在 CRTP 基类实例化时求值 requires-clause：HeapVisitor<D> 作为 D 的基类被
# 实例化时 D 尚不完备，`ConcreteVisitor::UsePrecomputedObjectSize()` 查找失败 →
# 三条 Visit 重载的约束全废 → 后续 51 处级联（too few arguments / Visit protected /
# no viable conversion）。clang 16+ 推迟到完备点求值，故上游无此问题。
# 修 = 约束改为函数体内的 static_assert（同一判据、同一时机保障：声明不再约束，
# 按元数重载；误用与否在函数体实例化时才检查，此时 D 必完备）——语义与编译期防护
# 等价，仅报错形态从约束失败变为 static_assert。3 声明 + 3 定义 = 6 处。
log "门0补丁15：CRTP 约束改 static_assert 6 处（heap-visitor.h/inl）"
python3 - "$NODE_SRC" <<'PYEOF15' | tee -a "$OUT_DIR/build-log.txt"
import sys
root = sys.argv[1]
edits = {
    'deps/v8/src/heap/heap-visitor.h': [
        ('  V8_INLINE size_t Visit(Tagged<HeapObject> object)\n'
         '    requires(!ConcreteVisitor::UsePrecomputedObjectSize());',
         '  V8_INLINE size_t Visit(Tagged<HeapObject> object);', 1),
        ('  V8_INLINE size_t Visit(Tagged<Map> map, Tagged<HeapObject> object)\n'
         '    requires(!ConcreteVisitor::UsePrecomputedObjectSize());',
         '  V8_INLINE size_t Visit(Tagged<Map> map, Tagged<HeapObject> object);', 1),
        ('  V8_INLINE size_t Visit(Tagged<Map> map, Tagged<HeapObject> object,\n'
         '                         int object_size)\n'
         '    requires(ConcreteVisitor::UsePrecomputedObjectSize());',
         '  V8_INLINE size_t Visit(Tagged<Map> map, Tagged<HeapObject> object,\n'
         '                         int object_size);', 1),
    ],
    'deps/v8/src/heap/heap-visitor-inl.h': [
        ('size_t HeapVisitor<ConcreteVisitor>::Visit(Tagged<HeapObject> object)\n'
         '  requires(!ConcreteVisitor::UsePrecomputedObjectSize())\n'
         '{\n'
         '  return Visit(object->map(cage_base()), object);\n'
         '}',
         'size_t HeapVisitor<ConcreteVisitor>::Visit(Tagged<HeapObject> object) {\n'
         '  static_assert(!ConcreteVisitor::UsePrecomputedObjectSize());\n'
         '  return Visit(object->map(cage_base()), object);\n'
         '}', 1),
        ('size_t HeapVisitor<ConcreteVisitor>::Visit(Tagged<Map> map,\n'
         '                                           Tagged<HeapObject> object)\n'
         '  requires(!ConcreteVisitor::UsePrecomputedObjectSize())\n'
         '{\n'
         '  return Visit(map, object, MaybeObjectSize());\n'
         '}',
         'size_t HeapVisitor<ConcreteVisitor>::Visit(Tagged<Map> map,\n'
         '                                           Tagged<HeapObject> object) {\n'
         '  static_assert(!ConcreteVisitor::UsePrecomputedObjectSize());\n'
         '  return Visit(map, object, MaybeObjectSize());\n'
         '}', 1),
        ('size_t HeapVisitor<ConcreteVisitor>::Visit(Tagged<Map> map,\n'
         '                                           Tagged<HeapObject> object,\n'
         '                                           int object_size)\n'
         '  requires(ConcreteVisitor::UsePrecomputedObjectSize())\n'
         '{\n'
         '  return Visit(map, object, MaybeObjectSize(object_size));\n'
         '}',
         'size_t HeapVisitor<ConcreteVisitor>::Visit(Tagged<Map> map,\n'
         '                                           Tagged<HeapObject> object,\n'
         '                                           int object_size) {\n'
         '  static_assert(ConcreteVisitor::UsePrecomputedObjectSize());\n'
         '  return Visit(map, object, MaybeObjectSize(object_size));\n'
         '}', 1),
    ],
}
grand = 0
for rel, pairs in edits.items():
    p = f'{root}/{rel}'
    s = open(p, encoding='utf-8').read()
    for item in pairs:
        old, new, expect = item
        n = s.count(old)
        if n != expect:
            print(f'错误：{rel} 命中 {n} != {expect}（{old[:60]!r}，上游结构变化？）'); sys.exit(1)
        s = s.replace(old, new)
        grand += expect
    open(p, 'w', encoding='utf-8').write(s)
    print(f'{rel}: {sum(i[2] for i in pairs)} 处')
if grand != 6:
    print(f'错误：合计 {grand} != 6'); sys.exit(1)
print(f'补丁15已落地：2 文件合计 {grand} 处约束改 static_assert')
PYEOF15

# ---- 门0补丁16（run 45011054163 实锤 json-stringifier.cc 前端崩溃 exit 139）----
# clang 15 在处理「模板函数体内的模板调用语句」上的 [[clang::always_inline]] 语句属性时
# 前端崩溃（Sema::ProcessStmtAttributes 空指针，栈已留证）。Clang 17 Release Notes 明载
# 该崩溃在 17 修复（always_inline/noinline 语句属性用于模板函数体内模板函数调用）。
# V8 的 V8_INLINE_STATEMENT 正是该属性（v8config.h:508），json-stringifier.cc 6 处
# 模板成员函数内使用 → 遇 clang 15 必崩。修 = 版本门控 ≥17（纯内联提示，丢掉零语义损失；
# clang 16 及以下走空宏）。
log "门0补丁16：V8_INLINE_STATEMENT 版本门控 ≥17（v8config.h，clang15 崩溃规避）"
python3 - "$NODE_SRC" <<'PYEOF16' | tee -a "$OUT_DIR/build-log.txt"
import sys
root = sys.argv[1]
rel = 'deps/v8/include/v8config.h'
p = f'{root}/{rel}'
s = open(p, encoding='utf-8').read()
old = ('#if !defined(DEBUG) && defined(__clang__) && V8_HAS_ATTRIBUTE_ALWAYS_INLINE\n'
       '# define V8_INLINE_STATEMENT [[clang::always_inline]]')
new = ('#if !defined(DEBUG) && defined(__clang__) && V8_HAS_ATTRIBUTE_ALWAYS_INLINE && \\\n'
       '    __clang_major__ >= 17\n'
       '# define V8_INLINE_STATEMENT [[clang::always_inline]]')
n = s.count(old)
if n != 1:
    print(f'错误：{rel} 命中 {n} != 1（上游结构变化？）'); sys.exit(1)
open(p, 'w', encoding='utf-8').write(s.replace(old, new))
print(f'{rel}: 1 处版本门控')
print('补丁16已落地：语句属性版本门控完成')
PYEOF16


# ---- 门0补丁17（run 45023953328 实锤 libnode.so / node_mksnapshot 链接红）----
# 编译面全绿（192 errors → 0）后仅剩两处链接红：ld.lld unable to find library -latomic
# （SOLINK libnode.so.137 + LINK node_mksnapshot）。源头 = v8_gypfiles/v8.gyp 的
# v8_base_without_compiler 目标 link_settings.libraries（条件 '(OS=="linux" and clang==1)
# or (v8_current_cpu in [...])' 在交叉编译下 OS=linux 且 clang==1 必中）；link_settings
# 会传播到全部下游链接目标，而补丁3 只清了 node.gyp 那处（只作用于 node 可执行目标，
# 故 nop/overlapped-checker 先通过）。修 = 与补丁3 同法原位清空 libraries（musl sysroot
# 无 libatomic；aarch64 128 位原子走后端内联 + compiler-rt builtins 兜底——本机 llvm-nm
# 实查 OHOS SDK 的 aarch64-linux-ohos/libclang_rt.builtins.a 含 __atomic_*_16 与被调
# __aarch64_cas16_* 等 20 个 outline-atomics 符号，SDK 另无任何 libatomic 文件）。条件文本
# 保留原样（mips/arm/riscv 分支语义不动）。
log "门0补丁17：v8.gyp 去 -latomic（link_settings 传播，musl 无此库）"
python3 - "$NODE_SRC" <<'PYEOF17' | tee -a "$OUT_DIR/build-log.txt"
import sys
root = sys.argv[1]
rel = 'tools/v8_gypfiles/v8.gyp'
p = f'{root}/{rel}'
s = open(p, encoding='utf-8').read()
old = "            'libraries': ['-latomic', ],\n"
new = ("            'libraries': [],  # node-ohos GATE0 PATCH17: musl 无 libatomic"
       "（同补丁3；link_settings 传播到 libnode.so/node_mksnapshot）\n")
n = s.count(old)
if n != 1:
    print(f'错误：{rel} -latomic 条目命中 {n} != 1（上游结构变化？）'); sys.exit(1)
open(p, 'w', encoding='utf-8').write(s.replace(old, new))
print(f'{rel}: 1 处 link_settings libraries 去 -latomic')
print('补丁17已落地：v8_gypfiles 去 -latomic 完成')
PYEOF17


CONFIGURE_FLAGS=(
  --dest-cpu=arm64
  --cross-compiling
  --shared
  --without-corepack
)
# 不带 --without-npm：npm 文件集是本门产物（任务书 §1；先例带该参是因其不要 npm）；
# 不带 --v8-disable-temporal-support：v24.22.3 无此开关（透传 gyp 硬红，见文件头注）

log "configure：${CONFIGURE_FLAGS[*]}（CC=$CC CXX=$CXX，均含 -fno-emulated-tls）"
{
  echo ""
  echo "==== configure ===="
  echo "CC=$CC CXX=$CXX（包装器内联 -fno-emulated-tls）"
  echo "flags: ${CONFIGURE_FLAGS[*]}"
} >> "$OUT_DIR/build-log.txt"

(
  cd "$NODE_SRC"
  ./configure "${CONFIGURE_FLAGS[@]}" > "$LOGS/configure.log" 2>&1
  echo "---- configure.log 尾 40 行 ----" >> "$OUT_DIR/build-log.txt"
  tail -40 "$LOGS/configure.log" >> "$OUT_DIR/build-log.txt"
)

# 补丁生效自检（run 44779847011 教训：gyp OS 值不可依赖，提前止损不烧长轮）——
# configure 生成的 makefile 里 zlib_arm_crc32 必须带上 -march，否则补丁条件未命中。
# 注意：node 的 config.gypi 落在源码根（out/ 下只有 Makefile 与 *.mk，run 44781349735 实锤）；
# 观测 grep 一律 2>/dev/null + || true——观测代码不许致命（同轮教训）。
{
  echo "---- gyp 变量实值（config.gypi 节选，根优先）----"
  grep -hE "'(OS|target_arch)'%?:" "$NODE_SRC/config.gypi" "$NODE_SRC/out/config.gypi" 2>/dev/null | head -4 || true
  echo "---- 生成物中 -march=armv8-a+aes+crc 命中文件（前 3）----"
  grep -rl 'armv8-a+aes+crc' "$NODE_SRC/out" 2>/dev/null | head -3 || true
} >> "$OUT_DIR/build-log.txt"
MARCH_HIT="$(grep -rl 'armv8-a+aes+crc' "$NODE_SRC/out" 2>/dev/null | head -1 || true)"
if [ -z "$MARCH_HIT" ]; then
  echo "错误：-march=armv8-a+aes+crc 未进 configure 生成物（补丁条件未命中——查上方 config.gypi 的 OS/target_arch 实值后修条件），提前止损。" >&2
  # 现场取证：zlib_arm_crc32 目标 .mk 里 crc32_simd 的实际编译命令行（定位条件未命中的确定性证据）
  for MK in "$NODE_SRC"/out/deps/zlib/zlib_arm_crc32.target.mk "$NODE_SRC"/deps/zlib/zlib_arm_crc32.target.mk; do
    [ -f "$MK" ] && { echo "---- $MK 内 crc32_simd 编译行 ----" >&2; grep -m3 "crc32_simd" "$MK" >&2 || true; }
  done
  exit 1
fi
log "补丁生效自检过：march 旗已进生成物（$MARCH_HIT）"

log "make -j4 -k（显式覆盖 2 核 nproc：-j2 实测 150 分钟未编完，run 44884007284 闸杀；4 并发 cc1plus 峰值 ~8G < 16G 内存）；构建前磁盘：$(df -h "$OUT_DIR" | tail -1 | awk '{print "avail="$4}')"
# -k（keep-going）自轮 21 后开启：此前失败点都在 configure/补丁/V8 前中段，-k 只浪费时间；
# 轮 19/20/21 已推进到 V8 中后段（TMP 库/turboshaft），首个红 TU 挡住同批独立 TU 的错误面
# → 用一次跑满换多层暴露。失败轮耗时会接近全量编译（估 150~175 分钟），闸 240 有余量。
make -C "$NODE_SRC" -j4 -k > "$LOGS/build.log" 2>&1
log "构建后磁盘：$(df -h "$OUT_DIR" | tail -1 | awk '{print "avail="$4}')（P6 预跑 P2-3 磁盘峰值观测）"
{
  echo ""
  echo "==== make 日志尾 100 行 ===="
  tail -100 "$LOGS/build.log"
} >> "$OUT_DIR/build-log.txt"

# ---- 门0补丁19（2026-11-22 预跑静态审计；实锤 = 轮24 SOLINK 输出名）----
# --shared 时 node.gyp 给 libnode 目标设 product_extension = <(shlib_suffix)，而
# configure.py:1860-1865 在 linux 上取 shlib_suffix = 'so.<node_module_version>'（v24 = so.137）
# → 产物实体 = out/Release/libnode.so.137。gyp make 的 _InstallableTargetInstallPath 用
# output_basename（libnode.so.137）把共享库 copy 到 PRODUCT_DIR，**不生成无版本号的
# libnode.so**（tools/install.py:186-196 同样只认 libnode.<suffix>；node.gyp 无 postbuild 建链）。
# 原写死 out/Release/libnode.so 会在链接全绿后误报「产物缺失」并整轮退出（且早于校验/打包，
# 不产任何 artifact）。修 = 精确名 → 通配 → lib/ 兜底三路解析，命中即记实体名；SONAME 记档
# 说明（门 1/2 一律 dlopen 绝对路径加载，SONAME=libnode.so.137 不影响）。
LIBNODE=""
for cand in "$NODE_SRC/out/Release/libnode.so" "$NODE_SRC"/out/Release/libnode.so.* "$NODE_SRC"/out/Release/lib/libnode.so*; do
  if [ -s "$cand" ]; then LIBNODE="$cand"; break; fi
done
if [ -z "$LIBNODE" ]; then
  echo "错误：out/Release 下无 libnode.so*（--shared 产物应为 libnode.so.<node_module_version>）——make 返回 0 但产物缺失？查 $LOGS/build.log。" >&2
  ls -l "$NODE_SRC/out/Release" 2>/dev/null | grep -i libnode >&2 || true
  exit 1
fi
log "libnode 实体解析：$LIBNODE"
log "libnode SONAME：$("$READELF" -d "$LIBNODE" | awk '/SONAME/{print $NF}')（门 1/2 dlopen 绝对路径加载，SONAME 不影响）"
# 官方 --shared 产物已预 strip，不再 strip（任务书 §3 #1）

# ================= e. 产物六件生成（任务书 §3）=================
STAGE="$OUT_DIR/stage"
mkdir -p "$STAGE"

# #1 libnode.so（原样拷贝，不 strip）
cp -f "$LIBNODE" "$OUT_DIR/libnode.so"

# #2 npm-fileset.tar.gz：deps/npm 去 test 目录全量拷贝（os.walk 仅剔各级 test 子目录——
#    node 源码 tools/install.py L97-100 同规则），顶层唯一目录 npm/，打 tar.gz
log "npm 文件集拷贝（剔各级 test 子目录）"
NPM_STAGE="$STAGE/npm"
python3 - "$NODE_SRC/deps/npm" "$NPM_STAGE" <<'PYEOF'
import os, shutil, sys
src, dst = sys.argv[1], sys.argv[2]
copied = 0
for root, dirs, files in os.walk(src):
    dirs[:] = [d for d in dirs if d != 'test']  # install.py 同规则：各级 test 子目录整棵剔除
    rel = os.path.relpath(root, src)
    outroot = dst if rel == '.' else os.path.join(dst, rel)
    os.makedirs(outroot, exist_ok=True)
    for f in files:
        s = os.path.join(root, f)
        if os.path.islink(s):
            os.symlink(os.readlink(s), os.path.join(outroot, f))  # 保符号链接（谁写谁读 = Node 自解包）
        else:
            shutil.copy2(s, os.path.join(outroot, f))
        copied += 1
print(f"npm fileset: {copied} files copied")
PYEOF
tar -czf "$OUT_DIR/npm-fileset.tar.gz" -C "$STAGE" npm
NPM_FILECOUNT="$(tar -tzf "$OUT_DIR/npm-fileset.tar.gz" | wc -l)"
log "npm-fileset.tar.gz：$NPM_FILECOUNT 个 tar 条目"

# #3 include-embed.tar.gz：src/*.h + deps/v8/include/ 全树 + deps/uv/include/ 全树
#    （node.h 传递包含 v8.h/uv.h，三树全收宁多勿缺——任务书 §3 #3，门 1 宿主壳编译消费）
log "嵌入头文件集打包（src/*.h + v8/include + uv/include）"
(
  cd "$NODE_SRC"
  [ -n "$(ls src/*.h 2>/dev/null)" ] || { echo "错误：$NODE_SRC/src 下无 .h 文件。" >&2; exit 1; }
  [ -d deps/v8/include ] || { echo "错误：缺 deps/v8/include。" >&2; exit 1; }
  [ -d deps/uv/include ] || { echo "错误：缺 deps/uv/include。" >&2; exit 1; }
  tar -czf "$OUT_DIR/include-embed.tar.gz" src/*.h deps/v8/include deps/uv/include
)
INCLUDE_COUNT="$(tar -tzf "$OUT_DIR/include-embed.tar.gz" | wc -l)"
log "include-embed.tar.gz：$INCLUDE_COUNT 个 tar 条目"

# 实测版本读取（防 tag 差异：npm 版本从 deps/npm/package.json、V8 从 v8-version.h）
# 门0补丁20（2026-11-22 预跑静态审计）：v8-version.h 的四个宏是 V8_MAJOR_VERSION /
# V8_MINOR_VERSION / V8_BUILD_NUMBER / V8_PATCH_LEVEL——原实现统一拼 `V8_<name>_VERSION`
# 且传 MAJOR/MINOR/BUILD/PATCH，BUILD/PATCH 两段匹配不到 → 实测输出 `13.6.?.?` 会原样
# 写进 manifest.runtime.v8Version（非构建阻断，但冻结事实污染）。改为按真实宏名逐段取。
NPM_VERSION_ACT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' \
  "$NODE_SRC/deps/npm/package.json" 2>/dev/null || echo "$NPM_VERSION_FALLBACK")"
V8_VERSION_ACT="$(python3 - "$NODE_SRC/deps/v8/include/v8-version.h" <<'PYEOF'
import re, sys
txt = open(sys.argv[1]).read()
def grab(macro):
    m = re.search(rf'#define {macro} (\d+)', txt)
    return m.group(1) if m else '?'
print(f"{grab('V8_MAJOR_VERSION')}.{grab('V8_MINOR_VERSION')}."
      f"{grab('V8_BUILD_NUMBER')}.{grab('V8_PATCH_LEVEL')}")
PYEOF
)"
log "实测版本：npm=$NPM_VERSION_ACT v8=$V8_VERSION_ACT"

# #5 license-manifest.json：逐包遍历 npm 文件集内 **/package.json 的 name/version/license
#    + 同目录 LICENSE*/LICENCE* 文件名；头两行 node=MIT / npm 主体=Artistic-2.0（任务书 §3 #5）
log "license 清单生成"
python3 - "$NPM_STAGE" "$NODE_SRC" "$OUT_DIR/license-manifest.json" <<'PYEOF'
import glob, json, os, sys
npm_stage, node_src, out = sys.argv[1], sys.argv[2], sys.argv[3]
entries = []
for pj in sorted(glob.glob(os.path.join(npm_stage, '**', 'package.json'), recursive=True)):
    try:
        meta = json.load(open(pj, encoding='utf-8'))
    except Exception:
        meta = {}
    pj_dir = os.path.dirname(pj)
    lic_files = sorted(set(
        os.path.basename(p)
        for pat in ('LICENSE*', 'LICENCE*')
        for p in glob.glob(os.path.join(pj_dir, pat))
    ))
    entries.append({
        'name': meta.get('name', ''), 'version': meta.get('version', ''),
        'license': meta.get('license', ''),
        'licenseFiles': lic_files,
        'packageJson': os.path.relpath(pj, npm_stage).replace(os.sep, '/'),
    })
result = {
    'note': 'npm 文件集内逐包许可清单（name/version/license + 同目录 LICENSE*/LICENCE* 文件名）',
    'node': {'license': 'MIT', 'source': 'node 源码树根 LICENSE 文件'},
    'npmMain': {'license': 'Artistic-2.0', 'source': 'deps/npm/LICENSE'},
    'packages': entries,
}
json.dump(result, open(out, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
print(f"license-manifest: {len(entries)} 个 package.json")
PYEOF
[ -s "$NODE_SRC/LICENSE" ] || echo "警告：node 源码树根 LICENSE 缺失（license-manifest node 头应引它）。" >&2
[ -s "$NODE_SRC/deps/npm/LICENSE" ] || echo "警告：deps/npm/LICENSE 缺失（license-manifest npmMain 头应引它）。" >&2

# #4 manifest.json（工厂生成事实部分；frozenAt 冻结在本机三验后，runner 侧恒 null）
sha256_of() { sha256sum "$1" | awk '{print $1}'; }
BYTES_OF_LIBNODE="$(stat -c '%s' "$OUT_DIR/libnode.so")"
BYTES_OF_NPM="$(stat -c '%s' "$OUT_DIR/npm-fileset.tar.gz")"
BYTES_OF_INC="$(stat -c '%s' "$OUT_DIR/include-embed.tar.gz")"
NODE_SRC_SHA256="${NODE_TARBALL_SHA256:-$( [ -s "$OUT_DIR/node-src.sha256" ] && awk '{print $1}' "$OUT_DIR/node-src.sha256" || echo '' )}"
RUN_ID="${GITHUB_RUN_ID:-0}"
RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-anxu24814-jpg/pyohos-builder}/actions/runs/${GITHUB_RUN_ID:-0}"
python3 - "$OUT_DIR/manifest.json" "$NODE_VERSION" "$NPM_VERSION_ACT" "$V8_VERSION_ACT" "$EPOCH" \
  "$NODE_SRC_SHA256" "$CLANG_VERSION" "$BYTES_OF_LIBNODE" "$BYTES_OF_NPM" "$BYTES_OF_INC" \
  "$NPM_FILECOUNT" "$RUN_ID" "$RUN_URL" <<'PYEOF'
import json, sys
(out, node_v, npm_v, v8_v, epoch, src_sha, clang_v, b_lib, b_npm, b_inc,
 fc, run_id, run_url) = sys.argv[1:14]
json.dump({
    'frozenAt': None,
    'runtime': {'nodeVersion': node_v, 'npmVersion': npm_v, 'v8Version': v8_v,
                'epoch': epoch, 'runtimeVersion': f'{node_v}-{epoch}'},
    'source': {'tarball': f'node-v{node_v}.tar.gz',
               'url': f'https://nodejs.org/dist/v{node_v}/node-v{node_v}.tar.gz',
               'sha256': src_sha},
    'toolchain': {'sdk': 'ohos-sdk-windows_linux-public_20260829.tar.gz',
                  'sdkSha256': '6bf6ae1efe8de0e8bd15ddbd7fac58bcb54d9620262a541b9b219439317a4c42',
                  'clangVersion': clang_v,
                  'configureFlags': ['--dest-cpu=arm64', '--cross-compiling', '--shared',
                                     '--without-corepack'],
                  'ccExtraFlags': ['-fno-emulated-tls']},
    'artifacts': {'libnode.so': {'bytes': int(b_lib), 'sha256': ''},
                  'npm-fileset.tar.gz': {'bytes': int(b_npm), 'sha256': '', 'fileCount': int(fc)},
                  'include-embed.tar.gz': {'bytes': int(b_inc), 'sha256': ''}},
    'patches': [
        {'file': 'deps/zlib/zlib.gyp',
         'change': "zlib_arm_crc32 目标 -march=armv8-a+aes+crc cflags 条件改为「非 win 且 arm64」（原仅 gcc 路径；两轮迭代：OS==openharmony 判据因 gyp 层 OS=linux 不命中，改 target_arch）",
         'reason': "OHOS clang 15 忽略 target(\"arch=armv8-a+aes+crc\") 属性致 CRC 内建后端不可选 ICE（run 44778328727/44779847011 实锤 + 本机 clang 15.0.4 复现，2026-11-21）"},
        {'file': 'deps/ada/ada.h',
         'change': "首个 ranges 用点前的 include 块后注入 std::ranges 八件等价 shim（find_if/find_if_not/replace/stable_sort/any_of/all_of/lower_bound/binary_search，经典算法实现，__clang_major__<16 守卫）",
         'reason': "OHOS SDK libc++ 缺 C++20 ranges 算法，ada 42 处调用全红（run 44782745171 实锤 + 本机 clang 15.0.4 复现终验通过，2026-11-21）"},
        {'file': 'node.gyp',
         'change': "linux+clang 分支 libraries 去 -latomic（musl sysroot 无此库）",
         'reason': "目标侧链接 nop/overlapped-checker 报 ld.lld unable to find -latomic（run 44786163438 实锤，2026-11-21）"},
        {'file': '(不落源码) cc-wrappers/compat.h 经 -include 注入目标侧 CXX 包装器（-c 门控）',
         'change': "std::make_unique_for_overwrite shim（C++23 P1132，特性宏守卫）；host 侧不注入（gcc13 自带真函数，注入反致重载歧义）",
         'reason': "V8 13.6 vector.h:296 使用之，目标侧 OHOS libc++ 缺（run 44788351099 实锤）；host 歧义教训 run 44795703343，2026-11-21"},
        {'file': 'deps/v8/src/{heap/factory-base.cc,heap/factory-base.h,objects/objects.h,objects/ordered-hash-table.cc,objects/ordered-hash-table.h}',
         'change': "22 处依赖返回类型 HandleType<T>::MaybeType 原位补 typename（模板模板参数+requires 形态）",
         'reason': "OHOS clang 15 对 C++20 relaxed typename（P0634）该复杂路径支持不全报 missing typename（run 44865919999 实锤 + 本机 clang 15.0.4 复现终验，全树扫描闭环恰 22 处 5 文件，2026-11-21）"},
        {'file': 'deps/v8/src/{heap/mark-compact.h,heap/mark-compact.cc,wasm/turboshaft-graph-interface.cc} + src/node_platform.cc',
         'change': "5 处依赖名补 typename（实锤 2 = WeakObjectWorklist<T>::Local；预防 3 = BrTableAnalysis<T>::CaseVector / TaskQueue<T>::PriorityQueue×2）",
         'reason': "P0634 族另一形态（成员函数模板的类模板实例嵌套类型），run 44896391564 实锤 mark-compact.h:344 + 全形态扫描人审 120 行真缺仅 5 处，2026-11-21"},
        {'file': '(不落源码) cc-wrappers/node-ohos-ranges.h 经 -include 注入目标侧 CXX 包装器（-c 门控，与 compat.h 并列）',
         'change': "std::ranges 算法 12 件 shim（ada 八件投影形态 + find/sort/reverse/for_each 基础形态），__cpp_lib_ranges<202202L 守卫；ada.h 补丁2 段加 NODE_OHOS_RANGES_ALGO_SHIM 互斥宏防双注入",
         'reason': "node src 构建图内 ranges 算法用面 7 种 23 用点（run 44896391564 后全树扫描），OHOS libc++ 15 缺；本机 14/15 文件语法扫 PASS（2026-11-21）"},
        {'file': 'src/{util.h,util-inl.h,node_builtins.h,node_builtins.cc,node_options-inl.h,node_options.cc,tracing/agent_legacy.cc}',
         'change': "视图 6 处经典改写（9 段）：elements_view 重载泛型化 std::get<U>、GetBuiltinIds 返回 vector<string>、for_each(subrange|values) 改经典 for、views::split×2 改 find 分割循环",
         'reason': "视图不 shim（需真视图类，改写更稳）；真实调用链 node_builtins.cc:674 兼容验证 + 本机 14/15 文件语法扫 PASS，2026-11-21"},
        {'file': 'deps/v8/src/wasm/{value-type.h,interpreter/wasm-interpreter.cc,interpreter/wasm-interpreter-runtime.cc}',
         'change': "TypeIndex 族聚合括号初始化 29 处改花括号（T(x)→T{x}、T({x})→T{{x}}，内部零改动；成员调用 ios.TypeIndex( 前置排除 + 同名成员函数的 wasm-disassembler 整文件跳过）",
         'reason': "OHOS clang 15 对 C++20 聚合括号初始化（P0960）支持不全报 no matching conversion for functional-style cast（run 44911644273 实锤 value-type.h:701 + 本机编译验证通过，全树扫描闭环真构造恰 29 处；v2 = disassembler 同名成员函数误伤教训 run 44924561530，2026-11-22）"},
        {'file': 'deps/v8/src/{objects/transitions-inl.h,objects/descriptor-array-inl.h,maglev/maglev-inlining.h}',
         'change': "4 处 std::ranges/std::views 用点改写经典等价形态（二分手写循环×2 + find_if/max_element 两迭代器式）",
         'reason': "OHOS libc++ 15 缺 std::views 与部分 ranges 算法（补丁2 shim 仅注入 ada.h 覆盖不到 V8 头；run 44875780751 实锤 transitions-inl.h:291 + 本机 clang 15.0.4 改写后编译推过改写点，全树扫描闭环 ada 外恰 3 文件 4 处，2026-11-21）"},
        {'file': 'deps/v8/src/sandbox/external-entity-table.h',
         'change': "using 别名声明位置依赖名 3 处补 typename（FreelistHead / Segment / WriteIterator = Base::*，Base 为依赖模板别名 SegmentedTable<Entry,size>）",
         'reason': "P0634 第 6 形态（别名声明位置），run 44975912114 实锤三行 9 errors + 本机 clang 15.0.4 负例复现/正例通过双向验证；同款字面另 2 处（code-pointer-table.h:133 / js-dispatch-table.h:201）Base 实参具体非依赖，明确不修（盲补即编译错），2026-11-22"},
        {'file': 'deps/v8/src/{base/template-meta-programming/list.h,compiler/turboshaft/assembler.h}',
         'change': "TMP 元函数结果类型 ::type 依赖名 9 处补 typename（list.h 6 = fold_right/fold_right1 两层 F<...>::type + insert_at_t/insert_at1_t/fold_right_t/fold_right1_t 四别名；assembler.h 3 = ReducerStack<ReducerList> 内 reducer_list_insert_at×2 + reducer_list_to_stack）",
         'reason': "P0634 第 7 形态（元函数 ::type 后缀），run 44987355713 实锤 list.h 5 行 + 本机 -include 四头编译细化出 6 处（含 CI 未报的 137 行）且同目录三头零错 + assembler.h 3 处最小复现负例恰报、正例零错双向验证；反向排除 67 处候选（maglev-ir 59 + baseline-compiler 3 的 CallInterfaceDescriptorFor<Builtin::k...> 具体枚举实参、mutex/condition-variable 3 的 LazyStaticInstance<Mutex,...> 具体类实参）非依赖不修，2026-11-22"},
        {'file': 'deps/v8/src/{compiler/turboshaft/assembler.h,json/json-stringifier.cc,wasm/interpreter/wasm-interpreter.cc}',
         'change': "依赖限定名 10 处补 typename（assembler.h 5 = IndexRange/Sequence 的 base::value_type/iterator_type ×4 + detail::LoopLabelForHelper<T>::type；json-stringifier.cc 2 = 成员函数模板内 StringT::Char；wasm-interpreter.cc 3 = Handlers<Compressed> 内 traits::* 三兄弟）",
         'reason': "P0634 第 8 形态（小写依赖别名 base / traits / 模板参数前缀），run 44993787875 实锤 assembler.h 5 行（列号与最小复现一致）+ 依赖别名传播扫描（别名表+模板参数集合）全树 16 候选人审收敛真依赖 10 处；明确不改 = interpreter-builtins-x64.cc 3（x64 不在 arm64 构建图）+ mutex.h:103/zone-compact-set.h:317-318（Mutex/std 具体名系扫描器误收）；同轮 make 加 -k（一次暴露多层），2026-11-22"},
        {'file': 'deps/v8/src/{wasm/wasm-module-builder.h,maglev/maglev-regalloc.cc,maglev/maglev-graph-builder.cc,heap/safepoint.cc,wasm/wasm-code-manager.cc,compiler/turboshaft/string-escape-analysis-reducer.h} + src/crypto/crypto_kmac.cc',
         'change': "聚合构造点经库中介转发 12 处改花括号（emplace_back(T{a,b}) / New<T>(T{...}) 形态；库函数收单值走移动、C++17 省略零开销；类型定义不动保持聚合；窄化处显式 static_cast）",
         'reason': "P0960 第二形态（Zone::New / emplace_back / construct_at 等库中介路径的聚合括号初始化），OHOS clang 15 缺 P0960 报 no matching constructor（run 45011054163 实锤 6 类型 7 文件；make -k 首次跑满暴露全量面），2026-11-22"},
        {'file': 'deps/v8/src/maglev/maglev-ir.h',
         'change': "依赖成员模板限定名 1 处补 typename（Base::template NextBitField<...>，Base = FixedInputValueNodeT<1,Derived> 依赖）",
         'reason': "P0634 第 9 形态（typename + template 双消歧义限定名），run 45011054163 实锤 4372/4385/4402 六行 ×14 TU；明确不改 4479/4566/4598 三处不依赖具体类内的无限定同名字面，2026-11-22"},
        {'file': 'deps/v8/src/heap/{heap-visitor.h,heap-visitor-inl.h}',
         'change': "CRTP Visit 重载的 requires 约束 6 处删除、同判据移入函数体 static_assert（3 声明 + 3 定义）",
         'reason': "clang 15 在 CRTP 基类实例化时求值 requires-clause（派生类尚未完备）→ ConcreteVisitor::UsePrecomputedObjectSize 查找失败，51 处级联（run 45011054163 实锤 heap-visitor.h:200/203/207 全实例化点；clang 16+ 推迟求值故上游无此问题），2026-11-22"},
        {'file': 'deps/v8/include/v8config.h',
         'change': "V8_INLINE_STATEMENT 增加 __clang_major__ >= 17 门控（clang 16 及以下走空宏，纯内联提示零语义损失）",
         'reason': "clang 15 处理「模板函数体内模板调用语句」的 [[clang::always_inline]] 语句属性时前端崩溃 exit 139（run 45011054163 实锤 json-stringifier.cc:2412；Clang 17 Release Notes 明载该崩溃于 17 修复），2026-11-22"},
        {'file': 'tools/v8_gypfiles/v8.gyp',
         'change': "v8_base_without_compiler 的 link_settings.libraries 去 -latomic（条件文本不动；musl sysroot 无此库）",
         'reason': "编译面全绿后仅剩链接红：libnode.so / node_mksnapshot 报 ld.lld unable to find -latomic（link_settings 自 v8 依赖传播到全部下游链接目标；补丁3 只覆盖 node.gyp 的 node 可执行目标），run 45023953328 实锤；安全性本机实查 = SDK 无任何 libatomic 文件，而 libclang_rt.builtins.a 含 __atomic_*_16 + __aarch64_cas16_* 20 个 outline-atomics 符号，2026-11-22"},
        {'file': '(不落源码) 脚本自校验：npm 文件集下限 + 关键路径四钉',
         'change': "npm-fileset.tar.gz 条目数下限 5000→2000，并新增关键路径四钉（npm/package.json、npm/bin/npm-cli.js、npm/lib/cli.js、npm/node_modules/ 树）",
         'reason': "原 5000 下限源自「deps/npm 万级」误估（v24.22.3 实测 2610 总条目、去 test 2384），会在链接全绿后把整轮判红且不产总包（校验先于总 tar）——P6 预跑镜头本机 tar -tzf 逐条统计拦下，2026-11-22"},
        {'file': '(不落源码) 脚本产物解析：libnode 实体名三路解析',
         'change': "libnode 产物路径由写死 out/Release/libnode.so 改为「精确名→libnode.so.* 通配→lib/libnode.so* 兜底」三路解析，命中记实体名 + SONAME 进 build-log",
         'reason': "--shared 时 gyp product_extension = shlib_suffix = so.<node_module_version>（configure.py:1860-1865，v24 = so.137），gyp make 按 output_basename 把库 copy 到 PRODUCT_DIR，不生成无版本号 libnode.so（install.py:186-196 同认 libnode.<suffix>；node.gyp 无 postbuild）；轮24 SOLINK 行即 obj.target/libnode.so.137 实锤，原路径会在链接全绿后误报产物缺失且整轮退出，2026-11-22"},
        {'file': '(不落源码) 脚本版本事实：V8 四段宏名修正',
         'change': "V8 版本抽取由统一拼 V8_<name>_VERSION 改为按真实宏名逐段取（V8_MAJOR_VERSION / V8_MINOR_VERSION / V8_BUILD_NUMBER / V8_PATCH_LEVEL）",
         'reason': "v8-version.h 的 BUILD/PATCH 段宏名是 V8_BUILD_NUMBER / V8_PATCH_LEVEL，原拆法输出 `13.6.?.?` 会原样写进 manifest.runtime.v8Version（非构建阻断但污染冻结事实）——P6 预跑镜头本机执行原逻辑复现，修正后输出 13.6.233.17，2026-11-22"},
    ],
    'licenses': {'node': 'MIT', 'npm': 'Artistic-2.0',
                 'npmDepsManifest': 'license-manifest.json'},
    'build': {'repo': 'anxu24814-jpg/pyohos-builder', 'workflow': 'build-node.yml',
              'runId': int(run_id), 'runUrl': run_url, 'date': ''},
    'references': [{'name': 'lzzhij/harmonyos-node-notes', 'license': 'CC BY 4.0'},
                   {'name': 'lzzhij/ohos-node-doctor', 'license': 'MIT'}],
}, open(out, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
print(f"manifest.json written (frozenAt=null, runId={run_id})")
PYEOF
# sha256 在 manifest 落定后回填（sha256_of 于上方定义）
python3 - "$OUT_DIR/manifest.json" \
  "$(sha256_of "$OUT_DIR/libnode.so")" \
  "$(sha256_of "$OUT_DIR/npm-fileset.tar.gz")" \
  "$(sha256_of "$OUT_DIR/include-embed.tar.gz")" <<'PYEOF'
import json, sys
path, s1, s2, s3 = sys.argv[1:5]
m = json.load(open(path, encoding='utf-8'))
m['artifacts']['libnode.so']['sha256'] = s1
m['artifacts']['npm-fileset.tar.gz']['sha256'] = s2
m['artifacts']['include-embed.tar.gz']['sha256'] = s3
m['build']['date'] = __import__('datetime').datetime.utcnow().strftime('%Y-%m-%d')
json.dump(m, open(path, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
PYEOF

# ================= f. runner 校验（任务书 §7 四件 + 附加，全命令化）=================
# 自查两问：①合法改动（V8 小版本升级、npm 文件数浮动）不红——判据只锁形态与下限；
# ②缺陷必红——PIE 形态 / INTERP 段 / 符号缺失 / 白名单外依赖 / 零字节各有一条独立红路径。
log "校验 1/4：ELF 头（Type: DYN 且 Machine: AArch64，禁 PIE 可执行）"
"$READELF" -h "$OUT_DIR/libnode.so" > "$OUT_DIR/elf-header.txt"
ETYPE="$(awk '/^ *Type:/{print $2}' "$OUT_DIR/elf-header.txt")"
MACHINE="$(awk '/^ *Machine:/{print $2}' "$OUT_DIR/elf-header.txt")"
[ "$ETYPE" = "DYN" ] || { echo "错误：libnode.so Type=$ETYPE（预期 DYN；ET_EXEC/PIE 形态 dlopen 后 TLS 别名宿主必崩）。" >&2; exit 1; }
[ "$MACHINE" = "AArch64" ] || { echo "错误：libnode.so Machine=$MACHINE（预期 AArch64）。" >&2; exit 1; }
cat "$OUT_DIR/elf-header.txt" >> "$OUT_DIR/build-log.txt"

log "校验 2/4：INTERP 段数 = 0（共享库无解释器段）"
"$READELF" -l "$OUT_DIR/libnode.so" > "$OUT_DIR/program-headers.txt"  # 先落盘：-l 失败由 set -e 自红（防截断形态假绿，P6 预跑 P2-2）
INTERP_N="$(grep -c INTERP "$OUT_DIR/program-headers.txt" || true)"
[ "$INTERP_N" = "0" ] || { echo "错误：libnode.so 含 $INTERP_N 个 INTERP 段（PIE 链接形态，红）。" >&2; exit 1; }

log "校验 3/4：node::Start 符号导出（dlsym 目标）"
# 先宽 grep node5Start（mangled 名以实测二进制为准，禁猜——任务书 §5/§7.3）；
# 宽匹配命中为红判据，精确名 _ZN4node5StartEiPPc 不中只降级警告（变体 mangling 不算缺陷）。
"$NM" -D "$OUT_DIR/libnode.so" | grep 'node5Start' > "$OUT_DIR/node-start-symbols.txt" \
  || { echo "错误：llvm-nm -D 未找到 node5Start 符号（node::Start 未导出，dlsym 必挂）。" >&2; exit 1; }
if grep -q '_ZN4node5StartEiPPc' "$OUT_DIR/node-start-symbols.txt"; then
  log "精确名 _ZN4node5StartEiPPc 在场"
else
  echo "警告：宽匹配命中但精确名 _ZN4node5StartEiPPc 不在（mangling 变体？实测符号见 node-start-symbols.txt，U5 本机核对后再定判据）。" >&2
fi
cat "$OUT_DIR/node-start-symbols.txt" >> "$OUT_DIR/build-log.txt"

log "校验 4/4：DT_NEEDED 白名单（含 libc++_shared.so；零绝对路径 / linux-gnu / libstdc++ / libgcc_s）"
"$READELF" -d "$OUT_DIR/libnode.so" > "$OUT_DIR/dynamic-raw.txt"  # 先落盘：-d 失败由 set -e 自红；防输出格式漂移致提取空表（P6 预跑 P2-1）
NEEDED_RAW_N="$(grep -c 'Shared library' "$OUT_DIR/dynamic-raw.txt" || true)"
[ "$NEEDED_RAW_N" -ge 1 ] || { echo "错误：readelf -d 无 Shared library 条目（输出格式漂移或动态段异常，见 dynamic-raw.txt）。" >&2; exit 1; }
grep -oP 'Shared library: \[\K[^\]]+' "$OUT_DIR/dynamic-raw.txt" > "$OUT_DIR/needed.txt" || true
cat "$OUT_DIR/needed.txt" >> "$OUT_DIR/build-log.txt"
grep -qx 'libc++_shared.so' "$OUT_DIR/needed.txt" \
  || { echo "错误：NEEDED 缺 libc++_shared.so（六约束②，主工程包内已有该件）。" >&2; exit 1; }
# 白名单 = 任务书 §7.4 六件 + doctor ELF-002 系统库集（ohos-node-doctor.mjs:219）并集：
# libz.so/libhilog.so/ld-musl/ld-linux 均为 OHOS 系统侧合法装载名
NEEDED_WHITELIST="libc.so libm.so libdl.so librt.so libpthread.so liblog.so libhilog.so libz.so libc++_shared.so ld-musl-aarch64.so.1 ld-linux-aarch64.so.1"
BAD_NEEDED=0
while IFS= read -r lib; do
  [ -z "$lib" ] && continue
  case " $NEEDED_WHITELIST " in
    *" $lib "*) ;;  # 白名单内
    *) echo "错误：NEEDED 白名单外条目：$lib（绝对路径/linux-gnu triple/libstdc++/libgcc_s = 链到宿主工具链）。" >&2; BAD_NEEDED=1 ;;
  esac
done < "$OUT_DIR/needed.txt"
[ "$BAD_NEEDED" = "0" ] || exit 1

log "附加校验：六件非零字节 + file 形态 + npm 文件数下限"
for f in libnode.so npm-fileset.tar.gz include-embed.tar.gz manifest.json license-manifest.json build-log.txt node-build-env.txt; do
  [ -s "$OUT_DIR/$f" ] || { echo "错误：产物缺失或零字节：$OUT_DIR/$f。" >&2; exit 1; }
done
FILE_OUT="$(file "$OUT_DIR/libnode.so")"
echo "$FILE_OUT" >> "$OUT_DIR/build-log.txt"
echo "$FILE_OUT" | grep -q 'ELF 64-bit LSB shared object' \
  || { echo "错误：file 形态异常：$FILE_OUT（预期 ELF 64-bit LSB shared object）。" >&2; exit 1; }
echo "$FILE_OUT" | grep -q 'ARM aarch64' \
  || { echo "错误：file 架构异常：$FILE_OUT（预期 ARM aarch64）。" >&2; exit 1; }
# 文件数下限口径修正（补丁18，2026-11-22）：v24.22.3 的 deps/npm 本机实查 = 2610 条目，
# 去各级 test 后 = 2384（1926 文件 + 458 目录，tar -tzf 逐条统计）；原 ≥5000 下限来自
# 「deps/npm 全量应为万级」的误估（实际万级是含 test 与文档源的 git 树口径），会在编译
# 全绿后把整轮判红且不产总包。改为 2000 保守下限（对实测留 ~16% 余量防拷贝截断）+
# 关键路径存在性四钉（纯计数抓不到「拷了但缺核心」的残缺）。
[ "$NPM_FILECOUNT" -ge 2000 ] \
  || { echo "错误：npm-fileset.tar.gz 条目数 $NPM_FILECOUNT < 2000（deps/npm 去 test 实测 2384，拷贝可能不完整）。" >&2; exit 1; }
for k in npm/package.json npm/bin/npm-cli.js npm/lib/cli.js; do
  tar -tzf "$OUT_DIR/npm-fileset.tar.gz" | grep -qx "$k" \
    || { echo "错误：npm-fileset.tar.gz 缺关键条目 $k（npm 包残缺）。" >&2; exit 1; }
done
tar -tzf "$OUT_DIR/npm-fileset.tar.gz" | grep -q '^npm/node_modules/' \
  || { echo "错误：npm-fileset.tar.gz 缺 npm/node_modules/ 树（npm 依赖集未随包）。" >&2; exit 1; }
# npm tar 顶层唯一目录 = npm/
BAD_TOP="$(tar -tzf "$OUT_DIR/npm-fileset.tar.gz" | awk -F/ '{print $1}' | sort -u | grep -vx 'npm' || true)"
[ -z "$BAD_TOP" ] || { echo "错误：npm-fileset.tar.gz 顶层目录不唯一：$BAD_TOP（预期仅 npm/）。" >&2; exit 1; }

# 校验结论进 build-log
{
  echo ""
  echo "==== 校验结论 ===="
  echo "1. ELF 头：Type=$ETYPE Machine=$MACHINE —— PASS"
  echo "2. INTERP 段数：$INTERP_N —— PASS"
  echo "3. node5Start 符号：$(wc -l < "$OUT_DIR/node-start-symbols.txt") 处命中 —— PASS"
  echo "4. NEEDED 白名单：$(wc -l < "$OUT_DIR/needed.txt") 条全过（含 libc++_shared.so）—— PASS"
  echo "附加：七件非零字节 + file 形态 + npm 条目 $NPM_FILECOUNT ≥ 2000 + 关键路径四钉 + 顶层唯一 npm/ —— PASS"
} >> "$OUT_DIR/build-log.txt"

# ================= 收尾：总 tar + 字节数表 =================
# 六件 + node-build-env.txt 打总 tar.gz（artifact 上传物；「Python 工厂同款」= 单 tarball 上传）
log "打总包 ${ARTIFACT_BASE}.tar.gz"
tar -czf "$OUT_DIR/${ARTIFACT_BASE}.tar.gz" -C "$OUT_DIR" \
  libnode.so npm-fileset.tar.gz include-embed.tar.gz \
  manifest.json license-manifest.json build-log.txt node-build-env.txt
echo "== 产物字节数表 =="
ls -l "$OUT_DIR"/libnode.so "$OUT_DIR"/npm-fileset.tar.gz "$OUT_DIR"/include-embed.tar.gz \
  "$OUT_DIR"/manifest.json "$OUT_DIR"/license-manifest.json "$OUT_DIR"/build-log.txt \
  "$OUT_DIR"/node-build-env.txt "$OUT_DIR"/"${ARTIFACT_BASE}.tar.gz" \
  | awk '{printf "%12d B  %s\n", $5, $9}'
echo "== node-ohos 构建完成：$OUT_DIR/${ARTIFACT_BASE}.tar.gz（npm 条目 $NPM_FILECOUNT，clang $CLANG_VERSION）=="
