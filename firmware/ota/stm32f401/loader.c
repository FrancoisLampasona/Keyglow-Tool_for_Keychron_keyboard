/* SPDX-License-Identifier: GPL-2.0-or-later
 * Experimental standalone loader: compile-tested only, not installed/qualified.
 * Starts from reset defaults (HSI), never from a direct application jump.
 * Uses ST's STM32F401xC CMSIS header; see THIRD_PARTY.md. */
#include "stm32f401xc.h"
#include "keyglow_ota.h"
#include <string.h>

#define RAMFUNC __attribute__((section(".ramfunc"),noinline))
#define FLASH_ERRORS (FLASH_SR_SOP|FLASH_SR_WRPERR|FLASH_SR_PGAERR|FLASH_SR_PGPERR|FLASH_SR_PGSERR)
extern uint32_t __data_start,__data_end,__data_load,__bss_start,__bss_end,__stack_top;
void Reset_Handler(void);
static void fault(void) { for(;;) __WFI(); }
__attribute__((used,section(".vectors")))
const uintptr_t vectors[16] = {
    (uintptr_t)&__stack_top,(uintptr_t)Reset_Handler,(uintptr_t)fault,(uintptr_t)fault,
    (uintptr_t)fault,(uintptr_t)fault,(uintptr_t)fault,0,0,0,0,(uintptr_t)fault,
    (uintptr_t)fault,0,(uintptr_t)fault,(uintptr_t)fault
};

/* Byte programming avoids assuming the x32 minimum supply voltage. Watchdog
 * service and busy polling execute in RAM while the single flash bank stalls.
 * No mass erase, option-byte, RDP, or WRP register operations exist here. */
static RAMFUNC bool flash_wait(void) {
    while(FLASH->SR&FLASH_SR_BSY) IWDG->KR=0xaaaa;
    return (FLASH->SR&FLASH_ERRORS)==0;
}
static RAMFUNC bool unlock(void) {
    if(!flash_wait())FLASH->SR=FLASH_ERRORS|FLASH_SR_EOP;
    if(FLASH->CR&FLASH_CR_LOCK){FLASH->KEYR=0x45670123;FLASH->KEYR=0xcdef89ab;}
    return (FLASH->CR&FLASH_CR_LOCK)==0;
}
static RAMFUNC void flush_cache(void) {
    uint32_t old=FLASH->ACR;
    FLASH->ACR=old&~(FLASH_ACR_ICEN|FLASH_ACR_DCEN);
    FLASH->ACR=(old&~(FLASH_ACR_ICEN|FLASH_ACR_DCEN))|FLASH_ACR_ICRST|FLASH_ACR_DCRST;
    FLASH->ACR=old;__DSB();__ISB();
}
static bool read_flash(void *ctx,uint32_t a,void *p,size_t n) {
    (void)ctx;
    if(a<KG_OTA_FLASH_BASE||a>KG_OTA_FLASH_END||n>KG_OTA_FLASH_END-a)return false;
    memcpy(p,(const void *)(uintptr_t)a,n);IWDG->KR=0xaaaa;return true;
}
static RAMFUNC bool program_flash(void *ctx,uint32_t a,uint32_t word) {
    (void)ctx;
    if((a&3u)||a<KG_OTA_APP_BASE||a>KG_OTA_FLASH_END-4u||!unlock())return false;
    bool success=true;
    for(unsigned i=0;i<4;i++) {
        volatile uint8_t *p=(volatile uint8_t *)(uintptr_t)(a+i);
        uint8_t v=(uint8_t)(word>>(8*i)),old=*p;
        if(old==v)continue;
        if((old&v)!=v){success=false;break;}
        FLASH->SR=FLASH_ERRORS|FLASH_SR_EOP;
        FLASH->CR=FLASH_CR_PG; /* PSIZE=00: x8 */
        *p=v;__DSB();
        success=flash_wait();FLASH->CR=0;
        if(!success)break;
    }
    FLASH->CR=FLASH_CR_LOCK;flush_cache();return success;
}
static RAMFUNC bool erase_flash(void *ctx,unsigned sector) {
    (void)ctx;
    /* This loader only installs; staging erasure belongs to a future app adapter. */
    if(sector<2||sector>4||!unlock())return false;
    FLASH->SR=FLASH_ERRORS|FLASH_SR_EOP;
    FLASH->CR=FLASH_CR_SER|(sector<<FLASH_CR_SNB_Pos); /* PSIZE=00 */
    FLASH->CR|=FLASH_CR_STRT;__DSB();
    bool ok=flash_wait();FLASH->CR=FLASH_CR_LOCK;flush_cache();return ok;
}
__attribute__((naked,noreturn)) static void enter(uint32_t address __attribute__((unused))) {
    __asm volatile("ldr r1,[r0]\nldr r2,[r0,#4]\nmsr msp,r1\nmovs r1,#0\nmsr control,r1\nmsr primask,r1\nisb\nbx r2");
}
__attribute__((noreturn)) static void jump(uint32_t address) {
    FLASH->CR=FLASH_CR_LOCK;
    SysTick->CTRL=0;SysTick->LOAD=0;SysTick->VAL=0;
    for(unsigned i=0;i<8;i++){NVIC->ICER[i]=UINT32_MAX;NVIC->ICPR[i]=UINT32_MAX;}
    SCB->ICSR=SCB_ICSR_PENDSTCLR_Msk|SCB_ICSR_PENDSVCLR_Msk;
    SCB->VTOR=address;__DSB();__ISB();enter(address);
}
void Reset_Handler(void) {
    __disable_irq();
    uint32_t *src=&__data_load;
    for(uint32_t *p=&__data_start;p<&__data_end;p++)*p=*src++;
    for(uint32_t *p=&__bss_start;p<&__bss_end;p++)*p=0;
    SCB->VTOR=KG_OTA_FLASH_BASE;
    /* Reject a different MCU/density before any flash write. */
    if((DBGMCU->IDCODE&0xfffu)!=0x423u||*(volatile uint16_t *)FLASHSIZE_BASE!=256u)jump(0x1fff0000u);
    const kg_ota_io io={NULL,read_flash,program_flash,erase_flash};
    kg_ota_result r=kg_ota_install(&io);
    if((r==KG_OTA_OK||r==KG_OTA_NO_SESSION||r==KG_OTA_NOT_READY)&&kg_ota_vectors_valid(&io,KG_OTA_APP_BASE,KG_OTA_APP_MAX))jump(KG_OTA_APP_BASE);
    /* Damaged/incomplete committed image never enters a partly erased app.
     * USB ROM DFU remains the recovery route, not a Bluetooth service. */
    jump(0x1fff0000u);
}
