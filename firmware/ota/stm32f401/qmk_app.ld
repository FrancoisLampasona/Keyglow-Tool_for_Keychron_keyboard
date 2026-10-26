/* SPDX-License-Identifier: GPL-2.0-or-later
 * Experimental linker layout for a future Q6 Max ISO QMK application.
 * ChibiOS rules.ld is provided by the pinned QMK checkout (Apache-2.0).
 * A full QMK build using this script has NOT been installed or qualified. */
MEMORY {
    flash0 (rx) : ORIGIN = 0x08008000, LENGTH = 96K
    flash1 (rx) : ORIGIN = 0x08004000, LENGTH = 16K
    flash2 (rx) : ORIGIN = 0, LENGTH = 0
    flash3 (rx) : ORIGIN = 0, LENGTH = 0
    flash4 (rx) : ORIGIN = 0, LENGTH = 0
    flash5 (rx) : ORIGIN = 0, LENGTH = 0
    flash6 (rx) : ORIGIN = 0, LENGTH = 0
    flash7 (rx) : ORIGIN = 0, LENGTH = 0
    ram0 (rwx) : ORIGIN = 0x20000000, LENGTH = 64K
    ram1 (rwx) : ORIGIN = 0x20000000, LENGTH = 64K
    ram2 (rwx) : ORIGIN = 0x20010000, LENGTH = 0
    ram3 (rwx) : ORIGIN = 0, LENGTH = 0
    ram4 (rwx) : ORIGIN = 0, LENGTH = 0
    ram5 (rwx) : ORIGIN = 0, LENGTH = 0
    ram6 (rwx) : ORIGIN = 0, LENGTH = 0
    ram7 (rwx) : ORIGIN = 0, LENGTH = 0
}
REGION_ALIAS("VECTORS_FLASH", flash0);
REGION_ALIAS("VECTORS_FLASH_LMA", flash0);
REGION_ALIAS("XTORS_FLASH", flash0);
REGION_ALIAS("XTORS_FLASH_LMA", flash0);
REGION_ALIAS("TEXT_FLASH", flash0);
REGION_ALIAS("TEXT_FLASH_LMA", flash0);
REGION_ALIAS("RODATA_FLASH", flash0);
REGION_ALIAS("RODATA_FLASH_LMA", flash0);
REGION_ALIAS("VARIOUS_FLASH", flash0);
REGION_ALIAS("VARIOUS_FLASH_LMA", flash0);
REGION_ALIAS("RAM_INIT_FLASH_LMA", flash0);
REGION_ALIAS("MAIN_STACK_RAM", ram0);
REGION_ALIAS("PROCESS_STACK_RAM", ram0);
REGION_ALIAS("DATA_RAM", ram0);
REGION_ALIAS("DATA_RAM_LMA", flash0);
REGION_ALIAS("BSS_RAM", ram0);
REGION_ALIAS("HEAP_RAM", ram0);
INCLUDE rules.ld
ASSERT(__vectors_base__ == 0x08008000, "OTA vector base must be sector 2")
