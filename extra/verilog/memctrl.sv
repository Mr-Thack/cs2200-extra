// NOT PART OF THE BUILD — designed but never integrated (see README).
// References cache_req_t / cache_resp_t, which were never added to types.sv,
// so this will not compile as-is. Not listed in the Makefile's COMPONENTS.
module unified_mem_controller (
    input  logic        clk, 
    input  logic        rst,

    // Execute Stage (Speculative Read)
    input  cache_req_t  req_ex,
    output cache_resp_t resp_ex,

    // Memory Stage (Definitive Read/Write)
    input  cache_req_t  req_mem,
    output cache_resp_t resp_mem,

    // Physical Single-Port DMEM Interface
    output logic [15:0] dmem_addr,
    output logic [31:0] dmem_wdata,
    output logic        dmem_we,
    input  logic [31:0] dmem_rdata
);

// ==========================================
// WRITE BUFFER (Circular FIFO)
// ==========================================
cache_req_t wq [0:3];
logic [2:0] wq_count;
logic [1:0] wq_head, wq_tail;

logic wq_full, wq_empty;
assign wq_full  = (wq_count == 3'd4);
assign wq_empty = (wq_count == 3'd0);

// ==========================================
// CACHE INSTANTIATION
// ==========================================
cache_resp_t l0_resp_ex, l0_resp_mem;
logic        cache_wr_en;
logic [15:0] cache_wr_addr;
logic [31:0] cache_wr_data;

l0_cache l0_inst (
    .clk(clk), .rst(rst),
    .rd_req_ex(req_ex),   .rd_resp_ex(l0_resp_ex),
    .rd_req_mem(req_mem), .rd_resp_mem(l0_resp_mem),
    .wr_en(cache_wr_en), .wr_addr(cache_wr_addr), .wr_data(cache_wr_data)
);

// ==========================================
// DMEM ARBITRATION
// ==========================================
logic dmem_read_active;

always_comb begin
    dmem_we = 1'b0;
    dmem_addr = '0;
    dmem_wdata = '0;
    dmem_read_active = 1'b0;

    // Arbitration Rules (Mem Read > Queue Pressure > Exec Read > Casual Drain)
    if (req_mem.memop == MEM_READ && !l0_resp_mem.hit) begin
        // 1. Mem Stage MUST read (Absolute Priority)
        dmem_addr = req_mem.addr;
        dmem_read_active = 1'b1;

    end else if (wq_full) begin
        // 2. Queue is full! Hijack the port to relieve pressure.
        dmem_addr  = wq[wq_tail].addr;
        dmem_wdata = wq[wq_tail].wdata;
        dmem_we    = 1'b1;

    end else if (req_ex.memop == MEM_READ && !l0_resp_ex.hit) begin
        // 3. Exec Stage early read
        dmem_addr = req_ex.addr;
        dmem_read_active = 1'b1;

    end else if (!wq_empty) begin
        // 4. Casual Write Queue Drain
        dmem_addr  = wq[wq_tail].addr;
        dmem_wdata = wq[wq_tail].wdata;
        dmem_we    = 1'b1;
    end
end

// ==========================================
// READ BYPASS & CACHE FILL LOGIC
// ==========================================

always_comb begin
    assign resp_ex.hit   = l0_resp_ex.hit || (dmem_read_active && dmem_addr == req_ex.addr);
    assign resp_ex.rdata = l0_resp_ex.hit ? l0_resp_ex.rdata : dmem_rdata;

    assign resp_mem.hit   = l0_resp_mem.hit || (dmem_read_active && dmem_addr == req_mem.addr);
    assign resp_mem.rdata = l0_resp_mem.hit ? l0_resp_mem.rdata : dmem_rdata;

    assign cache_wr_en   = req_mem.memop == MEM_WRITE || dmem_read_active;

    if (dmem_read_active) begin
        cache_wr_addr = dmem_addr;
        cache_wr_data = dmem_rdata;
    end else begin
        cache_wr_addr = req_mem.addr;
        cache_wr_data = req_mem.wdata;
    end
end

// ==========================================
// CLOCKED FIFO UPDATES
// ==========================================
logic push_wq;
assign push_wq = req_mem.memop == MEM_WRITE;

always_ff @(posedge clk) begin
    if (rst) begin
        wq_count <= '0; wq_head  <= '0; wq_tail  <= '0;
    end else begin
        if (push_wq && !dmem_we) wq_count <= wq_count + 3'd1;
        if (!push_wq && dmem_we) wq_count <= wq_count - 3'd1;

        if (push_wq) begin
            wq[wq_head] <= req_mem;
            wq_head <= wq_head + 2'd1;
        end

        if (dmem_we) begin
            wq_tail <= wq_tail + 2'd1;
        end
    end
end

endmodule
