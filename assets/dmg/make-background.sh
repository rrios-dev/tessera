#!/bin/zsh
# Renders the DMG window background at 1x and 2x and merges them into background.tiff, the
# multi-resolution image Finder picks from: black, a hairline grid fading from the top, a soft
# glow, the lockup, and background.svg on top. Needs ImageMagick.
# usage: assets/dmg/make-background.sh
set -euo pipefail
here=${0:A:h}
brand=$here/../brand
work=$(mktemp -d)
for scale in 1 2; do
  w=$((660 * scale)); h=$((420 * scale)); cell=$((44 * scale))
  lines=()
  for ((x = cell - 6 * scale; x < w; x += cell)); do lines+=(-draw "line $x,0 $x,$h"); done
  for ((y = cell - 6 * scale; y < h; y += cell)); do lines+=(-draw "line 0,$y $w,$y"); done
  magick -size ${w}x${h} xc:black -stroke 'rgb(20,20,20)' -strokewidth $scale "${lines[@]}" $work/grid.png
  magick -size ${w}x${h} -define gradient:center=$((w / 2)),0 -define gradient:radii=$((w * 85 / 100)),$((h * 150 / 100)) \
    radial-gradient:white-black $work/fade.png
  magick -size ${w}x${h} -define gradient:center=$((w / 2)),0 -define gradient:radii=$((w * 55 / 100)),$((h * 70 / 100)) \
    radial-gradient:'rgb(34,34,34)'-black $work/glow.png
  magick $work/grid.png $work/fade.png -compose multiply -composite \
    $work/glow.png -compose screen -composite $work/base.png
  magick -background none -density $((72 * scale)) $here/background.svg -resize ${w}x${h}! $work/front.png
  magick -background none -density 1200 $brand/lockup-white.svg -resize $((150 * scale))x $work/lockup.png
  magick $work/base.png $work/front.png -compose over -composite \
    $work/lockup.png -gravity north -geometry +0+$((58 * scale)) -composite \
    -alpha off -depth 8 -units PixelsPerInch -density $((72 * scale)) $work/background-$scale.png
done
tiffutil -cathidpicheck $work/background-1.png $work/background-2.png -out $work/background.tiff
tiffutil -lzw $work/background.tiff -out $here/background.tiff
cp $work/background-2.png $here/preview@2x.png
ls -la $here/background.tiff
