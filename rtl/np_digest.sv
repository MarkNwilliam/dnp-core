// np_digest - compact 64-bit byte-serial mixing digest.
//
// NOTE: this is a tamper-EVIDENT chain (diffuses edits so a single changed
// byte changes the whole digest). It is NOT a cryptographic hash and provides
// no authentication against a determined forger. A production plate must add a
// real MAC/signature (see doc/research.md "security caveats"). It is
// deliberately multiplier-free (64-bit add + xorshift) to keep area small.
module np_digest (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,      // 1-cycle pulse to begin
    input  wire        in_valid,   // a byte is presented
    input  wire [7:0]  in_byte,
    output reg         done,       // 1-cycle pulse on the 24th (final) byte
    output reg  [63:0] hash
);

  localparam int NB = 24;           // 16 record bytes + 8 serial bytes
  localparam [4:0] NB_LAST = 5'd23;
  localparam [63:0] H_INIT = 64'hCBF29CE484222325;
  localparam [63:0] R_INIT = 64'h9E3779B97F4A7C15;

  reg [63:0] h, r;
  reg [4:0]  cnt;
  reg        busy;

  function automatic [63:0] mix64(input [63:0] a, input [63:0] rr);
    reg [63:0] t;
    begin
      t = a + rr;
      t = t ^ {a[40:0], a[63:41]};   // rotl(a,23)
      t = t ^ {t[22:0], t[63:23]};   // rotl(t,41)
      t = t + (t << 7);              // cheap avalanche
      mix64 = t;
    end
  endfunction

  function automatic [63:0] xs64(input [63:0] x);
    begin
      x = x ^ (x << 13);
      x = x ^ (x >> 7);
      x = x ^ (x << 17);
      xs64 = x;
    end
  endfunction

  wire [63:0] h_n = mix64(h ^ {56'd0, in_byte}, r);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      h    <= H_INIT;
      r    <= R_INIT;
      cnt  <= 5'd0;
      busy <= 1'b0;
      done <= 1'b0;
      hash <= 64'd0;
    end else begin
      done <= 1'b0;
      if (start && !busy) begin
        h    <= H_INIT;
        r    <= R_INIT;
        cnt  <= 5'd0;
        busy <= 1'b1;
      end else if (busy && in_valid) begin
        h <= h_n;
        r <= xs64(r);
        if (cnt == NB_LAST) begin
          hash <= h_n;
          done <= 1'b1;
          busy <= 1'b0;
        end else begin
          cnt <= cnt + 5'd1;
        end
      end
    end
  end

endmodule
