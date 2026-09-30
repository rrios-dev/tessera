#!/bin/zsh
# Rasterises the brand SVGs: AppIcon.icns (every macOS size, @1x and @2x) and PNG exports of
# the mark, the wordmark and the lockups for documents and the web. Needs ImageMagick.
# usage: assets/brand/make-icons.sh   (after generate.py)
set -euo pipefail
here=${0:A:h}
cd $here
out=$here/png
set_dir=$(mktemp -d)/AppIcon.iconset
mkdir -p $out $set_dir
render() { magick -background none -density 1200 "$1" -resize "$2x$2" "$3"; }
for size in 16 32 128 256 512; do
  render app-icon.svg $size $set_dir/icon_${size}x${size}.png
  render app-icon.svg $((size * 2)) $set_dir/icon_${size}x${size}@2x.png
done
iconutil -c icns $set_dir -o $here/AppIcon.icns
for size in 1024 512 256 128 64 32; do render app-icon.svg $size $out/app-icon-$size.png; done
render app-icon-light.svg 1024 $out/app-icon-light-1024.png
for name in mark mark-white; do render $name.svg 512 $out/$name-512.png; done
for name in wordmark wordmark-white lockup lockup-white lockup-on-dark lockup-on-light; do
  magick -background none -density 600 $name.svg -resize 2000x $out/$name@2x.png
  magick -background none -density 300 $name.svg -resize 1000x $out/$name.png
done
ls -la $here/AppIcon.icns
