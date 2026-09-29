"""cocotb testbench for the Digital Number Plate core (np_core)."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer, FallingEdge
from cocotb.utils import get_sim_time

# ---------------------------------------------------------------- header map
CTL_REG, CTL_TAX, CTL_INS, CTL_CLASS = 0x01, 0x02, 0x04, 0x08
PLATE_OFFSET = 9
ZONE_OFF, MILEAGE_OFF = 14, 15
BAL_OFF, FEE_OFF = 16, 19

# ------------------------------------------------------------------ status map
ST_BUSY, ST_SEALED, ST_ERR = 0, 1, 2
ST_TAMPER, ST_BALOK, ST_IMMOB, ST_RDY, ST_VALID = 3, 4, 5, 6, 7

CLK_NS = 10


class Plate:
    def __init__(self, dut):
        self.dut = dut

    async def reset(self):
        d = self.dut
        d.rst_n.value = 0
        d.wr.value = 0
        d.go.value = 0
        d.rd.value = 0
        d.din.value = 0
        d.pps.value = 0
        d.zenter.value = 0
        d.zexit.value = 0
        d.brake_p.value = 0
        d.wheel_p.value = 0
        d.impact_p.value = 0
        d.weigh_p.value = 0
        d.seal_open.value = 0
        d.g_pulse.value = 0
        await Timer(5 * CLK_NS, units="ns")
        await RisingEdge(d.clk)
        d.rst_n.value = 1
        await Timer(5 * CLK_NS, units="ns")

    def status(self):
        return int(self.dut.status.value)

    async def write_byte(self, data):
        """One host header write (active-high one-cycle wr)."""
        d = self.dut
        d.din.value = data
        d.wr.value = 1
        await RisingEdge(d.clk)
        d.wr.value = 0
        d.din.value = 0
        await RisingEdge(d.clk)

    async def header(self, ctl, serial, plate, zone, mileage, bal, fee):
        """Write the full 32-byte header and seal it."""
        serial = bytes(serial)[:8].ljust(8, b"\x00")   # serial is exactly 8 bytes
        for i in range(32):
            if i == 0:
                b = ctl
            elif 1 <= i <= 8:
                b = serial[i - 1]
            elif PLATE_OFFSET <= i < PLATE_OFFSET + len(plate):
                b = plate[i - PLATE_OFFSET]
            elif i == ZONE_OFF:
                b = zone
            elif i == MILEAGE_OFF:
                b = mileage
            elif BAL_OFF <= i < BAL_OFF + 3:
                b = (bal >> (8 * (BAL_OFF + 2 - i))) & 0xFF   # big-endian
            elif FEE_OFF <= i < FEE_OFF + 2:
                b = (fee >> (8 * (FEE_OFF + 1 - i))) & 0xFF   # big-endian
            else:
                b = 0
            await self.write_byte(b)
        await self.seal()

    async def seal(self):
        d = self.dut
        d.go.value = 1
        await RisingEdge(d.clk)
        d.go.value = 0
        await Timer(2 * CLK_NS, units="ns")

    async def issue_token(self):
        """Go to issue a token, then wait for RDY. Returns the 24 bytes."""
        d = self.dut
        # a go strobe while sealed triggers a fresh token
        d.go.value = 1
        await RisingEdge(d.clk)
        d.go.value = 0
        for _ in range(200):
            await RisingEdge(d.clk)
            if self.status() & (1 << ST_RDY):
                break
        else:
            raise AssertionError("token never became RDY")
        return await self.read_token()

    async def read_token(self):
        d = self.dut
        out = []
        for _ in range(24):
            d.rd.value = 1
            await RisingEdge(d.clk)
            d.rd.value = 0
            # dout updates on this edge; sample just after
            await Timer(1, units="ns")
            out.append(int(d.dout.value))
            await RisingEdge(d.clk)
        return out

    async def pulse(self, sig, n=1):
        d = self.dut
        for _ in range(n):
            getattr(d, sig).value = 1
            await RisingEdge(d.clk)
            getattr(d, sig).value = 0
            await RisingEdge(d.clk)

    async def zone_trip(self, axles=0):
        await self.pulse("zenter")
        for _ in range(axles):
            await self.pulse("weigh_p")
        await self.pulse("zexit")


async def setup(dut, **kw):
    p = Plate(dut)
    cocotb.start_soon(Clock(dut.clk, CLK_NS, units="ns").start())
    await p.reset()
    return p


# ===================================================================== tests
@cocotb.test()
async def t_reset_defaults(dut):
    p = await setup(dut)
    assert p.status() == 0, "status should be clear after reset"
    assert int(dut.dout.value) == 0


@cocotb.test()
async def t_seal_requires_full_header(dut):
    p = await setup(dut)
    for _ in range(31):
        await p.write_byte(0)
    await p.seal()  # only 31 bytes written -> must error, not seal
    assert p.status() & (1 << ST_ERR), "ERR should latch on short header"
    assert not (p.status() & (1 << ST_SEALED)), "must not seal on short header"


@cocotb.test()
async def t_seal_and_token_identity(dut):
    p = await setup(dut)
    ctl = CTL_REG | CTL_TAX | CTL_INS | CTL_CLASS
    serial = bytes([0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0xF6, 0x07, 0x18])
    plate = b"UAB12"
    await p.header(ctl, serial, plate, 0, 0, 100_000, 250)
    assert p.status() & (1 << ST_SEALED), "should seal after full header"
    tok = await p.issue_token()
    assert tok[0:5] == list(plate), f"plate in token = {tok[0:5]}"
    # ctl/status byte: reg/tax/ins/class all set
    assert tok[5] & 0x0F == 0x0F, f"status ctl nibble = {tok[5] & 0x0F:x}"
    # balance 100000 big-endian over bytes 8,9,10
    bal = (tok[8] << 16) | (tok[9] << 8) | tok[10]
    assert bal == 100_000, f"balance = {bal}"
    # gate fee 250 big-endian over bytes 11,12
    fee = (tok[11] << 8) | tok[12]
    assert fee == 250, f"fee = {fee}"
    # bytes 16..23 are the 64-bit digest (serial is bound into it, not sent)
    assert any(tok[16:24]), "digest must be non-zero"


@cocotb.test()
async def t_invalid_zone_class_errors(dut):
    p = await setup(dut)
    ctl = CTL_REG | CTL_TAX
    serial = b"\x01\x02\x03\x04\x05\x06\x07\x08"
    await p.header(ctl, serial, b"KLM99", zone=0x0F, mileage=0, bal=0, fee=0)
    assert p.status() & (1 << ST_ERR), "zone_class>3 must set ERR"
    assert not (p.status() & (1 << ST_SEALED)), "must not seal invalid class"


@cocotb.test()
async def t_toll_decrements_on_passage(dut):
    p = await setup(dut)
    ctl = CTL_REG | CTL_TAX | CTL_INS
    serial = b"S" * 8
    bal, fee = 50_000, 500
    await p.header(ctl, serial, b"TOLL1", 0, 0, bal, fee)
    await p.issue_token()
    await p.zone_trip()          # first passage
    await p.zone_trip()          # second passage
    tok = await p.issue_token()
    expect = bal - 2 * fee
    got = (tok[8] << 16) | (tok[9] << 8) | tok[10]
    assert got == expect, f"balance {got} != expected {expect}"
    # passages counter = 2 (big-endian over bytes 13,14)
    assert ((tok[13] << 8) | tok[14]) == 2, f"passages = {tok[13:15]}"


@cocotb.test()
async def t_toll_unpaid_latches(dut):
    p = await setup(dut)
    ctl = CTL_REG | CTL_TAX | CTL_INS
    serial = b"S" * 8
    bal, fee = 300, 500  # fee exceeds balance
    await p.header(ctl, serial, b"POOR1", 0, 0, bal, fee)
    await p.zone_trip()
    tok = await p.issue_token()
    assert tok[5] & 0x40, "unpaid bit should be set in token status byte"
    # balance unchanged (not allowed to go negative)
    got = (tok[8] << 16) | (tok[9] << 8) | tok[10]
    assert got == bal, f"balance {got} != {bal} (must not go negative)"


@cocotb.test()
async def t_tamper_latches_permanently(dut):
    p = await setup(dut)
    ctl = CTL_REG | CTL_TAX | CTL_INS
    await p.header(ctl, b"S" * 8, b"TAMP1", 0, 0, 10_000, 100)
    dut.seal_open.value = 1     # break the enclosure
    await Timer(2 * CLK_NS, units="ns")
    assert p.status() & (1 << ST_TAMPER), "TAMPER should latch on seal_open"
    dut.seal_open.value = 0
    await Timer(2 * CLK_NS, units="ns")
    assert p.status() & (1 << ST_TAMPER), "TAMPER must not clear"
    assert p.status() & (1 << ST_IMMOB), "tamper should request immobilize"
    # status byte tamper bit (7) set in next token
    tok = await p.issue_token()
    assert tok[5] & 0x80, "tamper bit should be set in token"


@cocotb.test()
async def t_edr_counters(dut):
    p = await setup(dut)
    ctl = CTL_REG | CTL_TAX | CTL_INS
    await p.header(ctl, b"S" * 8, b"EDR01", 0, 0, 10_000, 100)
    await p.pulse("brake_p", 3)
    await p.pulse("impact_p", 2)
    await p.pulse("brake_p", 1)
    # sanity: counters are internal, exercised via a fresh token (no crash)
    await p.issue_token()


@cocotb.test()
async def t_axle_overweight_latches(dut):
    p = await setup(dut)
    ctl = CTL_REG | CTL_TAX | CTL_INS
    await p.header(ctl, b"S" * 8, b"HEAVY", 2, 0, 10_000, 100)
    await p.zone_trip(axles=8)   # 8 axles > limit of 6
    tok = await p.issue_token()
    assert tok[5] & 0x10, "overweight bit should be set (8 axles > 6)"


@cocotb.test()
async def t_digest_changes_with_balance(dut):
    p = await setup(dut)
    ctl = CTL_REG | CTL_TAX | CTL_INS
    await p.header(ctl, b"S" * 8, b"HASH1", 0, 0, 10_000, 100)
    tok_a = await p.issue_token()
    await p.zone_trip()
    tok_b = await p.issue_token()
    # same plate, but balance/passages changed -> record changed -> digest changed
    assert tok_a[0:5] == tok_b[0:5], "plate must be identical"
    assert tok_a[16:24] != tok_b[16:24], "digest must change when record changes"


@cocotb.test()
async def t_digest_deterministic(dut):
    """Same inputs must yield the same digest (no randomness)."""
    p1 = await setup(dut)
    await p1.header(CTL_REG | CTL_TAX, b"DET01", b"SAME1", 0, 0, 4242, 7)
    t1 = await p1.issue_token()
    # reset and repeat
    d = dut
    d.rst_n.value = 0
    await Timer(5 * CLK_NS, units="ns")
    await RisingEdge(d.clk)
    d.rst_n.value = 1
    await Timer(5 * CLK_NS, units="ns")
    await p1.header(CTL_REG | CTL_TAX, b"DET01", b"SAME1", 0, 0, 4242, 7)
    t2 = await p1.issue_token()
    assert t1 == t2, f"digest not deterministic: {t1[16:24]} vs {t2[16:24]}"


@cocotb.test()
async def t_immobilize_on_expired(dut):
    p = await setup(dut)
    # tax not paid -> not valid -> immobilize
    await p.header(CTL_REG, b"S" * 8, b"NOTAX", 0, 0, 10_000, 100)
    await p.issue_token()
    assert p.status() & (1 << ST_IMMOB), "expired tax should immobilize"
    assert not (p.status() & (1 << ST_VALID)), "must not be VALID without tax"
