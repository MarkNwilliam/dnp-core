module np_edr (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        freeze,
    input  wire        brake_p,    // harsh-braking sensor pulse
    input  wire        wheel_p,    // wheel-rotation pulse (4 per km)
    input  wire        impact_p,   // accelerometer impact pulse
    input  wire        weigh_p,    // weighbridge: one axle crossing
    input  wire        zenter,     // toll-zone entry (opens a passage)
    input  wire        zexit,      // toll-zone exit  (closes a passage)
    input  wire        tick_1s,    // 1 Hz boundary for the speed window
    output reg         speeding,
    output reg         overweight
);

  localparam [7:0] AXLE_LIMIT = 8'd6;    // >6 axles in a passage = overload
  localparam [15:0] SPEED_LIMIT = 16'd1000; // 100.0 km/h threshold (x10)

  // The token carries two evidence bits (speeding, overweight) rather than
  // the raw counters, so only the state those two need is kept: the pulse
  // count in the open 1 s window, and the axles in the open passage.
  reg [15:0] win_pulses;   // wheel pulses inside the current 1 s window
  reg [7:0]  cur_axles;    // axles counted in the open passage

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      speeding   <= 1'b0;
      overweight <= 1'b0;
      win_pulses <= 16'd0;
      cur_axles  <= 8'd0;
    end else if (!freeze) begin
      // axle-load enforcement across a passage
      if (zenter) cur_axles <= 8'd0;
      if (weigh_p) begin
        if (cur_axles != 8'hFF) cur_axles <= cur_axles + 8'd1;
      end
      if (zexit) begin
        if (cur_axles > AXLE_LIMIT) overweight <= 1'b1;
        cur_axles <= 8'd0;
      end

      if (wheel_p && (win_pulses != 16'hFFFF)) win_pulses <= win_pulses + 16'd1;

      // roll the 1 Hz speed window
      if (tick_1s) begin
        if (win_pulses > SPEED_LIMIT) speeding <= 1'b1;
        win_pulses <= 16'd0;
      end
    end
  end

endmodule
