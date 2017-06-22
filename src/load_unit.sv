// Author: Florian Zaruba, ETH Zurich
// Date: 22.05.2017
// Description: Load Unit, takes care of all load requests
//
// Copyright (C) 2017 ETH Zurich, University of Bologna
// All rights reserved.
//
// This code is under development and not yet released to the public.
// Until it is released, the code is under the copyright of ETH Zurich and
// the University of Bologna, and may contain confidential and/or unpublished
// work. Any reuse/redistribution is strictly forbidden without written
// permission from ETH Zurich.
//
// Bug fixes and contributions will eventually be released under the
// SolderPad open hardware license in the context of the PULP platform
// (http://www.pulp-platform.org), under the copyright of ETH Zurich and the
// University of Bologna.

import ariane_pkg::*;

module load_unit (
    input  logic                     clk_i,    // Clock
    input  logic                     rst_ni,   // Asynchronous reset active low
    input  logic                     flush_i,
    // load unit input port
    input  fu_op                     operator_i,
    input  logic [TRANS_ID_BITS-1:0] trans_id_i,
    input  logic                     valid_i,
    input  logic [63:0]              vaddr_i,
    input  logic [7:0]               be_i,
    // load unit output port
    output logic                     valid_o,
    output logic                     ready_o,
    output logic [TRANS_ID_BITS-1:0] trans_id_o,
    output logic [63:0]              result_o,
    output exception                 ex_o,
    // MMU -> Address Translation
    output logic                     translation_req_o,   // request address translation
    output logic [63:0]              vaddr_o,             // virtual address out
    input  logic [63:0]              paddr_i,             // physical address in
    input  exception                 ex_i,                // exception which may has happened earlier. for example: mis-aligned exception
    input  logic                     dtlb_hit_i,          // hit on the dtlb, send in the same cycle as the request
    // address checker
    output logic [11:0]              page_offset_o,
    input  logic                     page_offset_matches_i,
    // D$ interface
    output logic [11:0]              address_index_o,
    output logic [43:0]              address_tag_o,
    output logic [63:0]              data_wdata_o,
    output logic                     data_req_o,
    output logic                     data_we_o,
    output logic [7:0]               data_be_o,
    output logic                     kill_req_o,
    output logic                     tag_valid_o,
    input  logic                     data_gnt_i,
    input  logic                     data_rvalid_i,
    input  logic [63:0]              data_rdata_i
);
    enum logic [2:0] {IDLE, WAIT_GNT, SEND_TAG, WAIT_PAGE_OFFSET, ABORT_TRANSACTION, WAIT_TRANSLATION, WAIT_FLUSH} NS, CS;
    // in order to decouple the response interface from the request interface we need a
    // a queue which can hold all outstanding memory requests
    struct packed {
        logic [TRANS_ID_BITS-1:0] trans_id;
        logic [2:0]               address_offset;
        fu_op                     operator;
    } load_data_n, load_data_q, in_data;

    // page offset is defined as the lower 12 bits, feed through for address checker
    assign page_offset_o = vaddr_i[11:0];
    // feed-through the virtual address for VA translation
    assign vaddr_o = vaddr_i;
    // this is a read-only interface so set the write enable to 0
    assign data_we_o = 1'b0;
    // compose the queue data, control is handled in the FSM
    assign in_data = {trans_id_i, vaddr_i[2:0], operator_i};
    // output address
    // we can now output the lower 12 bit as the index to the cache
    assign address_index_o = vaddr_i[11:0];
    // translation from last cycle, again: control is handled in the FSM
    assign address_tag_o   = paddr_i[55:12];
    // directly output an exception
    assign ex_o = ex_i;

    // ---------------
    // Load Control
    // ---------------
    always_comb begin : load_control
        // default assignments
        NS                = CS;
        load_data_n       = in_data;
        translation_req_o = 1'b0;
        ready_o           = 1'b1;
        data_req_o        = 1'b0;
        // tag control
        kill_req_o        = 1'b0;
        tag_valid_o       = 1'b0;
        data_be_o         = be_i;

        case (CS)
            IDLE: begin
                // we've got a new load request
                if (valid_i) begin
                    // start the translation process even though we do not know if the addresses match
                    // this should ease timing
                    translation_req_o = 1'b1;
                    // check if the page offset matches with a store, if it does then stall and wait
                    if (!page_offset_matches_i) begin
                        // make a load request to memory
                        data_req_o = 1'b1;
                        // we got no data grant so wait for the grant before sending the tag
                        if (!data_gnt_i) begin
                            NS = WAIT_GNT;
                        end else begin
                            if (dtlb_hit_i)
                                // we got a grant and a hit on the DTLB so we can send the tag in the next cycle
                                NS = SEND_TAG;
                            else
                                NS = ABORT_TRANSACTION;
                        end
                    end else begin
                        // wait for the store buffer to train and the page offset to not match anymore
                        NS = WAIT_PAGE_OFFSET;
                    end
                end
            end

            // wait here for the page offset to not match anymore
            WAIT_PAGE_OFFSET: begin
                // we are definitely not ready to accept a new request
                // we need unique access to the LSU
                ready_o = 1'b0;

                // we make a new request as soon as the page offset does not match anymore
                if (!page_offset_matches_i) begin
                    NS = WAIT_GNT;
                end
            end

            // abort the previous request - free the D$ arbiter
            // we are here because of a TLB miss, we need to abort the current request and give way for the
            // PTW walker to satisfy the TLB miss
            ABORT_TRANSACTION: begin
                ready_o     = 1'b0;
                kill_req_o  = 1'b1;
                tag_valid_o = 1'b1;
                // redo the request by going back to the wait gnt state
                NS          = WAIT_TRANSLATION;
            end

            WAIT_TRANSLATION: begin
                ready_o           = 1'b0;
                translation_req_o = 1'b1;
                // we've got a hit and we can continue with the request process
                if (dtlb_hit_i)
                    NS = WAIT_GNT;
            end

            WAIT_GNT: begin
                // keep the translation request up
                translation_req_o = 1'b1;
                // we are waiting for the grant so we are not ready to accept anything new
                ready_o = 1'b0;
                // keep the request up
                data_req_o = 1'b1;
                // we finally got a data grant
                if (data_gnt_i) begin
                    // so we send the tag in the next cycle
                    if (dtlb_hit_i)
                        NS = SEND_TAG;
                    else // should we not have hit on the TLB abort this transaction an retry later
                        NS = ABORT_TRANSACTION;
                end
                // otherwise we keep waiting on our grant
            end
            // we know for sure that the tag we want to send is valid
            SEND_TAG: begin
                tag_valid_o = 1'b1;
                // we can make a new request here if we got one
                if (valid_i) begin
                    // start the translation process even though we do not know if the addresses match
                    // this should ease timing
                    translation_req_o = 1'b1;
                    // check if the page offset matches with a store, if it does stall and wait
                    if (!page_offset_matches_i) begin
                        // make a load request to memory
                        data_req_o = 1'b1;
                        // we got no data grant so wait for the grant before sending the tag
                        if (!data_gnt_i) begin
                            NS = WAIT_GNT;
                        end else begin
                            // we got a grant so we can send the tag in the next cycle
                            if (dtlb_hit_i)
                                // we got a grant and a hit on the DTLB so we can send the tag in the next cycle
                                NS = SEND_TAG;
                            else // we missed on the TLB -> wait for the translation
                                NS = ABORT_TRANSACTION;
                        end
                    end else begin
                        // wait for the store buffer to train and the page offset to not match anymore
                        NS = WAIT_PAGE_OFFSET;
                    end
                end
                // ----------
                // Exception
                // ----------
                // if we got an exception we need to kill the request immediately
                if (ex_i.valid) begin
                    kill_req_o = 1'b1;
                    NS = IDLE;
                end
            end

            WAIT_FLUSH: begin
                ready_o     = 1'b0;
                // the D$ arbiter will take care of presenting this to the memory only in case we
                // have an outstanding request
                kill_req_o  = 1'b1;
                tag_valid_o = 1'b1;
                // we've killed the current request so we can go back to idle
                NS = IDLE;
            end

        endcase
        // we got an exception
        if (ex_i.valid) begin
            // the next state will be the idle state
            NS = IDLE;
        end
        // if we just flushed and the queue is not empty or we are getting an rvalid this cycle wait in a extra stage
        if (flush_i) begin
            NS = WAIT_FLUSH;
        end
    end

    // decoupled rvalid process
    always_comb begin : rvalid_output
        valid_o = 1'b0;
        // output the queue data directly, the valid signal is set corresponding to the process above
        trans_id_o = load_data_q.trans_id;
        // we got an rvalid and are currently not flushing and not aborting the request
        if (data_rvalid_i && CS != WAIT_FLUSH) begin
            // we killed the request
            if(!kill_req_o)
                valid_o = 1'b1;
            // the output is also valid if we got an exception
            if (ex_i.valid)
                valid_o = 1'b1;
        end

    end


    // latch physical address for the tag cycle (one cycle after applying the index)
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni) begin
            CS          <= IDLE;
            load_data_q <= '0;
        end else begin
            CS          <= NS;
            load_data_q <= load_data_n;
        end
    end

    // ---------------
    // Sign Extend
    // ---------------
    logic [63:0] rdata_d_ext; // sign extension for double words, actually only misaligned assembly
    logic [63:0] rdata_w_ext; // sign extension for words
    logic [63:0] rdata_h_ext; // sign extension for half words
    logic [63:0] rdata_b_ext; // sign extension for bytes

    // double words
    always_comb begin : sign_extend_double_word
        rdata_d_ext = data_rdata_i[63:0];
    end

      // sign extension for words
    always_comb begin : sign_extend_word
        case (load_data_q.address_offset)
            default: rdata_w_ext = (load_data_q.operator == LW) ? {{32{data_rdata_i[31]}}, data_rdata_i[31:0]}  : {32'h0, data_rdata_i[31:0]};
            3'b001:  rdata_w_ext = (load_data_q.operator == LW) ? {{32{data_rdata_i[39]}}, data_rdata_i[39:8]}  : {32'h0, data_rdata_i[39:8]};
            3'b010:  rdata_w_ext = (load_data_q.operator == LW) ? {{32{data_rdata_i[47]}}, data_rdata_i[47:16]} : {32'h0, data_rdata_i[47:16]};
            3'b011:  rdata_w_ext = (load_data_q.operator == LW) ? {{32{data_rdata_i[55]}}, data_rdata_i[55:24]} : {32'h0, data_rdata_i[55:24]};
            3'b100:  rdata_w_ext = (load_data_q.operator == LW) ? {{32{data_rdata_i[63]}}, data_rdata_i[63:32]} : {32'h0, data_rdata_i[63:32]};
        endcase
    end

    // sign extension for half words
    always_comb begin : sign_extend_half_word
        case (load_data_q.address_offset)
            default: rdata_h_ext = (load_data_q.operator == LH) ? {{48{data_rdata_i[15]}}, data_rdata_i[15:0]}  : {48'h0, data_rdata_i[15:0]};
            3'b001:  rdata_h_ext = (load_data_q.operator == LH) ? {{48{data_rdata_i[23]}}, data_rdata_i[23:8]}  : {48'h0, data_rdata_i[23:8]};
            3'b010:  rdata_h_ext = (load_data_q.operator == LH) ? {{48{data_rdata_i[31]}}, data_rdata_i[31:16]} : {48'h0, data_rdata_i[31:16]};
            3'b011:  rdata_h_ext = (load_data_q.operator == LH) ? {{48{data_rdata_i[39]}}, data_rdata_i[39:24]} : {48'h0, data_rdata_i[39:24]};
            3'b100:  rdata_h_ext = (load_data_q.operator == LH) ? {{48{data_rdata_i[47]}}, data_rdata_i[47:32]} : {48'h0, data_rdata_i[47:32]};
            3'b101:  rdata_h_ext = (load_data_q.operator == LH) ? {{48{data_rdata_i[55]}}, data_rdata_i[55:40]} : {48'h0, data_rdata_i[55:40]};
            3'b110:  rdata_h_ext = (load_data_q.operator == LH) ? {{48{data_rdata_i[63]}}, data_rdata_i[63:48]} : {48'h0, data_rdata_i[63:48]};
        endcase
    end

    always_comb begin : sign_extend_byte
        case (load_data_q.address_offset)
            default: rdata_b_ext = (load_data_q.operator == LB) ? {{56{data_rdata_i[7]}},  data_rdata_i[7:0]}   : {56'h0, data_rdata_i[7:0]};
            3'b001:  rdata_b_ext = (load_data_q.operator == LB) ? {{56{data_rdata_i[15]}}, data_rdata_i[15:8]}  : {56'h0, data_rdata_i[15:8]};
            3'b010:  rdata_b_ext = (load_data_q.operator == LB) ? {{56{data_rdata_i[23]}}, data_rdata_i[23:16]} : {56'h0, data_rdata_i[23:16]};
            3'b011:  rdata_b_ext = (load_data_q.operator == LB) ? {{56{data_rdata_i[31]}}, data_rdata_i[31:24]} : {56'h0, data_rdata_i[31:24]};
            3'b100:  rdata_b_ext = (load_data_q.operator == LB) ? {{56{data_rdata_i[39]}}, data_rdata_i[39:32]} : {56'h0, data_rdata_i[39:32]};
            3'b101:  rdata_b_ext = (load_data_q.operator == LB) ? {{56{data_rdata_i[47]}}, data_rdata_i[47:40]} : {56'h0, data_rdata_i[47:40]};
            3'b110:  rdata_b_ext = (load_data_q.operator == LB) ? {{56{data_rdata_i[55]}}, data_rdata_i[55:48]} : {56'h0, data_rdata_i[55:48]};
            3'b111:  rdata_b_ext = (load_data_q.operator == LB) ? {{56{data_rdata_i[63]}}, data_rdata_i[63:56]} : {56'h0, data_rdata_i[63:56]};
        endcase
    end

    always_comb begin
        case (load_data_q.operator)
            LW, LWU:       result_o = rdata_w_ext;
            LH, LHU:       result_o = rdata_h_ext;
            LB, LBU:       result_o = rdata_b_ext;
            default:       result_o = rdata_d_ext;
        endcase
    end

endmodule