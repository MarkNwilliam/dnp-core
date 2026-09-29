// np_core - Digital Number Plate secure/evidence core (top).
//
// Host byte-port protocol (active-high one-cycle strobes, like FuelGuard):
//   SETUP   : wr (din) x32 to fill the 32-byte header, then go to seal.
//             go with <32 bytes -> err latch (no seal).
//   SEALED  : go -> snapshot the 16-byte record, mix 24 bytes
//             (record+serial) into a 64-bit digest, latch it.
//             rd -> read the 24-byte token (16 record + 8 digest) from
//             index 0, auto-incrementing.
// pps : 1 Hz time window (sec counter).
// Sensors: toll zone (zenter/zexit), EDR (brake/wheel/impact/weigh),
//          enclosure (seal_open), removal shock (g_pulse).
module np_core (
    input  wire        clk,
    input  wire        rst_n,
    // host port
    input  wire        wr,
    input  wire        go,
    input  wire        rd,
    input  wire [7:0]  din,
    output reg  [7:0]  dout,
    input  wire        pps,
    // sensors
    input  wire        zenter,
    input  wire        zexit,
    input  wire        brake_p,
    input  wire        wheel_p,
    input  wire        impact_p,
    input  wire        weigh_p,
    input  wire        seal_open,
    input  wire        g_pulse,
    // status
    output wire [7:0]  status
);

  // ------------------------------------------------------------------
  // host port strobe edge-detect
  // ------------------------------------------------------------------
  reg wr_d, go_d, rd_d;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin wr_d <= 1'b0; go_d <= 1'b0; rd_d <= 1'b0; end
    else begin wr_d <= wr; go_d <= go; rd_d <= rd; end
  end
  wire wr_p = wr & ~wr_d;
  wire go_p = go & ~go_d;
  wire rd_p = rd & ~rd_d;

  // ------------------------------------------------------------------
  // time
  // ------------------------------------------------------------------
  wire tick_1s;
  np_time u_time (.clk(clk), .rst_n(rst_n), .pps(pps), .tick_1s(tick_1s));

  // ------------------------------------------------------------------
  // identity / header
  // ------------------------------------------------------------------
  wire        id_all_written, id_sealed;
  wire [63:0] serial;
  wire [7:0]  plate0, plate1, plate2, plate3, plate4;
  wire        reg_ok, tax_ok, ins_ok, class_ok;
  wire [3:0]  zone_class;
  wire [7:0]  mileage;
  wire [23:0] bal_init;
  wire [15:0] gate_fee_in;

  wire header_valid = reg_ok && (zone_class <= 4'd3);
  wire id_go = go_p && id_all_written && header_valid;   // gate np_id's seal

  np_id u_id (
    .clk(clk), .rst_n(rst_n),
    .wr_p(wr_p), .din(din), .go(id_go),
    .all_written(id_all_written), .sealed(id_sealed),
    .serial(serial),
    .plate0(plate0), .plate1(plate1), .plate2(plate2),
    .plate3(plate3), .plate4(plate4),
    .reg_ok(reg_ok), .tax_ok(tax_ok), .ins_ok(ins_ok), .class_ok(class_ok),
    .zone_class(zone_class), .mileage(mileage),
    .bal_init(bal_init), .gate_fee(gate_fee_in)
  );

  // ------------------------------------------------------------------
  // error latch
  // ------------------------------------------------------------------
  reg err;
  wire seal_attempt = go_p && !id_sealed;
  wire err_now = (seal_attempt && !id_all_written) ||
                 (seal_attempt && id_all_written && !header_valid);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) err <= 1'b0;
    else if (err_now) err <= 1'b1;
  end

  // ------------------------------------------------------------------
  // toll
  // ------------------------------------------------------------------
  wire [23:0] balance;
  wire [15:0] gate_fee, passages;
  wire        in_zone, unpaid;
  wire        freeze;        // hold counters while a token is issued

  reg id_sealed_d;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) id_sealed_d <= 1'b0; else id_sealed_d <= id_sealed;

  wire init = id_sealed & ~id_sealed_d;  // seal-time load pulse

  np_toll u_toll (
    .clk(clk), .rst_n(rst_n), .freeze(freeze), .init(init),
    .zenter(zenter), .zexit(zexit),
    .bal_init(bal_init), .fee_in(gate_fee_in),
    .balance(balance), .gate_fee(gate_fee),
    .passages(passages),
    .in_zone(in_zone), .unpaid(unpaid)
  );

  // ------------------------------------------------------------------
  // tamper
  // ------------------------------------------------------------------
  wire tampered, removal;
  np_tamper u_tamper (
    .clk(clk), .rst_n(rst_n), .freeze(freeze),
    .seal_open(seal_open), .g_pulse(g_pulse),
    .tampered(tampered), .removal(removal)
  );

  // ------------------------------------------------------------------
  // EDR / load
  // ------------------------------------------------------------------
  wire        speeding, overweight;

  np_edr u_edr (
    .clk(clk), .rst_n(rst_n), .freeze(freeze),
    .brake_p(brake_p), .wheel_p(wheel_p), .impact_p(impact_p), .weigh_p(weigh_p),
    .zenter(zenter), .zexit(zexit), .tick_1s(tick_1s),
    .speeding(speeding), .overweight(overweight)
  );

  // ------------------------------------------------------------------
  // audit event (counted + chained; the token carries the count and the
  // chain bit, so no per-event payload is stored)
  // ------------------------------------------------------------------
  reg tampered_d, removal_d;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin tampered_d <= 1'b0; removal_d <= 1'b0; end
    else begin tampered_d <= tampered; removal_d <= removal; end
  end
  wire tamper_evt = (tampered | removal) & ~(tampered_d | removal_d);
  wire passage_evt = zexit & in_zone;
  wire ev_valid = tamper_evt | passage_evt | brake_p | impact_p | weigh_p;

  wire [7:0] log_head;
  wire       chain_bit;
  np_audit u_audit (
    .clk(clk), .rst_n(rst_n), .freeze(freeze),
    .ev(ev_valid & ~freeze),
    .log_head(log_head), .chain_bit(chain_bit)
  );

  // ------------------------------------------------------------------
  // token record + digest
  // ------------------------------------------------------------------
  wire        dig_done;
  wire [63:0] dig_hash;
  reg         issuing;
  reg         start_reg;   // clean 1-cycle registered pulse into the digest
  reg  [4:0]  feed;
  reg         in_valid;
  reg  [7:0]  in_byte;
  reg  [63:0] digest_reg;
  reg  [4:0]  rcnt;
  reg         rdy;

  // The token record is 16 bytes; bytes 16..23 of the digest input are the
  // sealed serial, which is immutable once sealed (np_id ignores writes after
  // the seal and tokens are only issued when sealed), so it is fed to the
  // digest straight from np_id instead of being held in a 24-byte snapshot.
  reg [7:0] rec_snap [0:15];

  // record bytes 0..15 (snapshot) + sealed serial 16..23 (digest tail)
  function automatic [7:0] rec_byte(input [4:0] i);
    begin
      case (i)
        5'd0:  rec_byte = plate0;
        5'd1:  rec_byte = plate1;
        5'd2:  rec_byte = plate2;
        5'd3:  rec_byte = plate3;
        5'd4:  rec_byte = plate4;
        5'd5:  rec_byte = {tampered|removal, unpaid, speeding, overweight,
                           reg_ok, tax_ok, ins_ok, class_ok};
        5'd6:  rec_byte = {4'd0, zone_class};
        5'd7:  rec_byte = mileage;
        5'd8:  rec_byte = balance[23:16];
        5'd9:  rec_byte = balance[15:8];
        5'd10: rec_byte = balance[7:0];
        5'd11: rec_byte = gate_fee[15:8];
        5'd12: rec_byte = gate_fee[7:0];
        5'd13: rec_byte = passages[15:8];
        5'd14: rec_byte = passages[7:0];
        5'd15: rec_byte = {log_head[6:0], chain_bit};
        5'd16: rec_byte = serial[63:56];
        5'd17: rec_byte = serial[55:48];
        5'd18: rec_byte = serial[47:40];
        5'd19: rec_byte = serial[39:32];
        5'd20: rec_byte = serial[31:24];
        5'd21: rec_byte = serial[23:16];
        5'd22: rec_byte = serial[15:8];
        5'd23: rec_byte = serial[7:0];
        default: rec_byte = 8'h00;
      endcase
    end
  endfunction

  // sealed serial byte i (i = 0..7), for the digest tail
  function automatic [7:0] serial_byte(input [2:0] i);
    begin
      case (i)
        3'd0:    serial_byte = serial[63:56];
        3'd1:    serial_byte = serial[55:48];
        3'd2:    serial_byte = serial[47:40];
        3'd3:    serial_byte = serial[39:32];
        3'd4:    serial_byte = serial[31:24];
        3'd5:    serial_byte = serial[23:16];
        3'd6:    serial_byte = serial[15:8];
        default: serial_byte = serial[7:0];
      endcase
    end
  endfunction

  // host token byte (16 record + 8 digest)
  function automatic [7:0] token_byte(input [4:0] i);
    begin
      if (i < 5'd16) token_byte = rec_snap[i[3:0]];
      else begin
        case (i)
          5'd16: token_byte = digest_reg[7:0];
          5'd17: token_byte = digest_reg[15:8];
          5'd18: token_byte = digest_reg[23:16];
          5'd19: token_byte = digest_reg[31:24];
          5'd20: token_byte = digest_reg[39:32];
          5'd21: token_byte = digest_reg[47:40];
          5'd22: token_byte = digest_reg[55:48];
          5'd23: token_byte = digest_reg[63:56];
          default: token_byte = 8'h00;
        endcase
      end
    end
  endfunction

  // next byte to feed the digest: 16 snapshot bytes, then the 8 serial bytes
  wire [7:0] feed_byte = (feed < 5'd16) ? rec_snap[feed[3:0]]
                                        : serial_byte(feed[2:0] - 3'd0);

  assign freeze = issuing;

  // snapshot capture + digest feed
  integer k;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      issuing <= 1'b0; feed <= 5'd0; in_valid <= 1'b0; in_byte <= 8'd0;
      digest_reg <= 64'd0; rcnt <= 5'd0; rdy <= 1'b0; dout <= 8'd0;
      for (k = 0; k < 16; k = k + 1) rec_snap[k] <= 8'h00;
    end else begin
      in_valid  <= 1'b0;
      start_reg <= 1'b0;

      // start a new token (register the start so the digest sees a clean pulse)
      if (go_p && id_sealed && !issuing && !err) begin
        for (k = 0; k < 16; k = k + 1) rec_snap[k] <= rec_byte(5'(k[3:0]));
        issuing   <= 1'b1;
        start_reg <= 1'b1;
        feed      <= 5'd0;
        rdy       <= 1'b0;
        rcnt      <= 5'd0;
      end

      // feed the 16 snapshot bytes then the 8 sealed serial bytes to the digest
      if (issuing && (feed < 5'd24)) begin
        in_valid <= 1'b1; in_byte <= feed_byte; feed <= feed + 5'd1;
      end

      // digest finished -> latch token
      if (dig_done) begin
        digest_reg <= dig_hash; issuing <= 1'b0; rdy <= 1'b1;
      end

      // host read port
      if (rd_p) begin
        dout <= token_byte(rcnt);
        if (rcnt < 5'd24) rcnt <= rcnt + 5'd1;
      end
    end
  end

  np_digest u_dig (
    .clk(clk), .rst_n(rst_n),
    .start(start_reg),
    .in_valid(in_valid), .in_byte(in_byte),
    .done(dig_done), .hash(dig_hash)
  );

  // ------------------------------------------------------------------
  // status
  // ------------------------------------------------------------------
  wire tamper_any  = tampered | removal;
  wire bal_ok      = (balance != 24'd0);
  wire valid       = id_sealed && reg_ok && tax_ok && ins_ok && !tamper_any && !err;
  wire immobilize  = id_sealed && (!reg_ok || !tax_ok || !ins_ok || tamper_any ||
                                    (balance == 24'd0));

  assign status = {valid, rdy, immobilize, bal_ok, tamper_any,
                   err, id_sealed, issuing};

endmodule
