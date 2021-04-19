// Reordering instructions in order to delay consecutive store/load instructions

module instr_reorder (
	input logic 				clk_i,
	input logic 				rst_ni,
	input logic 				flush_i,
	input logic 				debug_req_i,

	input ariane_pkg::scoreboard_entry_t 	issue_entry_i,
	input logic 				issue_entry_valid_i,
	input logic 				is_ctrl_flow_i,
	output logic 				issue_instr_ack_o,

	output ariane_pkg::scoreboard_entry_t	issue_entry_o,
	output logic 				issue_entry_valid_o,
	output logic 				is_ctrl_flow_o,
	input logic 				issue_instr_ack_i,

	input logic 				lsu_ready_i
);

	// delayed instruction
	struct packed {
		ariane_pkg::scoreboard_entry_t 	sbe;
		logic 				ie_valid;
		logic 				is_ctrl_flow;
	} issue_n, issue_q;

	logic is_previous_mult_n, is_previous_mult_q;

	wire buffer_empty;
	assign buffer_empty = !issue_q.ie_valid;

	logic swap_allowed;
	logic ls_swap;
	logic mult_chaining;
	logic swap;

	wire skip_buffer;
	assign skip_buffer = is_ctrl_flow_i | issue_entry_i.fu == ariane_pkg::CSR;

	always_comb begin

		issue_n = issue_q;
		is_previous_mult_n = (issue_entry_o.fu == ariane_pkg::MULT);
		
		// check if a swap is allowed (valid, no branch, dependencies respected)
		swap_allowed = issue_entry_valid_i
				& (issue_entry_i.fu != ariane_pkg::CTRL_FLOW)
				& (issue_q.sbe.fu != ariane_pkg::CTRL_FLOW)
				& ((issue_entry_i.rs1 != issue_q.sbe.rd)|(issue_q.sbe.fu == ariane_pkg::STORE))
				& ((issue_entry_i.rs2 != issue_q.sbe.rd)|(issue_q.sbe.fu == ariane_pkg::STORE))
				& (issue_entry_i.rd != issue_q.sbe.rs1)
				& ((issue_entry_i.rd != issue_q.sbe.rs2)|(issue_q.sbe.fu == ariane_pkg::LOAD))
				& ((issue_entry_i.rd != issue_q.sbe.rd)|(issue_q.sbe.fu == ariane_pkg::STORE));

		// check if delaying a load/store is usefull
		ls_swap = ((issue_q.sbe.fu == ariane_pkg::STORE) | (issue_q.sbe.fu == ariane_pkg::LOAD))
				& (issue_entry_i.fu != ariane_pkg::STORE)
				& (issue_entry_i.fu != ariane_pkg::LOAD)
				& (!lsu_ready_i);

		// check if chaining mult instructions is possible
		mult_chaining = (issue_entry_i.fu == ariane_pkg::MULT)
				& (issue_q.sbe.fu != ariane_pkg::MULT)
				& is_previous_mult_q;

		swap = swap_allowed & (ls_swap | mult_chaining);

		if (buffer_empty) begin
			// intermediary buffer is empty -> pass input data
			issue_entry_o = issue_entry_i;
			issue_entry_valid_o = issue_entry_valid_i;
			is_ctrl_flow_o = is_ctrl_flow_i;

			issue_instr_ack_o = 1;

			// if we can't pass data to the scoreboard, store it in the buffer
			if (!issue_instr_ack_i) begin
				if (!skip_buffer) begin
					issue_n.sbe = issue_entry_i;
					issue_n.ie_valid = issue_entry_valid_i;
					issue_n.is_ctrl_flow = is_ctrl_flow_i;
				end else
					issue_instr_ack_o = 0;
			end
		end else begin
			// if we attempt to push a branch instruction, we do not want to fill the middle buffer
			// and make too many instruction fetches
			issue_instr_ack_o = issue_instr_ack_i & !skip_buffer;

			if (swap) begin
				issue_entry_o = issue_entry_i;
				issue_entry_valid_o = issue_entry_valid_i;
				is_ctrl_flow_o = is_ctrl_flow_i;
			end else begin
				issue_entry_o = issue_q.sbe;
				issue_entry_valid_o = issue_q.ie_valid;
				is_ctrl_flow_o = issue_q.is_ctrl_flow;

				if (issue_instr_ack_i) begin
					if (!skip_buffer) begin
						issue_n.sbe = issue_entry_i;
						issue_n.ie_valid = issue_entry_valid_i;
						issue_n.is_ctrl_flow = is_ctrl_flow_i;
					end else
						issue_n = '0;
				end
			end
		end

		if (flush_i) begin
			issue_n = '0;
		end
	end

	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(~rst_ni) begin
			issue_q <= '0;
			is_previous_mult_q <= 0;
		end else begin
			issue_q <= issue_n;
			is_previous_mult_q <= is_previous_mult_n;
		end
	end

endmodule
