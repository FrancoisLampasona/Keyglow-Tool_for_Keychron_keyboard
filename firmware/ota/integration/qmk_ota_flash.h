/* SPDX-License-Identifier: GPL-2.0-or-later */
#pragma once
#include "keyglow_ota.h"
const kg_ota_io *keyglow_ota_staging_io(void);
bool keyglow_ota_flash_target_valid(void);
uint32_t keyglow_ota_application_length(void);
