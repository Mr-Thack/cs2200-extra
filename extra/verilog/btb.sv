// Metadata struct (19 bits total)
typedef struct packed {
    logic       valid; // 1 bit
    logic [14:0] tag;  // 15 bits
    logic [1:0]  mode; // 2 bits
    logic  age;  // 1 bit
} btb_meta_t;

module btb (
    input logic clk,
    input logic rst,

    // READ PORT (Fetch Stage)
    input  logic [31:0]   read_pc,
    output btb_read_data  rdata, 

    // WRITE PORT (Execute Stage)
    input  btb_write_data wdata
);

// ==========================================
// CACHE MEMORY (Split to bypass >32b limits)
// ==========================================
// btb_meta_t   btb_meta   [64]; // [8 Sets][8 Ways]
// logic [31:0] btb_target [64]; // [8 Sets][8 Ways]
btb_meta_t   btb_meta   [4]; // [2 Sets][2 Ways]
logic [31:0] btb_target [4]; // [2 Sets][2 Ways]

// ==========================================
// READ PORT: Combinational Search
// ==========================================
logic  read_set;
logic [14:0] read_tag;

assign read_set = read_pc[0];
assign read_tag = read_pc[15:1];

always_comb begin
    rdata.valid  = 1'b0;
    rdata.take   = 1'b0;
    rdata.target = 32'd0;

    // Search both 2 ways in the set simultaneously
    for (int i = 0; i < 2; i++) begin
        logic [1:0] idx = {read_set, i[0]}; // Convert to 2 bit flat index
        if (btb_meta[idx].valid && btb_meta[idx].tag == read_tag) begin
            rdata.valid  = 1'b1;
            rdata.target = btb_target[idx];
            rdata.take   = (btb_meta[idx].mode >= 2'b10); // Take if Weakly or Strongly Taken
        end
    end
end

// ==========================================
// WRITE PORT LOGIC: Find Hit / LRU Index
// ==========================================
logic  up_set;
logic [14:0] up_tag;

assign up_set = wdata.pc[0];
assign up_tag = wdata.pc[15:1];

logic       hit;
logic target_way; 
logic old_age;

always_comb begin
    hit        = 1'b0;
    target_way = 1'd0;
    old_age    = 1'd1; // Default to oldest

    // Step 1: Does this branch already exist in the cache?
    for (int i = 0; i < 2; i++) begin
        logic [1:0] idx = {up_set, i[0]}; // Convert to 2 bit flat index
        if (btb_meta[idx].valid && btb_meta[idx].tag == up_tag) begin
            hit        = 1'b1;
            target_way = i[0];
            old_age    = btb_meta[idx].age;
        end
    end

    // Step 2: If no hit, find the LRU (age == 1) or an invalid slot
    if (!hit) begin
        for (int i = 0; i < 2; i++) begin
            logic [1:0] idx = {up_set, i[0]}; // Convert to 2 bit flat index
            if (!btb_meta[idx].valid || btb_meta[idx].age == 1'd1) begin
                target_way = i[0];
            end
        end
    end
end

// ==========================================
// WRITE PORT EXECUTION: Clocked Update
// ==========================================
genvar i;
generate for (i = 0; i < 4; i++) begin : BTB_REGS
    always_ff @(posedge clk) begin
        if (rst) begin
            btb_meta[i]     <= '0;
            btb_meta[i].age <= i[0]; // Initialize LRU ages 0 to 1
            btb_target[i]   <= '0;
        end else if (wdata.write && wdata.pc != 32'd0) begin

            if (i[1] == up_set) begin
                if (i[0] == target_way) begin
                    // Update the Target Way Metadata & Address
                    btb_meta[i].valid <= 1'b1;
                    btb_meta[i].tag   <= up_tag;
                    btb_meta[i].age   <= 1'd0; // Mark as most recently used (youngest)
                    btb_target[i]     <= wdata.target;

                    // Saturating Counter Logic
                    if (hit) begin
                        if (wdata.taken && btb_meta[i].mode < 2'b11) begin 
                            btb_meta[i].mode <= btb_meta[i].mode + 2'd1;
                        end else if (!wdata.taken && btb_meta[i].mode > 2'b00) begin 
                            btb_meta[i].mode <= btb_meta[i].mode - 2'd1;
                        end
                    end else begin
                        // New allocation: Initialize prediction based on outcome
                        btb_meta[i].mode <= wdata.taken ? 2'b10 : 2'b01; 
                    end
                end else begin
                    // Different Way but in same set, so age it
                    if (btb_meta[i].valid && btb_meta[i].age < old_age) begin
                        btb_meta[i].age <= btb_meta[i].age + 1'd1;
                    end
                end
            end

        end
    end
end
endgenerate

endmodule
