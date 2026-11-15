// NOT PART OF THE BUILD — designed but never integrated (see README).
// References cache_req_t / cache_resp_t, which were never added to types.sv,
// so this will not compile as-is. Not listed in the Makefile's COMPONENTS.
module l0_cache (
    input  logic        clk,
    input  logic        rst,

    // 2x Combinational Read Ports
    input  cache_req_t  rd_req_ex,  output cache_resp_t rd_resp_ex,  // Execute Stage (Speculative)
    input  cache_req_t  rd_req_mem, output cache_resp_t rd_resp_mem, // Memory Stage (Definitive)

    // 1x Write/Update Port (For Stores AND Fetch Fills)
    input  logic        wr_en,
    input  logic [15:0] wr_addr,
    input  logic [31:0] wr_data
);

// Clean SystemVerilog Arrays! (16 Sets, 4 Ways)
logic [31:0] cache_data [0:15][0:3];
logic [12:0] cache_tag  [0:15][0:3]; // 12-bit tag [12:1] + 1 valid bit [0]
logic [1:0]  cache_lru  [0:15][0:3];

// ==========================================
// READ PORTS (Combinational)
// ==========================================
always_comb begin
    rd_resp_ex.hit  = 1'b0; rd_resp_ex.rdata  = '0;
    rd_resp_mem.hit = 1'b0; rd_resp_mem.rdata = '0;

    for (int w = 0; w < 4; w++) begin
        // Port: Execute
        if (cache_tag[rd_req_ex.addr[3:0]][w][0] && 
            cache_tag[rd_req_ex.addr[3:0]][w][12:1] == rd_req_ex.addr[15:4]) begin
            rd_resp_ex.hit = 1'b1; rd_resp_ex.rdata = cache_data[rd_req_ex.addr[3:0]][w];
        end
        // Port: Memory
        if (cache_tag[rd_req_mem.addr[3:0]][w][0] && 
            cache_tag[rd_req_mem.addr[3:0]][w][12:1] == rd_req_mem.addr[15:4]) begin
            rd_resp_mem.hit = 1'b1; rd_resp_mem.rdata = cache_data[rd_req_mem.addr[3:0]][w];
        end
    end
end

// ==========================================
// WRITE PORT (Clocked Write-Allocate)
// ==========================================
always_ff @(posedge clk) begin
    if (rst) begin
        for (int s=0; s<16; s++) begin
            for (int w=0; w<4; w++) begin
                cache_tag[s][w] <= '0;
                cache_lru[s][w] <= w[1:0]; // Init ages 0, 1, 2, 3
            end
        end
    end else if (wr_en) begin
        logic [3:0]  set_idx = wr_addr[3:0];
        logic [11:0] tag_in  = wr_addr[15:4];
        logic        hit_found = 0;
        logic [1:0]  target_way = 0;

        // 1. Check if the block already exists
        for (int w = 0; w < 4; w++) begin
            if (cache_tag[set_idx][w][0] && cache_tag[set_idx][w][12:1] == tag_in) begin
                hit_found = 1'b1; target_way = w[1:0];
            end
        end

        // 2. If it doesn't exist, find an Invalid or LRU (age == 3) slot
        if (!hit_found) begin
            for (int w = 0; w < 4; w++) begin
                if (!cache_tag[set_idx][w][0] || cache_lru[set_idx][w] == 2'd3) target_way = w[1:0];
            end
        end

        // 3. Write Data, Update Tag, Make Youngest
        cache_tag[set_idx][target_way]  <= {tag_in, 1'b1};
        cache_data[set_idx][target_way] <= wr_data;
        cache_lru[set_idx][target_way]  <= 2'd0; 

        // 4. Age the other ways in the set
        for (int w = 0; w < 4; w++) begin
            if (w[1:0] != target_way && cache_tag[set_idx][w][0] && cache_lru[set_idx][w] != 2'd3) begin
                cache_lru[set_idx][w] <= cache_lru[set_idx][w] + 2'd1;
            end
        end
    end
end

endmodule
