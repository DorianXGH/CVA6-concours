/*
    typedef struct packed {
        logic [DCACHE_INDEX_WIDTH-1:0] address_index;
        logic [DCACHE_TAG_WIDTH-1:0]   address_tag;
        logic [63:0]                   data_wdata;
        logic                          data_req;
        logic                          data_we;
        logic [7:0]                    data_be;
        logic [1:0]                    data_size;
        logic                          kill_req;
        logic                          tag_valid;
    } dcache_req_i_t;

    typedef struct packed {
        logic                          data_gnt;
        logic                          data_rvalid;
        logic [63:0]                   data_rdata;
    } dcache_req_o_t;

Basically, when doing a load request, data_req is put to 1, with the index set, and then waits until data_gnt is set.
On the next cycle, the tag is address_tag with tag_valid set. Then wait for data_rvalid to be set, data_rdata is then valid.

address_index | 1 2 3
address_tag   |   1 2 3
data_req      | 1 2 3
tag_valid     |   1 2 3
---
data_gnt      | 1 2 3
data_rvalid   |   1 2 3
data_rdata    |   1 2 3

*/

module prefetch_unit import ariane_pkg::*; import wt_cache_pkg::*; #(
  parameter ariane_pkg::ariane_cfg_t    ArianeCfg = ariane_pkg::ArianeDefaultConfig // contains cacheable regions
) 
(
    input  dcache_req_i_t                   cpu_port_i,
    output dcache_req_o_t                   cpu_port_o,

    output dcache_req_i_t                   cache_port_o,
    input  dcache_req_o_t                   cache_port_i,
    input logic                             clk,
    input logic                             rst_ni
);
    dcache_req_i_t  pf_port_o;
    dcache_req_o_t  pf_port_deadend;
    dcache_req_o_t  pf_port_i;
    logic cpu_has_control = 1'b1;
    assign cache_port_o = cpu_has_control ? cpu_port_i : pf_port_o;
    assign cpu_port_o = cpu_has_control ? cache_port_i : pf_port_deadend;
    assign pf_port_i = cpu_has_control ? pf_port_deadend : cache_port_i;

    typedef enum logic [1:0] {IDLE,SEND_REQ,WAIT_GNT,SEND_TAG} pref_state;

    logic [DCACHE_INDEX_WIDTH-1:0]history;
    logic [DCACHE_INDEX_WIDTH-1:0]last;
    logic [DCACHE_INDEX_WIDTH-1:0]predictions[8:0];
    logic [DCACHE_INDEX_WIDTH-1:0]step;
    logic [DCACHE_TAG_WIDTH-1:0]curtag;
    logic [3:0] confidence;
    logic [31:0] unused;
    logic [31:0] unused_thres = 32'h000000FF;
    logic in_req;

    assign pf_port_deadend.data_gnt = 0;
    assign pf_port_deadend.data_rvalid = 0;
    assign pf_port_deadend.data_rdata = 0;

    logic [15:0] test_cnt;

    assign step = last - history;
    assign predictions[0] = last;

    pref_state p_state;
    pref_state next_state;

    logic [3:0] cur_pred_index;
    logic [3:0] next_pred_index;
    logic cacheable;

    for(genvar k=1; k<9; k++) begin
        assign predictions[k] = predictions[k-1] + step;
    end

    always_comb begin
        pf_port_o.address_index = predictions[cur_pred_index];
        pf_port_o.address_tag = curtag;
        pf_port_o.data_wdata = '0;
        pf_port_o.data_we = 0;
        pf_port_o.data_be = 8'hFF;
        pf_port_o.data_size = 2'b11;
        pf_port_o.kill_req = 0;
        cacheable = is_inside_cacheable_regions(ArianeCfg,{curtag,pf_port_o.address_index});
        case (p_state)
            IDLE: begin
                next_state = (cpu_has_control || !cacheable) ? IDLE : SEND_REQ;
                next_pred_index = cacheable ? 4'b1 : 4'b1000;
                pf_port_o.data_req = 0;
                pf_port_o.tag_valid = 0;
            end
            SEND_REQ: begin
                pf_port_o.data_req = 1;
                pf_port_o.tag_valid = 0;
                next_pred_index = cur_pred_index;
                if(pf_port_i.data_gnt) begin
                    next_state = SEND_TAG;
                    next_pred_index = cur_pred_index + 1;
                end else begin
                    next_state = WAIT_GNT;
                end
            end
            WAIT_GNT: begin
                pf_port_o.data_req = 1;
                pf_port_o.tag_valid = 0;
                if(pf_port_i.data_gnt) begin
                    next_state = SEND_TAG;
                    next_pred_index = cur_pred_index + 1;
                end else begin
                    next_state = WAIT_GNT;
                end
            end
            SEND_TAG: begin
                pf_port_o.data_req = 0;
                pf_port_o.tag_valid = 1;
                next_state = IDLE;
                if(cur_pred_index != 4'b1000) begin
                    pf_port_o.data_req = 1;
                    next_pred_index = cur_pred_index;
                    if(pf_port_i.data_gnt) begin
                        next_state = SEND_TAG;
                        next_pred_index = cur_pred_index + 1;
                    end else begin
                        next_state = WAIT_GNT;
                    end
                end
            end
        endcase
    end

    always_ff @(posedge clk or negedge rst_ni) if (!rst_ni) begin
        confidence <= '0;
        history <= '0;
        last <= '0;
        unused <= '0;
        in_req <= 0;
        p_state <= IDLE;
        test_cnt <= '0;
        cur_pred_index <= 4'b1;
        p_state <= IDLE;
        curtag <= '0;
    end else begin
        p_state <= next_state;
        cur_pred_index <= next_pred_index;
         
        if(cpu_port_i.data_req) begin
            last <= cpu_port_i.address_index;
            history <= last;
            unused <= '0;
            in_req <= 1;
            if(cpu_port_i.address_index == predictions[1]) begin
                confidence <= (confidence != 4'b1111) ? confidence + 1 : confidence;
            end else begin
                confidence <= 4'b0;
            end
        end else begin
            if(cache_port_i.data_rvalid) begin
                in_req <= 0;
            end
            unused <= (unused != 32'hFFFFFFFF) ? unused + 1 : unused;
        end

        if(cpu_port_i.tag_valid) begin
            curtag <= cpu_port_i.address_tag;
        end

        if(cpu_has_control && (unused > unused_thres) && !(in_req || cpu_port_i.tag_valid || cpu_port_i.data_req || cache_port_i.data_gnt || cache_port_i.data_rvalid )) begin
            cpu_has_control <= 0;
        end else if (!cpu_has_control) begin
            if (cur_pred_index == 4'b1000) begin
                cpu_has_control <= 1;
            end
        end

    end

endmodule