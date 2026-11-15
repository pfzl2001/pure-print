# -*- coding: utf-8 -*-
"""Windows 构建前,幂等地修补 pub cache 中 pdfx / printing 的 CMake 配置。

为什么需要:
1. pdfx 与 printing 都调用 download_project(PROJ pdfium ...),共用同一个目标
   目录前缀,后执行的一方会覆盖 pdfium_SOURCE_DIR,导致链接到错误版本的
   pdfium.dll。这里把 printing 的项目名改为 pdfium_printing。
2. 两个插件都在 CMake configure 阶段从 GitHub 下载 pdfium,离线或网络不稳定
   时会拿到 0 字节文件。这里允许用环境变量指向预先下载好的 tgz。

本脚本只修改本机 pub cache 中的插件副本,不修改仓库源码。可重复执行。

用法(在 flutter pub get 之后、flutter build windows 之前):
    python tool/patch_windows_plugins.py
    PUREPRINT_LOCAL_PDFIUM=/path/4690.tgz \
    PUREPRINT_LOCAL_PDFIUM_PRINTING=/path/5200.tgz \
    flutter build windows --release
"""
import glob
import os
import re
import sys

PDFX_MARKER = "ENV{PUREPRINT_LOCAL_PDFIUM})"
PRINTING_MARKER = "ENV{PUREPRINT_LOCAL_PDFIUM_PRINTING})"
DOWNLOAD_ANCHOR = "# Download pdfium"

PDFX_BLOCK = """# Offline mirror (pure-print): allow a pre-downloaded pdfium archive.
if(DEFINED ENV{PUREPRINT_LOCAL_PDFIUM})
  set(PDFIUM_URL "$ENV{PUREPRINT_LOCAL_PDFIUM}")
endif()

"""

PRINTING_BLOCK = """# Offline mirror (pure-print): allow a pre-downloaded pdfium archive and a
# distinct project prefix so this does not collide with pdfx's download.
if(DEFINED ENV{PUREPRINT_LOCAL_PDFIUM_PRINTING})
  set(PDFIUM_URL "$ENV{PUREPRINT_LOCAL_PDFIUM_PRINTING}")
endif()

"""


def cache_roots():
    roots = []
    env = os.environ.get("PUB_CACHE")
    if env:
        roots.append(os.path.join(env, "hosted"))
    local = os.environ.get("LOCALAPPDATA")
    if local:
        roots.append(os.path.join(local, "Pub", "Cache", "hosted"))
    roots.append(os.path.join(os.path.expanduser("~"), ".pub-cache", "hosted"))
    out = []
    for r in roots:
        if not os.path.isdir(r):
            continue
        for d in os.listdir(r):
            p = os.path.join(r, d)
            if os.path.isdir(p):
                out.append(p)
    return out


def find(roots, pattern):
    hits = []
    for r in roots:
        hits.extend(glob.glob(os.path.join(r, pattern)))
    return sorted(set(hits))


def read(path):
    with open(path, "r", encoding="utf-8", newline="") as f:
        return f.read()


def write(path, text):
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(text)


def ensure_block(text, marker, block):
    if marker in text:
        return text, False
    if DOWNLOAD_ANCHOR not in text:
        raise RuntimeError("找不到 '# Download pdfium' 锚点,插件版本可能已变化")
    return text.replace(DOWNLOAD_ANCHOR, block + DOWNLOAD_ANCHOR, 1), True


def patch_pdfx(path):
    text = read(path)
    changed = False
    text, c = ensure_block(text, PDFX_MARKER, PDFX_BLOCK)
    changed |= c
    if changed:
        write(path, text)
    return changed


def patch_printing(path):
    text = read(path)
    changed = False
    text, c = ensure_block(text, PRINTING_MARKER, PRINTING_BLOCK)
    changed |= c

    if "pdfium_printing" not in text:
        new, n = re.subn(
            r"(download_project\s*\(\s*PROJ\s+)pdfium(\s)",
            r"\1pdfium_printing\2",
            text,
            count=1,
        )
        if n != 1:
            raise RuntimeError("未能定位 printing 的 download_project(PROJ pdfium)")
        text = new
        text = text.replace(
            "${pdfium_SOURCE_DIR}/PDFiumConfig.cmake",
            "${pdfium_printing_SOURCE_DIR}/PDFiumConfig.cmake",
        )
        changed = True
    if changed:
        write(path, text)
    return changed


def main():
    roots = cache_roots()
    if not roots:
        sys.exit("未找到 pub cache,请先执行 flutter pub get")
    pdfx = find(roots, "pdfx-*/windows/CMakeLists.txt")
    printing = find(roots, "printing-*/windows/CMakeLists.txt")
    if not pdfx or not printing:
        sys.exit("未找到 pdfx / printing 的 windows/CMakeLists.txt: %s / %s"
                 % (pdfx, printing))
    for p in pdfx:
        print(("PATCHED " if patch_pdfx(p) else "ok      ") + p)
    for p in printing:
        print(("PATCHED " if patch_printing(p) else "ok      ") + p)
    print("Windows 插件补丁检查完成")


if __name__ == "__main__":
    main()
