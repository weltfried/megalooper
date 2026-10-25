# Audio routing

Which audio device megalooper plays on, and where its channels sit, is a
**routing profile**. megalooper ships one, **`saSystem`**: Megalooper SA on
the system's default input and output, with nothing to set up (the manual's
[Configuration](manual.md#configuration)). Every other rig is a profile of
your own, in `profiles.scd` in your megalooper folder, offered in the launcher
beside `saSystem`: [Adding a rig](#adding-a-rig) says how to write one.

Running megalooper **beside Ableton Live** needs one: megalooper and Live
exchange audio over a loopback of some kind, and the profile says which. The
rest of this guide is the rigs megalooper was built on, the duo's own, kept
here as worked examples of each kind: a BlackHole aggregate beside Live, an
RME Fireface with TotalMix loopback, a Rogue Amoeba Loopback device, and the
TSMega interface on its own with a bass. Their profiles live in the duo's
`profiles.scd`, not in megalooper; the device names are theirs, and yours go
in a profile of your own.

A profile drives the audio device, the server's channel count, the looper's
channel offsets, the recording width and the latency default. megalooper's
own is in [`scripts/setup-routing.scd`](../scripts/setup-routing.scd), which
also says what every field means. Changing device or channel count requires
a server reboot.

## The three channel roles

Every profile carries the same three 0-indexed stereo pairs. They mean:

| Field | Direction | Carries |
| --- | --- | --- |
| `inChannel` | Live → SC | your instrument, **already processed in Live** |
| `outChannel` | SC → Live | the loop, back to Live |
| `returnChannel` | Live → SC | Live's **processed loop** return |

`returnChannel` **must** be a different pair from `inChannel`. Only the
loop-chaining recorder reads it; a normal overdub reads `inChannel` alone, so
the loop's own output can never be re-recorded into itself and feed back. The
next-loop capture is the one path that records `inChannel + returnChannel`.

Default is `0 / 0` — analog ins/outs 1+2 of whatever interface you have.

## Recording the set

There is a fifth role, and nothing plays it — it is only ever written to disk:

| Field | Direction | Carries |
| --- | --- | --- |
| `sessionChannel` | Live → SC | **Live's master**, for the session recorder |

The session recorder (note 70 / PC 17, or the Perform tab's **Record set**
button) writes what the room heard alongside the dry analysis tap. SC's own
output is not the same thing — that is the loop alone, without the guitar, the
drum racks or anything else Live adds — so it needs Live's master back on an
input pair.

It is set on **`\bhTsMega`** (`sessionChannel: 0` — BlackHole 1–2, which that
rig leaves unused) and nil on every other profile. That asymmetry is not
tidiness: a profile with the number set but no matching track in the Ableton set
records **silence** into the master file, and you would only find out after the
gig. Set it per rig once the Live side exists; until then the recorder writes
the dry tap alone and the Perform tab says so.

**Setup**, once per Ableton set:

1. Add an audio track. **Audio From: Resampling** (that is Live's master bus),
   **Monitor: In**, **Audio To: Ext. Out 1/2**.
2. That is BlackHole 1–2, which the `\bh*` rigs leave unused and SC already
   opens (`numInChans` reaches past them for the analysis tap), so it costs no
   channel-count change and no server reboot.
3. In your rig's profile (in your `profiles.scd`), set `sessionChannel: 0`.
   The duo's `\bhTsMega` has it.

**Check it before you rely on it.** With Live running and something playing,
the Perform tab should read *"master + dry tap"* rather than *"dry tap only"* —
that only proves the profile is set. That the pair actually carries audio is
proved by recording ten seconds and opening the file.

No feedback path is created: SC only ever writes `outChannel`, and the
Resampling track's output goes to Ext. Out rather than back into the master.

## The clean analysis tap

There is a fourth role, and it is different in kind — one **mono** channel, and
it carries no loop audio at all:

| Field | Direction | Carries |
| --- | --- | --- |
| `analysisChannel` | interface → SC | the **dry instrument**, for analysis only |

Meter detection sees nothing but onset times. Distortion and ambient FX smear
note attacks, and blurred onsets are the documented root cause of meter
mis-detection — straight 4/4 takes coming out 7/8, because no pulse grid fits and
`MeterAnalyzer` bails to the length-anchored fallback. So the analysis reads the
guitar **before** Live touches it, while `RecordBuf` goes on recording the
processed `inChannel`. What you hear and what gets looped do not change.

The dry signal is already on the device: SC and Live both have the *same* device
open, so SC can read the guitar's hardware input directly. **Live is not in this
path at all** — no pre-FX track, no extra loopback pair, nothing to set up in the
set. On the `\bh*` rigs the guitar is the interface's input 1, which the
aggregate puts at ch 17, so `analysisChannel = 16` and the input count rises to
17 while outputs stay at 16 (see `numInChans` below).

- **Off by channel, not by flag.** `analysisChannel = nil` means the analysis
  reads `inChannel`, exactly as it did before this existed. The **Analysis in**
  dropdown in the main window switches between the two live, so you can A/B a
  take against the same audio.
- **The failure mode to know.** A tap pointed at the wrong channel is *silent*,
  and silence looks like a musical problem: the loop records perfectly while
  every take reports 0 onsets and falls back to the anchored meter. When that
  happens the post window says so explicitly and names the channel.
- **Phase, not tempo.** The dry tap reaches SC immediately; the recorded audio
  arrives one Live round trip later (~15 ms). Onset times therefore sit that
  much *early* against the buffer. It is a constant offset, so tempo and meter
  are unaffected — it shifts only grid **phase**, which matters for BBCut slice
  alignment. Measure it once on the rig before trusting tight cuts.
- **Training exports are still the wet signal.** `exportTrainingLoop` writes the
  recorded buffer, so an exported WAV no longer matches what the detector heard.
  The JSON sidecar's `analyzerInput` does — and that is what
  `eval_meter_analyzer.scd` replays — but re-running onset detection over the WAV
  offline now measures the processed guitar, not the tap.

### `numInChans`

Optional, defaults to `numChans`. The analysis tap is the one thing SC needs from
the **hardware** block above the virtual device, and asking for those channels on
the output side too would hand SC a path to the speakers — the footgun the
`\bh*` rigs deliberately removed. So inputs grow and outputs stay put.

## Boot-time guards

Several checks run automatically, because every one of these failure modes is
silent otherwise:

- **Device present.** If the profile's device is missing, SuperCollider would
  quietly boot on the *default* device with the wrong channel count, breaking
  every SC↔Live route. Instead the boot aborts with a banner naming the profile,
  the device it wanted, and every device actually available. Name matching is
  lenient (either string contained in the other) because SC truncates long and
  non-ASCII device names — it lists "Das Zwölfer Microphone" as
  "Das Zwölfer Microphon".
- **Analysis channel sane.** If a profile declares `analysisChannel`, it must be
  a channel the device actually exposes and must not land on `outChannel` or
  `returnChannel`. Past the input block it would read a *private* bus, and the
  looper's own output bus is the first one allocated — so an out-of-range tap is
  a feedback path into onset detection, not merely silence.
- **Sample rate.** A profile may declare the rate its rig is wired for. This is
  the classic aggregate-device trap: every member has to run at one rate or
  CoreAudio silently resamples the odd one out, and this machine has devices
  sitting at both 44.1 and 48 kHz. A mismatch warns rather than aborts — the rig
  still makes sound, it just isn't the one that was set up.

### The device preflight

The guards above check that a device with the right *name* exists. That is not
enough, and the gap is exactly where the aggregates bite:

- `ServerOptions.devices` gives names alone.
- `s.options.numInputBusChannels` is what SC **asked for**, never what CoreAudio
  granted. Ask a degraded 16-channel aggregate for 17 inputs and SC boots
  perfectly happily — the analysis tap just reads a bus nothing ever fills, in
  silence, for the rest of the session.
- Nothing in SC can see what **Live** opened, and the two apps sharing one device
  is the entire premise of every `\bh*` rig.

So `~checkAudioDevice` asks the system instead, via
`system_profiler SPAudioDataType -json` (~0.2 s; sclang parses JSON itself, so
there is nothing to install). It runs before `s.boot`, because channel counts are
fixed the moment the server starts. Re-run either check at any time:

```supercollider
~checkAudioDevice.(~routingProfile);   // CoreAudio vs the profile
~checkLiveAudio.(~routingProfile);     // what Live opened, from its own log
```

| Finding | What it means | Result |
| --- | --- | --- |
| Fewer channels than `numChans` | A member has dropped out and the SC↔Live pairs cannot exist | **Aborts**, listing which expected members CoreAudio can still see |
| Fewer channels than `numInChans` | Only the instrument's input is gone | **Degrades**: the tap is switched off, `s.options` corrected, onset detection falls back to the recorded input — and says so |
| Device rate ≠ profile rate | The classic aggregate trap, caught *before* the boot instead of after | Warns |
| A `members` entry not present | The channel count still fits, so the remaining members have **shifted down** — every channel above the gap is now something else | Warns |
| A member at a different rate from the aggregate | CoreAudio is resampling it. This is the usual cause of an aggregate that works until it doesn't | Warns |

`members` is declared per profile in `~routingProfiles`. It builds nothing; it
exists so the preflight can say *"BlackHole 16ch is present, TSMEGA is gone"*
rather than only *"this device has two fewer channels than it should"*.

> **`MegaLoop BH (Built-in)` has a member that comes and goes.** *External
> Headphones* only exists in CoreAudio while something is plugged into the jack,
> and it sits **below** the speakers in the member list. Unplugging headphones
> therefore does not merely change where you monitor — it slides every output
> above it down by two, so Live's Master at 17/18 lands on the headphones with
> them in and on the speakers with them out. The preflight reports it for exactly
> that reason.

### The Live check

SC cannot ask Live anything, but Live writes its whole audio state to
`~/Library/Preferences/Ableton/<version>/Log.txt` every time that state changes,
so the newest block is current. `~checkLiveAudio` reads it and compares:

- **Input device ≠ output device** — the split-aggregate footgun below. Loud
  banner, because it looks like it works.
- **Live's device ≠ SC's device** — the pairs only meet if both apps open the
  same one.
- **Live's rate ≠ the profile's rate.**

It reports the timestamp of that block, because it is only as fresh as Live's
last audio-state change.

One thing the check *cannot* see, and the reason it prints a standing reminder:

> **Live's Input Config and Output Config are per device.** Switching Live to a
> different aggregate does not carry the enabled 17/18 pair across — you have to
> enable it again for the new device. Until you do, Live simply cannot see the
> guitar on ch 17 **while SC reads it perfectly**, which makes it look like a
> megalooper bug. `Log.txt` shows the device with its full channel count either
> way, so the log cannot distinguish the two.

---

## `\fireface` — RME Fireface 400 + TotalMix loopback

The lowest-latency option when the Fireface is present: no virtual audio device
in the path at all.

0-indexed channels: analog 0–3, ADAT 4–11, SPDIF 12–13.

```
Guitar -> analog in 1 -> Live (records analog 1); SC also reads it dry at 0
Live   -> ADAT 1-2 OUT  --[TotalMix loopback]--> ADAT 1-2 IN -> SC reads 4
SC     -> ADAT 3-4 OUT  --[TotalMix loopback]--> ADAT 3-4 IN -> Live records 6
```

The guitar arrives on a real analog input, so the clean analysis tap is just
`~analysisChannel = 0` — no extra channels and no `numInChans`.

**Setup**

1. In TotalMix, route the ADAT 1-2 OUT submix back into the ADAT 1-2 IN hardware
   input row (use the loopback button on the output strip). Same for ADAT 3-4.
2. In Live: set the guitar track's Audio To = "ADAT 1-2"; create a return track
   with Audio From = "ADAT 3-4".
3. Pick `fireface` in the launcher.

> **Gotcha.** Toggling loopback in TotalMix while Live is running often does not
> propagate to Live's input meters until Live's audio engine is restarted. If a
> freshly-enabled loopback shows zero signal on the expected Live input but
> TotalMix shows the output meter is hot, restart Live (or toggle the Audio
> Engine off and on in Preferences → Audio) before debugging further.

---

## `\loopback` — Rogue Amoeba Loopback, no Fireface

The older fallback, superseded by the `\bh*` profiles but kept because it needs
no aggregate device.

Reproduces the Fireface's channel layout in software so **the Ableton set stays
unchanged** across rigs — only `~routingProfile` flips. ONE 14-channel Loopback
device named "SC-Live Bridge" is used **directly by both SC and Live** — **no
Aggregate Device**. An aggregate puts the Bridge in two clock domains and drifts
into crackle after 30–60 s (BlackHole issue #137). Its Pass-Thru carries the
SC↔Live pairs exactly like the Fireface's ADAT loopback; the guitar enters as a
Loopback *source* and the speakers are a Loopback *monitor*. Both apps share the
Bridge's one clock, so the pass-thru pairs are sample-locked and nothing drifts.
(Verified against Rogue Amoeba docs, 2026-07.)

Channel map — 1-indexed as Live and Loopback show it. SC is 0-indexed, so its
offsets are 8/10/12, **identical to `\fireface`**:

| Channels | Route | SC offset |
| --- | --- | --- |
| 1–2 | Live Master → speaker MONITOR | — (Live Out 1/2) |
| 3 | guitar SOURCE → Live | `~analysisChannel = 2` (Live In 3) |
| 9–10 | Live guitar → SC | `~inChannel = 8` |
| 11–12 | SC loop → Live | `~outChannel = 10` |
| 13–14 | Live loop → SC | `~returnChannel = 12` |

**Setup**

1. **Loopback** (licensed — free mode degrades after ~20 min): New Virtual Device
   named EXACTLY "SC-Live Bridge"; grow Output Channels to 14 (Pass-Thru
   auto-extends 1:1 across all 14 — that *is* the loopback; leave ch 9–14 on
   Pass-Thru only). Add a SOURCE = your guitar interface (built-in mic, or the
   TS Mega) and drag its wire off ch 1/2 onto output ch 3. Add a MONITOR = your
   speakers/headphones on ch 1/2.
2. Sample rate 48 kHz on the Bridge, SC **and** Live. Set SC's and Live's audio
   buffer size to the same value and don't change either while both run — they
   share the one device, and mismatched buffers can crash CoreAudio.
3. **Live:** audio device = "SC-Live Bridge" (In and Out); enable I/O channels up
   to 14. Existing Fireface routings already match — change nothing.
4. **SC:** pick `loopback` in the launcher (channels 8/10/12, same as `\fireface`).
   `s.meter` should show 14 in / 14 out.

**Trade-off.** Live's guitar monitoring now passes through Loopback (~20–40 ms) —
fine for a fallback rig, less so for tight playing. Where possible, monitor the
guitar via the interface's own direct monitoring. Keep **nothing** on SC out 0/1
(that pair feeds the speaker monitor). Recalibrate "Overdub lat (ms)" by ear, and
soak-test ~45 min before a gig, listening for slow drift or crackle.

---

## `\bhFireface` / `\bhTsMega` / `\bhBuiltin` — BlackHole 16ch

The low-latency rigs. Same idea as the Loopback bridge, but the SC↔Live pairs
ride BlackHole (a pure kernel loopback, one buffer of delay) while the guitar and
the speakers stay on **real hardware** instead of being tunnelled through
Loopback's source/monitor. That is where the latency went: monitoring is now
interface-in → Live → interface-out, with no virtual device in the path at all.

BlackHole has no hardware ports, so each rig needs an Aggregate Device pairing it
with the interface. One ordering rule makes this work:

> ### BlackHole 16ch MUST be the FIRST sub-device in the aggregate.

CoreAudio concatenates sub-devices in list order, so BlackHole then owns channels
1–16 on **both** the input and the output side, and whatever interface follows
always starts at channel 17 — Fireface, TS Mega or built-in alike. One channel
map for every rig, and the SC↔Live pairs land on exactly the numbers the Ableton
set already uses:

| Channels | Route | SC offset |
| --- | --- | --- |
| 9–10 | Live guitar → SC | `~inChannel = 8` |
| 11–12 | SC loop → Live | `~outChannel = 10` |
| 13–14 | Live loop → SC | `~returnChannel = 12` |
| 17 | guitar in (interface input 1) | `~analysisChannel = 16` (Live In 17) |
| 17–18 | speakers out (interface output 1/2) | — (Live Out 17/18) |
| 1–8, 15–16 | unused BlackHole channels | leave them alone |

Both apps open the **same** aggregate, exactly as they both open the Bridge, so
there is one clock domain and nothing to drift.

> **Do not split Live across two of these aggregates** (e.g. Input = `TS Mega`,
> Output = `Built-in`) to dodge a device problem. It looks like it works, because
> BlackHole occupies ch 1–16 of both and the SC↔Live pairs still line up — but it
> opens BlackHole in **two clock domains at once**, each drift-correcting against
> a different master. That is the same topology that time-stretched and crackled
> the aggregated Loopback bridge after 30–60 s. Fix the device instead.

Note the last row that is *not* unused: ch 17 is the guitar's hardware input, and
both apps read it — Live to record and process it, SC to analyse it dry. That is
the clean analysis tap, and it is why these profiles ask for **17 input channels
but only 16 output channels** (`numInChans: 17`). Outputs stop at 16 on purpose:
SC still cannot reach the speakers by accident, so the `\loopback` rig's "keep
nothing on SC out 0/1" footgun stays gone.

**Setup**

1. Audio MIDI Setup → **+** → Create Aggregate Device. One per rig:

   | Aggregate name | Members |
   | --- | --- |
   | `MegaLoop BH (Fireface)` | BlackHole 16ch + Fireface 400 (E15) |
   | `MegaLoop BH (TSMega)` | BlackHole 16ch + TSMEGA + MacBook Pro Speakers |
   | `MegaLoop BH (Built-in)` | BlackHole 16ch + External Headphones + MacBook Pro Speakers + "stereo mic" |

   The TSMega aggregate's **third member is not optional**: Live refuses to
   drive TSMEGA's output stream and segfaults about a second after that
   aggregate becomes its output device. The speakers give Live an output it will
   actually drive, so Master goes to 19/20 and TSMEGA's own 17/18 stay unused.
   The preflight lists it as an expected member for that reason — an aggregate
   rebuilt without it will crash Live rather than fail cleanly.

   `MegaLoop BH (Built-in)` is the odd one out and is worth reading twice: its
   guitar input is the Loopback virtual device **"stereo mic"**, not the MacBook's
   own microphone, and it carries *two* output members. So it is 18 in / 20 out
   where the others are 18/18, and its monitoring lands on the headphones at
   17/18 with the speakers above them at 19/20. Input ch 17 — the analysis tap —
   is "stereo mic" channel 1 there, rather than a hardware input.

   Those member names are exactly what CoreAudio calls them; the footswitch
   interface shows up as "TSMEGA". Aggregate names are ASCII on purpose — SC
   miscounts multi-byte characters and truncates.

   **Drag BlackHole 16ch to the TOP of the list in each one** — the whole channel
   map depends on it. Tick Drift Correction on every row **except** the interface
   you set as Clock Source.
2. **Clock Source = the interface, not BlackHole.** A virtual device makes a poor
   master (that is what crackled the aggregated Loopback bridge), and since both
   apps sit on the aggregate they share whichever clock it uses.
3. **Sample rate 48 kHz everywhere**: the aggregate, BlackHole, the interface, SC
   and Live. BlackHole is already at 48 kHz; the old Bridge and the "Live Rig"
   aggregate are at 44.1 kHz, so do not inherit from those.
4. **Live:** audio device = the matching `MegaLoop BH (…)` aggregate, In and Out,
   then **Input Config and Output Config → enable the 17/18 pair on both sides**.
   Two changes to the set, once — the guitar track's input 3 → 17, and Master out
   1/2 → 17/18. Everything else (9/10, 11/12, 13/14) is untouched, and those two
   settings then hold for all three rigs.

   > **Enabling 17/18 is not optional, and skipping it does not fail gracefully.**
   > Master is routed to 17/18. If those channels are not enabled for the device,
   > Live has no buffer behind them and **segfaults about a second after you
   > select the device** — a null dereference on its audio thread, with nothing in
   > its own log to explain it (`Output Channels: 16` on an 18-channel device in
   > `Log.txt` is the tell). Leaving the input pair disabled is quieter but just
   > as broken: Live simply cannot see the guitar on ch 17.
   >
   > If Live crashes before you can reach Output Config, point Master at a pair
   > inside 1–16 first, switch the device, enable 17/18, then move Master back.
5. **SC:** pick the matching `~bh*` profile. Channels stay 8/10/12.
6. **Recalibrate "Overdub lat (ms)"** — the profiles start at a guess, not a
   measurement, and the BlackHole round trip is shorter than Loopback's.

---

## `\sa` — Megalooper SA, TSMEGA alone, no Live

The standalone instrument ([Megalooper SA](standalone.md)). There is no
Live and no aggregate: SC opens TSMEGA itself, one device and one clock. Quit
Live first. It does not need Live, and Live holding TSMEGA blocks the rate
switch below.

| Role | Channel | Carries |
|---|---|---|
| `inChannel` | 0 (TSMEGA input 1) | the instrument, dry. From Phase 2 the looper records the instrument chain instead |
| `outChannel` | the mixer's loop bus | the loop. The profile's 0 is replaced at boot by `scripts/setup-sa.scd` |
| outputs 1/2 | 0, 1 | the mix: instrument, loop, master level, a hard clip as the last safety |
| `returnChannel`, `analysisChannel`, `sessionChannel` | nil | no Live to return anything; analysis reads the recorded (dry) input |
| `bassChannel` | 1 (TSMEGA input 2) | the bass, dry, into the bass chain and onto its own strip. The looper does not record it |

Two things the profile does that no other one does:

- **It switches TSMEGA to 48 kHz before the boot** (`setSampleRate: true`,
  through `tools/coreaudio.py set-rate`). Plugged in on its own, TSMEGA comes up
  at 44.1 kHz; inside the TSMega aggregate it runs at the aggregate's 48.
- **It boots at 64 frames** (`hardwareBufferSize: 64`): a 9.3 ms round trip on
  the rig, against Live's 16.1 ms. The other profiles keep whatever buffer
  size the server had before any profile was applied.

The node order is the instrument's group, then the default group (every Looper synth),
then the mixer group, so the mixer hears the loop the same block it is written.

---

## Adding a rig

Write it into **`profiles.scd` in your megalooper folder**
(`~/Library/Application Support/SuperCollider/megalooper/` on macOS,
`~/.local/share/SuperCollider/megalooper/` on Linux). The file holds one
Event, a profile per key:

```supercollider
// My rigs.
(
    myRig: (
        device: "Exact CoreAudio Name", numChans: 16, numInChans: 17,
        inChannel: 8, outChannel: 10, returnChannel: 12,
        analysisChannel: 16,
        inChannelCount: 2, latencyMs: 15, abletonSyncMs: 0, sampleRate: 48000)
)
```

It is read at every start, and each rig appears in the launcher beside
`saSystem`; the launcher remembers the one you pick. A file that does not read
is reported in the log (`~/Library/Logs/megalooper.log`) and megalooper starts
with its own rig; a rig that names no device is left out. A rig of yours named
`saSystem` replaces megalooper's. From the SuperCollider IDE, set
`~defaultRoutingProfile = \myRig` in
[`scripts/setup-routing.scd`](../scripts/setup-routing.scd).

`ServerOptions.devices` lists the exact names, and the name must match — the boot
guard compares leniently but `MegaLoop BH (TS Mega)` and `MegaLoop BH (TSMega)`
do **not** match each other, so a rename in Audio MIDI Setup aborts the boot until
the profile is updated. `sampleRate`, `numInChans`, `analysisChannel` and
`abletonSyncMs` are all optional — omit `analysisChannel` on a rig where SC cannot
see the instrument's own input, and the analysis falls back to reading `inChannel`.
`./tools/run-checks.sh quick` checks your rigs with megalooper's own.

On an SA profile (`sa: true`), `bassChannel: 1` says a bass is on the
interface's input 2. Megalooper SA then plays it through the bass chain onto a
strip of its own. Leave it out on a rig without a bass. The static check
(`scripts/check.scd`) refuses one that is out of the profile's inputs, the
instrument's input or the analysis tap, or set on a profile without SA.

### The four calibrated values

| Field | What it corrects | How you get it |
| --- | --- | --- |
| `latencyMs` | Overdub round trip into the buffer. One-directional: clipped at 0, slider caps at 100 | By ear ("Overdub lat") |
| `abletonSyncMs` | When the MIDI clock is sent, so Live's 1.1.1 lands on the music | By ear ("Live sync") |
| `onsetNoteOffsetMs` | When the onset notes are sent, so they sit on the loop | By ear ("Offset"), or by recording both into Live |
| `chainRecOffsetMs` | Where the loop-chain recorder starts, so a chained loop is not rotated inside its own buffer | **Measured** — `scripts/check-chain-align.scd` |

All four are per-rig because they measure that rig's paths — a number calibrated
on one device is wrong on the next. The profile supplies the **starting** value;
the sliders and boxes then tune it live.

`chainRecOffsetMs` is the odd one out and the easy one: you do not guess it. Chain
a loop, run `~chainAlign.()`, and set it to the number the tool prints. It reports
the offset already in effect alongside the reading, and recommends the
*cumulative* value, so iterating converges instead of undoing itself.

`onsetNoteOffsetMs` exists because the loop's audio crosses the virtual device
and Live's input buffer while the notes go straight over IAC and are quantised to
Live's next audio block. Both are scheduled from the same origin, so the
remainder is a fixed offset this rig owns. It defaults to 0 when absent. **When you re-calibrate by ear, write the number back into the
profile**, or the next boot starts from the old one. `abletonSyncMs` defaults to
0 when absent, and must stay inside the slider's ±`~syncMax` (150 ms) — otherwise
`check.scd` fails, because the GUI would open showing a value it cannot represent.

Calibrated so far:

| Profile | `latencyMs` | `abletonSyncMs` | `onsetNoteOffsetMs` | `chainRecOffsetMs` |
| --- | --- | --- | --- | --- |
| `bhTsMega` | **54** (by ear) | **+68** (by ear) | **+53** (by ear) | **+59** (measured) |
| `bhBuiltin` | **68** (by ear) | **+150** (by ear, at the slider's limit) | **+63** (by ear) | never measured |

`bhTsMega` is **fully calibrated** as of 2026-09-07 — every value confirmed on the
rig after the `loopStartTime` fix. `bhBuiltin`'s two offsets are still arithmetic.

Note that `bhTsMega`'s two offsets are **not** the same number, though they were
before the fix. Both had been dialled by ear to −132, and at ~±15 ms of ear
precision that was merely close enough for both; with everything else correct the
difference became audible and they split. They shift different streams — the clock
drives Live's transport, the notes are quantised to its next audio block and then
trigger a drum rack — so don't assume they track each other when calibrating.

> **Anything still marked "derived" wants confirming.** On 2026-09-07 the
> `loopStartTime` bug below was fixed, and every offset moved by 200 ms — the
> constant the code removed, which is what preserves the old behaviour. (Not the
> 185 ms that was *measured*: that is the gap between `loopStartTime` and the
> audio, a different quantity from how far `loopStartTime` itself moved.)
>
> On `bhTsMega` all three were then settled on the rig, and the arithmetic proved
> a good starting point but not exact — the notes came in 15 ms under it. That is
> the old −132 having been slightly off within ear precision, not the shift being
> wrong; the clock, dialled from the same −132, confirmed at exactly +68. Expect
> ±15 ms of dialling on `bhBuiltin` too.

### Why these numbers used to be huge

Until 2026-09-07 every one of these offsets sat around −130 ms, which is far more
than any real path difference explains. The cause was one bug, compensated four
times over: `spawnEngine` set

```supercollider
loopStartTime = SystemClock.seconds + server.latency
```

on the assumption that the engine synth was scheduled `server.latency` ahead. It
was not — `Synth.new` sends its `s_new` immediately — so the reference every
phase-aligned routine uses sat ~185 ms later than the audio it described.
Measured on the rig with
[`scripts/check-loop-phase.scd`](../scripts/check-loop-phase.scd): a median of
183.5 ms against an `s.latency` of 0.2.

The onset notes, BBCut, the MIDI-clock Start and the chain recorder's boundary
each inherited that error and each absorbed it into its own trim. With the
reference corrected, the offsets should be **small and physically meaningful** —
the genuine difference between what SC sends and what Live puts out.

If any of them still comes out near ±130, suspect the reference again and re-run
`~loopPhaseCheck.()`; it should now report a difference near zero.

`latencyMs` is deliberately **not** one of these. It compensates a round trip
*into* the buffer rather than an offset *out* to Live, never read `loopStartTime`
(so the fix did not move it), only ever runs in one direction (`latencyMs_` clips
at 0), and its slider tops out at `~latencyMax` (100 ms). Giving it one of the
offsets above would be silently clipped to 0 and would take the overdub alignment
with it.

Two things still invalidate the offsets whatever their size: **changing the
plugin chain** in Live, and **fixing the sample-rate mismatch**, since part of
what they absorb is CoreAudio resampling a 48 kHz member inside a 44.1 kHz
aggregate. Re-measure after either. `~syncMax` was raised from 100 to 150 back
when these were ±130; at the corrected sizes it is no longer load-bearing, but
there is no reason to narrow it again.

Whatever you add, run `sclang scripts/check.scd` — it resolves every profile and
catches the channel mistakes that are otherwise silent at runtime.
