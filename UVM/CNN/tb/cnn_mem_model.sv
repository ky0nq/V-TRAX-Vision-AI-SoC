// ============================================================
// cnn_mem_model : TB-side RAM contents (Image RAM / shared Weight+Bias RAM)
//   - the responder returns this content for the DUT read address
//   - the sequence fills it via backdoor (pack), the predictor reads it via backdoor (unpack)
//   - out-of-range reads return 0 and are only counted (not an error: the DUT keeps issuing addresses even when idle)
// ============================================================
class cnn_mem_model extends uvm_object;
	`uvm_object_utils(cnn_mem_model)

	int unsigned depth = 0;
	int unsigned width = 32;
	bit [31:0]   mem[];
	int unsigned oor_reads = 0;
	int unsigned rd_count  = 0;

	// fixed-size buffer for $readmemh (more portable than reading directly into a dynamic array)
	//   kept 4-state so a word missing from the file (X) marks the end. static, since instances use it sequentially
	static logic [31:0] load_buf [0:65535];

	function new(string name = "cnn_mem_model");
		super.new(name);
	endfunction

	function void configure(int unsigned depth_, int unsigned width_);
		depth = depth_;
		width = width_;
		mem   = new[depth];
		clear();
	endfunction

	function void clear();
		foreach (mem[i]) mem[i] = 32'd0;
		oor_reads = 0;
		rd_count  = 0;
	endfunction

	function bit [31:0] mask();
		return (width >= 32) ? 32'hFFFF_FFFF : ((32'd1 << width) - 32'd1);
	endfunction

	// DUT read (called by the responder every clk)
	function bit [31:0] read(int unsigned addr);
		rd_count++;
		if (addr >= depth) begin
			oor_reads++;
			return 32'd0;
		end
		return mem[addr] & mask();
	endfunction

	// backdoor read (not counted in statistics)
	function bit [31:0] peek(int unsigned addr);
		if (addr >= depth) return 32'd0;
		return mem[addr] & mask();
	endfunction

	function void write(int unsigned addr, bit [31:0] data);
		if (addr >= depth) begin
			`uvm_error(get_type_name(), $sformatf("%s : write out of range addr=%0d depth=%0d", get_name(), addr, depth))
			return;
		end
		mem[addr] = data & mask();
	endfunction

	// fill from a file (hex, one line per word) starting at base. returns the number of words read
	function int load_hex(string fname, int unsigned base = 0, int unsigned max_words = 0);
		int n;
		int unsigned lim;
		foreach (load_buf[i]) load_buf[i] = 32'hXXXX_XXXX;
		$readmemh(fname, load_buf);
		lim = (max_words == 0) ? (depth - base) : max_words;
		n = 0;
		for (int unsigned i = 0; i < lim; i++) begin
			if (base + i >= depth) break;
			if ($isunknown(load_buf[i])) break;     // end of file
			mem[base + i] = load_buf[i] & mask();
			n++;
		end
		`uvm_info(get_type_name(), $sformatf("%s : loaded %0d words from '%s' at base %0d", get_name(), n, fname, base), UVM_LOW)
		return n;
	endfunction

	function void save_hex(string fname);
		int fd;
		fd = $fopen(fname, "w");
		if (fd == 0) begin
			`uvm_error(get_type_name(), $sformatf("cannot open '%s'", fname))
			return;
		end
		foreach (mem[i]) $fdisplay(fd, "%0h", mem[i]);
		$fclose(fd);
	endfunction

	function string convert2string();
		return $sformatf("%s depth=%0d width=%0d reads=%0d oor=%0d", get_name(), depth, width, rd_count, oor_reads);
	endfunction
endclass
