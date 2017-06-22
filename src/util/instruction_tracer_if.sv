// Author: Florian Zaruba, ETH Zurich
// Date: 16.05.2017
// Description: Instruction Tracer Interface
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
//
import ariane_pkg::*;
`ifndef INSTR_TRACER_IF_SV
`define INSTR_TRACER_IF_SV
interface instruction_tracer_if (
        input clk
    );
    logic            rstn;
    logic            flush_unissued;
    logic            flush;
    // Decode
    fetch_entry      fetch;
    logic            fetch_valid;
    logic            fetch_ack;
    // Issue stage
    logic            issue_ack; // issue acknowledged
    scoreboard_entry issue_sbe; // issue scoreboard entry
    // WB stage
    logic [4:0]      waddr;
    logic [63:0]     wdata;
    logic            we;
    // commit stage
    scoreboard_entry commit_instr; // commit instruction
    logic            commit_ack;
    // address translation
    logic            lsu_valid;
    logic            translation_valid;
    logic [63:0]     vaddr;
    logic [63:0]     paddr;
    logic            is_store;
    logic            st_ready;
    logic            ld_ready;
    // exceptions
    exception        exception;
    // the tracer just has a passive interface we do not drive anything with it
    clocking pck @(posedge clk);
        input rstn, flush_unissued, flush, fetch, fetch_valid, fetch_ack, issue_ack, issue_sbe, waddr, lsu_valid,
              wdata, we, commit_instr, commit_ack, translation_valid, vaddr, paddr, is_store, st_ready, ld_ready, exception;
    endclocking

endinterface
`endif