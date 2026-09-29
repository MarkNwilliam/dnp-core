module np_tamper (
    input  wire clk,
    input  wire rst_n,
    input  wire freeze,
    input  wire seal_open,     // level: 1 = enclosure/seal broken
    input  wire g_pulse,       // event pulse from shock/removal sensor
    output reg  tampered,      // latched, never clearable after seal
    output reg  removal        // plate removal attempt (latched)
);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tampered <= 1'b0;
      removal  <= 1'b0;
    end else if (!freeze) begin
      if (seal_open) tampered <= 1'b1;    // sticky
      if (g_pulse)   removal  <= 1'b1;    // sticky
    end
  end

endmodule
