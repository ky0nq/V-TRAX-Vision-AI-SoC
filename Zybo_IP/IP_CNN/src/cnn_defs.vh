// =============================================================================
// cnn_defs.vh  -  CNN accelerator common width define
//
//   K_total        13bit   1 ~ 4096
//   chunk_len      9bit    1 ~ 256        (one wgt_buf half = max chunk length)
//   local_addr     9bit    weight_buf 0 ~ 511 = {half, 0 ~ 255}
//   pos_index      12bit   output position
//   #channel       6bit    32 
//   channel index  5bit
//   oc_group       4bit
// =============================================================================
`ifndef CNN_DEFS_VH
`define CNN_DEFS_VH

`define DW        24     // 24bit bus = signed INT8 * 3 (lane0/1/2)
`define KEEP_W     3     // lane mask
`define ACC_W     32     // PE accumulate / bias : signed INT32
`define PE_N       9     // 3 x 3 PE
`define RES_W    288     // PE_N * ACC_W, pe_array -> output_fifo
`define COL_W     96     // 3 * ACC_W,   output_fifo -> post_process
`define RESULT_W   8     // final regression output = signed INT8

`define ACT_AW    14     // input_buf : 24bit x 16384 Word (region A=0, B=8192)
`define WBUF_AW    9     // weight_buf : 24bit x 512 Word = 2 halves x 256 (double buffer, 2026-09-23). Address = {half, 0 ~ 255}
`define CHUNK_W    9     // chunk_len 1 ~ 256 (256 is not stored in 8 bits)
`define K_W       13     // K_total 1 ~ 4096
`define POS_W     12     // output position index
`define W_AW      16     // Weight Word address
`define PARAM_AW   7     // Param record address 0 ~ 127
`define PARAM_W   96     // Param record width
`define OCG_W      4     // oc_group index
`define OCB_W      5     // out_ch_base
`define CH_W       6     // #channel (32)
`define DIM_W      7     // W / H (maximum 64)

//   [11:0] = pos, [16:12] = out_ch_base, [17] = tile_end, [18] = layer_end
`define META_W    19
`define META_POS      11:0
`define META_OCB      16:12
`define META_TEND     17
`define META_LEND     18

//   [31:0] bias_corr(signed32) [63:32] multiplier(signed32, non-negative)
//   [69:64] shift(unsigned6)   [77:70] out_zero_point(signed8)
//   [95:78] reserved = 0
`define PRM_BIAS      31:0
`define PRM_MULT      63:32
`define PRM_SHIFT     69:64
`define PRM_OZP       77:70

`endif
