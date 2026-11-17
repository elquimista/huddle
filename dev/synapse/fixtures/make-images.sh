#!/bin/bash
# Regenerates the pictures that `seed.py images` sends. Needs ffmpeg (brew install ffmpeg).
# All of them are computer-generated patterns, so nothing is photographed or borrowed.
#   photo.jpg   1600 x 1067   a large, colourful picture, like a photo
#   tall.png     600 x 2400   very tall, like a long screenshot
#   wide.jpg    3000 x  400   very wide, like a panorama
#   tiny.png      32 x   32   smaller than the space images get
#   anim.gif     240 x  180   two seconds of animation
set -euo pipefail
cd "$(dirname "$0")"
quiet=(-hide_banner -loglevel error -y)
ffmpeg "${quiet[@]}" -f lavfi -i "gradients=s=1600x1067:c0=0x1b3a5c:c1=0xf2a65a:c2=0xd94f70:c3=0x2e8b8b:n=4:seed=7:speed=0.01" -frames:v 1 -q:v 5 photo.jpg
ffmpeg "${quiet[@]}" -f lavfi -i "testsrc2=s=600x2400" -frames:v 1 -pix_fmt rgb24 tall.png
ffmpeg "${quiet[@]}" -f lavfi -i "gradients=s=3000x400:c0=0x243b55:c1=0x8fd3f4:c2=0xfbc2eb:n=3:seed=3:speed=0.01" -frames:v 1 -q:v 5 wide.jpg
ffmpeg "${quiet[@]}" -f lavfi -i "color=c=0x34c759:s=32x32" -frames:v 1 tiny.png
# The length is given to the source itself: the palette filter waits for its input to end.
ffmpeg "${quiet[@]}" -f lavfi -t 2 -i "gradients=s=240x180:rate=10:c0=0xff5e62:c1=0xff9966:c2=0x4facfe:c3=0x43e97b:n=4:seed=5:speed=0.12" \
    -vf "split[a][b];[a]palettegen=max_colors=32[p];[b][p]paletteuse=dither=bayer" anim.gif
ls -l photo.jpg tall.png wide.jpg tiny.png anim.gif
