/* SPDX-License-Identifier: GPL-2.0-or-later
 * QMK/ChibiOS staging-only flash driver. No application/loader/EEPROM writes.
 * Compile verified; not yet hardware qualified. */
#include "quantum.h"
#include "qmk_ota_flash.h"
#include "wear_leveling_legacy_config.h"
#include <string.h>

_Static_assert(WEAR_LEVELING_LEGACY_EMULATION_BASE_PAGE_ADDRESS == 0x08004000u, "Keep existing EEPROM sector");
_Static_assert(WEAR_LEVELING_BACKING_SIZE == 6144u, "Keep existing EEPROM backing size");
_Static_assert(WEAR_LEVELING_LOGICAL_SIZE == 3072u, "Keep existing EEPROM logical size");

#define RAMCODE __attribute__((section(".ramtext"),noinline))
#define ERRORS (FLASH_SR_SOP|FLASH_SR_WRPERR|FLASH_SR_PGAERR|FLASH_SR_PGPERR|FLASH_SR_PGSERR)

static RAMCODE void busy_timeout_reset(void) {
    /* Returning to flash while its bank is busy is not a bounded timeout.
     * Reset from RAM; only staging can have been modified by this driver. */
    __DSB();
    SCB->AIRCR=(0x5fau<<SCB_AIRCR_VECTKEY_Pos)|SCB_AIRCR_SYSRESETREQ_Msk;
    __DSB();
    for(;;) __NOP();
}
static RAMCODE bool wait_ready(uint32_t cycles) {
    uint32_t start=DWT->CYCCNT;
    while(FLASH->SR&FLASH_SR_BSY) {
        IWDG->KR=0xaaaau;
        if((uint32_t)(DWT->CYCCNT-start)>cycles)busy_timeout_reset();
    }
    return (FLASH->SR&ERRORS)==0;
}
static RAMCODE bool unlock(uint32_t cycles) {
    (void)wait_ready(cycles);
    FLASH->SR=ERRORS|FLASH_SR_EOP;
    if(FLASH->CR&FLASH_CR_LOCK){FLASH->KEYR=0x45670123u;FLASH->KEYR=0xcdef89abu;}
    return (FLASH->CR&FLASH_CR_LOCK)==0;
}
static RAMCODE void flush_cache(void) {
    uint32_t old=FLASH->ACR;
    FLASH->ACR=old&~(FLASH_ACR_ICEN|FLASH_ACR_DCEN);
    FLASH->ACR=(old&~(FLASH_ACR_ICEN|FLASH_ACR_DCEN))|FLASH_ACR_ICRST|FLASH_ACR_DCRST;
    FLASH->ACR=old;__DSB();__ISB();
}
static RAMCODE bool program_locked(uint32_t address,uint32_t value,uint32_t cycles) {
    if(!unlock(cycles))return false;
    bool ok=true;
    for(unsigned i=0;i<4;i++){
        volatile uint8_t *p=(volatile uint8_t *)(address+i);
        uint8_t byte=(uint8_t)(value>>(8u*i)),old=*p;
        if(old==byte)continue;
        if((old&byte)!=byte){ok=false;break;}
        FLASH->SR=ERRORS|FLASH_SR_EOP;
        FLASH->CR=FLASH_CR_PG; /* PSIZE=0, byte writes. */
        *p=byte;__DSB();
        ok=wait_ready(cycles);FLASH->CR=0;
        if(!ok)break;
    }
    FLASH->CR=FLASH_CR_LOCK;flush_cache();return ok;
}
static RAMCODE bool erase_locked(uint32_t cycles) {
    if(!unlock(cycles))return false;
    FLASH->SR=ERRORS|FLASH_SR_EOP;
    FLASH->CR=FLASH_CR_SER|(5u<<FLASH_CR_SNB_Pos);
    FLASH->CR|=FLASH_CR_STRT;__DSB();
    bool ok=wait_ready(cycles);
    FLASH->CR=FLASH_CR_LOCK;flush_cache();return ok;
}
bool keyglow_ota_flash_target_valid(void) {
    return (DBGMCU->IDCODE&0xfffu)==0x423u&&*(volatile uint16_t *)FLASHSIZE_BASE==256u;
}
static bool prepare_clock(void) {
    /* 8 s fits an unsigned cycle delta without ambiguity at this MCU's clock. */
    if(SystemCoreClock<1000000u||SystemCoreClock>84000000u)return false;
    CoreDebug->DEMCR|=CoreDebug_DEMCR_TRCENA_Msk;
    DWT->CTRL|=DWT_CTRL_CYCCNTENA_Msk;
    uint32_t first=DWT->CYCCNT;
    __NOP();__NOP();__NOP();__NOP();
    return DWT->CYCCNT!=first;
}
static bool read_flash(void *context,uint32_t address,void *out,size_t size) {
    (void)context;
    if(address<KG_OTA_FLASH_BASE||address>KG_OTA_FLASH_END||size>KG_OTA_FLASH_END-address)return false;
    memcpy(out,(const void *)address,size);return true;
}
static bool program_flash(void *context,uint32_t address,uint32_t value) {
    (void)context;
    if((address&3u)||address<KG_OTA_STAGE_BASE||address>KG_OTA_FLASH_END-4u||!keyglow_ota_flash_target_valid()||!prepare_clock())return false;
    uint32_t prior=__get_PRIMASK(),cycles=SystemCoreClock/10u;
    __disable_irq();
    bool ok=program_locked(address,value,cycles);
    __set_PRIMASK(prior);return ok;
}
static bool erase_flash(void *context,unsigned sector) {
    (void)context;
    if(sector!=5||!keyglow_ota_flash_target_valid()||!prepare_clock())return false;
    uint32_t prior=__get_PRIMASK(),cycles=SystemCoreClock*8u;
    __disable_irq();
    bool ok=erase_locked(cycles);
    __set_PRIMASK(prior);return ok;
}
const kg_ota_io *keyglow_ota_staging_io(void) {
    static const kg_ota_io io={NULL,read_flash,program_flash,erase_flash};return &io;
}
uint32_t keyglow_ota_application_length(void) {
    extern const uint8_t __flash0_free__[];
    /* Linker end of the final loadable byte, including RAM initializers. */
    return (uint32_t)(uintptr_t)__flash0_free__-KG_OTA_APP_BASE;
}
