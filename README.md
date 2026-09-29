# 10 — Digital Number Plate ASIC

A compact **trusted evidence core** for a digital number plate (DNP), targeting
the IHP sg13g2 open PDK (Tiny Tapeout 2x2). Written in
SystemVerilog, verified with cocotb.

The core is the security/enforcement heart of the plate. GPS, RFID/UHF, cellular,
display and power are **external** modules that talk to it over a byte-wide host
port. What the core guarantees:

- **Sealed identity** — a 32-byte write-once header (serial, plate string,
  class, tax/insurance flags) that is validated and locked at seal.
- **Road-user charging** — a decrement-only prepaid toll balance with passage
  evidence; the balance never goes negative and unpaid latches.
- **Evidence integrity** — a per-token 64-bit tamper-evident digest that binds
  the live record to the sealed identity, plus a rolling event chain.
- **Enforcement** — sticky tamper/removal, axle-overload, speeding, and
  tax/insurance gates driving an `IMMOB` output.

## Status

- RTL: 8 modules, lint-clean (verilator `-Wall`, iverilog).
- Simulation: **12/12 cocotb tests pass** (icarus), and again on the
  gate-level netlist after the Tiny Tapeout flow.
- Synthesis: generic yosys **3137 cells / 689 FFs**, no latches, `check` clean.
- Physical: shipped as `10-Digital-Number-Plate-TinyTapeout` (IHP sg13g2,
  **2x2** tiles). Real flow: 4,652 std cells, 63.1% utilization, setup and
  hold WNS/TNS 0.0 at 20 ns, LVS clean, 0 route DRC, 0 antenna. 50
  max-fanout violations remain on wide control nets.

> **Why 2x2 and not 1x1/1x2:** the generic-cell estimate badly understates
> this design. A 1x2 GDS run came in at 115% utilization, and trimming
> unreachable registers moved it by <1% — the area is in the 64-bit
> byte-serial digest (two 64-bit adders plus five 64-bit XOR trees ≈ 43% of
> the cells), which is combinational datapath rather than flops. Narrowing
> the digest or dropping its `+r` avalanche step would both weaken the
> evidence field, so the tile was enlarged instead.

> **Security note:** the 64-bit digest is *tamper-evident, not cryptographic*.
> It detects naive record edits but is **not** a MAC/signature and provides no
> real authentication. A production plate must add a proper signature block or
> a secure-element coprocessor. See `doc/research.md` §1 for the full threat
> model and caveats.

## Layout

```
rtl/           np_core, np_id, np_toll, np_edr, np_audit, np_tamper,
               np_time, np_digest   (SystemVerilog)
sim/           test_np.py (cocotb), Makefile, run.sh
synth/         synth.ys (yosys area/cell check)
doc/           research.md (spec, header/token maps, threat model, notes)
```

## Quick start

```bash
# run the cocotb suite (use run.sh — it fixes the cocotb version clash)
./sim/run.sh

# lint
verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-UNUSED -Wno-VARHIDDEN \
    --top-module np_core rtl/*.sv

# synthesize (area / cell count)
yosys synth/synth.ys
```

See `doc/research.md` for the host protocol, 32-byte header map, 24-byte token
format, toll model, and the cocotb environment gotcha.
