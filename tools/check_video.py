# -*- coding: utf-8 -*-
"""Check a demo video against the competition submission rules.

Rules: MP4 container, H.264 video, AAC audio, <= 180 s, <= 300 MB,
1920x1080 (or larger), constant frame rate 24-30 fps.

Usage: python tools/check_video.py deliverables/video/demo.mp4
"""
import os
import re
import subprocess
import sys

import imageio_ffmpeg

FFMPEG = imageio_ffmpeg.get_ffmpeg_exe()
LIMIT_S = 180.0
LIMIT_BYTES = 300 * 1024 * 1024


def probe(path):
    p = subprocess.run([FFMPEG, "-hide_banner", "-i", path],
                       capture_output=True, text=True, errors="replace")
    txt = p.stderr
    info = {"raw": txt}
    m = re.search(r"Duration:\s*(\d+):(\d+):(\d+\.\d+)", txt)
    if m:
        info["duration"] = int(m.group(1)) * 3600 + int(m.group(2)) * 60 + float(m.group(3))
    m = re.search(r"Stream #\d+:\d+.*?Video:\s*([a-z0-9]+).*?(\d{3,4})x(\d{3,4})", txt, re.S)
    if m:
        info["vcodec"] = m.group(1)
        info["width"] = int(m.group(2))
        info["height"] = int(m.group(3))
    m = re.search(r"(\d+(?:\.\d+)?)\s*fps", txt)
    if m:
        info["fps"] = float(m.group(1))
    info["acodec"] = "aac" if re.search(r"Audio:\s*aac", txt) else ("none" if "Audio:" not in txt else "other")
    info["size"] = os.path.getsize(path)
    return info


def main():
    if len(sys.argv) < 2:
        print("usage: python tools/check_video.py <file.mp4>")
        return 2
    path = sys.argv[1]
    if not os.path.isfile(path):
        print("FAIL file not found:", path)
        return 2
    i = probe(path)
    fails = []

    def need(ok, msg):
        print(("OK   " if ok else "FAIL ") + msg)
        if not ok:
            fails.append(msg)

    need(path.lower().endswith(".mp4"), "container is .mp4")
    need(i.get("vcodec") == "h264", f"video codec is H.264 (got {i.get('vcodec')})")
    need(i.get("acodec") == "aac", f"audio codec is AAC (got {i.get('acodec')})")
    need(i.get("duration", 999) <= LIMIT_S, f"duration <= 180 s (got {i.get('duration')} s)")
    need(i["size"] <= LIMIT_BYTES, f"size <= 300 MiB (got {i['size']/1048576:.1f} MiB)")
    need(i.get("width", 0) >= 1920 and i.get("height", 0) >= 1080,
         f"resolution >= 1920x1080 (got {i.get('width')}x{i.get('height')})")
    need(23.5 <= i.get("fps", 0) <= 30.5, f"frame rate 24-30 fps (got {i.get('fps')})")

    print(f"\nfile: {path}\n{i['size']/1048576:.1f} MiB, {i.get('duration')} s, "
          f"{i.get('width')}x{i.get('height')} @ {i.get('fps')} fps, {i.get('vcodec')}/{i.get('acodec')}")
    if fails:
        print("\nRESULT: FAIL (%d)" % len(fails))
        return 1
    print("\nRESULT: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
