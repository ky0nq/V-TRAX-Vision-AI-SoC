// ============================================================
// cnn_tb_defs.svh
//   TB-only macros. Only things that cannot live inside a package, such as hierarchical paths, go here.
//   (numeric constants use the localparams in cnn_tb_types.sv)
// ============================================================
`ifndef CNN_TB_DEFS_SVH
`define CNN_TB_DEFS_SVH

// DUT instance path (must match the instance name in tb_top.sv)
`define CNN_DUT        tb_top.dut

// act_buf_probe : input_buf memory (24bit x 16384). layer_scb reads layer results from it
`define CNN_ACT_BUF_MEM   `CNN_DUT.U_ACT_PATH.INPUT_BUF.mem

`endif
