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
for a in "\$@"; do
  case "\$a" in -c) exec "$CLANGXX" -fno-emulated-tls -include "$COMPAT_H" "\$@";; esac
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

log "make -j$(nproc)（先例原样；预算 40~70 分钟）；构建前磁盘：$(df -h "$OUT_DIR" | tail -1 | awk '{print "avail="$4}')"
make -C "$NODE_SRC" -j"$(nproc)" > "$LOGS/build.log" 2>&1
log "构建后磁盘：$(df -h "$OUT_DIR" | tail -1 | awk '{print "avail="$4}')（P6 预跑 P2-3 磁盘峰值观测）"
{
  echo ""
  echo "==== make 日志尾 100 行 ===="
  tail -100 "$LOGS/build.log"
} >> "$OUT_DIR/build-log.txt"

LIBNODE="$NODE_SRC/out/Release/libnode.so"
if [ ! -s "$LIBNODE" ]; then
  echo "错误：构建产物缺失或零字节：$LIBNODE（构建失败但 make 返回 0？查 $LOGS/build.log）。" >&2
  exit 1
fi
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
NPM_VERSION_ACT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' \
  "$NODE_SRC/deps/npm/package.json" 2>/dev/null || echo "$NPM_VERSION_FALLBACK")"
V8_VERSION_ACT="$(python3 - "$NODE_SRC/deps/v8/include/v8-version.h" <<'PYEOF'
import re, sys
txt = open(sys.argv[1]).read()
def grab(name):
    m = re.search(rf'#define V8_{name}_VERSION (\d+)', txt)
    return m.group(1) if m else '?'
print(f"{grab('MAJOR')}.{grab('MINOR')}.{grab('BUILD')}.{grab('PATCH')}")
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
    ],
    'licenses': {'node': 'MIT', 'npm': 'Artistic-2.0',
                 'npmDepsManifest': 'evidence/license-manifest.json'},
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
[ "$NPM_FILECOUNT" -ge 5000 ] \
  || { echo "错误：npm-fileset.tar.gz 条目数 $NPM_FILECOUNT < 5000（deps/npm 全量去 test 应为万级——拷贝可能不完整）。" >&2; exit 1; }
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
  echo "附加：七件非零字节 + file 形态 + npm 条目 $NPM_FILECOUNT ≥ 5000 + 顶层唯一 npm/ —— PASS"
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
