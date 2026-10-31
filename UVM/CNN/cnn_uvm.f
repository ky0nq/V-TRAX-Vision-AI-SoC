// cnn_uvm filelist (VCS : vcs -full64 -sverilog -ntb_opts uvm -f cnn_uvm.f -top tb_top)
//   Makefile 과 같은 옵션을 여기에도 둔다
-timescale=1ns/1ps
-assert svaext
-debug_access+all
-kdb
+incdir+rtl
+incdir+tb

// ---- RTL : DUT = top_cnn ----
//   AXI4-Lite 래퍼 (AXI4_Lite_interconnect_v1_0*.v) 는 넣지 않는다. TB 가 start 핀을 직접 구동한다.
//   GitHub 원본 (.v) 을 쓸 때는 아래 .sv 를 같은 이름의 .v 로 바꾼다. cnn_defs.vh 는 rtl/ 것을 쓴다
rtl/pe_core.sv
rtl/act_path.sv
rtl/wgt_path.sv
rtl/out_path.sv
rtl/top_cnn_cntl.sv
rtl/top_cnn.sv

// ---- TB ----
tb/cnn_ctrl_if.sv
tb/cnn_img_if.sv
tb/cnn_wgt_if.sv
tb/cnn_sva.sv
tb/cnn_pkg.sv
tb/tb_top.sv
