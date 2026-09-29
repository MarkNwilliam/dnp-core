module np_toll (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        freeze,     // freeze while token is issued
    input  wire        init,       // one-shot at seal, load header values
    input  wire        zenter,     // toll zone entry sensor
    input  wire        zexit,      // toll zone exit sensor
    input  wire [23:0] bal_init,   // prepaid balance from header, 1/100
    input  wire [15:0] fee_in,     // flat charge per passage from header
  output reg  [23:0] balance,    // 1/100, decrement-only after seal
  output reg  [15:0] gate_fee,   // 1/100 per passage
  output reg  [15:0] passages,   // monotonic passage counter
  output reg         in_zone,
  output reg         unpaid      // insufficient balance latched
);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      balance   <= 24'd0;
      gate_fee  <= 16'd0;
      passages  <= 16'd0;
      in_zone   <= 1'b0;
      unpaid    <= 1'b0;
    end else if (init) begin
      // seal-time load: authoritative provisioning, then read-only counters
      balance  <= bal_init;
      gate_fee <= fee_in;
      passages <= 16'd0;
      in_zone  <= 1'b0;
      unpaid   <= 1'b0;
    end else if (!freeze) begin
      if (zenter && !in_zone) begin
        in_zone <= 1'b1;
      end else if (zexit && in_zone) begin
        in_zone <= 1'b0;
        if (passages != 16'hFFFF) passages <= passages + 16'd1;
        if (balance >= {8'd0, gate_fee})
          balance <= balance - {8'd0, gate_fee};
        else
          unpaid <= 1'b1;
      end
    end
  end

endmodule
