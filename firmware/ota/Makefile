# SPDX-License-Identifier: GPL-2.0-or-later
CC ?= cc
CFLAGS = -std=c11 -Wall -Wextra -Werror -pedantic -O1 -g
CORE = src/keyglow_ota.c src/sha256.c src/keyglow_ota_wire.c
.PHONY: test clean
test: build/test_ota
	./build/test_ota
	python3 -B tests/test_package.py
build/test_ota: $(CORE) tests/test_ota.c include/keyglow_ota.h include/keyglow_ota_wire.h src/sha256.h
	mkdir -p build
	$(CC) $(CFLAGS) -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -Iinclude $(CORE) tests/test_ota.c -o $@
clean:
	rm -rf build
