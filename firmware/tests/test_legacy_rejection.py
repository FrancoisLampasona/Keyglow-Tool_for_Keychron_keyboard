#!/usr/bin/env python3
"""Frozen installed v0.5 decoder must reject the new protocol, even when armed."""
from pathlib import Path
import hashlib
import subprocess
import tempfile
firmware=Path(__file__).resolve().parents[1]
source=firmware/'tests/fixtures/ble_rgb_protocol_v2.c'
assert hashlib.sha256(source.read_bytes()).hexdigest()=='25873280ca04c3adc6c9ff02e41ba0339c02f8e69a46abbcfe8747d8a85e2111'
harness=r'''
#include "ble_rgb_protocol.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
    for (unsigned armed=0;armed<2;++armed) for (unsigned cmd=3;cmd<=4;++cmd) for (unsigned mode=0;mode<=22;++mode) {
        ble_rgb_decoder_t d; ble_rgb_command_t result;
        ble_rgb_init(&d); if (armed) ble_rgb_arm(&d,0,0);
        uint8_t frame[13]={0x4b,0x52,0x47,0x42,3,(uint8_t)cmd,(uint8_t)mode,0,0,0,0,0,0};
        uint16_t crc=ble_rgb_crc16(frame,11); frame[11]=(uint8_t)(crc>>8); frame[12]=(uint8_t)crc;
        uint32_t now=0; uint8_t clock=0;
        for (unsigned i=0;i<52;++i) {
            clock^=4; now+=80;
            uint8_t symbol=(frame[i/4]>>(6-2*(i%4)))&3;
            assert(!ble_rgb_feed(&d,now,clock|symbol,&result));
        }
    }
    puts("PASS: frozen installed v0.5 decoder rejects all v3 mode/command combinations, armed and unarmed; no accidental downgrade application.");
}
'''
with tempfile.TemporaryDirectory(prefix='tastiera-legacy-test-') as temp:
    path=Path(temp); (path/'test.c').write_text(harness)
    subprocess.run(['cc','-std=c11','-Wall','-Wextra','-Werror','-pedantic','-fsanitize=address,undefined','-I'+str(firmware),str(source),str(path/'test.c'),'-o',str(path/'test')],check=True)
    subprocess.run([str(path/'test')],check=True)
