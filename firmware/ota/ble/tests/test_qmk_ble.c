/* SPDX-License-Identifier: GPL-2.0-or-later */
#include "qmk_ble_ota.h"
#include "keyglow_ble_wire.h"
#include "ble_rgb_protocol.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static unsigned checks;
#define CHECK(value) do { ++checks; if (!(value)) { fprintf(stderr,"BLE QMK line %d: %s\n",__LINE__,#value);exit(1); } } while(0)
static uint32_t now = 100;
static matrix_row_t matrix[MATRIX_ROWS];
static uint8_t mods, weak, oneshot, locked, retry, transport = TRANSPORT_BLUETOOTH, wireless = WT_CONNECTED;
static uint16_t consumer, system_usage;
static bool queue_empty = true, low_battery;
static report_keyboard_t keyboard;
static report_nkro_t nkro;
report_keyboard_t *keyboard_report = &keyboard;
report_nkro_t *nkro_report = &nkro;
static led_t leds;
static unsigned sends, submissions, deliveries, cancellations;
static uint8_t reports[1000][8], submitted[276], engine_reply[120];
static size_t submitted_size;
static bool engine_busy, engine_ready, cancel_refused;
static uint32_t le32(const uint8_t *p){return(uint32_t)p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24;}
static void put32(uint8_t *p,uint32_t v){for(unsigned i=0;i<4;i++)p[i]=(uint8_t)(v>>(i*8));}
uint8_t get_mods(void){return mods;} uint8_t get_weak_mods(void){return weak;}
uint8_t get_oneshot_mods(void){return oneshot;} uint8_t get_oneshot_locked_mods(void){return locked;}
uint16_t host_last_consumer_usage(void){return consumer;} uint16_t host_last_system_usage(void){return system_usage;}
led_t host_keyboard_led_state(void){return leds;} bool battery_is_critical_low(void){return low_battery;}
matrix_row_t matrix_get_row(uint8_t row){return matrix[row];}
bool report_buffer_is_empty(void){return queue_empty;} uint8_t report_buffer_get_retry(void){return retry;}
uint32_t timer_read32(void){return now;} uint8_t get_transport(void){return transport;} uint8_t wireless_get_state(void){return wireless;}
bool keyglow_ota_submit_frame(const uint8_t *frame,size_t size){
    CHECK(kg_ble_request_valid(frame,size)&&frame[5]!=0x7f);
    if(engine_busy)return false;
    memcpy(submitted,frame,size);submitted_size=size;++submissions;engine_busy=true;return true;
}
bool keyglow_ota_peek_reply(uint8_t *out,size_t capacity,size_t *size){
    if(!engine_ready)return false;CHECK(capacity>=sizeof engine_reply);memcpy(out,engine_reply,sizeof engine_reply);*size=sizeof engine_reply;return true;
}
bool keyglow_ota_reply_delivered(uint32_t identifier){
    CHECK(engine_ready&&identifier==le32(engine_reply+8));++deliveries;engine_ready=engine_busy=false;return true;
}
bool keyglow_ota_busy(void){return engine_busy;}
bool keyglow_ota_cancel_pending(void){++cancellations;if(cancel_refused)return false;engine_ready=engine_busy=false;return true;}
void lkbt51_send_keyboard(uint8_t *report){
    CHECK(transport==TRANSPORT_BLUETOOTH&&wireless==WT_CONNECTED&&!low_battery);
    CHECK(!mods&&!weak&&!oneshot&&!locked&&!keyboard.mods&&!keyboard.reserved&&!nkro.mods&&!consumer&&!system_usage&&queue_empty&&!retry);
    for(unsigned row=0;row<MATRIX_ROWS;row++)CHECK(!matrix[row]);
    for(unsigned i=0;i<KEYBOARD_REPORT_KEYS;i++)CHECK(!keyboard.keys[i]);
    for(unsigned i=0;i<NKRO_REPORT_BITS;i++)CHECK(!nkro.bits[i]);
    for(unsigned i=0;i<8;i++)if(i!=1)CHECK(!report[i]);
    CHECK(sends<1000);memcpy(reports[sends++],report,8);
}
static void task(uint32_t elapsed){now+=elapsed;keyglow_ble_ota_task();}
static void reset(void){
    engine_busy=engine_ready=cancel_refused=false;keyglow_ble_ota_link_changed();
    memset(matrix,0,sizeof matrix);memset(&keyboard,0,sizeof keyboard);memset(&nkro,0,sizeof nkro);
    keyboard.report_id=1;nkro.report_id=4;
    mods=weak=oneshot=locked=retry=0;consumer=system_usage=0;queue_empty=true;low_battery=false;
    transport=TRANSPORT_BLUETOOTH;wireless=WT_CONNECTED;sends=submissions=deliveries=cancellations=0;leds.raw=0;task(401);
}
static void feed(const uint8_t *frame,size_t size,bool assert_suppression){
    for(size_t i=0;i<=size*4;i++){
        uint8_t mask;CHECK(kg_ble_request_led_mask(frame,size,i,&mask));now+=20;leds.raw=mask;
        bool forward=keyglow_ble_ota_led_update(leds);
        if(assert_suppression&&i>=16)CHECK(!forward);
        task(0);
    }
}
static void request(uint8_t op,uint32_t id){uint8_t frame[276];size_t size;CHECK(kg_ble_request_encode(op,id,NULL,0,frame,sizeof frame,&size));feed(frame,size,true);}
static void complete(uint8_t result){
    memset(engine_reply,0,sizeof engine_reply);memcpy(engine_reply,"KGOT",4);engine_reply[4]=1;engine_reply[5]=submitted[5]|0x80;engine_reply[6]=104;
    memcpy(engine_reply+8,submitted+8,4);put32(engine_reply+12,result);put32(engine_reply+16,1);
    for(unsigned i=20;i<116;i++)engine_reply[i]=(uint8_t)i;
    put32(engine_reply+116,kg_ble_crc32(engine_reply,116));engine_ready=true;task(0);
}
static size_t compact(uint8_t *out){size_t size;CHECK(kg_ble_ack_from_legacy(engine_reply,120,submitted[5]==3||submitted[5]==8,out,143,&size));return size;}
static void send_all(void){uint8_t ack[143];size_t size=compact(ack);task(599);CHECK(sends==0);task(1);for(size_t i=1;i<=size*2;i++)task(100);CHECK(sends==size*2+1);}
static void verify_reports(void){uint8_t ack[143],decoded[143]={0};size_t size=compact(ack);for(size_t i=0;i<size*2;i++){CHECK((reports[i][1]&0xf0u)==((i&1u)?0x90u:0x80u));decoded[i/2]=(uint8_t)((decoded[i/2]<<4)|(reports[i][1]&15));}CHECK(!memcmp(decoded,ack,size));for(unsigned i=0;i<8;i++)CHECK(reports[size*2][i]==0);}
static void receipt(bool corrupt){uint8_t ack[143],frame[276];size_t acksize=compact(ack),size;CHECK(kg_ble_ack_receipt_encode(ack,acksize,frame,sizeof frame,&size));if(corrupt){frame[13]^=1;put32(frame+size-4,kg_ble_crc32(frame,size-4));}feed(frame,size,true);}
static void blocked(uint8_t *field){reset();request(2,1);complete(0);*field=1;task(600);CHECK(sends==0&&!engine_busy&&deliveries==0);}
int main(void){
    /* The valid RGB HSV/speed bytes literally spell KGOT. Outer KRGB owns
     * the complete frame, including its CRC; the RGB result still applies. */
    reset();uint8_t rgb[13]={'K','R','G','B',3,4,1,'K','G','O','T',0,0};uint16_t rgbcrc=ble_rgb_crc16(rgb,11);rgb[11]=(uint8_t)(rgbcrc>>8);rgb[12]=(uint8_t)rgbcrc;
    ble_rgb_decoder_t real_rgb;ble_rgb_init(&real_rgb);ble_rgb_command_t command;unsigned rgb_commands=0;
    for(size_t i=0;i<=sizeof(rgb)*4;i++){now+=20;leds.raw=i==0?0:(uint8_t)((i&1u?4u:0u)|((rgb[(i-1)/4]>>(6-2*((i-1)%4)))&3));CHECK(keyglow_ble_ota_led_update(leds));if(ble_rgb_feed(&real_rgb,now,leds.raw,&command))++rgb_commands;task(0);}
    CHECK(rgb_commands==1&&command.hue=='K'&&command.saturation=='G'&&command.value=='O'&&command.speed=='T'&&!submissions);
    /* Conversely, an entire valid KRGB packet inside KGOT is never forwarded. */
    reset();uint8_t outer[276];size_t outer_size;CHECK(kg_ble_request_encode(2,51,rgb,sizeof rgb,outer,sizeof outer,&outer_size));feed(outer,outer_size,true);CHECK(submissions==1&&submitted_size==outer_size&&!memcmp(submitted,outer,outer_size));
    for(unsigned op=2;op<=8;op+=3){reset();request((uint8_t)op,op);CHECK(submissions==1&&sends==0);complete(0);send_all();verify_reports();CHECK(deliveries==0&&engine_busy);receipt(true);CHECK(!deliveries&&engine_busy);receipt(false);CHECK(deliveries==1&&!engine_busy);task(400);CHECK(!keyglow_ble_ota_busy());}
    /* Receipt can begin while the final zero is still pending; no symbols lost. */
    reset();request(2,21);complete(0);task(600);for(unsigned i=1;i<30;i++)task(100);CHECK(sends==30);receipt(false);CHECK(sends==31&&deliveries==1);
    /* Identical requests replay the ACK without repeating the mutation, before
     * and after the receipt. Never extend the original cache/engine deadline. */
    reset();request(2,22);complete(0);send_all();unsigned before=submissions;sends=0;feed(submitted,submitted_size,true);CHECK(submissions==before);send_all();receipt(false);CHECK(deliveries==1);sends=0;feed(submitted,submitted_size,true);send_all();receipt(false);CHECK(deliveries==1&&submissions==before);sends=0;feed(submitted,submitted_size,true);task(1000);CHECK(!sends&&submissions==before);
    reset();request(2,30);complete(0);send_all();task(60000);CHECK(!engine_busy&&!deliveries);receipt(false);CHECK(!deliveries);
    blocked(&mods);blocked(&weak);blocked(&oneshot);blocked(&locked);blocked(&keyboard.mods);blocked(&keyboard.reserved);blocked(&nkro.mods);
    for(unsigned i=0;i<KEYBOARD_REPORT_KEYS;i++)blocked(&keyboard.keys[i]);
    for(unsigned i=0;i<NKRO_REPORT_BITS;i++)blocked(&nkro.bits[i]);
    for(unsigned row=0;row<MATRIX_ROWS;row++)for(unsigned col=0;col<MATRIX_COLS;col++){reset();request(2,1);complete(0);matrix[row]=(matrix_row_t)1u<<col;task(600);CHECK(!sends&&!engine_busy&&!deliveries);}
    for(unsigned choice=0;choice<5;choice++){reset();request(2,1);complete(0);if(choice==0)consumer=1;else if(choice==1)system_usage=1;else if(choice==2)low_battery=true;else if(choice==3)transport=TRANSPORT_USB;else wireless=WT_DISCONNECTED;task(600);CHECK(!sends&&!engine_busy&&!deliveries);}
    reset();request(2,1);complete(0);task(600);CHECK(sends==1);queue_empty=false;task(100);CHECK(sends==1&&!engine_busy); /* no release over pending typing */
    reset();request(2,1);complete(0);retry=1;task(600);CHECK(!sends);retry=0;task(599);CHECK(!sends);task(1);CHECK(sends==1);retry=1;task(100);CHECK(sends==1&&!engine_busy);
    reset();request(2,1);complete(0);queue_empty=false;task(5000);CHECK(!sends&&!engine_busy);
    reset();request(2,1);task(60000);CHECK(!sends&&!engine_busy);
    reset();request(2,1);complete(0);keyrecord_t key={.event={.pressed=true}};keyglow_ble_ota_process_record(&key);task(600);CHECK(!sends&&!engine_busy);
    reset();request(2,1);complete(0);keyglow_ble_ota_link_changed();task(600);CHECK(!sends&&!engine_busy);
    /* An aborted request's trailing bytes cannot become a second request or
     * RGB traffic until an actual intersymbol timeout, even after key release. */
    reset();request(2,1);complete(0);keyglow_ble_ota_process_record(&key);feed(submitted,submitted_size,true);CHECK(submissions==1&&!engine_busy&&!sends);task(400);request(2,2);CHECK(submissions==2);
    reset();request(2,1);complete(0);cancel_refused=true;keyglow_ble_ota_link_changed();task(600);CHECK(!sends&&engine_busy&&keyglow_ble_ota_busy());
    /* A corrupt frame remains quarantined from the RGB decoder until a gap. */
    reset();uint8_t malformed[40];size_t size;CHECK(kg_ble_request_encode(2,1,(const uint8_t*)"KRGBKRGB",8,malformed,sizeof malformed,&size));malformed[size-1]^=1;
    for(size_t i=0;i<=size*4;i++){now+=20;leds.raw=i==0?0:(uint8_t)((i&1u?4u:0u)|((malformed[(i-1)/4]>>(6-2*((i-1)%4)))&3));bool forward=keyglow_ble_ota_led_update(leds);if(i>=16)CHECK(!forward);task(0);}CHECK(!submissions);task(400);leds.raw=0;CHECK(keyglow_ble_ota_led_update(leds));
    reset();now=UINT32_MAX-200;request(2,99);complete(0);send_all();verify_reports();receipt(false);CHECK(deliveries==1);
    printf("BLE OTA QMK glue: %u assertions passed; HID, engine and flash are mocks.\n",checks);return 0;
}
