/*
 *  cam_ae.c
 *
 *  OV5640 AE target adjustment. Read cam_ae.h first for what this does and why.
 */

#include "cam_ae.h"
#include "xil_printf.h"
#include "../ov5640/OV5640.h"

/*===========================================================================
 *  Registers
 *===========================================================================*/

/* AE target brightness */
#define REG_AEC_CTRL0F      0x3A0F      /* stable range upper (WPT)  */
#define REG_AEC_CTRL10      0x3A10      /* stable range lower (BPT)  */
#define REG_AEC_CTRL1B      0x3A1B      /* stable range upper (WPT2) */
#define REG_AEC_CTRL1E      0x3A1E      /* stable range lower (BPT2) */
#define REG_AEC_CTRL11      0x3A11      /* fast zone upper           */
#define REG_AEC_CTRL1F      0x3A1F      /* fast zone lower           */

/* Values AE currently holds (used read-only) */
#define REG_AEC_PK_EXP_H    0x3500      /* [3:0] = exp[19:16]       */
#define REG_AEC_PK_EXP_M    0x3501      /*         exp[15:8]        */
#define REG_AEC_PK_EXP_L    0x3502      /*         exp[7:0]         */
#define REG_AEC_PK_GAIN_H   0x350A      /* [1:0] = gain[9:8]        */
#define REG_AEC_PK_GAIN_L   0x350B      /*         gain[7:0]        */

/* Gain ceiling */
#define REG_AEC_GAIN_CEIL_H 0x3A18
#define REG_AEC_GAIN_CEIL_L 0x3A19

/*===========================================================================
 *  Level table
 *
 *  Level 0  : OmniVision recommended initial values. Values from a clear source.
 *  Level +2 : sensor reset defaults. Where our system was before this module.
 *  Others   : interpolated between them. Refine them with measurements.
 *
 *  In each row, the relation upper (WPT) > lower (BPT) and
 *  fast zone lower < BPT < WPT < fast zone upper must hold.
 *===========================================================================*/
typedef struct {
    u8          wpt;        /* 0x3A0F */
    u8          bpt;        /* 0x3A10 */
    u8          wpt2;       /* 0x3A1B */
    u8          bpt2;       /* 0x3A1E */
    u8          vpt_hi;     /* 0x3A11 */
    u8          vpt_lo;     /* 0x3A1F */
    const char *name;
} Ae_target;

static const Ae_target ae_tab[AE_LEVEL_COUNT] = {
    /*  WPT   BPT   WPT2  BPT2  VPThi VPTlo */
    {  0x18, 0x10, 0x18, 0x0E, 0x30, 0x08, "-3  darkest (max highlight protection)" },
    {  0x20, 0x18, 0x20, 0x16, 0x40, 0x0C, "-2  darker"                             },
    {  0x28, 0x20, 0x28, 0x1E, 0x50, 0x10, "-1  slightly darker"                        },
    {  0x30, 0x28, 0x30, 0x26, 0x60, 0x14, " 0  OmniVision recommended"                  },
    {  0x48, 0x40, 0x48, 0x3E, 0x90, 0x20, "+1  brighter"                               },
    {  0x78, 0x68, 0x78, 0x68, 0xD0, 0x40, "+2  sensor reset default (before tuning)"    },
};

static Ae_level cur = AE_LEVEL_0;

/*===========================================================================
 *  Apply
 *===========================================================================*/

void cam_ae_set(Ae_level lv)
{
    const Ae_target *t;

    if (lv >= AE_LEVEL_COUNT) {
        return;
    }
    t = &ae_tab[lv];

    /*
     * Bundle them in a group write. If the six are written separately, a frame boundary
     * can pass in between, so a half-way combination where only the upper limit has dropped
     * while the lower is still high may be applied for one frame. That shows up as visible flicker.
     */
    OV5640_GroupBegin();
    OV5640_WriteSCCB(REG_AEC_CTRL0F, t->wpt);
    OV5640_WriteSCCB(REG_AEC_CTRL10, t->bpt);
    OV5640_WriteSCCB(REG_AEC_CTRL1B, t->wpt2);
    OV5640_WriteSCCB(REG_AEC_CTRL1E, t->bpt2);
    OV5640_WriteSCCB(REG_AEC_CTRL11, t->vpt_hi);
    OV5640_WriteSCCB(REG_AEC_CTRL1F, t->vpt_lo);
    OV5640_GroupCommit();

    cur = lv;

    xil_printf("AE target : %s\r\n", t->name);
    xil_printf("  (takes a few frames to settle - wait before judging)\r\n");
}

void cam_ae_init(void)
{
    cam_ae_set(AE_LEVEL_0);
}

void cam_ae_down(void)
{
    if (cur == AE_LEVEL_M3) {
        xil_printf("AE target : already at the darkest level (%s)\r\n", ae_tab[cur].name);
        xil_printf("  For more, dim the lighting or go to manual exposure.\r\n");
        return;
    }
    cam_ae_set((Ae_level)(cur - 1));
}

void cam_ae_up(void)
{
    if (cur == AE_LEVEL_P2) {
        xil_printf("AE target : already at the brightest level (%s)\r\n", ae_tab[cur].name);
        return;
    }
    cam_ae_set((Ae_level)(cur + 1));
}

Ae_level cam_ae_get(void)
{
    return cur;
}

const char *cam_ae_name(Ae_level lv)
{
    if (lv >= AE_LEVEL_COUNT) {
        return "?";
    }
    return ae_tab[lv].name;
}

/*===========================================================================
 *  Status output
 *===========================================================================*/

void cam_ae_dump(void)
{
    const Ae_target *t = &ae_tab[cur];
    u8  r0f, r10, r1b, r1e, r11, r1f;
    u32 exp_raw, exp_lines;
    u16 gain_raw, ceil_raw;
    int ok;

    xil_printf("\r\n--- AE status -----------------------------------\r\n");
    xil_printf("level : %s\r\n", t->name);

    /*-------------------------------------------------------------------
     *  Read back target registers
     *
     *  If you write without verifying, when SCCB silently fails you cannot find the cause
     *  of "I changed the value but the screen stays the same".
     *-------------------------------------------------------------------*/
    r0f = OV5640_ReadSCCB(REG_AEC_CTRL0F);
    r10 = OV5640_ReadSCCB(REG_AEC_CTRL10);
    r1b = OV5640_ReadSCCB(REG_AEC_CTRL1B);
    r1e = OV5640_ReadSCCB(REG_AEC_CTRL1E);
    r11 = OV5640_ReadSCCB(REG_AEC_CTRL11);
    r1f = OV5640_ReadSCCB(REG_AEC_CTRL1F);

    ok = (r0f == t->wpt) && (r10 == t->bpt) &&
         (r1b == t->wpt2) && (r1e == t->bpt2) &&
         (r11 == t->vpt_hi) && (r1f == t->vpt_lo);

    xil_printf("target registers (expected -> read back)\r\n");
    xil_printf("  0x3A0F WPT   0x%02X -> 0x%02X\r\n", t->wpt,    r0f);
    xil_printf("  0x3A10 BPT   0x%02X -> 0x%02X\r\n", t->bpt,    r10);
    xil_printf("  0x3A1B WPT2  0x%02X -> 0x%02X\r\n", t->wpt2,   r1b);
    xil_printf("  0x3A1E BPT2  0x%02X -> 0x%02X\r\n", t->bpt2,   r1e);
    xil_printf("  0x3A11 VPThi 0x%02X -> 0x%02X\r\n", t->vpt_hi, r11);
    xil_printf("  0x3A1F VPTlo 0x%02X -> 0x%02X\r\n", t->vpt_lo, r1f);
    xil_printf("  => %s\r\n", ok ? "match" : "!! MISMATCH - suspect SCCB");

    /*-------------------------------------------------------------------
     *  Values AE currently holds
     *
     *  Exposure is 20 bits, in units of 1/16 line.
     *  Gain is 10 bits; the actual multiplier is value/16.
     *-------------------------------------------------------------------*/
    exp_raw = ((u32)(OV5640_ReadSCCB(REG_AEC_PK_EXP_H) & 0x0F) << 16)
            | ((u32) OV5640_ReadSCCB(REG_AEC_PK_EXP_M)         <<  8)
            |  (u32) OV5640_ReadSCCB(REG_AEC_PK_EXP_L);
    exp_lines = exp_raw >> 4;

    gain_raw = ((u16)(OV5640_ReadSCCB(REG_AEC_PK_GAIN_H) & 0x03) << 8)
             |  (u16) OV5640_ReadSCCB(REG_AEC_PK_GAIN_L);

    ceil_raw = ((u16)OV5640_ReadSCCB(REG_AEC_GAIN_CEIL_H) << 8)
             |  (u16)OV5640_ReadSCCB(REG_AEC_GAIN_CEIL_L);

    xil_printf("current AE operating point\r\n");
    xil_printf("  exposure     : %d lines (raw %d, unit 1/16 line)\r\n",
               (int)exp_lines, (int)exp_raw);
    xil_printf("  gain         : %d.%02d x (raw %d)\r\n",
               (int)(gain_raw / 16), (int)((gain_raw % 16) * 100 / 16),
               (int)gain_raw);
    xil_printf("  gain ceiling : %d.%02d x (raw %d)\r\n",
               (int)(ceil_raw / 16), (int)((ceil_raw % 16) * 100 / 16),
               (int)ceil_raw);

    /*-------------------------------------------------------------------
     *  How to read
     *-------------------------------------------------------------------*/
    xil_printf("how to read this\r\n");
    if (gain_raw <= 20) {
        xil_printf("  Gain is near 1x, so the scene is bright enough.\r\n");
        xil_printf("  If highlights are still blown, lower the target ('a').\r\n");
    } else {
        xil_printf("  Gain is raised. AE is exposing for the dark areas and\r\n");
        xil_printf("  giving up the bright ones. Lower the target, or even\r\n");
        xil_printf("  out the lighting.\r\n");
    }
    xil_printf("-------------------------------------------------\r\n");
}
