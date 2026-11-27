# DDC/CI

## One transport: Apple Silicon only

| | Apple Silicon |
| --- | --- |
| Route | `IOAVServiceRead/WriteI2C` |
| In the SDK? | **No** — see [private-apis.md](private-apis.md) |
| Status here | Implemented, verified on a ViewSonic VX2780-2K (see `Tests/HardwareMatrix/results.md`) |

### Why there is no Intel transport

HiDisplay supports Apple Silicon only. The Intel route was never implemented, and the stub that used to
report `.unsupported` has been removed along with the rest of the Intel code.

It was not a matter of effort. `IOI2CSendRequest` takes an `IOI2CRequest` struct that is not projected
into Swift, because it contains a function-pointer completion field. Using it needs either a C shim
target or a hand-declared struct layout — and hand-declaring a kernel ABI struct from memory is exactly
the kind of guess that becomes memory corruption when a field order or padding assumption is wrong.

If Intel support is ever wanted back, it needs:

1. A C shim target exposing `IOI2CRequest` and `IOI2CSendRequest` with the **header's own** layout, so
   the ABI comes from the SDK rather than from memory.
2. `IOFramebufferPortFromCGDisplayID`, or a vendor/product match over `IOFramebuffer` services.
3. `IOI2CInterfaceCount` / `IOI2CCopyInterfaceForBus` / `IOI2CInterfaceOpen`, one bus at a time, with the
   connection closed on every exit path.
4. An Intel test machine. Adding it without one would be the same guess in a new place.

## Binding to the right monitor

The delicate part is not the I2C call. It is deciding *which* `DCPAVServiceProxy` is the display the
caller means — and the answer is not on that node.

**The metadata and the DDC channel live on different nodes.** On macOS 26.5.2, `DisplayAttributes` (with
vendor, product, serial) is on `AppleCLCD2`, while `IOAVServiceCreateWithService` only accepts a
`DCPAVServiceProxy`, which has no `DisplayAttributes` at all. Handing it the metadata node returns null —
which is exactly what happened the first time this ran on hardware, and it presented as "no DDC transport
could bind", i.e. as though the monitor were at fault.

No property joins the two nodes. Their ancestors are named consistently, and that is the join:

```
dispext0@8000000               → AppleCLCD2         (has DisplayAttributes)
dispext0:dcpav-service-epic:0  → DCPAVServiceProxy  (is the IOAVService source)
```

So `AppleSiliconAVServiceTransport`:

1. Finds which display *units* match the identity, by reading `DisplayAttributes` off `AppleCLCD2` nodes
   and taking each one's unit token (`IORegistryAccess.displayUnitToken`).
2. **Refuses to bind at all** if more than one unit matches — two identical monitors with no serial.
3. Binds the `DCPAVServiceProxy` carrying the same token.

A display with no brightness control is a visible, explainable limitation. A slider that dims the wrong
monitor is not.

The registry-node order is also not guaranteed to match `CGGetOnlineDisplayList`, so nothing here matches
by index.

### MCDP29xx bridge chips

Some docks, hubs, and Apple's own USB-C↔DisplayPort cables put a Parade MCDP29xx bridge chip between the
Mac and the monitor. Every I2C call at the normal DDC/CI chip address `0x37` NAKs immediately on these —
a signature identical to "no I2C channel at all" (`0xe0114000`, below) unless you know to ask elsewhere.

The bridge announces itself in the registry, not on the `DCPAVServiceProxy` node itself but on its
**parent**: `EPICProviderClass == "AppleDCPMCDP29XX"`. `AppleSiliconAVServiceTransport` checks this once
at bind time (`IORegistryAccess.parentStringProperty`) and, when it matches, uses chip address `0xB7`
(`DDC.mcdp29xxChipAddress`) for every read and write on that display instead of `0x37`. The reply delay
needs no change — `DDC.replyDelay` is already 50 ms, at least as long as displays behind the bridge need.

Technique and constants are from [m1ddc](https://github.com/waydabber/m1ddc)
(`sources/ioregistry.m` `isMCDP29XXProxy()`, `headers/ioregistry.h` `DDC_CHIP_ADDRESS_MCDP29XX`,
`headers/i2c.h` `DDC_MCDP_READ_WAIT`). `hidisplay-probe`'s Brightness section prints the chip address
used for each display, and `--ddc-sweep` includes `0xB7` in the addresses it tries.

## Wire format

Constants: chip address `0x37` (`0x6E >> 1`), sub-address `0x51`, host source address `0x51`, display
address `0x6E`.

Set brightness:

```
51 84 03 10 <hi> <lo> <checksum>
│  │  │  └─ VCP 0x10 = brightness
│  │  └──── 0x03 Set VCP Feature
│  └─────── 0x80 | payload length 4
└────────── host source address — checksummed, NOT transmitted (see below)
checksum = XOR of all preceding bytes, seeded with 0x6E
```

Get brightness request:

```
51 82 01 10 <checksum>
```

Reply, 11 bytes:

```
6E 88 02 <result> 10 <type> <max hi> <max lo> <cur hi> <cur lo> <checksum>
 0  1  2     3     4    5       6        7        8        9        10
checksum seeded with 0x50
```

### Whether the host address goes on the wire depends on the link

The single most expensive detail in this file, and it has no fixed answer.

`IOAVServiceWriteI2C(service, 0x37, 0x51, data, len)` takes the sub-address as its third argument. The
frames above *begin* with that same 0x51. Whether the driver emits it for you — making a copy in
`data` a duplicate the display cannot parse — depends on the transport underneath. DisplayPort 1.1
carries DDC as I2C-over-AUX emulation; 1.2 and later use native AUX; the two paths disagree.

Measured on one ViewSonic VX2780-2K, toggling only that monitor's own "DisplayPort 1.1" OSD setting
and changing nothing else:

| DP 1.1 | frame that gets a reply | wire bytes |
| --- | --- | --- |
| on | `withoutHostAddress` | `82 01 10 AC` |
| off | `withHostAddress` | `51 82 01 10 AC` |

The checksum is the same either way, and is always computed over the full frame including the 0x51:
the display reconstructs that byte from the sub-address before verifying.

`DDCCommandQueue` therefore does not assume. It sends the shape it is holding, and on a null message
sends the other one and adopts whichever answers. It re-learns on *every* null message rather than
latching once, because the setting that changes this lives in the monitor's menu and toggling it does
not force a reconnect — a shape confirmed at probe time can stop working under a live connection.

### The null message is the only symptom

A display that cannot parse a request replies `6E 80 BE`: a well-formed frame, correct checksum, zero
payload. Reading 11 or 12 bytes just repeats it. Nothing errors and nothing times out.

That same reply is what a display sends when DDC/CI is switched off in its OSD, so a framing problem
and a disabled monitor are indistinguishable from the outside. On the VX2780-2K this cost a full
session: OSD toggled, competing apps quit, timing swept 50–200 ms, read lengths 11 and 12, chip
0x37/0x6E, offsets 0x51/0x00 — every combination null, until the frame shape was changed.

Because it is the one signal a wrong shape gives, `VCPCodec.DecodeError.nullMessage` is its own case,
checked before the checksum. Reported as `badChecksum` — which it also technically is, since the read
buffer runs past the three bytes actually sent — the recovery above never happens.

Reach for `hidisplay-probe --ddc-sweep` before believing a monitor is at fault. It tries both frame
shapes across several chip addresses and offsets and prints raw bytes, decoding nothing. Run it with
nothing else touching the bus: I2C is not shareable, and a concurrent probe produces readings that
look like a hardware quirk and are not.

### Reply checksum seed is 0x50, not 0x51

0x51 is the host address a display *reads from*; 0x50 is the one it *writes to*, and a reply is seeded
with the latter. Seeding with 0x51 rejects every well-formed reply as corrupt. Verify against the real
capture above: those ten bytes XOR to 0xDB, and 0xDB ^ 0x8B = 0x50.

This bug sat latent behind the framing one — no reply ever arrived to be mis-verified.

MCCS asks for ~40 ms between request and reply; the code uses 50 ms as a floor and some panels need more.

### Ranges are not 0–100

The maximum comes from the monitor's own reply. 0–255 is common and 0–64 exists. Assuming 0–100 would make
every value on a 0–255 panel wrong by 2.5×.

### Checksums are often wrong

A non-trivial number of monitors compute the reply checksum incorrectly while reporting correct values.
`decodeReply` rejects a bad checksum by default so line noise cannot be read as a brightness value — but
`DDCBrightnessController.probe` retries once with `tolerateChecksumMismatch: true` and, if that succeeds,
persists the quirk in the profile for that display. On reconnect or wake, the session is seeded with the
saved tolerance, so the first read does not fail on a monitor already known to miscompute checksums.
The tolerance follows the latest observation: a valid reply clears it again, because latching true
forever would let one transient bus glitch permanently disable checksum verification. The returned `Reply`
still records `checksumValid: false` so diagnostics show why a value is suspect.

## Throttling

- `setBrightness` records the value and returns; it never awaits the wire.
- The drain loop writes at most one frame per 60 ms (~16/s). The DDC/CI floor is 50 ms; see "Dell
  S2725QS" below for why the code does not sit exactly on it.
- Intermediate values are overwritten, not queued — that is the coalescing.
- The loop re-checks after each write, so the final value always lands.
- Writes are never retried: a brightness write is idempotent and superseded a moment later by the next
  slider position, so retrying only adds bus traffic during a drag.
- Reads are retried at most twice, with linear backoff, and only for `.timeout` / `.ioError`.

`DDCCommandQueueTests` asserts all of this against `FakeDDCTransport`, including that 50 rapid values
produce far fewer than 50 writes and that the last one is the value released on.

## Support trace: what a customer's machine can tell us

**Settings → Display Diagnostics → Export Diagnostics…** writes a JSON file to Downloads. Besides the
probe results it now carries, per external display, a `ddcTraces` entry and the display stack's own
log lines from this launch (`recentLog`, read back from the unified log by `RecentLog`).

The trace (`DDCTracer`, on the display's own queue via `DDCCommandQueue.withExclusiveBus`) reads
brightness in each frame shape, and if one answers, writes the value one raw step away, reads it back,
then restores the original and reads again. Every frame is recorded as hex with its outcome. Nothing is
written unless a read succeeded first.

| `verdict` | Meaning | Where to look next |
| --- | --- | --- |
| `noTransport` | No `IOAVService` could be bound; `bindFailure` says why | Identity matching, or a dock that hides the display |
| `noReply` | Bound, every frame failed. Outcomes say `request failed` or `reply failed` | The Mac's port, cable or dock — see `link` and `machineModel` |
| `nullReply` | The monitor answered `6E 80 BE` in both shapes | DDC/CI switched off in the monitor's menu |
| `writeIgnored` | Read works, the write returned success, the old value came back | Monitor has brightness locked (HDR), or drops the frame |
| `writeAccepted` | Reads and writes both work | The fault is in the app above the wire, not in DDC |
| `readbackFailed` | First read worked, the read-back did not | Flaky bus; compare step timings |

`link` copies the registry's `Transport` dictionary (`Upstream`/`Downstream`), `Location` and
`EPICProviderClass` for the display, and `environment.machineModel` is the Mac's model identifier.
Together they answer the commonest question — is this the built-in HDMI port of a Mac that cannot
carry DDC over it.

## Dell S2725QS (27 Plus 4K): what is known

No hardware on the bench. Compiled from Dell's user guide and other projects' notes on the family,
so that a customer report can be read against it. None of it is verified here.

- **Brightness is plain VCP `0x10`**, range 0–100; no vendor-specific code is involved. The S2725QC
  (same family, USB-C) lists `10 12 14 … 60 62 …` in its capabilities string and is driven at chip
  `0x37`, sub-address `0x51`, with frames that do *not* repeat the host address
  ([Sankew/Dell-Control](https://github.com/Sankew/Dell-Control)). That is `withoutHostAddress`, which
  the queue learns on its own.
- **The monitor has two HDMI 2.1 ports and one DisplayPort 1.4, and no USB-C.** It ships with an HDMI
  cable only. A Mac user therefore most likely plugs it into the Mac's built-in HDMI port, and DDC
  over that port is unsupported by MonitorControl on every M1 Mac and on the entry M2 Mac mini
  ([MonitorControl README](https://github.com/MonitorControl/MonitorControl#supported-displays)).
  This is the first thing to rule out; a USB-C→DisplayPort cable is the workaround.
- **DDC/CI can be switched off**: OSD → Others → DDC/CI.
- **HDR locks brightness.** The user guide: brightness and contrast are unavailable while Smart HDR
  is on and HDR content is displayed. Writes are then accepted on the wire and ignored — the
  `writeIgnored` verdict.
- **Writes too close together are dropped without an error.** Dell-Control measured the S2725QC
  ignoring a command that arrives less than about 50 ms after a write, and waits 60 ms; hence
  `DDC.writeInterval`.
- m1ddc and MonitorControl send every write twice, because a single write is occasionally dropped by
  some monitors. This app sends once. Not changed without evidence: if a trace ever shows
  `writeAccepted` on a display whose slider still misses, repeating the final write is the fix to try.

## Probing must not change what is on screen

`probe` performs one read and never writes a value. Probing by writing-then-reading is how other tools do
it, but it makes plugging in a monitor visibly flicker, and on a monitor that accepts writes while
reporting nonsense it can leave the panel stuck at the probe value.

Probe results are cached per connection session and can be overridden per display in Settings.

## Probes race display wake, so transient failures are retried

Observed on macOS with a VX2780-2K: the settled probe after a monitor display-sleep/wake fires while
the display is still re-registering. Two failure shapes, both within seconds of "Display is turned on"
in `pmset -g log`:

- the bind finds no display unit, because the registry node carrying `DisplayAttributes` has not been
  repopulated yet (`no display unit matched vendor …` in `ddc.transport`);
- the bind succeeds but the monitor's I2C bus is not answering yet, so the probe read times out.

Both used to downgrade the display to software dimming *permanently* — nothing re-probes DDC until
the next reconfiguration. Probe results now carry `isTransient`: true for bind failures and
timeout/I/O errors, false for answers that prove the display itself declined (a null message is a
monitor saying no, not a monitor still waking). `BrightnessCoordinator` re-probes transient failures
at 2 s / 5 s / 10 s, epoch-guarded so a disconnect or newer probe cancels the chain, and undoes the
interim software dimming when DDC comes back. A display that genuinely never binds (DisplayLink,
AirPlay, virtual) costs three bounded extra probes per settle and then stays on software dimming.

## When there is no I2C channel at all

Observed on macOS 26.5.2 through a Realtek USB-C display path: every combination of chip address
(`0x37`, `0x6E`) and offset (`0x51`, `0x00`) fails identically and immediately, on both read and write,
with `0xe0114000`.

That is an IOKit error in DCP's own subsystem `0x114` — not one of the general `kIOReturn*` values, so a
decoder that only knew the standard constants would print "unknown". `IOReturnDescription` recognises it
and says what it means: the connection carries video but no I2C, which is normal for many docks,
adapters, KVMs and virtual displays.

Identical immediate failure across all four combinations, in both directions, is the distinguishing
signature. A wrong chip address and a wrong offset would fail *differently*; a sleeping monitor would
time out rather than reject. So this pattern means the path, not the app.

This section used to add "a framing error would produce a reply that fails to decode". That was wrong,
and believing it wasted a debugging session on the VX2780-2K. A framing error produces a **null
message** — a perfectly well-formed frame with a valid checksum that decodes cleanly and simply
carries no data. It is not distinguishable from a monitor with DDC/CI switched off. `6E 80 BE` means
*the display did not understand the request*, and the request is a thing this app controls.

## Known hardware behaviour to expect

- Some cables, hubs and HDMI adapters block DDC entirely.
- A sleeping monitor does not answer; this is `.timeout`, not `.unsupported`, because it recovers.
- Some monitors answer only after a delay longer than the MCCS minimum.
- Read may work while write does not, or write may work while read returns a stale value.
- A KVM can make the same physical monitor appear with different EDID.
- DisplayLink and AirPlay displays have no DDC bus at all — they fall through to shade dimming.

## Scope

| VCP | Feature | Written when |
| --- | --- | --- |
| `0x10` | Brightness | Slider, brightness keys, restore of the saved value after a probe or wake. |
| `0x12` | Contrast | Only when the user moves its slider on the display's settings page. |
| `0x62` | Volume | Its slider, or the volume keys while sound plays through that monitor. |
| `0x60` | Input source | Only after the user confirms a dialog. |

Brightness is the only value the app writes on its own. The other three are read on demand (when
the display's card or page is shown, or on the first volume key press) and never restored or synced,
so a bug cannot mute a monitor or change its picture unasked. Input switching is confirmed because
a monitor sent to an input with nothing connected shows "no signal" and no longer answers DDC from
this Mac; only its own buttons bring it back.

All four share the display's one `DDCCommandQueue`, so the bus token, write spacing and learned frame
shape apply to every feature. Writes coalesce per feature. The input source reply's maximum field is
not a range and may be zero; `VCPCodec.decodeReply` accepts that for this code only.

Mute (`0x8D`) and power (`0xD6`) are still absent. The mute key sets the volume to zero and restores
the previous level on the next press.

The volume keys act only while the default audio output is a DisplayPort or HDMI device with no
system volume control (`AudioOutputProbe`). The audio device is matched to a display by name; with a
single DDC display connected, that display is used whatever the name.
