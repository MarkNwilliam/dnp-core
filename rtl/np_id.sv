module np_id (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        wr_p,        // host header byte write
    input  wire [7:0]  din,         // host header byte in
    input  wire        go,          // seal request
    output wire        all_written, // 32 header bytes present
    output wire        sealed,
    output wire [63:0] serial,
    output wire [7:0]  plate0,
    output wire [7:0]  plate1,
    output wire [7:0]  plate2,
    output wire [7:0]  plate3,
    output wire [7:0]  plate4,
    output wire        reg_ok,
    output wire        tax_ok,
    output wire        ins_ok,
    output wire        class_ok,
    output wire [3:0]  zone_class,
    output wire [7:0]  mileage,
    output wire [23:0] bal_init,    // prepaid road-toll balance, 1/100
    output wire [15:0] gate_fee     // flat charge per passage, 1/100
);

  // 32-byte header (see doc/research.md):
  //  [0]      ctl: [0] reg_ok [1] tax_ok [2] ins_ok [3] class_ok
  //  [1..8]   serial (8 bytes, big endian)
  //  [9..13]  plate string, 5 chars (e.g. "UAB12")
  //  [14]     zone class: 0 private, 1 commercial, 2 heavy, 3 emergency
  //  [15]     odometer seed, x10 km
  //  [16..18] prepaid balance, 1/100 currency (decrement-only after seal)
  //  [19..20] flat toll per passage, 1/100
  //  [21..31] reserved (host should write 0)
  //
  // Bytes 21..31 are counted so the "all 32 written" seal gate still holds,
  // but they are not stored: no output ever reads them, so holding 11 bytes
  // of flops for them would be pure area.
  localparam HDR_LAST_USED = 6'd20;

  reg [7:0] hdr [0:20];
  reg       seal;
  reg [5:0] cnt;

  integer i;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      seal <= 1'b0;
      cnt  <= 6'd0;
      for (i = 0; i <= HDR_LAST_USED; i = i + 1) hdr[i] <= 8'h00;
    end else begin
      if (wr_p && !seal) begin
        if (cnt <= HDR_LAST_USED) hdr[cnt[4:0]] <= din;
        if (cnt < 6'd32) cnt <= cnt + 6'd1;
      end
      if (go && !seal && (cnt == 6'd32)) seal <= 1'b1;
    end
  end

  assign all_written = (cnt == 6'd32);
  assign sealed      = seal;
  assign serial      = {hdr[1], hdr[2], hdr[3], hdr[4], hdr[5], hdr[6], hdr[7], hdr[8]};
  assign plate0      = hdr[9];
  assign plate1      = hdr[10];
  assign plate2      = hdr[11];
  assign plate3      = hdr[12];
  assign plate4      = hdr[13];
  assign zone_class  = hdr[14][3:0];
  assign mileage     = hdr[15];
  assign reg_ok      = hdr[0][0];
  assign tax_ok      = hdr[0][1];
  assign ins_ok      = hdr[0][2];
  assign class_ok    = hdr[0][3];
  assign bal_init    = {hdr[16], hdr[17], hdr[18]};
  assign gate_fee    = {hdr[19], hdr[20]};

endmodule
