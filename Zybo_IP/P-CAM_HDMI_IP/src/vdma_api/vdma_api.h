#ifndef VDMA_API_H_
#define VDMA_API_H_

/*
 *  vdma_api.h
 *
 *  A thin wrapper for using AXI VDMA as a frame buffer. The body is the Xilinx example
 *  vdma_api.c, used almost as is.
 *
 *  ---------------------------------------------------------------------
 *  Note on encoding
 *
 *  This file was originally encoded in GB2312 (Chinese). The three enum
 *  comments below were in Chinese, so even with the editor set to UTF-8 this file alone
 *  looked garbled. All the other sources were UTF-8 and looked fine, but this one being
 *  mixed in made it look like "the Korean comments are garbled".
 *
 *  The comments were translated keeping the original meaning (first to Korean, now English) and re-saved as UTF-8.
 *  Not a single character of code was changed.
 *
 *      Original //VDMA只开启读通道          -> Open only the VDMA read channel
 *      Original //VDMA只开启写通道          -> Open only the VDMA write channel
 *      Original //同时开启VDMA写通道和读通道 -> Open both write and read at the same time
 */

/* ------------------------------------------------------------ */
/*              Include File Definitions                        */
/* ------------------------------------------------------------ */

#include "xaxivdma.h"
#include "xparameters.h"
#include "xil_exception.h"

/* ------------------------------------------------------------ */
/*              General Type Declarations                       */
/* ------------------------------------------------------------ */

/*
 *  Operating mode to pass to run_vdma_frame_buffer().
 *
 *  Use BOTH when both directions are needed, e.g. camera -> DDR -> HDMI.
 *  If only one side is opened, the other channel is neither configured nor started.
 */
typedef enum
{
	ONLY_READ=1,    /* Open only the VDMA read channel (DDR -> display) */
	ONLY_WRITE,     /* Open only the VDMA write channel (camera -> DDR) */
	BOTH            /* Open both write and read at the same time */
}vdma_run_mode;

/* ------------------------------------------------------------ */
/*              Procedure Declarations                          */
/* ------------------------------------------------------------ */

/*
 *  Configures VDMA in frame buffer mode and starts it.
 *
 *  InstancePtr        : XAxiVdma instance held by the caller
 *  DeviceId           : XPAR_AXIVDMA_0_DEVICE_ID
 *  hsize              : horizontal pixel count. Internally multiplied by the stream width (bytes)
 *                       to get the actual stride
 *  vsize              : vertical line count
 *  buf_base_addr      : frame buffer start address
 *  number_frame_count : frame count when using the frame counter interrupt
 *  enable_frm_cnt_intr: if 0, only the error interrupt is enabled
 *  mode               : the enum above
 *
 *  Returns : XST_SUCCESS on success
 */
int run_vdma_frame_buffer(XAxiVdma* InstancePtr, int DeviceId, int hsize,
		int vsize, int buf_base_addr, int number_frame_count,
		int enable_frm_cnt_intr,vdma_run_mode mode);

/* ------------------------------------------------------------ */

/************************************************************************/

#endif /* VDMA_API_H_ */
