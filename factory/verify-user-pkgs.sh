#!/usr/bin/env bash
# verify-user-pkgs.sh — 门 5 自装包白名单 qemu 预验证（2026-11-15 门 5 笔）
# 按真机五层布局（stdlib.zip : site-packages.zip : extras : py-site : libs）组装，
# 白名单 9 件 wheel 下载 → sha256 校验 → 解包进 py-site → qemu aarch64 冒烟 9 项
# 真值判据（与 host 全链验证 / BLOCKED 真机清单同源）。
# 前置：qemu-aarch64-static 在 PATH；rootfs 就绪（$WORK/alpine-a64，STAGE=rootfs 产物——
# build-packages.sh 同约定；本机 Windows 无 qemu，实际跑面 = builder 仓 CI 或 WSL/Linux 机）。
# 产物输入源（U1a 2026-11-16 起双面，二选一由环境变量定）：
#   · aicontrol 工作副本（缺省）：RAW_PY/LIBS 不传时默认指本仓 rawfile/python 双 zip
#     与 entry/libs/arm64-v8a（本地回归用）。
#   · builder 仓 CI（机跑面）：调方传 RAW_PY=<含 site-packages.zip+extras.zip 的目录>
#     与 LIBS=<.so 平铺目录>（从 gate2 g2 tarball + build-packages pkg-final artifact
#     组装——builder 仓没有 aicontrol 工作副本，见 verify-user-pkgs.yml 组装步骤）。
# 用法：WORK=<ohos-py-pkgs 目录> [RAW_PY=… LIBS=…] bash verify-user-pkgs.sh
# ★ 白名单冻结单源 = entry/src/main/ets/common/pyexec/PyPackages.ets（PY_USER_PACKAGES）——
#   本脚本 WHITELIST 表是它的验证侧镜像，换版本两处同步（同 PY_PRESET_PACKAGES 纪律）。
set -euo pipefail

WORK="${WORK:-$HOME/ohos-py-pkgs}"
ROOTFS="$WORK/alpine-a64"
HERE="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$HERE/../.." && pwd)"
RAW_PY="${RAW_PY:-$APP_ROOT/entry/src/main/resources/rawfile/python}"
LIBS="${LIBS:-$APP_ROOT/entry/libs/arm64-v8a}"

# 白名单（与 PyPackages.ets PY_USER_PACKAGES 同源冻结——name version sha256 url）
WHITELIST='
python-docx|1.2.0|3fd478f3250fbbbfd3b94fe1e985955737c145627498896a8a6bf81f4baf66c7|https://files.pythonhosted.org/packages/d0/00/1e03a4989fa5795da308cd774f05b704ace555a70f9bf9d3be057b680bcf/python_docx-1.2.0-py3-none-any.whl
python-pptx|1.0.2|160838e0b8565a8b1f67947675886e9fea18aa5e795db7ae531606d68e785cba|https://files.pythonhosted.org/packages/d9/4f/00be2196329ebbff56ce564aa94efb0fbc828d00de250b1980de1a34ab49/python_pptx-1.0.2-py3-none-any.whl
pypdf|7.1.0|47cca6b24bdcf4c4d65b5f7b8b972535c61710a061261e737688777cfd9a7bfb|https://files.pythonhosted.org/packages/ed/4c/d19f91b743c8579b67e3d8b001e095745dec5bb13a9b4b9eadc235a85d9e/pypdf-7.1.0-py3-none-any.whl
pdfplumber|0.11.10|7741ea81bf165b474b153e6789d10d18e06b6ddcf3ec84289c3ef2fed6802580|https://files.pythonhosted.org/packages/a2/9a/07d658e1e7fad860f1c541ab941348125dbdab773be3a0afaf32361866c7/pdfplumber-0.11.10-py3-none-any.whl
beautifulsoup4|4.15.0|d6f88de62e1d4e38ecb1077eb9724cd0eff29d2a08ca16a401e9b9e93f117cf9|https://files.pythonhosted.org/packages/88/c6/92fcd42f1ba33e1184263f25bfabf3d27c383410470f169e4b8163bf9c17/beautifulsoup4-4.15.0-py3-none-any.whl
soupsieve|4.1.1|8ff3422dab0b720fb667ee79864d80531a0e57994a13eb701697719ffcb751f6|https://files.pythonhosted.org/packages/cd/65/7fae69a095696195334a934eab23aeb12e2715e6c3f08025d2f91942750e/soupsieve-4.1.1-py3-none-any.whl
xlsxwriter|3.3.1|8e2c89e59d733fe59e112317218c64fbbc276d90a8c144ebd6f7fa15e7ab184a|https://files.pythonhosted.org/packages/88/eb/1e6af9959a567901a7e7c7cef2e75883e487df223ed67f9a8977ff863bd8/xlsxwriter-3.3.1-py3-none-any.whl
pdfminer.six|20260107|366585ba97e80dffa8f00cebe303d2f381884d8637af4ce422f1df3ef38111a9|https://files.pythonhosted.org/packages/20/8b/28c4eaec9d6b036a52cb44720408f26b1a143ca9bce76cc19e8f5de00ab4/pdfminer_six-20260107-py3-none-any.whl
charset-normalizer|3.5.2|b6b751274acb69d77b3323d6b7dbaa3c7fdfc1eb829b7eb61d262f32e1af9685|https://files.pythonhosted.org/packages/fc/ad/d07d7862a62ffa6d79d68074d14823243dd235a77c45262acbf6adeb28bf/charset_normalizer-3.5.2-py3-none-any.whl
'

if [ ! -x "$ROOTFS/lib/ld-musl-aarch64.so.1" ]; then
  echo "错误：rootfs 未就绪（$ROOTFS）——先在构建机跑 build-packages.sh STAGE=rootfs。" >&2
  exit 1
fi
command -v qemu-aarch64-static >/dev/null || { echo "错误：qemu-aarch64-static 不在 PATH。" >&2; exit 1; }
# 产物输入源显式校验（P0-1）：双面输入下环境变量指错路径必须当场红，不能等 cp 半途炸
for f in site-packages.zip extras.zip; do
  [ -s "$RAW_PY/$f" ] || { echo "错误：输入缺 $RAW_PY/$f（RAW_PY=$RAW_PY）。" >&2; exit 1; }
done
if [ ! -d "$LIBS" ] || [ -z "$(ls -A "$LIBS" 2>/dev/null)" ]; then
  echo "错误：LIBS 目录不存在或为空：$LIBS。" >&2
  exit 1
fi

VWORK="$WORK/verify-user"
rm -rf "$VWORK"
mkdir -p "$VWORK/site-root/py-site" "$VWORK/extras" "$VWORK/libs" "$VWORK/wheels"
cp -f "$RAW_PY/site-packages.zip" "$VWORK/site-root/"
( cd "$VWORK/extras" && unzip -qo "$RAW_PY/extras.zip" )
cp -fr "$LIBS/"* "$VWORK/libs/"
# gate3 增量（可选并入）：白名单闭包可落在预置 gate3 层（pdfminer.six 20260107 硬依赖
# cryptography——首跑 ModuleNotFoundError 实锤），builder CI 传 G3_OUT=<含 extras/ 与
# libs/ 子树的目录> 使布局全量同构真机；本地缺省空 = aicontrol 工作副本形态（entry/libs
# 已含 gate3 .so、rawfile extras.zip 已含 gate3 合并树，天然全量无需并入）。
G3_OUT="${G3_OUT:-}"
if [ -n "$G3_OUT" ]; then
  [ -d "$G3_OUT/extras" ] || { echo "错误：G3_OUT=$G3_OUT 无 extras/ 子树。" >&2; exit 1; }
  cp -fr "$G3_OUT/extras/." "$VWORK/extras/"
  [ -d "$G3_OUT/libs" ] && cp -fr "$G3_OUT/libs/." "$VWORK/libs/"
fi

# 下载 + sha256 校验 + 解包进 py-site（与 PyPackages.ets 引导脚本闸序同源：哈希 → 内容
# 检查（此处 unzip 前列黑名单）→ 解包）
echo "== [1/3] 下载白名单 wheel 并校验 sha256"
while IFS='|' read -r name version sha url; do
  [ -z "$name" ] && continue
  fn="$(basename "$url")"
  curl -fsSL --retry 2 -o "$VWORK/wheels/$fn" "$url"
  got="$(sha256sum "$VWORK/wheels/$fn" | cut -d' ' -f1)"
  if [ "$got" != "$sha" ]; then
    echo "错误：$name sha256 不符（got $got）" >&2; exit 2
  fi
  # 二进制条目黑名单（同引导脚本判据——.so 及 .so.数字 变体、其余平台二进制后缀）
  if unzip -l "$VWORK/wheels/$fn" | awk '{print $4}' | grep -Eiq '\.(so|pyd|dll|dylib|node|a|o|exe|bin)$|\.so\.'; then
    echo "错误：$name wheel 含二进制条目" >&2; exit 3
  fi
  ( cd "$VWORK/site-root/py-site" && unzip -qo "$VWORK/wheels/$fn" )
  echo "  OK $name $version"
done <<< "$WHITELIST"

# qemu 运行器（PYTHONPATH 五层 = 真机门 5 布局：py-site 在 extras 与 libs 之间）
# fortify 符号族差集存根（同 build-packages.sh rootfs 段 run-python.sh 形制）：qemu 的
# Alpine musl 无 OHOS fortify 符号（__fd_chk 等），stdlib 扩展装载即 relocation 失败
# ——首跑实锤 select.cpython-313.so: __fd_chk: symbol not found；stub 随 rootfs
# 自举（STAGE=rootfs）生成在 $ROOTFS/py/ext/。
STUB="$ROOTFS/py/ext/libexecinfo_stub.so"
[ -s "$STUB" ] || { echo "错误：fortify 存根不在（$STUB）——rootfs 自举未跑或布局漂移。" >&2; exit 1; }
cat > "$VWORK/run-user-verify.sh" <<EOF
#!/bin/sh
export PYTHONHOME=$ROOTFS/usr/local
export PYTHONPATH=$ROOTFS/py/python313.zip:$VWORK/site-root/site-packages.zip:\$PWD/extras:\$PWD/site-root/py-site:\$PWD/libs
export LD_LIBRARY_PATH=\$PWD/libs
export LD_PRELOAD=$STUB
exec qemu-aarch64-static -L $ROOTFS $ROOTFS/usr/local/bin/python3.13 "\$@"
EOF
chmod +x "$VWORK/run-user-verify.sh"

cat > "$VWORK/smoke_user.py" <<'EOF'
# 9 项真值判据（与 host 全链验证 verify-whitelist 同源；假值即抛 → 非零退出）
import io, os, sys, tempfile
ok = []
def check(name, fn):
    r = fn()
    if not r:
        raise AssertionError(name + ' -> ' + repr(r))
    ok.append(name); print('ok', name)
def _docx():
    from docx import Document
    d = Document(); d.add_paragraph('hello door5')
    b = io.BytesIO(); d.save(b)
    return len(b.getvalue()) > 1000
def _pptx():
    from pptx import Presentation
    b = io.BytesIO(); Presentation().save(b)
    return len(b.getvalue()) > 1000
def _pypdf():
    from pypdf import PdfWriter, PdfReader
    w = PdfWriter(); w.add_blank_page(200, 100)
    b = io.BytesIO(); w.write(b); b.seek(0)
    return len(PdfReader(b).pages) == 1
def _pdfplumber():
    from pypdf import PdfWriter
    from pdfplumber import PDF
    w = PdfWriter(); w.add_blank_page(200, 100)
    b = io.BytesIO(); w.write(b); b.seek(0)
    with PDF(b) as pdf:
        return len(pdf.pages) == 1
def _bs4():
    from bs4 import BeautifulSoup
    s = BeautifulSoup('<div><a href="/x">a</a><a href="/y">b</a></div>', 'html.parser')
    return [a['href'] for a in s.select('a[href]')] == ['/x', '/y']
def _xlsx():
    from xlsxwriter import Workbook
    b = io.BytesIO(); wb = Workbook(b); ws = wb.add_worksheet()
    ws.write(0, 0, 'door5'); wb.close()
    return len(b.getvalue()) > 200
def _pdfminer():
    from pypdf import PdfWriter
    from pdfminer.high_level import extract_text
    w = PdfWriter(); w.add_blank_page(200, 100)
    fd, path = tempfile.mkstemp(suffix='.pdf'); os.close(fd)
    with open(path, 'wb') as f: w.write(f)
    try:
        return isinstance(extract_text(path), str)
    finally:
        os.unlink(path)
def _charset():
    from charset_normalizer import detect
    a = detect('你好世界，这是足够长的中文样本供编码检测'.encode('gbk'))['encoding'].lower()
    b = detect('plain ascii text long enough for detection'.encode())['encoding'].lower()
    return 'gb' in a and b == 'ascii'
def _soupsieve():
    import soupsieve
    return soupsieve.__version__ != ''
check('python-docx', _docx)
check('python-pptx', _pptx)
check('pypdf', _pypdf)
check('pdfplumber', _pdfplumber)
check('beautifulsoup4+soupsieve', _bs4)
check('xlsxwriter', _xlsx)
check('pdfminer.six', _pdfminer)
check('charset-normalizer', _charset)
check('soupsieve', _soupsieve)
if len(ok) != 9:
    raise SystemExit('USER-SMOKE-FAIL %d/9' % len(ok))
print('USER-PKGS-OK 9 items passed')
EOF

echo "== [2/3] qemu 五层布局冒烟"
( cd "$VWORK" && ./run-user-verify.sh smoke_user.py ) \
  || { echo "错误：qemu 白名单冒烟失败。" >&2; exit 4; }
echo "== [3/3] 全绿：门 5 白名单在 OHOS 布局下可用"
