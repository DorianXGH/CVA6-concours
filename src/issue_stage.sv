// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Author: Florian Zaruba, ETH Zurich
// Date: 21.05.2017
// Description: Issue stage dispatches instructions to the FUs and keeps track of them
//              in a scoreboard like data-structure.


module issue_stage import ariane_pkg::*; #(
    parameter int unsigned NR_ENTRIES = 8,
    parameter int unsigned NR_WB_PORTS = 4,
    parameter int unsigned NR_ISSUE_PORTS = 2,
    parameter int unsigned NR_COMMIT_PORTS = 2
)(
    input  logic                                     clk_i,     // Clock
    input  logic                                     rst_ni,    // Asynchronous reset active low

    output logic                                     sb_full_o,
    input  logic                                     flush_unissued_instr_i,
    input  logic                                     flush_i,
    // from ISSUE
    input  scoreboard_entry_t                        decoded_instr_i,
    input  logic                                     decoded_instr_valid_i,
    input  logic                                     is_ctrl_flow_i,
    output logic                                     decoded_instr_ack_o,
    // to EX
    output [NR_ISSUE_PORTS-1:0][riscv::VLEN-1:0]                         rs1_forwarding_o,  // unregistered version of fu_data_o.operanda
    output [NR_ISSUE_PORTS-1:0][riscv::VLEN-1:0]                         rs2_forwarding_o, // unregistered version of fu_data_o.operandb
    output fu_data_t [NR_ISSUE_PORTS-1:0]                                 fu_data_o,
    output logic [NR_ISSUE_PORTS-1:0][riscv::VLEN-1:0]                   pc_o,
    output logic [NR_ISSUE_PORTS-1:0]                                     is_compressed_instr_o,
    input  logic                                     flu_ready_i,
    output logic                                     alu_valid_o,
    // ex just resolved our predicted branch, we are ready to accept new requests
    input  logic                                     resolve_branch_i,

    input  logic                                     lsu_ready_i,
    output logic                                     lsu_valid_o,
    // branch prediction
    output logic                                     branch_valid_o,   // use branch prediction unit
    output branchpredict_sbe_t                       branch_predict_o, // Branch predict Out

    output logic                                     mult_valid_o,

    input  logic                                     fpu_ready_i,
    output logic                                     fpu_valid_o,
    output logic [1:0]                               fpu_fmt_o,        // FP fmt field from instr.
    output logic [2:0]                               fpu_rm_o,         // FP rm field from instr.

    output logic                                     csr_valid_o,

    // write back port
    input logic [NR_WB_PORTS-1:0][TRANS_ID_BITS-1:0] trans_id_i,
    input bp_resolve_t                               resolved_branch_i,
    input logic [NR_WB_PORTS-1:0][riscv::XLEN-1:0]   wbdata_i,
    input exception_t [NR_WB_PORTS-1:0]              ex_ex_i, // exception from execute stage
    input logic [NR_WB_PORTS-1:0]                    wt_valid_i,

    // commit port
    input  logic [NR_COMMIT_PORTS-1:0][4:0]          waddr_i,
    input  logic [NR_COMMIT_PORTS-1:0][riscv::XLEN-1:0] wdata_i,
    input  logic [NR_COMMIT_PORTS-1:0]               we_gpr_i,
    input  logic [NR_COMMIT_PORTS-1:0]               we_fpr_i,

    output scoreboard_entry_t [NR_COMMIT_PORTS-1:0]  commit_instr_o,
    input  logic              [NR_COMMIT_PORTS-1:0]  commit_ack_i
);
    // ---------------------------------------------------
    // Scoreboard (SB) <-> Issue and Read Operands (IRO)
    // ---------------------------------------------------
    logic [NR_ISSUE_PORTS-1:0][2**REG_ADDR_SIZE-1:0] rd_clobber_gpr_sb_iro;
    logic [NR_ISSUE_PORTS-1:0][2**REG_ADDR_SIZE-1:0] rd_clobber_fpr_sb_iro;
    logic [NR_ISSUE_PORTS-1:0][2**REG_ADDR_SIZE-1:0] rd_clobber_gpr_csr_sb_iro;

    logic [NR_ISSUE_PORTS-1:0][REG_ADDR_SIZE-1:0]  rs1_iro_sb;
    riscv::xlen_t [NR_ISSUE_PORTS-1:0]              rs1_sb_iro;
    logic [NR_ISSUE_PORTS-1:0]                      rs1_valid_sb_iro;

    logic [NR_ISSUE_PORTS-1:0][REG_ADDR_SIZE-1:0]  rs2_iro_sb;
    riscv::xlen_t [NR_ISSUE_PORTS-1:0]              rs2_sb_iro;
    logic [NR_ISSUE_PORTS-1:0]                     rs2_valid_iro_sb;

    logic [NR_ISSUE_PORTS-1:0][REG_ADDR_SIZE-1:0]  rs3_iro_sb;
    logic [NR_ISSUE_PORTS-1:0][FLEN-1:0]           rs3_sb_iro;
    logic [NR_ISSUE_PORTS-1:0]                      rs3_valid_iro_sb;

    scoreboard_entry_t         issue_instr_rename_sb;
    logic                      issue_instr_valid_rename_sb;
    logic                      issue_ack_sb_rename;

    scoreboard_entry_t [NR_ISSUE_PORTS-1:0]        issue_instr_sb_iro;
    logic [NR_ISSUE_PORTS-1:0]                     issue_instr_valid_sb_iro;
    logic [NR_ISSUE_PORTS-1:0]                      issue_ack_iro_sb;

    // ---------------------------------------------------------
    // 1. Re-name
    // ---------------------------------------------------------
    re_name i_re_name (
        .clk_i                  ( clk_i                        ),
        .rst_ni                 ( rst_ni                       ),
        .flush_i                ( flush_i                      ),
        .flush_unissied_instr_i ( flush_unissued_instr_i       ),
        .issue_instr_i          ( decoded_instr_i              ),
        .issue_instr_valid_i    ( decoded_instr_valid_i        ),
        .issue_ack_o            ( decoded_instr_ack_o          ),
        .issue_instr_o          ( issue_instr_rename_sb        ),
        .issue_instr_valid_o    ( issue_instr_valid_rename_sb  ),
        .issue_ack_i            ( issue_ack_sb_rename          )
    );

    // ---------------------------------------------------------
    // 2. Manage instructions in a scoreboard
    // ---------------------------------------------------------
    scoreboard #(
        .NR_ENTRIES (NR_ENTRIES ),
        .NR_WB_PORTS(NR_WB_PORTS),
        .NR_COMMIT_PORTS(NR_COMMIT_PORTS)
    ) i_scoreboard (
        .sb_full_o             ( sb_full_o                                 ),
        .unresolved_branch_i   ( 1'b0                                      ),
        .rd_clobber_gpr_o      ( rd_clobber_gpr_sb_iro                     ),
        .rd_clobber_fpr_o      ( rd_clobber_fpr_sb_iro                     ),
        .rd_clobber_gpr_csr_o  ( rd_clobber_gpr_csr_sb_iro                 ),
        .rs1_i                 ( rs1_iro_sb                                ),
        .rs1_o                 ( rs1_sb_iro                                ),
        .rs1_valid_o           ( rs1_valid_sb_iro                          ),
        .rs2_i                 ( rs2_iro_sb                                ),
        .rs2_o                 ( rs2_sb_iro                                ),
        .rs2_valid_o           ( rs2_valid_iro_sb                          ),
        .rs3_i                 ( rs3_iro_sb                                ),
        .rs3_o                 ( rs3_sb_iro                                ),
        .rs3_valid_o           ( rs3_valid_iro_sb                          ),

        .decoded_instr_i       ( issue_instr_rename_sb                     ),
        .decoded_instr_valid_i ( issue_instr_valid_rename_sb               ),
        .decoded_instr_ack_o   ( issue_ack_sb_rename                       ),
        .issue_instr_o         ( issue_instr_sb_iro                        ),
        .issue_instr_valid_o   ( issue_instr_valid_sb_iro                  ),
        .issue_ack_i           ( issue_ack_iro_sb                          ),

        .resolved_branch_i     ( resolved_branch_i                         ),
        .trans_id_i            ( trans_id_i                                ),
        .wbdata_i              ( wbdata_i                                  ),
        .ex_i                  ( ex_ex_i                                   ),
        .*
    );

    // ---------------------------------------------------------
    // 3. Issue instruction and read operand, also commit
    // ---------------------------------------------------------

    logic [NR_ISSUE_PORTS-1:0] alu_valid;
    logic [NR_ISSUE_PORTS-1:0] branch_valid;
    logic [NR_ISSUE_PORTS-1:0] csr_valid;
    logic [NR_ISSUE_PORTS-1:0] mult_valid;
    logic [NR_ISSUE_PORTS-1:0] lsu_valid;
    logic [NR_ISSUE_PORTS-1:0] fpu_valid;

    branchpredict_sbe_t [NR_ISSUE_PORTS-1:0] branch_predict;
    logic [NR_ISSUE_PORTS-1:0][1:0] fpu_fmt;
    logic [NR_ISSUE_PORTS-1:0][2:0] fpu_rm;

    assign alu_valid_o = |alu_valid;
    assign branch_valid_o = |branch_valid;
    assign csr_valid_o = |csr_valid;
    assign mult_valid_o = |mult_valid;
    assign lsu_valid_o = |lsu_valid;
    assign fpu_valid_o = |fpu_valid;

    assign branch_predict_o = fu_data_o[0].fu == CTRL_FLOW ? branch_predict[0] : branch_predict[1];
    assign fpu_fmt_o = (fu_data_o[0].fu == FPU || fu_data_o[0].fu == FPU_VEC) ? fpu_fmt[0] : fpu_fmt[1];
    assign fpu_rm_o = (fu_data_o[0].fu == FPU || fu_data_o[0].fu == FPU_VEC) ? fpu_rm[0] : fpu_rm[1];

    for (genvar i = 0; i < NR_ISSUE_PORTS; i++) begin : gen_instr_fifo

        issue_read_operands #(
        .NR_COMMIT_PORTS ( NR_COMMIT_PORTS )
        )i_issue_read_operands  (
            .flush_i             ( flush_unissued_instr_i          ),
            .issue_instr_i       ( issue_instr_sb_iro[i]              ),
            .issue_instr_valid_i ( issue_instr_valid_sb_iro[i]        ),
            .issue_ack_o         ( issue_ack_iro_sb[i]                ),
            .fu_data_o           ( fu_data_o[i]                       ),
            .flu_ready_i         ( flu_ready_i                     ),
            .rs1_o               ( rs1_iro_sb[i]                      ),
            .rs1_i               ( rs1_sb_iro[i]                      ),
            .rs1_valid_i         ( rs1_valid_sb_iro[i]                ),
            .rs2_o               ( rs2_iro_sb[i]                      ),
            .rs2_i               ( rs2_sb_iro[i]                      ),
            .rs2_valid_i         ( rs2_valid_iro_sb[i]                ),
            .rs3_o               ( rs3_iro_sb[i]                      ),
            .rs3_i               ( rs3_sb_iro[i]                      ),
            .rs3_valid_i         ( rs3_valid_iro_sb[i]                ),
            .rd_clobber_gpr_i    ( rd_clobber_gpr_sb_iro[i]           ),
            .rd_clobber_fpr_i    ( rd_clobber_fpr_sb_iro[i]           ),
            .rd_clobber_gpr_csr_i( rd_clobber_gpr_csr_sb_iro[i]       ),
            .alu_valid_o         ( alu_valid[i]                     ),
            .branch_valid_o      ( branch_valid[i]                  ),
            .csr_valid_o         ( csr_valid[i]                     ),
            .mult_valid_o        ( mult_valid[i]                    ),
            .lsu_valid_o         ( lsu_valid[i]                     ),
            .fpu_valid_o         ( fpu_valid[i]                     ),
            .fu_data_o           ( fu_data_o[i] ),
            .fpu_fmt_o           ( fpu_fmt[i] ),
            .fpu_rm_o            ( fpu_rm[i] ),
            .rs1_forwarding_o    ( rs1_forwarding_o[i] ),
            .rs2_forwarding_o    ( rs2_forwarding_o[i] ),
            .pc_o                ( pc_o[i] ),
            .is_compressed_instr_o ( is_compressed_instr_o[i] ),
            .branch_predict_o ( branch_predict[i] ),
            .*
        );

    end

endmodule
