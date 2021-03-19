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
    input  dcache_req_o_t                   cache_port_i
)
    dcache_req_i_t  pf_port_o;
    dcache_req_o_t  pf_port_deadend;
    dcache_req_o_t  pf_port_i;
    logic cpu_has_control = 1'b1;
    assign cache_port_o = cpu_has_control ? cpu_port_i : pf_port_o;
    assign cpu_port_o = cpu_has_control ? cache_port_i : pf_port_deadend;
    assign pf_port_i = cpu_has_control ? pf_port_deadend : cache_port_i;
endmodule