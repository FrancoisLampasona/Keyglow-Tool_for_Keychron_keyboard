# OTA source and dependency licenses

Original files in this directory: SPDX `GPL-2.0-or-later`. No extracted proprietary
Keychron radio or Launcher binary is included. The portable core/tests/package
builder need only standard C/Python libraries.

The optional ARM build reads these files from a separately obtained QMK checkout,
pinned for this investigation at `2b493ff95f2665db719b1e95c91babb5036e72f3`:

- `lib/chibios/os/common/ext/ST/STM32F4xx/stm32f401xc.h`: ST 3-clause BSD notice below.
- `lib/chibios/os/common/ext/ARM/CMSIS/Core/Include/{core_cm4.h,cmsis_gcc.h,...}`:
  Arm CMSIS, Apache-2.0. Retain the checkout's copyright/license notices if
  redistributing headers or binaries that incorporate them.
- `lib/chibios/os/common/startup/ARMCMx/compilers/GCC/ld/rules*.ld`: ChibiOS,
  Apache-2.0, used by the optional QMK application linker layout.
- GNU ARM toolchain `libgcc`: GPL-3.0 with GCC Runtime Library Exception. See the
  toolchain's license files when distributing linked artifacts.

No third-party source files have been copied into this directory. Combining
GPL-2.0-or-later source with Apache-2.0 components requires distributing the
combined work under a compatible later GPL version (GPLv3), retaining third-party
notices. No release loader binary is distributed by this change.

## ST header redistribution notice

Copyright (c) 2017 STMicroelectronics

Redistribution and use in source and binary forms, with or without modification,
are permitted provided that the following conditions are met:
  1. Redistributions of source code must retain the above copyright notice,
     this list of conditions and the following disclaimer.
  2. Redistributions in binary form must reproduce the above copyright notice,
     this list of conditions and the following disclaimer in the documentation
     and/or other materials provided with the distribution.
  3. Neither the name of STMicroelectronics nor the names of its contributors
     may be used to endorse or promote products derived from this software
     without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
