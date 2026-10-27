#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Build pinned public USB components for the app's macOS 13 deployment target.
# No hardware, credentials, firmware or system installation is accessed.
set -eu
cd "$(dirname "$0")/.."
project="$PWD"
root="$project/build/usb-tools"
mkdir -p "$root/downloads" "$root/src" "$root/prefix"
fetch() {
    name="$1"; expected="$2"; url="$3"
    if [ ! -f "$root/downloads/$name" ]; then curl -fL --proto '=https' "$url" -o "$root/downloads/$name"; fi
    actual="$(shasum -a 256 "$root/downloads/$name" | cut -d ' ' -f 1)"
    [ "$actual" = "$expected" ] || { printf '%s\n' "Checksum mismatch: $name" >&2; exit 1; }
}
fetch dfu-util-0.11.tar.gz b4b53ba21a82ef7e3d4c47df2952adf5fa494f499b6b0b57c58c5d04ae8ff19e https://dfu-util.sourceforge.net/releases/dfu-util-0.11.tar.gz
fetch libusb-1.0.29.tar.bz2 5977fc950f8d1395ccea9bd48c06b3f808fd3c2c961b44b0c2e6e29fc3a70a85 https://github.com/libusb/libusb/releases/download/v1.0.29/libusb-1.0.29.tar.bz2
if [ ! -d "$root/src/dfu-util-0.11" ]; then tar -xzf "$root/downloads/dfu-util-0.11.tar.gz" -C "$root/src"; fi
if [ ! -d "$root/src/libusb-1.0.29" ]; then tar -xjf "$root/downloads/libusb-1.0.29.tar.bz2" -C "$root/src"; fi
export MACOSX_DEPLOYMENT_TARGET=13.0
# A conservative limit avoids an empty sysctl-derived value in restricted builds.
export lt_cv_sys_max_cmd_len=32768
export CC="$(xcrun -f clang)"
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export CFLAGS="-O2 -mmacosx-version-min=13.0"
export LDFLAGS="-mmacosx-version-min=13.0"
cd "$root/src/libusb-1.0.29"
if [ -f Makefile ]; then make clean > "$root/libusb-clean.log" 2>&1; fi
./configure --prefix="$root/prefix" --enable-static --disable-shared > "$root/libusb-configure.log" 2>&1
make -j4 > "$root/libusb-make.log" 2>&1
make install > "$root/libusb-install.log" 2>&1
cd "$root/src/dfu-util-0.11"
if [ -f Makefile ]; then make clean > "$root/dfu-clean.log" 2>&1; fi
USB_CFLAGS="-I$root/prefix/include/libusb-1.0" USB_LIBS="$root/prefix/lib/libusb-1.0.a -lobjc -framework IOKit -framework CoreFoundation -framework Security" \
./configure --prefix="$root/prefix" > "$root/dfu-configure.log" 2>&1
make -j4 > "$root/dfu-make.log" 2>&1
make install > "$root/dfu-install.log" 2>&1
"$root/prefix/bin/dfu-util" --version
printf '%s\n' "USB components built in $root/prefix; source archives retained in downloads."
