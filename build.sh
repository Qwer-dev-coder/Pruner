#!/usr/bin/env bash
# Builds dist/Pruner.exe on Linux/macOS with mingw-w64:
#   sudo apt install gcc-mingw-w64-x86-64 binutils-mingw-w64-x86-64
# The exe embeds Pruner.ps1 and assets/ and unpacks them on start.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$PWD"
CC="${CC:-x86_64-w64-mingw32-gcc}"
RC="${RC:-x86_64-w64-mingw32-windres}"

rm -rf build && mkdir -p build dist
{
  echo '#include <winuser.h>'
  echo "1 24 \"$ROOT/launcher/app.manifest\""
  echo "1 ICON \"$ROOT/launcher/icon.ico\""
  echo "#include \"$ROOT/launcher/version.rc\""
} > build/resources.rc

: > build/files.txt
id=101
add() { echo "$id|$1" >> build/files.txt; echo "$id RCDATA \"$ROOT/$1\"" >> build/resources.rc; id=$((id + 1)); }
add "Pruner.ps1"
for f in assets/wallpapers/*; do [ -f "$f" ] && add "$f"; done
echo "100 RCDATA \"$ROOT/build/files.txt\"" >> build/resources.rc

"$RC" -O coff -i build/resources.rc -o build/resources.o
"$CC" -O2 -s -municode -mwindows -static -o dist/Pruner.exe launcher/launcher.c build/resources.o -lshell32 -luser32
echo "Built dist/Pruner.exe ($(du -h dist/Pruner.exe | cut -f1))"
