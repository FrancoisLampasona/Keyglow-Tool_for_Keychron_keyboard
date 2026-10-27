/* SPDX-License-Identifier: GPL-2.0-or-later */
ENTRY(Reset_Handler)
MEMORY {
    /* Final 256 bytes are reserved for private, USB-only owner provisioning. */
    LOADER (rx) : ORIGIN = 0x08000000, LENGTH = 0x3F00
    RAM (rwx) : ORIGIN = 0x20000000, LENGTH = 64K
}
SECTIONS {
    .vectors : { KEEP(*(.vectors)) } > LOADER
    .text : { *(.text*) *(.rodata*) . = ALIGN(4); } > LOADER
    .ARM.exidx : { *(.ARM.exidx*) } > LOADER
    .data : {
        . = ALIGN(4); __data_start = .;
        *(.ramfunc*) *(.data*)
        . = ALIGN(4); __data_end = .;
    } > RAM AT > LOADER
    __data_load = LOADADDR(.data);
    .bss (NOLOAD) : {
        . = ALIGN(4); __bss_start = .; *(.bss*) *(COMMON)
        . = ALIGN(4); __bss_end = .;
    } > RAM
    __stack_top = ORIGIN(RAM) + LENGTH(RAM);
    ASSERT(__bss_end < __stack_top - 4096, "Need at least 4 KiB stack")
    ASSERT(LOADADDR(.data) + SIZEOF(.data) <= ORIGIN(LOADER) + LENGTH(LOADER), "Loader exceeds sector zero")
    /DISCARD/ : { *(.comment) *(.note*) }
}
