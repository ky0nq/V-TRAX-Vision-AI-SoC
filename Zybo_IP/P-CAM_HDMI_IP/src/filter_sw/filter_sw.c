/*
 *  filter_sw.c
 *
 *  Software filter. Read filter_sw.h first for the structure and caveats.
 */

#include <string.h>

#include "filter_sw.h"
#include "xil_printf.h"
#include "xil_cache.h"
#include "xtime_l.h"
#include "xaxivdma_hw.h"

/*===========================================================================
 *  ★ Channel positions in memory
 *
 *  Since the stream is R-B-G and AXI puts the least significant byte at the lowest address,
 *  we assume each pixel is laid out in memory as [G][B][R].
 *
 *  How to check : select FILT_CH_R with 'n' and press 'f'.
 *      Only red remains     -> the three lines below are correct. Leave them as is.
 *      Only green remains   -> swap OFF_R and OFF_G.
 *      Only blue remains    -> swap OFF_R and OFF_B.
 *
 *  As long as these three lines are right, all the filters below are right too.
 *===========================================================================*/
#define OFF_G   0
#define OFF_B   1
#define OFF_R   2

#define BYTES_PER_PIXEL 3

/*===========================================================================
 *  State
 *===========================================================================*/
static XAxiVdma *s_vdma;
static UINTPTR   s_cap_base;
static UINTPTR   s_disp[2];
static u16       s_w, s_h;
static u32       s_stride;          /* Bytes per line */
static u32       s_frame_bytes;
static int       s_ready;
static int       s_disp_idx;        /* Display buffer the CPU writes next */
static int       s_live;            /* 1 = live video mode */
static Filt_kind s_kind = FILT_GRAY;
static int       s_thresh = 128;

static const char *s_names[FILT_COUNT] = {
    "copy   (baseline, no processing)",
    "R only (byte order check)",
    "G only (byte order check)",
    "B only (byte order check)",
    "gray",
    "binary",
    "sobel 3x3",
};

/*===========================================================================
 *  Helpers
 *===========================================================================*/

/* Luminance of one pixel. 77/150/29 are the Rec.601 coefficients normalized to 8 bits. */
static u8 gray_of(const u8 *p)
{
    return (u8)(((u32)p[OFF_R] * 77u +
                 (u32)p[OFF_G] * 150u +
                 (u32)p[OFF_B] * 29u) >> 8);
}

static void put_gray(u8 *p, u8 v)
{
    p[OFF_R] = v;
    p[OFF_G] = v;
    p[OFF_B] = v;
}

/*
 *  Index of the capture buffer S2MM has just finished filling.
 *
 *  PARKPTR[28:24] is the index "currently being written", so the buffer just before it
 *  is the completed frame. If you skip this calculation and use the current index as is,
 *  you end up filtering a half-filled frame.
 */
static int newest_capture(void)
{
    u32 pp  = XAxiVdma_ReadReg(s_vdma->BaseAddr, XAXIVDMA_PARKPTR_OFFSET);
    int cur = (int)((pp & XAXIVDMA_PARKPTR_WRTSTR_MASK) >> XAXIVDMA_WRTSTR_SHIFT);
    int n   = s_vdma->MaxNumFrames;

    if (cur < 0 || cur >= n) {
        cur = 0;
    }
    return (cur + n - 1) % n;
}

/*
 *  ★ Function that changes the read channel start addresses and also makes them "take effect".
 *
 *  This one cost a lot of time once. Despite its name, XAxiVdma_DmaSetBufferAddr()
 *  only writes the values into the start address registers. VDMA does not use them
 *  right away.
 *
 *      xaxivdma_channel.c : XAxiVdma_ChannelSetBufferAddr()
 *          -> XAxiVdma_WriteReg(StartAddrBase, START_ADDR_OFFSET + i*4, addr)
 *             ... and then simply returns. There is no commit step.
 *
 *  This design does not use SG (INCLUDE_SG = 0), so it is in direct register mode,
 *  and in this mode the configuration is committed by writing VSIZE.
 *
 *      xaxivdma_channel.c : XAxiVdma_ChannelStart()
 *          else {
 *              // Direct register mode: Update vsize to start the channel
 *              XAxiVdma_WriteReg(StartAddrBase, VSIZE_OFFSET, Channel->Vsize);
 *          }
 *
 *  So after writing the addresses we call XAxiVdma_DmaStart() once more to rewrite
 *  VSIZE. This is safe even for a channel that is already running. ChannelStart has
 *  a path that "if already running, only rewrites VSIZE and returns XST_SUCCESS",
 *  and XST_DEVICE_BUSY only occurs in SG mode.
 *
 *  Without this the symptom is very quiet. The function returns XST_SUCCESS
 *  and the logs look normal, but the screen just stays the same.
 */
static int commit_read_addrs(UINTPTR *set)
{
    int st = XAxiVdma_DmaSetBufferAddr(s_vdma, XAXIVDMA_READ, set);

    if (st != XST_SUCCESS) {
        return st;
    }
    return XAxiVdma_DmaStart(s_vdma, XAXIVDMA_READ);   /* Rewriting VSIZE = commit */
}

/*
 *  Points all MM2S frame stores at the same address.
 *
 *  With all three at the same place, VDMA reads the same buffer whichever index it picks.
 *  No need to worry about parking or genlock index calculation.
 */
static int point_display_at(UINTPTR addr)
{
    UINTPTR set[XAXIVDMA_MAX_FRAMESTORE];
    int i;

    for (i = 0; i < s_vdma->MaxNumFrames; i++) {
        set[i] = addr;
    }
    return commit_read_addrs(set);
}

/*===========================================================================
 *  Filter implementations
 *
 *  All are one-way src -> dst. Since nothing is processed in place, neighborhood
 *  operations never accidentally re-read already processed pixels.
 *===========================================================================*/

static void filt_copy(const u8 *src, u8 *dst)
{
    memcpy(dst, src, s_frame_bytes);
}

/* Keeps only the byte at the keep position and zeroes the other two channels. */
static void filt_channel(const u8 *src, u8 *dst, int keep)
{
    u32 n = (u32)s_w * s_h;
    u32 i;

    for (i = 0; i < n; i++) {
        const u8 *sp = src + i * BYTES_PER_PIXEL;
        u8       *dp = dst + i * BYTES_PER_PIXEL;

        dp[0] = 0;
        dp[1] = 0;
        dp[2] = 0;
        dp[keep] = sp[keep];
    }
}

static void filt_gray(const u8 *src, u8 *dst)
{
    u32 n = (u32)s_w * s_h;
    u32 i;

    for (i = 0; i < n; i++) {
        put_gray(dst + i * BYTES_PER_PIXEL, gray_of(src + i * BYTES_PER_PIXEL));
    }
}

static void filt_binary(const u8 *src, u8 *dst)
{
    u32 n = (u32)s_w * s_h;
    u32 i;

    for (i = 0; i < n; i++) {
        u8 g = gray_of(src + i * BYTES_PER_PIXEL);
        put_gray(dst + i * BYTES_PER_PIXEL, (g >= (u8)s_thresh) ? 255 : 0);
    }
}

/*
 *  Sobel 3x3.
 *
 *  Written simply on purpose. It computes the luminance of the 9 neighbors on the spot for each pixel,
 *  reading 27 bytes per pixel. It is slow. That is this filter's educational value -
 *  this is where the difference shows when the same algorithm is moved to the PL.
 *
 *  To make it faster : precompute luminance one line at a time and rotate three lines,
 *  which cuts reads to 1/3. A good optimization exercise.
 *
 *  The one-pixel border has no neighbors, so it is left at 0.
 */
static void filt_sobel(const u8 *src, u8 *dst)
{
    int x, y;

    memset(dst, 0, s_frame_bytes);

    for (y = 1; y < (int)s_h - 1; y++) {
        const u8 *r0 = src + (u32)(y - 1) * s_stride;
        const u8 *r1 = src + (u32) y      * s_stride;
        const u8 *r2 = src + (u32)(y + 1) * s_stride;
        u8       *dp = dst + (u32) y      * s_stride + BYTES_PER_PIXEL;

        for (x = 1; x < (int)s_w - 1; x++) {
            int xm = (x - 1) * BYTES_PER_PIXEL;
            int xc =  x      * BYTES_PER_PIXEL;
            int xp = (x + 1) * BYTES_PER_PIXEL;

            int p00 = gray_of(r0 + xm), p01 = gray_of(r0 + xc), p02 = gray_of(r0 + xp);
            int p10 = gray_of(r1 + xm),                         p12 = gray_of(r1 + xp);
            int p20 = gray_of(r2 + xm), p21 = gray_of(r2 + xc), p22 = gray_of(r2 + xp);

            int gx = (p02 + 2 * p12 + p22) - (p00 + 2 * p10 + p20);
            int gy = (p20 + 2 * p21 + p22) - (p00 + 2 * p01 + p02);
            int m;

            if (gx < 0) gx = -gx;
            if (gy < 0) gy = -gy;

            m = gx + gy;            /* |Gx|+|Gy| : approximation that avoids the square root */
            if (m > 255) m = 255;

            put_gray(dp, (u8)m);
            dp += BYTES_PER_PIXEL;
        }
    }
}

/*===========================================================================
 *  Public functions
 *===========================================================================*/

int filter_sw_init(XAxiVdma *vdma, UINTPTR cap_base, UINTPTR disp_base, u16 w, u16 h)
{
    if (vdma == NULL || w == 0 || h == 0) {
        return -1;
    }

    s_vdma        = vdma;
    s_cap_base    = cap_base;
    s_w           = w;
    s_h           = h;
    s_stride      = (u32)w * BYTES_PER_PIXEL;
    s_frame_bytes = s_stride * h;
    s_disp[0]     = disp_base;
    s_disp[1]     = disp_base + s_frame_bytes;
    s_disp_idx    = 0;
    s_live        = 1;
    s_ready       = 1;

    /*
     * Clear the display buffers to black. Otherwise, at the moment of the first switch,
     * garbage values in DDR are visible for one frame.
     */
    memset((void *)s_disp[0], 0, s_frame_bytes);
    memset((void *)s_disp[1], 0, s_frame_bytes);
    Xil_DCacheFlushRange((INTPTR)s_disp[0], s_frame_bytes * 2);

    xil_printf("filter : ready. capture 0x%08X x3, display 0x%08X x2 "
               "(%d bytes each)\r\n",
               (unsigned)s_cap_base, (unsigned)s_disp[0],
               (int)s_frame_bytes);
    return 0;
}

void filter_sw_next(void)
{
    s_kind = (Filt_kind)((s_kind + 1) % FILT_COUNT);
    xil_printf("filter : %s   (press 'f' to apply)\r\n", s_names[s_kind]);
}

Filt_kind filter_sw_get(void)
{
    return s_kind;
}

const char *filter_sw_name(Filt_kind k)
{
    return (k < FILT_COUNT) ? s_names[k] : "?";
}

void filter_sw_thresh(int delta)
{
    s_thresh += delta;
    if (s_thresh < 0)   s_thresh = 0;
    if (s_thresh > 255) s_thresh = 255;
    xil_printf("filter : binary threshold = %d\r\n", s_thresh);
}

void filter_sw_apply(void)
{
    int       cap;
    const u8 *src;
    u8       *dst;
    XTime     t0, t1;
    u32       us, ms;

    if (!s_ready) {
        xil_printf("filter : not initialised\r\n");
        return;
    }

    cap = newest_capture();
    src = (const u8 *)(s_cap_base + (UINTPTR)cap * s_frame_bytes);
    dst = (u8 *)s_disp[s_disp_idx];

    /*
     * We need to read data that VDMA wrote bypassing the cache, so first discard
     * stale copies left in the cache.
     */
    Xil_DCacheInvalidateRange((INTPTR)src, s_frame_bytes);

    XTime_GetTime(&t0);

    switch (s_kind) {
    case FILT_COPY:   filt_copy(src, dst);                break;
    case FILT_CH_R:   filt_channel(src, dst, OFF_R);      break;
    case FILT_CH_G:   filt_channel(src, dst, OFF_G);      break;
    case FILT_CH_B:   filt_channel(src, dst, OFF_B);      break;
    case FILT_GRAY:   filt_gray(src, dst);                break;
    case FILT_BINARY: filt_binary(src, dst);              break;
    case FILT_SOBEL:  filt_sobel(src, dst);               break;
    default:          filt_copy(src, dst);                break;
    }

    XTime_GetTime(&t1);

    /* If the result is only in the cache, VDMA reads old contents. Always flush it out. */
    Xil_DCacheFlushRange((INTPTR)dst, s_frame_bytes);

    /* Only after writing is complete is the display switched here. This is double buffering. */
    if (point_display_at(s_disp[s_disp_idx]) != XST_SUCCESS) {
        xil_printf("filter : failed to repoint MM2S\r\n");
        return;
    }
    s_disp_idx ^= 1;
    s_live = 0;

    us = (u32)(((t1 - t0) * 1000000ULL) / COUNTS_PER_SECOND);
    ms = us / 1000u;

    xil_printf("filter : %s\r\n", s_names[s_kind]);
    xil_printf("  source capture buffer : %d\r\n", cap);
    xil_printf("  processing time       : %d.%03d ms\r\n",
               (int)ms, (int)(us % 1000u));
    if (us > 0) {
        xil_printf("  => %d fps if run continuously\r\n",
                   (int)(1000000u / us));
    }
    xil_printf("  ('b' to go back to live video)\r\n");
}

void filter_sw_live(void)
{
    UINTPTR set[XAXIVDMA_MAX_FRAMESTORE];
    int i;

    if (!s_ready) {
        return;
    }
    if (s_live) {
        xil_printf("filter : already showing live video\r\n");
        return;
    }

    /* Restore MM2S to the original 3 capture buffers. */
    for (i = 0; i < s_vdma->MaxNumFrames; i++) {
        set[i] = s_cap_base + (UINTPTR)i * s_frame_bytes;
    }
    if (commit_read_addrs(set) != XST_SUCCESS) {
        xil_printf("filter : failed to restore MM2S\r\n");
        return;
    }

    s_live = 1;
    xil_printf("filter : back to live video\r\n");
}

void filter_sw_dump(void)
{
    xil_printf("\r\n--- software filter -----------------------------\r\n");
    xil_printf("state      : %s\r\n", s_live ? "live video" : "frozen (filtered)");
    xil_printf("filter     : %s\r\n", s_names[s_kind]);
    xil_printf("threshold  : %d  (binary only)\r\n", s_thresh);
    xil_printf("resolution : %dx%d, stride %d, frame %d bytes\r\n",
               (int)s_w, (int)s_h, (int)s_stride, (int)s_frame_bytes);
    xil_printf("capture    : 0x%08X (3 buffers)\r\n", (unsigned)s_cap_base);
    xil_printf("display    : 0x%08X / 0x%08X\r\n",
               (unsigned)s_disp[0], (unsigned)s_disp[1]);
    xil_printf("byte order : G=%d B=%d R=%d  (see filter_sw.c if colours look wrong)\r\n",
               OFF_G, OFF_B, OFF_R);
    xil_printf("-------------------------------------------------\r\n");
}
