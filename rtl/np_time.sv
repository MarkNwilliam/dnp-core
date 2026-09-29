module np_time (
    input  wire clk,
    input  wire rst_n,
    input  wire pps,        // 1 Hz window signal from the host/module
    output wire tick_1s
);

  // 3-stage edge detect on the host PPS so a 1 Hz window yields one tick.
  // The absolute second count is not carried: no token field or status bit
  // reports it, so a free-running 16-bit counter would be unreadable flops.
  reg s0, s1, s2;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s0 <= 1'b0; s1 <= 1'b0; s2 <= 1'b0;
    end else begin
      s0 <= pps; s1 <= s0; s2 <= s1;
    end
  end

  assign tick_1s = s1 & ~s2;

endmodule
