/*
 *  filter_sw.h
 *
 *  Software filter that processes the frame buffer directly on the CPU (PS).
 *  No hardware (block design/bitstream) changes at all.
 *
 *  ---------------------------------------------------------------------
 *  Why no hardware change is needed
 *
 *  In AXI VDMA, the read and write channels have separate start address registers.
 *
 *      XAXIVDMA_MM2S_ADDR_OFFSET 0x50   read (HDMI) channel address block
 *      XAXIVDMA_S2MM_ADDR_OFFSET 0xA0   write (camera) channel address block
 *
 *  So they can be split like this in software alone.
 *
 *      S2MM(camera) -> [cap0][cap1][cap2]      cycles as is
 *                             |
 *                          CPU read -> filter -> CPU write
 *                             v
 *      MM2S(HDMI)   -> [disp0] or [disp1]      displayed alternately
 *
 *  The NUM_FSTORES = 3 constraint is not a problem either. We are not increasing
 *  the number of frame stores, only using different addresses for the existing 3.
 *
 *  As a side effect, genlock worries go away. The "screen jitters when you wave your hand" problem
 *  was caused by read and write sharing the same buffer; now they are structurally separated.
 *
 *  ---------------------------------------------------------------------
 *  Double buffering
 *
 *  The CPU always writes to the buffer "not currently on screen". Only after it finishes
 *  is MM2S switched to it. So a half-drawn frame is never displayed.
 *
 *      Writing : MM2S -> disp0 (completed previous result)
 *                CPU  -> disp1 (in progress)
 *      Done    : MM2S -> switch to disp1, write to disp0 next
 *
 *  ---------------------------------------------------------------------
 *  Must-follow rule : cache
 *
 *  VDMA reads and writes DDR directly through the HP port. It bypasses the CPU cache.
 *
 *      Before read : Xil_DCacheInvalidateRange()  - discard stale copies in the cache
 *      After write : Xil_DCacheFlushRange()       - push results that exist only in the cache out to memory
 *
 *  If you omit this, even with perfect filter logic the screen won't change or previous frames
 *  get mixed in. It is the kind of failure whose cause is very hard to find.
 *
 *  ---------------------------------------------------------------------
 *  Byte order in memory  ★ Check this first
 *
 *  The AXI4-Stream in this pipeline is laid out as R-B-G.
 *
 *      AXI_BayerToRGB.vhd:419
 *          m_axis_video_tdata <= "00" & Red & Blue & Green;
 *
 *  In AXI the least significant byte of tdata goes to the lowest address, so in memory
 *
 *      byte 0 = tdata[7:0]   = G
 *      byte 1 = tdata[15:8]  = B
 *      byte 2 = tdata[23:16] = R
 *
 *  That is, each pixel is [G][B][R]. Neither the commonly expected RGB nor BGR.
 *
 *  ⚠ This is an inference. That is why the channel-separation filters were added first.
 *    If applying FILT_CH_R leaves only reddish tones on screen, it is correct;
 *    if it comes out green or blue, fixing just the three lines OFF_R / OFF_G / OFF_B
 *    at the top of filter_sw.c makes all the other filters correct as well.
 *
 *  ---------------------------------------------------------------------
 *  Performance expectations
 *
 *  One 720p frame is 1280 x 720 x 3 = 2.76 MB. Reading and writing it moves
 *  5.5 MB per frame over DDR. On a single Cortex-A9 core at 666 MHz:
 *
 *      Point ops (gray/binary) : roughly 10~20 fps
 *      3x3 convolution (Sobel) : roughly 2~5 fps
 *
 *  This module prints the processing time in ms every run. The gain from moving
 *  the same algorithm to the PL is left as a number. That comparison is the real purpose of this module.
 */

#ifndef FILTER_SW_H
#define FILTER_SW_H

#include "xil_types.h"
#include "xaxivdma.h"

typedef enum {
    FILT_COPY = 0,      /* Plain copy - baseline that measures memory bandwidth only */
    FILT_CH_R,          /* Keep red only - for checking byte order */
    FILT_CH_G,          /* Keep green only */
    FILT_CH_B,          /* Keep blue only */
    FILT_GRAY,          /* Grayscale */
    FILT_BINARY,        /* Binarization (adjustable threshold) */
    FILT_SOBEL,         /* Sobel 3x3 edge */
    FILT_COUNT
} Filt_kind;

/*
 *  vdma       : instance already started via run_vdma_frame_buffer()
 *  cap_base   : start address of the 3 capture buffers written by S2MM (= FRAME_BUFFER_ADDR)
 *  disp_base  : start address for the 2 display buffers. Must not overlap the 3 capture buffers.
 *  w, h       : resolution
 *
 *  Returns : 0 on success
 */
int         filter_sw_init(XAxiVdma *vdma, UINTPTR cap_base, UINTPTR disp_base,
                           u16 w, u16 h);

/* Cycles the filter selection. The screen does not change - press 'f' to apply. */
void        filter_sw_next(void);
Filt_kind   filter_sw_get(void);
const char *filter_sw_name(Filt_kind k);

/*
 *  Grabs the current frame, applies the filter and displays it (still image).
 *  Prints the processing time over UART.
 */
void        filter_sw_apply(void);

/* Turns the filter off and returns to the original live camera feed. */
void        filter_sw_live(void);

/* Adjusts the binarization threshold by adding delta. Clamped to 0~255. */
void        filter_sw_thresh(int delta);

/* Prints the current state over UART. */
void        filter_sw_dump(void);

#endif /* FILTER_SW_H */
