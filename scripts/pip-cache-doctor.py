"""清理 pip HTTP 缓存里写坏的条目。

背景：pip 的 http-v2 缓存把每条响应拆成两个文件 —— 元数据（含 Content-Length）和
``<key>.body``。写 body 时先写 ``<key>.body<random>.tmp`` 再改名。如果改名/写入被打断
（在受 IPGuard 这类文件管控软件的机器上很常见），就会留下一个 ``.tmp`` 孤儿，而 ``.body``
可能已经是截断的。之后 pip 读到的是截断的 body，却按元数据里的长度去校验，于是稳定报：

    ProtocolError: ('Connection broken: IncompleteRead(15417 bytes read, 383 more expected)')

这种错误重试无效（缓存里的内容不会变），换镜像也无效（根本没走网络）。

用法：
    python scripts/pip-cache-doctor.py           # 只报告，不删
    python scripts/pip-cache-doctor.py --fix     # 删除可疑条目
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path


def cache_dir() -> Path:
    out = subprocess.run(  # noqa: S603
        [sys.executable, "-m", "pip", "cache", "dir"],
        capture_output=True,
        text=True,
        check=True,
    )
    return Path(out.stdout.strip())


def find_suspect_entries(http_v2: Path) -> dict[Path, list[Path]]:
    """按 key 归组：有 .tmp 孤儿的 key 视为写入被打断，整条作废。"""
    entries: dict[Path, list[Path]] = {}
    for tmp in http_v2.rglob("*.tmp"):
        # 文件名形如 <key>.body<random>.tmp，key 是 .body 之前的部分
        name = tmp.name
        if ".body" not in name:
            continue
        key = tmp.parent / name.split(".body", 1)[0]
        files = entries.setdefault(key, [])
        files.append(tmp)

    for key, files in entries.items():
        for sibling in (key, key.with_name(key.name + ".body")):
            if sibling.exists():
                files.append(sibling)
    return entries


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fix", action="store_true", help="实际删除可疑条目（默认只报告）")
    args = parser.parse_args()

    http_v2 = cache_dir() / "http-v2"
    if not http_v2.is_dir():
        print(f"没有找到 {http_v2}，无需处理。")
        return 0

    entries = find_suspect_entries(http_v2)
    if not entries:
        print("pip HTTP 缓存看起来是干净的。")
        return 0

    total_files = sum(len(v) for v in entries.values())
    total_bytes = sum(f.stat().st_size for v in entries.values() for f in v if f.exists())
    print(f"发现 {len(entries)} 条写入被打断的缓存条目（{total_files} 个文件，{total_bytes / 1024 / 1024:.1f} MiB）。")

    if not args.fix:
        print("加 --fix 执行删除。删除是安全的：pip 只会重新下载这些响应。")
        return 0

    removed = 0
    for files in entries.values():
        for f in files:
            try:
                f.unlink()
            except FileNotFoundError:
                continue
            except OSError as exc:
                print(f"  删除失败 {f}: {exc}")
            else:
                removed += 1
    print(f"已删除 {removed} 个文件。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
