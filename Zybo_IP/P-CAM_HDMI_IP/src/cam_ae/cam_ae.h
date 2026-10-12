/*
 *  cam_ae.h
 *
 *  OV5640 auto-exposure (AE) target adjustment — for highlight protection
 *
 *  ---------------------------------------------------------------------
 *  Why this module is needed
 *
 *  The Pcam path runs the sensor in RAW mode and bypasses the ISP, but exposure
 *  (integration time) and analog gain sit before the ISP, so they still work. In other words, AE is active.
 *
 *  However, both the official Digilent code and our code touch only these
 *  three in the 0x3A range.
 *
 *      {0x3a13, 0x43}   pre-gain
 *      {0x3a18, 0x00}   gain ceiling high byte
 *      {0x3a19, 0xf8}   gain ceiling = 248/16 = 15.5x
 *
 *  The exposure targets (0x3A0F / 0x3A10 / 0x3A1B / 0x3A1E / 0x3A11 / 0x3A1F)
 *  are never written, so they run at the sensor's reset defaults.
 *
 *      Reset default          : 0x78 / 0x68 / 0x78 / 0x68 / 0xD0 / 0x40
 *      OmniVision recommended : 0x30 / 0x28 / 0x30 / 0x26 / 0x60 / 0x14
 *
 *  The defaults are more than twice as bright as the recommended values. As AE
 *  raises exposure to bring the frame average up to this target, bright areas saturate in the sensor.
 *  Once a signal has saturated, the downstream gamma curve cannot recover it.
 *
 *  ---------------------------------------------------------------------
 *  Register meanings (standard OV5640 register map)
 *
 *      0x3A0F  AEC CTRL0F   stable range upper limit (WPT)
 *      0x3A10  AEC CTRL10   stable range lower limit (BPT)
 *      0x3A1B  AEC CTRL1B   stable range upper limit (WPT2)
 *      0x3A1E  AEC CTRL1E   stable range lower limit (BPT2)
 *      0x3A11  AEC CTRL11   fast zone upper limit
 *      0x3A1F  AEC CTRL1F   fast zone lower limit
 *
 *  WPT/BPT define the target brightness window (hysteresis), and the fast zone is
 *  the outer boundary for converging quickly when far outside that window. Lowering the values lowers
 *  the target brightness, which reduces exposure and preserves the highlights.
 *
 *  ⚠ Honest limitation : only level 0 (recommended) and level +2 (reset default) are
 *     values from a clear source. The other four levels are interpolated between them. So instead of
 *     "setting it once and hard-coding it", this module was built so you can raise and lower it
 *     in real time over UART. Tuning while watching the screen is the reliable way.
 *
 *  ---------------------------------------------------------------------
 *  Usage order
 *
 *      cam_ae_init();          // Once at boot. Applies level 0
 *      cam_ae_down();          // Darker (protect highlights)
 *      cam_ae_up();            // Brighter
 *      cam_ae_dump();          // Check targets + actual exposure/gain
 *
 *  AE takes a few frames to converge. After changing it, wait about 0.5 s
 *  before judging.
 */

#ifndef CAM_AE_H
#define CAM_AE_H

#include "xil_types.h"

typedef enum {
    AE_LEVEL_M3 = 0,    /* Darkest — maximum highlight protection */
    AE_LEVEL_M2,
    AE_LEVEL_M1,
    AE_LEVEL_0,         /* OmniVision recommended value (default) */
    AE_LEVEL_P1,
    AE_LEVEL_P2,        /* Sensor reset default = state before using this module */
    AE_LEVEL_COUNT
} Ae_level;

/* Applies level 0 (recommended). Call after OV5640_SetMode720p(). */
void        cam_ae_init(void);

/* Applies the given level. Does nothing if out of range. */
void        cam_ae_set(Ae_level lv);

/* One step darker / brighter. Stays put when it reaches the end. */
void        cam_ae_down(void);
void        cam_ae_up(void);

Ae_level    cam_ae_get(void);
const char *cam_ae_name(Ae_level lv);

/*
 *  Prints the current AE state over UART.
 *
 *    - Reads back the 6 target registers to confirm they were actually written
 *    - The exposure (line count) and analog gain (multiplier) AE currently holds
 *    - Gain ceiling
 *
 *  When highlights blow out: if gain is near 1.0x but exposure is large, the lighting
 *  is too bright; if gain is large, AE is giving up the bright areas
 *  to expose for the dark areas.
 */
void        cam_ae_dump(void);

#endif /* CAM_AE_H */
