// ============================================================
// cnn_host_event : event observed by host_agent's monitor (sent out on the analysis port)
// ============================================================
class cnn_host_event extends uvm_object;
	`uvm_object_utils(cnn_host_event)

	cnn_host_kind_e  kind;
	bit signed [7:0] final_result;   // EV_DONE
	bit              irq_en;         // i_irq_en at that moment
	bit              irq;            // o_irq at that moment
	int              layer_idx;      // EV_LAYER_DONE : the layer that finished
	int              cnn_state;
	longint          cycle;          // observed clk (accumulated since reset)
	longint          latency;        // EV_DONE : clks since START fire

	function new(string name = "cnn_host_event");
		super.new(name);
		kind = EV_RESET;
		final_result = 0;
		irq_en = 0; irq = 0;
		layer_idx = 0; cnn_state = 0;
		cycle = 0; latency = 0;
	endfunction

	function string convert2string();
		return $sformatf("%s cycle=%0d layer=%0d state=%0d result=%0d irq_en=%0b irq=%0b latency=%0d",
			kind.name(), cycle, layer_idx, cnn_state, final_result, irq_en, irq, latency);
	endfunction
endclass
