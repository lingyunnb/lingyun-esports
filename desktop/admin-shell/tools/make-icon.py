# -*- coding: utf-8 -*-
"""
品牌图标产物生成器（一次性，产物入库；源图不入库改动）
================================================================================
输入：docs/验收素材/2026-10-09-QQ互联提交/qq_icon_512.png（512×512 直角 PNG，QQ 互联提交用）
输出：build/icon.png（窗口图标，原图直拷）
      build/icon.ico（exe 图标，多尺寸 16/24/32/48/64/128/256）

为什么自己生成 .ico 而不让 electron-builder 转换：
  转换要走它的 app-builder 二进制与图标流水线，多一个可能失败/多一次下载的环节；
  本机就有 Pillow（DSH 运行时自带），离线、确定、可重复。

用法：<python> tools/make-icon.py
"""
import os
import shutil
import sys

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
REPO = os.path.abspath(os.path.join(ROOT, "..", ".."))
SRC = os.path.join(REPO, "docs", "验收素材", "2026-10-09-QQ互联提交", "qq_icon_512.png")
BUILD = os.path.join(ROOT, "build")

SIZES = [16, 24, 32, 48, 64, 128, 256]


def main():
    if not os.path.exists(SRC):
        print(f"[FAIL] 源图不存在：{SRC}")
        return 1
    os.makedirs(BUILD, exist_ok=True)
    img = Image.open(SRC).convert("RGBA")
    print(f"[源图] {SRC} → {img.size[0]}×{img.size[1]} {img.mode}")

    png_out = os.path.join(BUILD, "icon.png")
    shutil.copyfile(SRC, png_out)
    print(f"[写入] {png_out}（{os.path.getsize(png_out)} B）")

    ico_out = os.path.join(BUILD, "icon.ico")
    img.save(ico_out, format="ICO", sizes=[(s, s) for s in SIZES])
    print(f"[写入] {ico_out}（{os.path.getsize(ico_out)} B，尺寸 {SIZES}）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
