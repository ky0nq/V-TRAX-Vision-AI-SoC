// ============================================================
// cnn_host_agent : host_agent = sequencer + driver + monitor on cnn_ctrl_if
//   plays the SoC host : reset, start handshake, done wait, irq_en / irq_clear
// ============================================================
class cnn_host_agent extends uvm_agent;
	`uvm_component_utils(cnn_host_agent)

	cnn_host_sequencer sequencer;
	cnn_host_driver    driver;
	cnn_host_monitor   monitor;

	uvm_analysis_port #(cnn_host_event) ap;

	function new(string name = "cnn_host_agent", uvm_component parent);
		super.new(name, parent);
	endfunction

	function void build_phase(uvm_phase phase);
		super.build_phase(phase);
		monitor = cnn_host_monitor::type_id::create("monitor", this);
		if (get_is_active() == UVM_ACTIVE) begin
			sequencer = cnn_host_sequencer::type_id::create("sequencer", this);
			driver    = cnn_host_driver::type_id::create("driver", this);
		end
	endfunction

	function void connect_phase(uvm_phase phase);
		super.connect_phase(phase);
		ap = monitor.ap;
		if (get_is_active() == UVM_ACTIVE) begin
			driver.seq_item_port.connect(sequencer.seq_item_export);
		end
	endfunction
endclass
