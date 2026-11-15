#!/usr/bin/env python3
"""在 Caddy 的 android 站点块里临时插入 / 移除一个下载路径。

serve-apk.sh 调用它，不要单独跑。
包裹标记让 --remove 能精确删干净，不会动到别的配置。
"""

import shutil
import sys

CADDYFILE = "/etc/caddy/Caddyfile"
BEGIN = "# BEGIN android-apk-download"
END = "# END android-apk-download"


def strip_block(text):
    """删掉标记包裹的那段（含标记行）。没有就原样返回。"""
    out = []
    skipping = False
    for line in text.splitlines(keepends=True):
        stripped = line.strip()
        if stripped == BEGIN:
            skipping = True
            continue
        if stripped == END:
            skipping = False
            continue
        if not skipping:
            out.append(line)
    return "".join(out)


def build_block(token):
    return (
        "\t" + BEGIN + "\n"
        "\thandle_path /dl/" + token + "/* {\n"
        "\t\troot * /opt/android-mcp/public\n"
        "\t\tfile_server\n"
        "\t}\n"
        "\t" + END + "\n"
    )


def main():
    if len(sys.argv) < 3:
        print("usage: caddy_apk_patch.py <host> <token|--remove>", file=sys.stderr)
        return 2

    host = sys.argv[1]
    token = sys.argv[2]
    marker = host + " {"

    with open(CADDYFILE, "r", encoding="utf-8") as fh:
        original = fh.read()

    if original.find(marker) < 0:
        print("在 {0} 里找不到 {1} 站点块".format(CADDYFILE, host), file=sys.stderr)
        return 1

    cleaned = strip_block(original)

    if token == "--remove":
        updated = cleaned
    else:
        idx = cleaned.find(marker)
        if idx < 0:
            print("清理后找不到站点块，不改", file=sys.stderr)
            return 1
        insert_at = cleaned.find("\n", idx) + 1
        updated = cleaned[:insert_at] + build_block(token) + cleaned[insert_at:]

    if updated == original:
        print("no-change")
        return 0

    shutil.copy2(CADDYFILE, CADDYFILE + ".bak-apk")
    with open(CADDYFILE, "w", encoding="utf-8") as fh:
        fh.write(updated)
    print("patched")
    return 0


if __name__ == "__main__":
    sys.exit(main())
