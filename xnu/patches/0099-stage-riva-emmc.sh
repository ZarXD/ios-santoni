#!/bin/bash
# dxb runs patches/*.sh from the XNU source root before applying *.patch.
# riva (MSM8917): stage the eMMC root driver next to the UFS one and add a
# "rd=mmcroot0" branch to IOFindBSDRoot. Idempotent, SANTONI-only.
set -euo pipefail

[[ "${MACHINE_CONFIG:-}" == SANTONI ]] || exit 0

python3 - << 'PY'
from pathlib import Path
import re

# 1) conf/files: register bsd/dev/sweet_mmc.c right after sweet_ufs.c
f = Path('bsd/conf/files')
t = f.read_text()
if 'bsd/dev/sweet_mmc.c' not in t:
    line = 'bsd/dev/sweet_ufs.c\t\t\tstandard\n'
    if line in t:
        t = t.replace(line, line + 'bsd/dev/sweet_mmc.c\t\t\tstandard\n', 1)
    else:
        t += 'bsd/dev/sweet_mmc.c\t\t\tstandard\n'
    f.write_text(t)
    print('riva: registered sweet_mmc.c in bsd/conf/files')

# 2) IOKitBSDInit.cpp: rd=mmcroot0 branch before the UFS root branch
f = Path('iokit/bsddev/IOKitBSDInit.cpp')
t = f.read_text()
if 'sweet_mmc_rootdev' not in t:
    anchor = re.search(r'#if defined\(ARM64_BOARD_CONFIG_SWEET\)\s*\n\s*//\s*\n\s*//\s*SWEET: root on a GPT partition', t)
    if not anchor:
        print('riva: UFS root anchor not found yet, will be added by later patch')
    else:
    block = (
        '#if defined(ARM64_BOARD_CONFIG_SWEET)\n'
        '//\n'
        '//\tSWEET: root on eMMC (riva, bsd/dev/sweet_mmc.c)\n'
        '//\n'
        '\tif (strcmp(rdBootVar, "mmcroot0") == 0) {\n'
        '\t\textern int sweet_mmc_rootdev(dev_t *dev);\n'
        '\t\tOSSafeReleaseNULL(matching);\n'
        '\t\tint mmc_error = sweet_mmc_rootdev(root);\n'
        '\t\tif (mmc_error) {\n'
        '\t\t\tpanic("IOFindBSDRoot: SWEET eMMC root %s unavailable: %d", rdBootVar, mmc_error);\n'
        '\t\t}\n'
        '\t\tstrlcpy(rootName, rdBootVar, rootNameSize);\n'
        '\t\tIOLog("BSD root: %s, major %d, minor %d\\n", rootName, major(*root), minor(*root));\n'
        '\t\t*oflags = 0;\n'
        '\t\tgoto iofrootx;\n'
        '\t}\n'
        '#endif\n'
        '\n'
    )
    t = t[:anchor.start()] + block + t[anchor.start():]
    f.write_text(t)
    print('riva: added rd=mmcroot0 branch to IOFindBSDRoot')
PY

# 3) Driver source: extract bsd/dev/sweet_mmc.c from the patch in this dir.
#    Patches land in dxb/patches/, xnu root is CWD.
if [ ! -f bsd/dev/sweet_mmc.c ]; then
  python3 - << 'PY'
from pathlib import Path
import glob

src = None
for pat in ('patches/0099*.patch', '../patches/0099*.patch'):
    hits = sorted(glob.glob(pat))
    if hits:
        src = hits[0]
        break
assert src, '0099 riva emmc patch not found'
text = Path(src).read_text()
start = text.index('+++ b/bsd/dev/sweet_mmc.c')
start = text.index('\n', start) + 1          # skip the +++ line
body = []
for line in text[start:].splitlines():
    if line.startswith('diff --git'):
        break
    body.append(line[1:] if line.startswith('+') else line)
out = Path('bsd/dev/sweet_mmc.c')
out.write_text('\n'.join(body).lstrip('\n'))
print('riva: wrote bsd/dev/sweet_mmc.c from', src)
PY
fi

echo "riva emmc staged (SANTONI)"
