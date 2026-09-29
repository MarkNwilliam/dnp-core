# Digital Number Plate ASIC — research & design notes

## 1. Scope and threat model

This project implements the **trusted evidence core** of a Ugandan digital
number plate (DNP). It is deliberately *not* the whole plate: GPS, RFID/UHF
reader, cellular modem, display and power are external modules that talk to
this core over a byte-wide host port.

The core owns four things that must be trustworthy:

1. **Identity** — a write-once, sealed identity (serial + plate string + class).
2. **Road-user charging** — a decrement-only prepaid toll balance and passage
   evidence, with an anti-rollback balance that never goes negative.
3. **Evidence integrity** — a per-token 64-bit digest that binds the live
   record to the sealed identity, plus a rolling event chain.
4. **Enforcement** — tamper/immobilize, axle-overload and tax/insurance gates.

### Security caveats (read this before trusting it)

- The 64-bit digest (`np_digest`) is a **tamper-EVIDENT mixing function, not a
  cryptographic hash or MAC.** It uses only 64-bit adds, rotates and an
  xorshift (deliberately multiplier-free to keep area tiny). It reliably
  detects an *accidental or naive* edit of a token, but it provides **no
  authentication against a determined forger** and is not collision-resistant
  in any cryptographic sense. A production plate must add a real
  signature/MAC (e.g. an ECDSA P-256 verify block or a secure-element coprocessor).
- Tamper and removal are detected via sensor inputs, but the *sensor*
  (microswitch / shock sensor) is external and is the real attack surface.
- The whole design assumes a trusted host writes the 32-byte header exactly
  once. There is no key in this version, so anyone who can drive the host port
  before seal can provision an arbitrary identity. A production part gates
  provisioning behind a manufacturer key.
- Road-toll top-up / reload is **not** implemented on-chip (see §5).

## 2. Host byte-port protocol

Active-high, one-cycle strobes, edge-detected internally. Data is on
`din`/`dout` (8-bit). This matches the FuelGuard host model for reuse.

| Pin | Dir | Meaning |
|-----|-----|---------|
| `wr`  | in  | write `din` to the next header byte (setup only) |
| `go`  | in  | setup: seal the header · sealed: issue a fresh token |
| `rd`  | in  | read the next token byte (auto-increment) |
| `din` | in  | host data in |
| `dout`| out | host data out |

Sensors (all one-cycle pulses or levels):

| Pin | Meaning |
|-----|---------|
| `pps`       | 1 Hz time window (seconds counter / speed window) |
| `zenter`/`zexit` | toll-zone entry / exit (a passage = zenter…zexit) |
| `brake_p`   | harsh-braking pulse |
| `wheel_p`   | wheel-rotation pulse (4 per km) |
| `impact_p`  | accelerometer impact pulse |
| `weigh_p`   | weighbridge: one axle crossing |
| `seal_open` | enclosure/seal broken (level) |
| `g_pulse`   | plate-removal shock pulse |

`status[7:0]` (read back over the host port in a future rev; exposed as a
vector here):

| Bit | Name |
|-----|------|
| 0 | `BUSY` (token being issued) |
| 1 | `SEALED` (identity locked) |
| 2 | `ERR` (latched protocol/validation error) |
| 3 | `TAMPER` (tamper **or** removal latched) |
| 4 | `BALOK` (balance non-zero) |
| 5 | `IMMOB` (immobilize request) |
| 6 | `RDY` (token ready to read) |
| 7 | `VALID` (registered + taxed + insured + untampered + no error) |

## 3. Sealed header (32 bytes, big-endian multi-byte fields)

Written byte-by-byte with `wr`, then `go` seals it (only when all 32 bytes are
present and the header validates).

| Byte(s) | Field |
|---------|-------|
| 0 | ctl: bit0 `reg_ok`, bit1 `tax_ok`, bit2 `ins_ok`, bit3 `class_ok` |
| 1–8 | serial (8 bytes, big-endian) |
| 9–13 | plate string, 5 chars (e.g. `"UAB12"`) |
| 14 | zone class: 0 private, 1 commercial, 2 heavy, 3 emergency |
| 15 | odometer seed, x10 km |
| 16–18 | prepaid balance, 1/100 currency (24-bit) |
| 19–20 | flat toll per passage, 1/100 (16-bit) |
| 21–31 | reserved (host writes 0) |

**Seal validation:** `reg_ok` must be 1 and `zone_class <= 3`, else `ERR`
latches and the part does **not** seal. A `go` with < 32 bytes also latches
`ERR` without sealing. After seal the header is read-only.

## 4. Token format (24 bytes, read after `go` while sealed)

| Byte(s) | Field |
|---------|-------|
| 0–4 | plate string (echoed, bound by digest) |
| 5 | status: bit7 tamper/removal, bit6 unpaid, bit5 speeding, bit4 overweight, bit3 reg_ok, bit2 tax_ok, bit1 ins_ok, bit0 class_ok |
| 6 | zone class |
| 7 | mileage (x10 km) |
| 8–10 | balance after this token, 1/100, big-endian |
| 11–12 | flat toll fee, big-endian |
| 13–14 | passage counter, big-endian |
| 15 | event-log head (7 bits) ‖ rolling chain bit (1 bit) |
| 16–23 | 64-bit digest (little-endian byte order as emitted) |

The digest is computed over **24 bytes = the 16-byte record above + the 8-byte
sealed serial**. So the token is *bound* to the sealed identity even though the
serial itself is not transmitted: a roadside reader that knows the plate's
registered serial can recompute the digest over `record ‖ serial` and verify it
matches bytes 16–23. Swapping in a different record (e.g. a different balance
or a forged plate) changes the digest.

## 5. Road-user charging model

- The **balance is loaded once, at seal**, from header bytes 16–18, then is
  strictly **decrement-only**.
- Each **passage** = a `zenter`…`zexit` pair. On `zexit` the flat fee (header
  19–20) is subtracted, the passage counter increments, and a rolling event is
  logged. If the fee exceeds the balance the balance holds (never negative) and
  `unpaid` latches → `BALOK` drops, `IMMOB` asserts.
- **Top-up / reload is not on-chip in v1** — by design, the holder can never
  re-credit the balance themselves. A production part adds an authority reload
  path gated by a manufacturer key (future revision).

## 6. EDR / load / evidence

- Harsh events (`brake_p`, `impact_p`) increment saturating counters.
- `wheel_p` integrates an odometer (40 pulses = 1 km) and a per-second speed
  window (pulses/s, x10 km/h) that latches a `speeding` flag over 100 km/h.
- `weigh_p` counts axles within a `zenter`…`zexit` passage; > 6 axles latches
  `overweight` and records the peak axle count.
- A 4-entry ring of recent events (type + magnitude) plus a 1-bit rolling chain
  flag gives cheap swap/rollback evidence in the token (byte 15).

## 7. Modules

| Module | Role |
|--------|------|
| `np_core`   | top: host port, header validation, token issue/read FSM, record build, status |
| `np_id`     | 32-byte sealed header, identity, balance/fee provision |
| `np_toll`   | zone passages, decrement-only balance, unpaid latch |
| `np_edr`    | odometer, speed, harsh-event counters, axle-load/overweight |
| `np_audit`  | 4-entry event ring + rolling chain bit |
| `np_tamper` | sticky tamper / removal latches |
| `np_time`   | 1 Hz seconds counter + tick |
| `np_digest` | 24-byte → 64-bit tamper-evident mixing digest |

## 8. Verification

`sim/test_np.py` (cocotb, icarus) — 12 tests, all passing:

reset defaults · short-header seal rejected · seal + token identity/status ·
invalid zone class rejected · toll decrement on passage · unpaid latch ·
permanent tamper · EDR counters · axle-overweight · digest changes with record ·
digest deterministic · immobilize on expired tax.

Run with `sim/run.sh` (see §9 for why the wrapper exists).

## 9. Environment gotcha (cocotb version mismatch)

This machine has two cocotb installs:

- pyenv Python 3.11 → cocotb **2.0.1** (working `cocotb-config`),
- oss-cad-suite → cocotb 2.1.0 but its `cocotb-config` is **broken** on the
  bundled libpython (`Symbol not found: _mkfifoat`).

`iverilog`/`vvp` come from oss-cad-suite, but the VPI module and the embedded
interpreter must use the *same* cocotb. Mixing pyenv's VPI with oss-cad-suite's
embedded cocotb gives `Symbol not found: (_gpi_finish)`. `sim/run.sh` fixes this
by putting pyenv's cocotb on `PYTHONPATH` (so the oss-cad `vvp` loads pyenv's
cocotb, matching the VPI lib). Don't call bare `make` without that `PYTHONPATH`.

## 10. Synthesis result

Generic yosys `synth -flatten` gives **3137 cells / 689 flip-flops** (no
latches, `check -assert` = 0 problems). That number turned out to be a poor
predictor of physical area, so do not size tiles from it — run the real flow.

What actually happened (Tiny Tapeout, IHP sg13g2, `10-Digital-Number-Plate-TinyTapeout`):

| Attempt | Mapped cell area | Utilization | Result |
|---|---|---|---|
| 1x1 (never run) | — | — | estimate said it would fit; the estimate was wrong |
| 1x2, original | 69,851 µm² | 122.4 % | GPL-0301, no place |
| 1x2, serial snapshot + dead ring removed | 65,424 µm² | 114.7 % | GPL-0301, no place |
| 1x2, all unreachable state removed | 65,675 µm² | 115.2 % | GPL-0301, no place |
| **2x2, final** | **65,675 µm²** | **63.1 %** | **green** |

Final: 4,652 std cells (2,866 logic + 690 sequential), core 128,155 µm², die
419.52 × 313.74 µm, setup and hold WNS/TNS 0.0 at the 20 ns target across all
three corners, LVS clean, 0 route DRC, 0 antenna violations, 2.62 mW total.

### Why removing flops did not help

Step 3 removed ~318 generic cells (~9%) and step 4 removed ~190 more
flip-flops, yet area barely moved and then went *up* 0.5%. The reason is that
area here is not in flops. `np_digest` is a 64-bit byte-serial mixer that
instantiates two 64-bit adders and five 64-bit XOR trees, which map to 548
XOR/XNOR and 346 mux2 cells — roughly 43% of the whole design. That is
combinational datapath, so trimming registers cannot touch it.

Both ways to shrink it cost something real:

- Narrow the digest (64→32 bits) would roughly halve it, but weakens the
  evidence field and changes the 24-byte token format.
- Drop the `t + (t << 7)` avalanche step saves one 64-bit adder (~4%), but
  measurably weakens diffusion.

Since the digest is already documented as tamper-*evident* rather than
cryptographic, and its real value is detecting naive field edits while actual
authentication is meant to come from a signature or secure element, enlarging
the tile was the honest trade: keep the evidence field intact and pay in area.

### Known issue

**50 max-fanout violations** on wide control nets. Timing is clean at every
corner, so this does not affect function at 20 ns, but it is a real
signal-integrity smell. A production run would add a buffer tree on those
nets. Recorded rather than rounded away.

