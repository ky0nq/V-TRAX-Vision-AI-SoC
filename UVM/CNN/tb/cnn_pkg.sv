`timescale 1ns / 1ps
`include "uvm_macros.svh"
package cnn_pkg;

	import uvm_pkg::*;

	// constants / types
	`include "cnn_tb_types.sv"

	// config / models
	`include "cnn_env_cfg.sv"
	`include "cnn_mem_model.sv"
	`include "infer_item.sv"           // cnn_infer_item
	`include "cnn_ref_model.sv"

	// host_agent (cnn_ctrl_if)
	`include "host_item.sv"            // cnn_host_item
	`include "host_event.sv"           // cnn_host_event
	`include "host_sqr.sv"             // cnn_host_sequencer
	`include "host_drv.sv"             // cnn_host_driver
	`include "host_mon.sv"             // cnn_host_monitor
	`include "host_agt.sv"             // cnn_host_agent

	// img_agent (cnn_img_if) / wgt_agent (cnn_wgt_if)
	`include "img_resp.sv"             // cnn_image_responder
	`include "img_agent.sv"            // cnn_img_agent
	`include "param_resp.sv"           // cnn_wgt_param_responder
	`include "wgt_agent.sv"            // cnn_wgt_agent

	// virtual sequencer / checking / coverage
	`include "cnn_vsqr.sv"             // cnn_virtual_sequencer
	`include "cnn_predictor.sv"
	`include "cnn_scb.sv"              // cnn_scoreboard
	`include "cnn_layer_scb.sv"
	`include "cnn_cov.sv"              // cnn_coverage

	// environment
	`include "cnn_env.sv"

	// sequence / test
	`include "cnn_seq_lib.sv"
	`include "cnn_test_lib.sv"

endpackage
