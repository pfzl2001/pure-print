# -*- coding: utf-8 -*-
"""从 pubspec.lock + 本地 pub cache 重新生成 assets/licenses/THIRD_PARTY_NOTICES.txt。

开发期工具,不参与 App 运行。依赖变更后执行:
    python tool/generate_notices.py

目的:确保公开源码时,所有直接依赖与传递依赖的许可证全文都能随仓库提供,
避免手工维护清单出现遗漏(例如 Apache-2.0 / MPL-2.0 分发条款要求保留许可文本)。
"""
import hashlib
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOCK = os.path.join(ROOT, "pubspec.lock")
OUT = os.path.join(ROOT, "assets", "licenses", "THIRD_PARTY_NOTICES.txt")
FONT = os.path.join(ROOT, "assets", "fonts", "DroidSansFallbackFull.ttf")

# 固定到 AOSP android-4.4.4_r2 标签:该版本同时含中文与拉丁字形,
# 且与本仓库随附文件字节完全一致(master 分支的较新版本缺少拉丁字形)。
FONT_SOURCE = (
    "https://github.com/aosp-mirror/platform_frameworks_base/blob/"
    "android-4.4.4_r2/data/fonts/DroidSansFallbackFull.ttf"
)
FONT_UPSTREAM_TAG = "android-4.4.4_r2"


def cache_roots():
    base = os.environ.get("PUB_CACHE")
    if not base:
        base = os.path.join(
            os.environ.get("LOCALAPPDATA", os.path.expanduser("~")),
            "Pub",
            "Cache",
        )
    hosted = os.path.join(base, "hosted")
    if not os.path.isdir(hosted):
        return []
    return [os.path.join(hosted, d) for d in os.listdir(hosted)
            if os.path.isdir(os.path.join(hosted, d))]


def parse_lock():
    text = open(LOCK, encoding="utf-8").read().replace("\r", "")
    packages = []
    cur = None
    for line in text.split("\n"):
        m = re.match(r"^  ([A-Za-z0-9_]+):\s*$", line)
        if m:
            cur = {"name": m.group(1), "source": "", "version": ""}
            packages.append(cur)
            continue
        if cur is None:
            continue
        m = re.match(r"^    source:\s*(\S+)", line)
        if m:
            cur["source"] = m.group(1)
            continue
        m = re.match(r'^    version:\s*"?([^"\s]+)"?', line)
        if m:
            cur["version"] = m.group(1)
    return [p for p in packages if p["source"] and p["version"]]


def find_license(name, version, roots):
    for root in roots:
        path = os.path.join(root, "%s-%s" % (name, version), "LICENSE")
        if os.path.isfile(path):
            return open(path, encoding="utf-8", errors="replace").read().strip()
    return None


def spdx_of(text):
    head = " ".join(text[:400].split()) if text else ""
    if "Mozilla Public License" in head:
        return "MPL-2.0"
    if "Apache License" in head:
        return "Apache-2.0"
    if "Redistribution and use in source and binary forms" in head:
        return "BSD-3-Clause"
    if "BSD" in head[:120]:
        return "BSD-3-Clause"
    if "Permission is hereby granted, free of charge" in head or "MIT" in head[:120]:
        return "MIT"
    return "SEE-LICENSE-TEXT"


def main():
    roots = cache_roots()
    packages = parse_lock()
    if not packages:
        sys.exit("无法解析 pubspec.lock")

    groups = {}  # sha -> {spdx, text, members}
    sdk_members = []
    for p in packages:
        label = "%s-%s" % (p["name"], p["version"])
        if p["source"] == "sdk":
            sdk_members.append(label)
            continue
        text = find_license(p["name"], p["version"], roots)
        if text is None:
            text = ("LICENSE file not found in local pub cache. "
                    "See the package page on pub.dev for its license.")
        key = hashlib.sha256(text.encode("utf-8", "replace")).hexdigest()[:12]
        g = groups.setdefault(key, {"spdx": spdx_of(text), "text": text, "members": []})
        g["members"].append(label)

    font_sha = "(font missing)"
    if os.path.isfile(FONT):
        font_sha = hashlib.sha256(open(FONT, "rb").read()).hexdigest()

    lines = []
    w = lines.append
    w("纯净打印 / 第三方开源许可声明")
    w("=" * 64)
    w("")
    w("本文件由 tool/generate_notices.py 依据 pubspec.lock 自动生成,请勿手工编辑。")
    w("覆盖范围:全部直接依赖与传递依赖(含 dev_dependencies)。")
    w("")
    w("本应用为独立开发,未使用任何商业打印 App 的代码、资源、界面素材、商标、")
    w("私有 SDK 或服务端接口;打印能力基于公开的 IPP / mDNS / AirPrint 标准实现。")
    w("")
    w("随附字体")
    w("-" * 64)
    w("文件: assets/fonts/DroidSansFallbackFull.ttf")
    w("来源: Android Open Source Project (AOSP) platform/frameworks/base")
    w("      标签: " + FONT_UPSTREAM_TAG)
    w("      " + FONT_SOURCE)
    w("许可: Apache License 2.0 (全文见下方 Apache-2.0 分组)")
    w("SHA-256: " + font_sha)
    w("说明: 取自 AOSP 官方镜像且字节一致,未作修改;仅在生成 PDF 时用于嵌入字形。")
    w("      该标签版本同时包含中文与拉丁字形,可正常渲染标题与表格数字。")
    w("")
    w("组件清单")
    w("-" * 64)
    for key in sorted(groups, key=lambda k: groups[k]["members"][0]):
        g = groups[key]
        w("[%s] %s" % (g["spdx"].ljust(16), ", ".join(sorted(g["members"]))))
    if sdk_members:
        w("[Flutter/Dart SDK] " + ", ".join(sorted(sdk_members)))
        w("  SDK 组件随 Flutter SDK 提供,使用 BSD-3-Clause 许可证。")
    w("")
    w("许可证全文(按文本去重,同一分组内所有组件适用)")
    w("=" * 64)

    ordered = sorted(groups.items(), key=lambda kv: (kv[1]["spdx"], kv[1]["members"][0]))
    for i, (key, g) in enumerate(ordered, 1):
        w("")
        w("--- L%d | %s | %d 个组件 ---" % (i, g["spdx"], len(g["members"])))
        w("适用: " + ", ".join(sorted(g["members"])))
        w("-" * 64)
        w(g["text"])

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    print("已生成 %s" % OUT)
    print("组件 %d 个 / 许可证分组 %d 组 / %d 字节"
          % (len(packages), len(groups), os.path.getsize(OUT)))


if __name__ == "__main__":
    main()
