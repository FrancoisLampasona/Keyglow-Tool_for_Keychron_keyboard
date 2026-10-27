#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Reproduce upstream LKBT51 SPI bounds failures, then test the in-memory fix.

Extracts the actual pinned read function and its caller allocation. SPI is a
synchronous host stub; no keyboard, credentials or firmware build are accessed.
The QMK working tree is read-only. Both expected ASan failures are required.
"""
import difflib
import importlib.util
import os
from pathlib import Path
import re
import resource
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
FIRMWARE = Path(__file__).resolve().parents[1]
SOURCE_PATH = 'keyboards/keychron/common/wireless/lkbt51.c'
HEADER_PATH = 'keyboards/keychron/common/wireless/lkbt51.h'
spec = importlib.util.spec_from_file_location('qmk_patch', FIRMWARE / 'apply-qmk-patch.py')
patch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patch)


def read_function(source):
    start = source.index('void lkbt51_read(uint8_t* payload, uint8_t len) {')
    return source[start:source.index('\n}', start) + 2]


def caller(source):
    match = re.search(r'        uint8_t buf\[[^\n]+\n        lkbt51_read\(buf, expect_len\);', source)
    assert match, 'Expected receive allocation and read call missing'
    return match.group(0)


PREAMBLE = r'''
#include <assert.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#define HAL_USE_SPI 1
static int WT_DRIVER, spicfg;
static unsigned calls, transferred;
static bool rx_only, verify_bytes;
static volatile uint8_t checksum;
static uint8_t expect_len;
static void spiStart(void *driver, const void *config) { (void)driver; (void)config; }
static void spiSelect(void *driver) { (void)driver; }
static void spiUnselect(void *driver) { (void)driver; }
static void spiStop(void *driver) { (void)driver; }
static void spiExchange(void *driver, size_t count, const void *tx, void *rx) {
    (void)driver;
    const uint8_t *bytes = tx;
    ++calls; transferred = (unsigned)count;
    if (!rx_only) {
        for (size_t index = 0; index < count; ++index) checksum ^= bytes[index];
    }
    if (verify_bytes) {
        assert(count == (unsigned)expect_len + 4u);
        assert(bytes[0] == 0x84 && bytes[1] == 0x7f && bytes[2] == 0 && bytes[3] == 0x80);
        for (size_t index = 4; index < count; ++index) assert(bytes[index] == 0);
    }
    memset(rx, 0x53, count);
}
'''


def program(source, header):
    constants = []
    for name, text in [('PACKET_MAX_LEN', header), ('VALID_DATA_START_INDEX', source), ('BUFFER_SIZE', source)]:
        match = re.search(r'^#define ' + name + r' (\d+)$', text, re.MULTILINE)
        assert match, 'Expected pinned constant missing: ' + name
        constants.append(match.group(0))
    return '\n'.join(constants) + '\n' + PREAMBLE + read_function(source) + r'''
static void run_caller(void) {
''' + caller(source) + r'''
    if (verify_bytes) {
        if (expect_len <= PACKET_MAX_LEN) {
            assert(calls == 1 && transferred == (unsigned)expect_len + 4u);
            for (unsigned index = 0; index < transferred; ++index) assert(buf[index] == 0x53);
            for (unsigned index = transferred; index < sizeof(buf); ++index) assert(buf[index] == 0);
        } else {
            assert(calls == 0);
            for (unsigned index = 0; index < sizeof(buf); ++index) assert(buf[index] == 0);
        }
    }
}
int main(int argc, char **argv) {
    assert(argc == 2);
    if (!strcmp(argv[1], "fixed")) {
        verify_bytes = true;
        for (unsigned length = 0; length <= UINT8_MAX; ++length) {
            expect_len = (uint8_t)length; calls = transferred = 0; run_caller();
        }
        puts("LKBT51 SPI bounds: 0..64 preserve header/4+len clocks; 65..255 reject before SPI; ASan/UBSan passed.");
    } else {
        rx_only = !strcmp(argv[1], "rx"); expect_len = PACKET_MAX_LEN; run_caller();
    }
    return 0;
}
'''


def no_core_dump():
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def main():
    qmk = Path(sys.argv[1]) if len(sys.argv) > 1 else FIRMWARE.parent / 'build/qmk-firmware'
    actual = subprocess.check_output(['git', '-C', str(qmk), 'rev-parse', 'HEAD'], text=True).strip()
    assert actual == patch.PIN, 'Test requires the pinned QMK checkout'
    # Read committed upstream, even when the working tree already has the fix.
    source, header = [subprocess.check_output(['git', '-C', str(qmk), 'show', patch.PIN + ':' + path], text=True)
                      for path in (SOURCE_PATH, HEADER_PATH)]
    working_before = (qmk / SOURCE_PATH).read_bytes()
    fixed = patch.patch_lkbt51_source(source)
    assert patch.patch_lkbt51_source(fixed) == fixed, 'Patch must be idempotent'
    assert '#define BUFFER_SIZE 64' in fixed and 'expect_len = 64;' in fixed
    assert 'i += len;' in read_function(fixed) and 'spiExchange(&WT_DRIVER, i, pkt, payload);' in fixed
    for drift in [source.replace('void lkbt51_read(', 'void changed_read(', 1),
                  source.replace('uint8_t buf[BUFFER_SIZE] = {0};', 'uint8_t buf[63] = {0};', 1)]:
        try:
            patch.patch_lkbt51_source(drift)
        except ValueError:
            pass
        else:
            raise AssertionError('Unexpected source drift was accepted')
    public_patch = ''.join(difflib.unified_diff(source.splitlines(keepends=True), fixed.splitlines(keepends=True),
                                              fromfile='a/' + SOURCE_PATH, tofile='b/' + SOURCE_PATH))
    assert (FIRMWARE / 'patches/lkbt51-spi-bounds.patch').read_text() == public_patch, 'Public patch differs from integration'
    environment = dict(os.environ, ASAN_OPTIONS='detect_leaks=0:abort_on_error=1', UBSAN_OPTIONS='halt_on_error=1')
    with tempfile.TemporaryDirectory(prefix='keyglow-lkbt51-bounds-') as temporary:
        directory = Path(temporary)
        for name, text in [('upstream', source), ('fixed', fixed)]:
            path = directory / (name + '.c')
            path.write_text(program(text, header))
            binary = directory / name
            subprocess.run(['cc', '-std=c11', '-O0', '-g', '-Wall', '-Wextra', '-Werror', '-pedantic',
                            '-fsanitize=address,undefined', str(path), '-o', str(binary)], check=True)
            if name == 'upstream':
                for mode, diagnostic in [('tx', 'READ of size 1'), ('rx', 'WRITE of size 68')]:
                    result = subprocess.run([str(binary), mode], capture_output=True, text=True, env=environment,
                                            preexec_fn=no_core_dump)
                    assert result.returncode != 0 and 'stack-buffer-overflow' in result.stderr and diagnostic in result.stderr, result.stderr
                    print('Pinned upstream: reproduced ' + mode.upper() + ' stack-buffer-overflow (expected negative control).')
            else:
                subprocess.run([str(binary), 'fixed'], check=True, env=environment, preexec_fn=no_core_dump)
    assert (qmk / SOURCE_PATH).read_bytes() == working_before, 'Test changed the QMK working tree'
    print('Patch idempotence, source-drift rejection and public diff parity passed; checkout/hardware untouched.')


if __name__ == '__main__':
    main()
