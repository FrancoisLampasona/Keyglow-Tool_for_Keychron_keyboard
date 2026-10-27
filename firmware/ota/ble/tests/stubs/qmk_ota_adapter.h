#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
bool keyglow_ota_submit_frame(const uint8_t *frame, size_t size);
bool keyglow_ota_peek_reply(uint8_t *out, size_t capacity, size_t *size);
bool keyglow_ota_reply_delivered(uint32_t request_id);
bool keyglow_ota_busy(void);
bool keyglow_ota_cancel_pending(void);
