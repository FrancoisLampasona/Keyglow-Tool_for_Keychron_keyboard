/* SPDX-License-Identifier: GPL-2.0-or-later */
#include "keyglow_ota.h"
#include "keyglow_ota_auth.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
static uint8_t flash[256*1024],application[KG_OTA_APP_MAX],staging[128*1024];
static unsigned writes;
static bool read_flash(void *context,uint32_t address,void *out,size_t size){(void)context;assert(address>=KG_OTA_FLASH_BASE&&address<=KG_OTA_FLASH_END&&size<=KG_OTA_FLASH_END-address);memcpy(out,flash+(address-KG_OTA_FLASH_BASE),size);return true;}
static bool program_flash(void *context,uint32_t address,uint32_t value){(void)context;assert(!(address&3u)&&address>=KG_OTA_APP_BASE&&address<=KG_OTA_FLASH_END-4u);uint8_t *p=flash+(address-KG_OTA_FLASH_BASE);for(unsigned i=0;i<4;i++){uint8_t b=(uint8_t)(value>>(8*i));assert((p[i]&b)==b);p[i]&=b;}writes++;return true;}
static bool erase_flash(void *context,unsigned sector){(void)context;assert(sector>=2&&sector<=4);static const unsigned base[]={32768,49152,65536,131072};memset(flash+base[sector-2],255,base[sector-1]-base[sector-2]);writes++;return true;}
static size_t load(const char *path,uint8_t *out,size_t maximum){FILE *file=fopen(path,"rb");assert(file);size_t size=fread(out,1,maximum,file);assert(!ferror(file)&&fgetc(file)==EOF);fclose(file);return size;}
int main(int argc,char **argv){assert(argc==3);size_t image_size=load(argv[1],application,sizeof application),stage_size=load(argv[2],staging,sizeof staging);memset(flash,0x5a,sizeof flash);memset(flash+128*1024,255,128*1024);memcpy(flash+128*1024,staging,stage_size);const kg_ota_io io={NULL,read_flash,program_flash,erase_flash};kg_ota_status status;assert(kg_ota_inspect(&io,&status)==KG_OTA_OK);assert(status.ready&&status.committed&&!status.installed&&status.authenticated&&!status.install_started);assert(status.manifest.length==image_size);uint8_t fixture_key[32];for(unsigned i=0;i<32;i++)fixture_key[i]=(uint8_t)(i+1);assert(kg_ota_install(&io)==KG_OTA_AUTH_ERROR);assert(kg_ota_install_authenticated(&io,fixture_key)==KG_OTA_OK);assert(!memcmp(flash+32768,application,image_size));for(unsigned i=0;i<32768;i++)assert(flash[i]==0x5a);assert(kg_ota_inspect(&io,&status)==KG_OTA_OK&&status.installed&&status.install_started);unsigned first=writes;assert(kg_ota_install_authenticated(&io,fixture_key)==KG_OTA_OK&&writes==first);printf("Actual relocated QMK authenticated bootstrap: %zu-byte application installed from Python format2 assembly; EEPROM/loader preserved and repeated install is a no-op (public test key only)\n",image_size);return 0;}
