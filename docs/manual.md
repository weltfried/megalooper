# megalooper: the manual

Installing megalooper and the first run are in the [README](../README.md).
Megalooper SA's effect chains, sounds and plugins are in
[Megalooper SA](standalone.md), and the drums' kits in [Drums](drums.md).

This manual is the reference for everything else: the rigs, every control,
the MIDI map, the onset notes, the grains, the cutter, working with Ableton
Live, calibration, how the meter is found, and the tests. Much of it was
written for the rig megalooper grew up on (the TSMega floor controller, a
Faderfox UC4 and Ableton Live), and says so where it is
about that rig.

## Optional extras

- *(Live integration)* install AbletonOSC: copy its folder into
  `~/Music/Ableton/User Library/Remote Scripts/`, then in Live's preferences
  under **Link, Tempo & MIDI → Control Surface**, select `AbletonOSC`.
- *(MIDI Clock to Live)* enable the macOS IAC Driver: open
  **Audio MIDI Setup → MIDI Studio**, double-click **IAC Driver**, tick
  **Device is online**, and ensure at least one port is enabled. Then in Live,
  under **Link, Tempo & MIDI**, enable **Sync** on the IAC input.

## Configuration

Audio routing is chosen by a **routing profile**. Pick it in the Desktop
launcher's dropdown, or from the editor flip one line in
`scripts/setup-routing.scd`:

```supercollider
~defaultRoutingProfile = \standalone;
// \standalone | \fireface | \loopback | \bhFireface | \bhTsMega | \bhBuiltin
```

Each profile sets the audio device, server channel count, the SC↔Live channel
offsets, the dry-guitar analysis tap, recording width, and default
overdub-latency compensation:

- **`\standalone`** — the default, and the only profile that needs no setup at
  all. It names no device: SuperCollider opens whatever CoreAudio is currently
  defaulting to, so it is correct on any Mac. Two channels in and out, the
  recorded input doubles as the analysis tap (nothing processes it on the way in,
  so it is already dry), and there is no Ableton Live in the picture.

  What it cannot do, and says so rather than failing quietly: **loop chaining**
  is off (chaining re-records what Live sends back, and there is no Live — the
  "Rec next loop" button is disabled with a tooltip), and **MIDI clock** and
  **Live sync** are inactive unless an IAC bus happens to exist.

  Two things to know before the first loop. **Use headphones**: the looper plays
  back while it records, so built-in mic into built-in speakers is a feedback
  loop. And **the default input and output must run at the same sample rate** —
  scsynth refuses to boot otherwise, and a stock Mac often has the microphone at
  44.1 kHz and the speakers at 48 kHz. megalooper checks this before booting,
  names both devices, and there is one command that fixes it:

  ```bash
  python3 tools/coreaudio.py defaults             # do they agree?
  python3 tools/coreaudio.py match-default-rates  # make them agree
  ```

  `tools/coreaudio.py` is a standard-library-only CoreAudio bridge — no
  dependencies, no build step. It also lists devices with their real channel
  counts (`list`), shows one in full (`inspect`), and cross-checks every reading
  against `system_profiler` (`selftest`). `list` output is the right thing to
  paste into a bug report.

- **`\bhFireface` / `\bhTsMega` / `\bhBuiltin`** — the low-latency rigs.
  **BlackHole 16ch** carries the SC↔Live pairs while the guitar and the speakers
  stay on real hardware, so monitoring is interface-in → Live → interface-out
  with no virtual device in the path. Each profile names an Aggregate Device
  (`MegaLoop BH (…)`) that pairs BlackHole with that rig's interface. **BlackHole
  must be first in the aggregate**: CoreAudio concatenates sub-devices in list
  order, so BlackHole then owns ch 1–16 on both sides and the interface always
  starts at ch 17 — the same map for all three rigs. The SC↔Live pairs stay on
  9/10, 11/12, 13/14 and SC's channels stay `8/10/12`; in Live only the guitar
  input (3 → 17) and Master out (1/2 → 17/18) move, once, for all three rigs.
  Both apps open the same aggregate, so there is one clock domain — and so SC can
  also read the guitar's own input at ch 17 as the dry analysis tap
  (`analysisChannel = 16`, inputs 17 / outputs 16). Full recipe — clock source,
  drift correction, 48 kHz — in [docs/routing.md](routing.md).
- **`\fireface`** — RME Fireface + TotalMix loopback. Guitar → analog 1 → Live,
  Live → ADAT loopback → SC records, SC → ADAT loopback → Live. One 18-channel
  device does everything, and with no virtual device anywhere it is still the
  lowest-latency option when the Fireface is present.
- **`\loopback`** — the older fallback, superseded by the `\bh*` profiles but
  kept because it needs no aggregate. ONE **Rogue Amoeba Loopback** virtual device
  (`SC-Live Bridge`, **14 channels**, Pass-Thru) is used **directly by both SC
  and Live** — no Aggregate Device. It reproduces the Fireface's channel layout:
  the guitar comes in as a Loopback **input source** on ch 3, the speakers are a
  Loopback **monitor** on ch 1/2, and the SC↔Live pairs sit on ch 9/10, 11/12,
  13/14 — the same channels your Ableton set already uses, so **Live needs no
  changes**, and SC's channels stay `8/10/12` (same as `\fireface`). One shared
  virtual clock means no aggregate drift. Trade-off: live guitar monitoring runs
  through Loopback (~20–40 ms) — fine as a fallback, less so for tight playing.
  Keep everything at 48 kHz and the same buffer size. Full steps in
  [docs/routing.md](routing.md).

### Device preflight

Aggregate devices fail *quietly*. A member drops out and the aggregate keeps
working with fewer channels; SC asks for 17 inputs, CoreAudio grants 16, and the
analysis tap reads a bus nothing ever fills — for the whole session, in silence,
looking exactly like a detection bug. So before `s.boot`, megalooper asks the
system what it actually has:

- **`~checkAudioDevice`** compares the device's real channel count, sample rate
  and expected member devices (`system_profiler`, ~0.2 s) against the profile.
  Missing SC↔Live channels **abort**; a missing analysis tap **degrades** — the
  tap is switched off, `s.options` corrected, and onset detection falls back to
  the recorded input, loudly. Sample-rate and member problems warn.
- **`~checkLiveAudio`** reads Live's own `Log.txt` and flags the two things SC
  cannot otherwise see: Live's **input and output on different devices** (the
  split-aggregate footgun — it looks like it works, then crackles and needs a
  reboot), and Live on a **different device than SC**.

Both re-run on demand: `~checkAudioDevice.(~routingProfile)`,
`~checkLiveAudio.(~routingProfile)`. Details and the full message reference are
in [docs/routing.md](routing.md#the-device-preflight).

> One thing no check can see: **Live's Input Config and Output Config are per
> device.** Switching Live to another aggregate does not carry the enabled 17/18
> pair across, and until you re-enable it Live cannot see the guitar on ch 17
> while SC reads it perfectly.

The full step-by-step setup for every rig (Loopback channel names, the Aggregate
Device, TotalMix loopback, and Live's track routing) is in
**[docs/routing.md](routing.md)**. `ServerOptions.devices` in SC prints the
available device names. To add or tweak a rig, edit the `~routingProfiles` table
in `scripts/setup-routing.scd`.

Each profile also carries that rig's four calibrated timing values —
**`latencyMs`** (the "Overdub lat" slider), **`abletonSyncMs`** (the "Live sync"
slider, negative pulls Live earlier), **`onsetNoteOffsetMs`** (the onset notes'
"Offset" box, negative sends them earlier) and **`chainRecOffsetMs`** (where the
loop-chain recorder starts) — because all four measure that rig's paths and do
not carry across devices. They are applied at boot, before the windows open, so
the controls start there. After switching profiles, recalibrate and **write the
numbers back into the profile**, or the next boot starts from the old ones.

The first three are dialled by ear. `chainRecOffsetMs` is not: chain a loop, run
`~chainAlign.()` from
[check-chain-align.scd](../scripts/check-chain-align.scd), and set it to the number
the tool prints — see [Across multiply, undo and loop
chaining](#across-multiply-undo-and-loop-chaining).

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

The rest are still guesses. Anything still marked **derived** is arithmetic —
every offset moved by 200 ms on 2026-09-07 when the `loopStartTime` bug was
fixed, that being the constant the code removed. Expect to dial ±15 ms off it.
See [Why these numbers used to be
huge](routing.md#why-these-numbers-used-to-be-huge).

## Running

### From the Desktop icon

Build the app once:

```bash
./tools/make-app.sh            # builds ~/Desktop/megalooper.app
./tools/make-app.sh /Applications   # or somewhere else
```

Double-click it and a small window opens: pick the rig from the dropdown and
press **Start megalooper**. A ✓ next to a profile means that rig's audio device
is connected right now, so a missing interface is visible *before* the boot
rather than as an aborted boot. **Rescan** re-checks CoreAudio if you plug
something in after opening the window. **Buffer** sets the audio buffer: leave
it at *as the rig sets it*, or pick a bigger one (256 frames) on a slower
computer that clicks or drops out. It adds as much delay (5 ms each way at
48 kHz), so run the latency step on the Calibrate view after changing it. The
chosen rig and buffer are remembered for next time, and closing the window
quits the app and the server.

The bundle is a thin wrapper around `scripts/launcher.scd` with the repo path
baked in — nothing is copied, so script edits take effect on the next launch
with no rebuild. **Moving the repo breaks it; re-run `make-app.sh` after a
move.** macOS warns once because the bundle is unsigned: right-click → Open →
Open. There is no post window under the icon, so all output goes to
`~/Library/Logs/megalooper.log`, and boot failures also appear in the launcher's
status line.

### From the SuperCollider IDE

Open `scripts/boot.scd` and evaluate the parenthesized boot block (place the
cursor inside, press `Cmd+.` first if a server is already running, then
`Cmd+Return`). The rig here comes from `~defaultRoutingProfile` in
`scripts/setup-routing.scd` — the launcher's choice only applies when launched
from the icon.

`boot.scd` is only an orchestrator: it picks the routing profile, loads the
part-files beside it, and calls their builders in order. Re-running it rebuilds
everything — including freeing the `Looper`, which **destroys the recorded
loop**. To iterate on one part without losing the loop, re-evaluate that part's
file and call its builder:

```supercollider
~buildGuiWindow.();       // rebuild the whole window, loop untouched
~buildBBCutPane.();       // rebuild ONE pane in place; the status band, the
~buildGranularPane.();    // other panes and the running audio are untouched
~buildAnalysisPane.();
~buildPerformPane.();
~buildRigPane.();
~wireLooperController.(); // re-subscribe the GUI after rebuilding a pane
~setupMidiBindings.();    // rebuild the MIDI router's map and responders
```

A pane rebuild swaps a fresh `View` into its holder inside the window's
`StackLayout`; the stack's own children are built once and never touched, so the
tabs cannot drift out of step with what they are showing.

After editing anything under `scripts/`, run the static check — it parses and
loads every file without booting a server, opening a window or touching MIDI:

```
/Applications/SuperCollider.app/Contents/MacOS/sclang scripts/check.scd
```

Wait for the post window to print `Boot complete.`: the `megalooper` window
opens on the Perform view (see [GUI](#gui)).

## Controls

### Keyboard (the megalooper window must be focused)

| Key | Action                                                            |
|-----|-------------------------------------------------------------------|
| `R` | Multi-purpose trigger (record → play → overdub → play → ...)      |
| `S` | Stop                                                              |
| `M` | Multiply loop length (×2)                                         |
| `U` | Undo (one level deep)                                             |
| `V` | Reverse                                                           |
| `G` | Toggle granular layer                                             |
| `B` | Toggle BBCut (algorithmic re-splicing of the loop)                |
| `C` | Clear                                                             |
| `A` | Next reading — the analyser's runner-up meter, then the one after; lands on a loop boundary |
| `Cmd+M` | MIDI Map mode on and off — see *Mapping your own controller* |

A letter with Cmd or Ctrl held is no shortcut: Cmd+C doesn't clear. In MIDI
Map mode the letters still work, and Esc, Delete and Cmd+Z join them.

The `R` trigger cycles per Ableton's Looper spec:

```
empty -> record  ->  play  ->  overdub  ->  play  ->  ...
                                  ^                       |
                                  +-----------------------+
stopped -> play
```

### MIDI

Which message does what is a **MIDI map**, and a control can be put on any
controller: see *Mapping your own controller* below. megalooper ships two maps
in `presets/midi/`.

**tsmega**, the TSMega floor controller. Every rig but `standalone` starts with
it (the profile's `midiMap:`). It answers only the input named TSMEGA, on any
channel. The effects and the drums are Megalooper SA's; on a Live rig those
programs reach Live's own devices through the proxy, as before.

| Message | Action |
|---|---|
| Program Change 4 | Trigger |
| Program Change 5 | Clear |
| Program Change 6 | Record next loop (loop chaining) — was Stop until 2026-09-23 |
| Program Change 7 | Break — drop out now, resume on a loop downbeat |
| Program Change 8 | The delay on and off (SA) |
| Program Change 9, 10, 11 | Pitch Loops, the Envelope Filter, Pitch Shift (SA) |
| Program Change 12, 14, 15 | The loop's Echo, Saturator, Redux (SA) |
| Program Change 13 | Toggle the granular layer |
| Program Change 16 | Toggle onset notes — the drum part Live plays from the loop |
| Program Change 17 | The drums' steps on and off (SA) |
| Program Change 18 | Toggle BBCut |
| Program Change 19 | **Next reading** — the take's runner-up meter, then the one after, round to the analyser's own; lands on a loop boundary |
| Program Change 20 | **Record the set** (megalooper's own files) |
| Program Change 21 | **Live arrangement record** — arms Live; it starts when the transport does |
| CC 4 | Overdub feedback (0 = replace, 127 = full preserve) |
| CC 7 | **Onset threshold** (0.01–2.0, exponential). Mirrors Perform's Onset macro; watch the onset lamp while you sweep it |

**The pedal's flicker.** The TSMega's expression pedal hops one step back and
forth on its own when nobody touches it (68, 69, 68 at rest on the SA rig).
Its two CCs in the map carry `"hysteresis": 1`: a move counts if it is two
steps or more, or one step on in the direction of the last. The control stays
within a step of the pedal, and a threshold set with the Onset macro is no
longer taken back by the next hop. Since phase 4 every knob or pedal on a CC
has that one step unless its mapping says otherwise; the Knobs row of Setup's
MIDI map sets the default.

**keys-and-knobs**, for keyboards and knob boxes, any input. No rig starts
with it; pick it in Setup's MIDI map, or learn your own controller's knobs instead.

| Message | Action |
|---|---|
| Note On 60–65 | Trigger, Stop, Multiply, Undo, Reverse, Clear |
| Note On 66 | Toggle BBCut |
| Note On 67 | Record next loop |
| Note On 68 | Break |
| Note On 69 | Dissolve — run the ending; press again to abort |
| Note On 70 | **Record the set** |
| Note On 71 | **Next reading** |
| CC 11 | **Arc / intensity** — expression pedal. Drives the granular level and the cutter's density: heel = the dry loop with a cutter that barely chops and no grains, toe = everything as dialled in |
| CC 40–47 | The Grains' Pitch, Grain and Read position sections (Sound) — see below |
| CC 118 | Granular morph (0 = frozen drone, 127 = pulsed scan) |
| CC 119 | Granular level |

**CC 40–47** is one contiguous block covering three of the four sections of the
Grains, in the order they list them — so a bank of eight knobs
lands on it without anything to remember:

| CC | Control | Section |
| --- | --- | --- |
| 40 | Pitch (−24…+24 semitones, 64 = unison) | Pitch |
| 41 | Detune (redrawn per grain) | Pitch |
| 42 | Grain size (×, 64 = morph untouched) | Grain |
| 43 | Density (×, 64 = morph untouched) | Grain |
| 44 | Size rand | Grain |
| 45 | Position — where in the loop grains come from | Read position |
| 46 | Scan — how the read point moves | Read position |
| 47 | Spray | Read position |

Every knob binding uses the **same law as its control's widget**, so a fader
sweep and a mouse drag cover the same range in the same shape.

> **Changed on 2026-10-08**, when the maps became files (they had been numbers
> in `setup-midi.scd`, which a copy in `scripts/tests/legacy-midi-bindings.scd`
> keeps). Program Change 8 is the delay alone on every rig, so on a Live rig it
> no longer toggles the cutter, which keeps 18. The notes and the knob CCs moved
> to keys-and-knobs. And the TSMega's map answers only the TSMEGA.

#### Mapping your own controller

**MIDI Map mode**, as in Live. Press **MIDI MAP** in the top bar (on every
view), or Cmd+M. Every control in the window is outlined in blue and says what
drives it ("PC 4"). Click one, and move a knob or press a switch on your
controller: that now drives it. Shift-click instead adds one more, so a control
can answer two switches. While a control waits, its mask is amber and counts
down its 15 s, and so does the map bar above the footer. Esc cancels, and
pressed again leaves. **Delete** (or the Delete key) takes the waiting
control's MIDI away, and Cmd+Z or **Undo** brings it back.
**Keep** keeps the map, and **Done** leaves; with changes not kept it asks
first: Keep, Discard or Later. The controls don't move while map mode is on.
MIDI goes on driving everything until you click a control; while one waits,
every message goes to it, and no footswitch acts nor anything reaches Live
(15 s at most).

Everything else is in the **MIDI map** section of the Setup view, including
the controls that have no widget, such as Live's arrangement record and the
views themselves (Show Perform, Show Sound, …, to put them on footswitches):

- **Inputs**: every MIDI input there is, each a switch: whether megalooper
  listens to it. One switched off reaches no control and nothing of it goes on
  to Live. Plugged in after the boot? Press **Rescan**.
- **Send back**: for a controller that takes MIDI back, such as the Faderfox
  UC4, whether megalooper sends it where each control it drives is. An encoder
  then goes on from where the mouse or a preset put its control, with no jump,
  and a button's light shows its switch. A knob is never sent its own moves,
  and not while it is being turned. Off until you switch it on. Unplugged and
  plugged in again, a controller shows its own values until you press
  **Rescan**.
- **Map**: which map this rig uses; the choice is kept per rig. **Keep** writes
  it as yours, and the next boot starts with it. Nothing is written before
  Keep. **Undo** takes the last change back. **Revert** goes back to what was
  kept, and **Reset to shipped** to the map as megalooper ships it (yours goes
  into the backups); both ask for a second click. **Load from…** opens a map
  file, a backup or one someone sent you.
- **The list**: every binding, with its range where it has one. A row is grey
  when its control isn't on this rig, an SA effect on a Live rig, say. Select a
  row to change it:
  - **Learn** arms its control again;
  - **×** removes the binding;
  - **Set Min** and **Set Max** take the control's value as it is now: put it
    where that end of the knob should be, then press;
  - **Swap** turns the knob round;
  - the channel and the input it answers;
  - for a CC on a switch, what kind of switch it is (one message a press, or
    press and release);
  - for a toggle, whether a press flips it, holds it on, or it follows the
    switch;
  - for a knob or pedal: its **takeover**, its hysteresis, and its **input
    range**. Takeover is what the knob does when its control is somewhere
    else, because the mouse or a preset moved it. The control **jumps** to the
    knob, as it always did. Or it waits until the knob gets to it (**picks
    up**). Or the two meet at the ends (**scales**). For the input range, press
    **Sweep**, move the pedal from one end to the other and press Done; a
    pedal that stops at 126 then still takes its control to the end. A sweep
    left running ends itself 20 s on and changes nothing. **Full** gives back
    the whole travel.
- **Knobs**: the takeover and the hysteresis of every knob mapping that
  doesn't say: jump to the knob and one step, unless you change them.
- **Add a mapping**: pick a pane and a control, press **Learn**, then move a knob
  or press a switch. On the way:
  - a CC switch is pressed twice, which tells one that sends a message a press,
    like the TSMega's, from one that sends press and release;
  - a knob counts once it has moved 3 steps, so a resting pedal's flicker is
    never learned;
  - if the message already drives another control, the section asks: **Move it
    here**, **Both** or **Cancel**;
  - while a control is learning, up to 15 s, MIDI drives nothing and nothing
    goes on to Live. Once it counts a switch's presses, up to 4 s more, only
    that switch is held back.

Yours live in `~/Library/Application Support/SuperCollider/megalooper/midi/`,
outside the repo and shared by every checkout. The last five Keeps of each map
are in `backups/<map>/`, and `settings.json` beside the folder holds each rig's
choice, the inputs switched off or sent back to, and the Knobs row's defaults
(they don't travel with a map). Keep makes the map this rig's choice; on a
rig with no map yet it is called "mine". If the input a map is for is switched
off or not connected, the footer's status line says so. If your map can't be read at boot, its newest
readable backup is loaded, never the shipped map: a different layout could put
Clear on a switch you now use for something else. With no backup there is no
map, and the footer says the footswitches are off. A map is JSON, data only:
[MIDI map files](midi-maps.md) has the format.

Megalooper sends one CC of its own, outgoing on the IAC bus alongside the MIDI
clock: **CC 100 on channel 16**, 0 when a break opens and 127 when the loop comes
back — see [Breaks](#breaks).

> **Moved from CC 20 on 2026-09-22**, when the session recorder took Program
> Change 20. Every program change is proxied to Live as *CC number = program
> number* on that same channel, so a break macro on CC 20 would have been
> flipped by every press of the record footswitch. If you have an Ableton set
> from before that date, this is the one control to re-map. Since 2026-10-08
> the proxy leaves program change 100 out of that translation (it still goes to
> Live as a program change), so no controller can flip the macro by sending it.

All MIDI input is logged to the post window by default, a message held back
marked as such. To silence the log, evaluate `~midiLog = false` in SC.

**One router.** Every message goes through one router
(`scripts/setup-midimap.scd`): to the controls bound to it, then on to Live,
then into the log, in that order. So Live gets a forwarded message after
whatever the action itself sends it (a break's macro CC comes before the
forwarded program change, for one). `~setupMidiBindings.()` rebuilds it, and
keeps a map's changes not kept yet.

### The arc — intensity and dissolve

Two axes over the same three levels (the dry loop, the cutter, the granular
layer), for shaping a piece without taking a hand off the instrument.

**Intensity** is the expression pedal's control (CC 11 in the keys-and-knobs map;
map any pedal to it in MIDI Map mode), mirrored by the **Arc** macro on
Perform. Heel is the dry loop with a cutter that is running but barely
chopping and no grains; toe is the cutter chopping as you dialled it in and the
granular layer at its set level.

**Dissolve** is the ending. Arm it with the Dissolve button, or a footswitch mapped to it, and
it runs over `dissolveBars`, so both hands are free for the last melody; press
again to abort and restore. Things leave in the order that sounds like a piece
ending rather than like a fader going down — **the cutter first, then the body
of the loop, and the granular haze last.**

Intensity moves two things: the **level of the granular layer**, and **how much
the cutter is chopping**. The cutter's own level is not one of them — it was
until 2026-10-05, and a cutter thinned to a few repeats *and* turned down read
as the layer going away rather than as it chopping less, so now only the
dissolve takes the cutter's level out. Each cut procedure names one parameter
the pedal drives — `cutchance` for Break/Repeat, `stutterchance` for BBCutProc11,
`rollchance` for ChooseCutProc — scaled from that parameter's own floor up to
whatever you set. So at the heel Break/Repeat never breaks the loop up at all,
and at the toe it does exactly what you dialled in. WarpCutProc1 and SQPusher1
read their parameters once at build time, so the pedal does not reach them at
all; driving them would rebuild the cutter on every message.

That means **the Cutter pane's slider shows the value at full arc**, not
necessarily what is running. The arc-driven row carries a live `arc → 0.20`
reading beside it so both numbers are visible at once.

Both axes are **multipliers, never replacements**. The per-voice cutter mix, the
granular level and every stored parameter stay exactly where you set them, so
their own controls keep meaning what they say while the arc moves over the top —
and presets save what you dialled in, not what the pedal happened to be doing.

Intensity **defaults to 1**, so a rig with no expression pedal connected behaves
exactly as it did before this existed — the pedal takes over the moment it is
touched and never before.

### Breaks

Hit Program Change 7 (the TSMega's map), the Break button, or a switch mapped to it, and the looper goes
silent so the room can play into the hole, coming back **on a loop downbeat**.

The hole opens the instant you stomp — the mute is not quantised, so it lands
exactly where your foot did. Only the **resume** is on the grid: it waits out
whatever is left of the pass you struck it in, plus `breakLoops` - 1 further
whole loops (1–8, default 1). The pass you struck it in counts as the first one,
so the default comes back on the **next** loop downbeat, and the loop always
returns at the top of a phrase rather than somewhere in the middle of one.

That means a one-loop break lasts anything from a hair to a full pass, depending
on where your foot landed: stomp just after a downbeat and you get nearly a whole
loop of room, stomp just before one and the hole is barely there. When you want a
guaranteed full pass of silence no matter when you hit it, ask for 2 (Perform's
BREAK LOOPS). The state block wears the Break hatch and counts down the seconds
remaining, and so does the Break tile, so you always know when it is coming
back.

It **mutes, never stops**: the engine, the MIDI clock and Live's sync are
untouched, so the loop comes back precisely where it would have been.

**The break tells Live about itself**, so the room can hear something change
rather than only hearing something leave. It sends **CC 100 on channel 16** out
through the same IAC bus as the clock: **0** the instant the hole opens, **127**
when the loop returns. Map that to a rack macro in Live — two Rhythmic Steps
devices on one macro, say — and the break swaps the pattern for exactly its own
length, with the original back on the downbeat.

The values are absolute rather than a toggle, so a macro nudged by hand is put
right by the next break instead of inverted for the rest of the set, and a break
cancelled by a stop or a clear still sends the 127. It is sent for every way of
striking a break — a footswitch, the button, or a cancel — because
it hangs off the looper's own break state and not off any one of those. Channel
16 is the same channel the proxied program changes land on, chosen for the same
reason: nothing the controller forwards can collide with it.

In Live: enable **Remote** for the IAC input under Preferences → Link/MIDI, then
MIDI-map the macro to CC 100 and map it to both devices' on/off switches, one
with its range inverted. That is how `megalooper-slave.als` does it: the main
device is on at 64–127 and the break device at 0–63, and the rack's chain
selector is not used.

A break silences everything the looper makes, the onset-note part included; a
break that left the drums playing in Live would not be a break. The state
block wears the Break hatch while one is open, because a deliberate silence and
genuinely broken audio otherwise look identical.

### GUI

megalooper is **one window**, laid out for a laptop screen (1440 × 900) and read
from playing distance: a top bar, Perform's status band, four views and a
footer.

```
┌ ∞ MEGALOOPER │ 1 Perform │ 2 Sound ■□ │ 3 FX □ │ 4 Drums □ │ 5 Setup □ │ CPU 14% │ ◐ │ ? │ RIG SA MIDI ● │ ■ MIDI MAP ⌘M │ ● SET REC 12:04 ┐
├────────────────┬──────────────────────────────────────────┬────────────────────┤
│ LOOPER STATE   │ TAKE · DETECTED                          │ INPUT              │
│ ▶ PLAYING      │ 7/8   103.2   2   Dm                     │ ▇▇▇▇▇▇▇▇▇░░ -9 dB  │  the status band
│ R → overdub    │ [or 7/4 @ 206.4?] close call: press A    │ ■ Onset thr 0.50   │  (Perform only)
├────────────────┴──────────────────────────────────────────┴────────────────────┤
│ BAR 2/2 · BEAT 3/7                                              2.44 / 8.14 s  │
│ │1 2 3 4 5 6 7│1 2 ▓ 4 5 6 7│ ← the beat under the playhead, in the state's colour
├──────┬────────┬────────┬─────────┬───────┬─────────────────────────────────────┤
│ Loop │ Cutter │ Grains │ Effects │ Drums │ ACTIONS · FOOTSWITCH                │
│[FWD] │ [ON]   │ [OFF]  │ [2 ON]  │[MAIN] │ Trigger  Stop   Break  Next reading │  Perform
│ ...  │ ...    │ ...    │ ...     │ ...   │ Dissolve Rec next loop Undo  Clear  │
│      │        │        │         │       │ MACROS · Master  Arc  Onset         │
├──────┴────────┴────────┴─────────┴───────┤                                     │
│ LEVELS · Guitar Loop Drums Onset kit Master (SA only, as on Setup)             │
├──────────────────────────────────────────┴─────────────────────────────────────┤
│ R trigger  S stop  M multiply  …                          Refused: nothing playing │  the footer
└────────────────────────────────────────────────────────────────────────────────┘
```

- **The top bar**, on every view: the logo, a Möbius loop whose twist
  travels round once a pass while the loop plays (and stands when it
  stops), the views' tabs (keys **1–5**, and **6**
  for the Calibrate wizard, which has no tab; each tab's squares light in its
  parts' colours while they run), the server's **CPU** (red past 60 %), **◐**
  (dark or light, key **T**, kept for the next boot; with the loop and Live's
  clock stopped, since the rebuild holds the language, and the clock, for
  65–80 ms), **?** (the help lines: the sentences that explain a page, hidden
  or shown together, key **H**, kept for the next boot), the rig and a lamp
  for MIDI arriving,
  **MIDI MAP** and **SET REC** — the set recorder, with the file it writes
  under it.
- **The status band**, on Perform: the **state block** (`EMPTY`, `● REC`,
  `▶ PLAYING`, `● OVERDUB`, `■ STOPPED`, filled in the state's colour, and the
  Break hatch while a break is open) with what R does next; the **take** —
  signature, BPM, bars, key, and the reading chip (`or 7/4 @ 206.4?` on a close
  call, `→ 7/4 · lands in 1 loop` while a reading is armed) with **Revert**;
  the **input** — the level in dB and the **onset lamp**; and the **bar grid**,
  a cell per beat with the bar lines in ink and the beat under the playhead
  filled. On every other view it folds into a 56 px **strip** — state, take,
  position, lamp and meter — so they never leave the screen.
- **The views**:

| View | Key | What lives there |
|---|---|---|
| **Perform** | 1 | A column per layer — **Loop** (forward/reverse, feedback, length, ×2), **Cutter** (on/off, Mix/Insert/Gate, the arc-driven parameter with its tick), **Grains** (on/off, morph, level) and on Megalooper SA **Effects** and **Drums** — then the **actions** (Trigger, Stop, Break, Next reading, Dissolve, Rec next loop, Undo, Clear, each with its key and footswitch), Break loops and Dissolve bars, and the **macros**: Master, Arc, Onset |
| **Sound** | 2 | The **Cutter** (preset, voices, procedure, cut synth, ratio, parameters, level, pan, voice effects) beside the **Grains** (preset, Blend, Pitch, Grain, Read position, grain window) |
| **FX** | 3 | Megalooper SA only: the **effects** chains (click a block to edit it, its square to switch it) and their sounds |
| **Drums** | 4 | Megalooper SA only: the **drums** (step sequencer, timing, kits, mix) |
| **Setup** | 5 | **Analysis** (monitor, counts, threshold, overdub detection, onset notes, pitch, fallback meter, export) · **Rig** (profile, device, analysis input, input, Live transport, the three timing bars, SA's levels, the MIDI map) · **Calibrate** (where the wizard is) and **MIDI in** |
| **Calibrate** | 6 | The wizard, step by step; Esc goes back to Setup |

- **The footer**: the keys, and one status line — `Refused: …` in red when the
  looper would not do what was asked (from a key, a click or a footswitch),
  what MIDI has to say, or "Typing…" while a name field has the keyboard.

Everything shown is painted from a model notification, never from the click,
so a refused action reports honestly — asking for the cutter with no loop
recorded leaves its switch dark and its tab's square empty, and the footer
says why. Panes are built once and kept alive; switching views only changes
which one shows, so a MIDI CC arriving while you look at another view still
moves the right bar. Every pane but Perform's effects is inside a
`ScrollView`, so a smaller screen scrolls.

**Colour means one thing.** The layers' colours (loop blue, cutter violet,
grains cyan, effects pink, drums yellow) mark which part a control belongs to;
the states' (rec red, play green, overdub orange, armed amber) fill the state
block, the beat under the playhead and a tile that is live, nowhere else. A
layer that is off loses its colour. MIDI Map's blue is its own.

**Fonts.** The design is set in Nitti Grotesk and Nitti. Installed in Font Book,
megalooper uses them; without them it falls back to the system's sans and mono
at the same sizes.

The controls, by view:

- **Live transport** *(Setup)* — how the looper drives Live's transport:
  - *Start + Stop* (default): send MIDI Start on play, MIDI Stop on stop.
  - *Start only*: send MIDI Start, never send Stop. Live keeps running after the
    looper stops. MIDI Clock keeps flowing so Live's external sync stays alive.
  - *Don't touch*: send nothing. Live is fully decoupled.
- **Input** *(Setup)* — *Mono* (default) or *Stereo*. In mono mode the looper
  reads `inChannel` only and duplicates it to both buffer channels so the
  output is audible on both ears. In stereo mode it reads `inChannel` and
  `inChannel + 1` independently. Takes effect on the next record or play.
- **Listen for onsets on** *(Setup)* — which input the onset and pitch detection listens
  to. *Clean tap* reads the guitar's **dry hardware input** directly off the
  shared audio device, with Live nowhere in the path; *Same as input* analyses
  the processed guitar being recorded, as older versions always did. Only the
  analysis moves — the loop is recorded from `inChannel` either way. Distortion
  and ambient FX smear note attacks, and blurred onsets are the main cause of
  meter mis-detection, so the dry tap is the better default where the rig
  exposes one. If a take reports 0 onsets while recording fine, the tap is on
  the wrong channel — the post window says so. The recorder also compares the
  tap's peak with the recorded input's over every take and warns when the tap
  sits 30 dB or more below it: a tap that quiet still yields a few onsets at a
  low threshold, and the meter fitted to them is noise — fix the gain, not the
  threshold. See [docs/routing.md](routing.md).
- **Master** *(Perform's macros)* — final post-limiter gain (0–1).
- **Morph** *(Perform's Grains column)* — between frozen drone (0) and pulsed scan
  locked to the detected pulse (1). Mirrors the Grains' Morph on Sound (CC 118 in the
  keys-and-knobs map); moving either updates both. Sound holds the rest of the layer.
- **Overdub latency** *(Setup)* — round-trip latency compensation (0–100 ms).
  See "Calibrating overdub latency" below.
- **Live sync** *(Setup)* — bipolar MIDI-clock offset (±150 ms, centre 0).
  Shifts when the MIDI Start/clock is sent so Live's downbeat lines up with the
  loop instead of lagging ~10–20 ms; negative pulls Live earlier. See "Live
  integration" below.
- **Feedback** *(Perform's Loop column)* — how much of the existing buffer content is preserved
  during overdub. `1.0` (default) is classic additive overdub: existing
  content stays at full level and the new input layers on top. `0.0` makes
  the overdub *replace* the existing content. Intermediate values fade the
  existing content by that amount per overdub pass (so e.g. `0.5` halves the
  existing audio each pass, useful for self-erasing layered patterns).
  Feedback only takes effect while overdubbing — pure playback always passes
  the buffer through untouched.

### The status band

The top of Perform (`scripts/gui-status.scd` builds and paints it) answers
"what is it doing right now" at a glance, and its strip keeps the answer on
every other view. It is **read-only** but for Revert — painted from model
notifications, so nothing here can be clicked into a state you didn't intend.

- **Bar grid** — a cell per beat, bar lines in ink, the beats played this pass
  shaded and the beat under the playhead filled in the state's colour (the
  hatch on a break), with `BAR 2/2 · BEAT 3/7` and `3.42 / 7.00 s` over it.
  Read straight off the engine's own phase bus at 20 Hz, so it cannot drift
  against the audio. With no meter detected it falls back to elapsed/total
  alone rather than inventing a beat. **Bar 1 beat 1 is where you pressed
  record** — the same downbeat Live's 1.1.1, the cutter's beat 0 and the
  break's resume use, so the four never disagree, even on a take that opens
  with a pickup. A meter detected from an overdub counts from the downbeat that
  detection chose, which is also where it started Live.
- **Take** — what the analyser decided: `7/8`, `103.2` BPM, `2` bars, the key;
  `TAKE · ANCHORED` when the loop fell back to the length-anchored meter, which
  is also the reason the cutter will refuse to start. When the analyser's
  runner-up scored close the chip says so — `or 7/4 @ 206.4?` — which is the
  take that wants the next-reading switch; while a reading is armed the chip is
  filled and counts down, `→ 7/4 @ 206.4 BPM · 2 bars · lands in 1 loop`, and
  once one is in force it says which, `reading 2/5`. See
  [The next reading](#the-next-reading).
- **Input** — the level, off the analysis monitor's feed, in dB. The first
  answer to "is the guitar getting through at all", so it is never behind a
  view.
- **State** — the block: `EMPTY`, `● REC`, `▶ PLAYING`, `● OVERDUB` or
  `■ STOPPED`, filled so recording and overdub are unmistakable across a room,
  and the Break hatch while a break is open.

**MIDI in** (Setup) is a scrolling monitor of incoming note / CC / program
messages, the same lines the post window shows. **Pause** freezes it while you
read; **Clear** empties it. It keeps the last 200 lines and repaints at 10 Hz
while Setup shows, so a CC sweep can't stall the GUI. `~midiLog` silences only
the **post window** — the monitor always receives, which is the point: you can
stop the post spam and still watch the controller. The top bar's lamp lights on
every message, whichever view shows.

### Onset analysis

`MeterAnalyzer` never hears audio — only onset times. So when detection admits
ghost onsets or misses real hits, meter detection fails and the loop drops to the
anchored fallback meter. That is the documented root cause of straight 4/4 takes
coming out 7/8, and the **onset threshold** is the lever. Tuning it is something
you do *while playing*, so the two controls that matter are on Perform — the
lamp in the status band, the threshold among the macros — and the rest is in
Setup's Analysis column (`scripts/gui-analysis.scd`).

On **Perform**:

- **Onset lamp** — a light that flashes for ~200 ms every time the detector
  fires at the current threshold. Flashes *between* notes mean ghosts (raise the
  threshold); a hit that leaves the lamp dark means it's too high. If it never
  flashes at all, check the input meter above it: a flat meter means the
  analysis input is silent (wrong channel), not that the threshold is wrong.
- **Onset** macro, the threshold (0.01–2.0, default **0.5**), also **MIDI CC 7** —
  live on both the monitor *and* a running recorder, so you tune against what
  you're playing and the next take detects exactly what you just saw. The
  travel is **exponential**: a nudge of 1% of the slider moves the threshold by
  about 5% of wherever it currently is, so it feels the same at 0.05 as at 1.0.
  On the old linear slider every setting worth telling apart was crammed into
  the first tenth of the travel. The trade is a coarser top end, which is the
  end nobody tunes in; the default 0.5 sits at about three quarters across.

In **Setup's Analysis column**:

- **Monitor** toggle — a free-running detection chain that mirrors the recorder's
  exactly (same input, odf type, `mingap`, threshold). It needs no loop and no
  transport, so you can set the threshold *before* committing a take. Starts when
  the window opens and stops when it closes, so it costs nothing when unused.
- **Readout** — input peak in dB, onsets counted since the last reset, and the
  strength of the most recent onset (the same salience value `MeterAnalyzer`'s
  accent test sees).

- **Onset notes** — sends the loop's onsets to Live as MIDI. See
  [Onset notes](#onset-notes) below.

The threshold is also an optional per-rig profile field, `onsetThreshold`,
alongside `latencyMs` and `abletonSyncMs` — how noisy the guitar input is depends
on the interface and the tap. Tune it here, then write the number back into the
profile.

> **Why a lamp and not a waveform.** This pane used to draw a scrolling envelope
> with the onsets marked on it. It was the most expensive thing in the GUI — 120
> `Pen` calls per repaint off a 60 Hz feed, measured wrecking the language-side
> MIDI clock whenever the tab was on screen — and it answered only the one question the lamp answers
> directly. Plotting the *detection function* instead would have been worth the
> cost, but it isn't available: `Onsets` whitens its odf before comparing it to
> the threshold, so the UGen's `rawodf` output is on a different scale entirely
> (measured here: raw odf averaged ~1.4 while a threshold of 0.5 was firing only
> on real hits). Drawing that against the threshold would look informative and
> be wrong.
>
> The monitor synth reports on two clocks to make this cheap: the input level at
> **15 Hz** (enough for a meter) and each onset on its **own trigger**, one OSC
> message per hit. Sending onsets as a flag polled at the level rate is what used
> to force that rate up; on their own trigger they can't be missed by frame
> quantisation or merged when two land in one frame.

### Overdub meter detection

For loops that open atmospheric. Take one has no attacks, so no meter is found
and Live's transport is never started — correct, there is no beat to follow.
Turn on **Overdub detect** in the analysis window, overdub a rhythmic pattern,
and the meter is derived from *that* instead, then Live is started.

- **Runs on `endOverdub`**, and only while the loop still has **no valid meter**
  (a length-anchored fallback counts as none). Without that gate every overdub
  would re-tempo Live mid-performance.
- **Detect now** forces a re-analysis of the last overdub's onsets past that
  gate. The quality guards below still apply.
- Onsets arrive already in **loop coordinates**: the engine publishes its read
  position on a control bus and the analyser latches it at each onset, so
  several loop passes fold onto one grid with no clock arithmetic — and playing
  the pattern a few times *strengthens* the grid rather than flooding it. Hits
  within 30 ms of each other merge, keeping the loudest reading.
- The loop is **never resized**; there is already audio in it. Instead the tempo
  is forced to divide the existing loop exactly (`tau = loopDur / n`). A tempo a
  hair off the loop length drifts against Live over a few minutes.
- **Live starts on the detected downbeat**, not immediately — the transport start
  is held until the loop next reaches that phase, so Live's 1.1.1 lands on the
  music rather than wherever the analysis happened to finish.

Two guards make this safe, and they exist because widening the search breaks
things in both directions:

| Setting | Default | Why |
| --- | --- | --- |
| `overdubMaxBars` | 8 | The default 4-bar enumeration cannot describe a long pad. Measured: a 12 s loop at 120 BPM in 4/4 (**six** bars) is reported as *12/8 at 60 BPM* — confidently wrong — until the limit is raised. First-take detection keeps the tighter default. |
| `overdubMinDensity` | 0.5 | A fine grid will always "fit" a few scattered onsets. At no density, five rubato onsets came out as *7/4*. Measured on synthetic patterns: 0.5 admits real playing and rejects rubato; 0.6 starts rejecting genuine syncopation. |
| `overdubMinOnsets` | 8 | An absolute floor before detection is even attempted. |

Both thresholds are **provisional** — tuned against synthetic onset patterns, not
real playing, exactly like the onset threshold itself.

### The next reading

The analyser scores every meter that fits a take and keeps the ranked list, not
only the winner. On realistic takes the winner is right about half the time,
and when it is wrong the runner-up is the truth in a third of the cases. So the recovery for a
wrong meter is one footswitch: **Program Change 19 (the TSMega's map), key `A`, or
the Next reading tile on Perform** moves the take to the reading
that scored second. Press it again and it moves on to the third; past the last
it comes round to the analyser's own answer, so one switch always gets you
back. **Revert**, beside the reading chip, goes straight home.

What it changes and what it leaves alone:

- The **audio never changes**, and neither does the onset-note drum part —
  those are the hits you played, and they never looked at the meter.
- The **cutter** follows the new grid. A reading that keeps the pulse and the
  pulse count (7/8 read as 7/4, or two bars of 6/8 read as one of 12/8) leaves
  it running untouched; one that changes the pulse (12/8 read as 4/4) respawns
  it on the boundary, with no hole in front of it.
- The **grains** take the new pulse at once; the **dissolve** counts the new
  bar from its next arming; the **status band** shows the new take.
- **Live** gets the new tempo and signature the way an analysis delivers them,
  and the MIDI clock moves to the new period from that tick.

**It lands on a loop boundary, never on the press**, and the reading chip counts
down to it, so the bass player hears it coming the way a break is heard. Which
boundary: Live counts bars in MIDI-clock ticks from the Start it received, and a
reading that changes how many quarter notes a loop holds makes Live's bar line
meet the loop boundary only every so many loops. The looper knows the tick
count, so it picks the first of the next three boundaries where Live's bar line
will fall — usually the very next one — and lands there without restarting
Live. If no boundary in reach lines up it lands on the next one and sends Start
again, the same relocation the first take does; **while the set is being
recorded no Start is sent**, because a Start would overwrite the take, and Live's
bar line is left where it falls with the tempo still right.

Refused, with a line in the post window and nothing lit: when nothing is
playing, and on a take that fit no grid, because the length-anchored fallback
has no next reading to offer. A stop, a clear, a new take or an undo cancels a
reading that has not landed.

`mingap` (currently 20 frames, ~107 ms — the minimum spacing between onsets) is
deliberately *not* exposed: `Onsets` sizes internal state from it, so it is not
safe to change on a running synth. Edit it in `Looper.loadSynthDefs` if you need
to, in **both** the recorder and the monitor or the lamp starts lying.

## Onset notes

The onsets `MeterAnalyzer` fits its grid to are also, straightforwardly, a drum
part — they are exactly where the attacks were. Turn on **Onset notes** in the
onset analysis window and they go out of `midiOut` as MIDI notes, once per loop
pass, so Live can trigger a Drum Rack or sampler from the rhythm you played.

### It replays the loop, it does not track your hands

This is a **stored pattern**, built once when a take is analysed and then
repeated in lockstep with the audio — not a live trigger off the detector. That
is the more useful of the two for a looper:

- It keeps playing when you stop playing, which a live trigger cannot.
- It repeats *exactly*, so what Live receives on pass 40 is what it received on
  pass 1.
- It carries none of the detector's ~15–25 ms latency: the pattern is scheduled
  against `loopStartTime`, the wall-clock moment the loop's audio actually leaves
  the server, and `~midiOut.latency` is 0, so each
  note is sent as its own audio is heard.

The pattern comes from the same onsets the meter was fitted to. For a loop whose
**first take had no attacks at all**, it comes instead from the overdub that gave
it its meter — so turning on [Overdub meter detection](#overdub-meter-detection)
also gets an atmospheric loop a drum part.

### Controls

| Control | Default | What it does |
| --- | --- | --- |
| **Onset notes** | off | Toggle. Starts and stops with the loop; stopping releases any note still gated, so nothing hangs in Live. |
| **Note** | 36 (C1) | The note every onset sends. Octaves are numbered **as Live numbers them** (middle C = C3), so 36 is the Drum Rack's first pad, not SC's C2. |
| **Ch** | 2 | MIDI channel, shown 1–16 as Live shows it. Defaults to **2**, which is where the rigs here are already mapped; the notes are the only ones megalooper sends down the IAC bus. |
| **Vel** | 40–127 | Velocity of the quietest and loudest hit. |
| **Dynamics** | 30 dB | How far below the loop's loudest hit maps to the minimum velocity. Small = compressed, large = wide. |
| **Offset** | 0 ms | Timing trim, **negative sends the notes earlier**. Per-rig — see below. Takes effect on the next hit, so dial it while the loop runs. |
| **Gate** | 20 ms | How long each note is held. Drum racks and one-shot samplers ignore it; a gated synth or pad does not. Shortened automatically so a gate can never run into the next hit. |
| **Chance** | 100% | How likely each onset is to be sent. See [Thinning the part](#thinning-the-part) below. |

The readout beside the toggle shows how many hits are in the pattern and how long
one pass of it is — and, once Chance is below 100%, how many of them are actually
playing.

### Thinning the part

Guitar picking is usually busier than the drum part you want out of it. **Chance**
is the slider for that: at 100% every onset is sent, at 50% about half of them,
at 0% none. Nothing is edited — the analysed pattern is left whole, so sweeping
back up to 100% returns exactly what you played.

The dice are thrown **once per take**, not once per pass. That matters, and it is
the one thing to understand about this control:

- The thinned part still **repeats exactly**, pass after pass, like the full one
  does. That is the property the whole feature rests on, and a per-pass re-roll
  would have thrown it away for a drum part that changed every time round.
- The slider is therefore **monotonic**: 50% → 60% *adds* hits, it does not
  reshuffle the ones already sounding. You can dial it against the loop and hear
  the part fill in rather than scramble.
- To get a *different* subset at the same density, press **Re-roll**. It touches
  nothing but which hits sound — same pattern, same timing, same audio.

A new take rolls fresh dice, and undo restores the take's own roll along with its
audio, so an undone loop comes back with the part you were hearing.

Chance is read per hit as the note is sent, so moving the slider or re-rolling
lands on the next hit — no rebuild, no restart, and the pattern never loses phase
against the audio.

### Velocity

Velocity is mapped from each onset's strength — the same salience value the
accent analysis uses — **relative to the loudest hit in that loop**, over the
Dynamics window in dB. Two consequences worth knowing:

- It is **gain-independent**. Moving the interface's input trim does not change
  the velocities, because nothing here is an absolute amplitude.
- It is **dB, not linear**. Linear on amplitude piles nearly every guitar onset
  into the top of the velocity range; in dB the dynamics read the way they
  sounded.

The velocity controls are evaluated per note as it is sent, so changing any of
them takes effect on the very next hit — no rebuild, no restart, no gap.

### Setting Live up

Arm a MIDI track, set its input to the same IAC bus megalooper's MIDI Clock goes
to, set its input **channel to 2**, and drop a Drum Rack on it. With the defaults
the hits land on the Rack's first pad.

Set the channel rather than leaving the track on *All*: the break's macro CC
(channel 16) goes down the same bus, and a track listening to everything will
also see it.

### Lining the notes up

The loop's audio and its notes do **not** travel the same path, so they do not
arrive together and no default can be right for every rig:

- The **loop** goes SC → the virtual device → Live's input buffer → Live → out.
  That is two buffers the notes never see, plus whatever the set's plugin delay
  compensation adds.
- The **notes** go SC → IAC → Live, where they are quantised to Live's next audio
  block and then trigger a sampler.

Both are scheduled from the same origin — `loopStartTime`, the wall-clock moment
the loop's audio starts — so what is left is a fixed per-rig difference. That is
what **Offset** is for, and it is the same kind of number as "Overdub lat" and
"Live sync": set by ear, then written back into the profile as
`onsetNoteOffsetMs`.

Guessing at it by ear is hard, because a 10–20 ms flam is easier to hear than to
size. To **measure** it instead, record both signals in Live and read the gap off
the waveform:

1. Arm one audio track recording the loop (SC's output pair, 11/12) and one
   recording the drum rack's output.
2. Play a loop with the onset notes on, and record a few passes.
3. Zoom in on a hit that appears in both, and measure the distance between the
   two transients.
4. If the drum hit is **later** than the loop transient by *n* ms, set Offset to
   **−*n***. Re-record and confirm it closed.

### Across multiply, undo and loop chaining

The pattern keeps **its own period** — the loop length it was built for — rather
than following `loopFrames`. Multiply and loop chaining both lengthen the loop by
a whole-number factor and copy the audio with it, so a pattern at the original
period tiles across the longer loop exactly as the audio does. Undo snapshots and
restores the pattern with the buffer, so undoing a take does not leave the
previous take's rhythm playing over it.

Two things follow from the pattern being tied to an analysis:

- A **loop chained** over another inherits the old pattern, because chaining
  records without analysing. The captured audio contains the old loop, so the
  rhythm is still in there — but it describes the take underneath, not what you
  just played over it.
- The **onset threshold is the ceiling on quality**. Ghost onsets become ghost
  notes and missed hits become missing ones, so this is one more reason to tune
  the threshold against the onset lamp in the status band.

## Granular layer

Press `G` to toggle a parallel granular voice using SuperCollider's `Warp1`
UGen, sourced from the recorded loop region.

### Morph: the meta-control

One parameter, on the main window's **Granular** slider (and CC 118 in the
keys-and-knobs map), slides between two poles:

- **Morph = 0** — Frozen drone: long (~0.4 s) grains, heavily overlapped, with
  a static pointer plus tiny jitter. A smear of one moment in the loop.
- **Morph = 1** — Pulsed scan: grain window equals the detected `tau` (one
  beat), no overlap, pointer scans through the loop region in one full pass
  per `loopDur`. Grain N reads from beat N of the recording, so the rhythm of
  the granulator matches the rhythm of what was played. The scan is read off
  the dry engine's own playhead, so it is locked to the loop by construction:
  toggle the layer on wherever you like, mid-pass or not, and the pulse lands
  on the loop's own hits every time. (Before 2026-09-25 it free-ran from the
  moment of the toggle, and each toggle put it somewhere else.) Over a stopped
  loop there is no playhead to follow and the scan runs free until play starts.

Everything in between is a continuous lerp of the four underlying parameters
(window size, overlaps, scan rate, jitter). A 100 ms lag smooths the CC stream.

### Granular layer

Morph is a great *performance* control and a poor *sound-design* one: it moves
four things at once and there is no way to ask it for "the pulsed grid, but an
octave down and sprayed loose". So the Grains, on the Sound view
(`scripts/gui-granular.scd`; key 2, or the Grains column's name on Perform), expose
the rest of the granulator, and morph keeps its job — it sets the **base** of the
texture, and every control here **bends that base**.

Every default is **neutral**: with all of them untouched the layer sounds exactly
as it did when morph was the only control. **Reset tweaks** puts them all back
without disturbing morph itself.

| Control | Range | What it does |
| --- | --- | --- |
| **Level** | 0–1 (0.7) | Granular level, summed with the engine before the master limiter. Was previously fixed. |
| **Pitch** | ±24 st | Grain transposition. The read pointer is untouched, so this pitches the layer *without* changing how fast it moves through the loop. |
| **Detune** | 0–12 st | Random detune redrawn for **every grain**. Under ~0.2 st it thickens like a chorus; a few semitones shatters the loop into pitched confetti. |
| **Grain size** | ⅛–8 × | Grain length as a multiple of morph's (0.4 s drone, one beat pulsed). Below ~0.2× grains stop carrying pitch and read as texture. |
| **Density** | ¼–4 × | Overlapping grain count, as a multiple of morph's (6 drone, 1 pulsed). Thickness — and the CPU bill. |
| **Size rand** | 0–1 (0.1) | `Warp1`'s `windowRandRatio`: how much grain *length* varies grain to grain. A little breaks up the comb filtering perfectly regular overlaps produce. |
| **Window** | 4 shapes | Grain envelope: **Hann** (Warp1's own), **Plateau** (flat top — thicker drones, harder pulses), **Percussive** (instant attack, long decay — this is what makes the pulsed end read as *rhythm*), **Swell** (attacks erased; even a plucked loop smears into pad). |
| **Position** | 0–1 | Where in the loop grains read from. At the drone end this **is** the freeze point — sweep it to walk the drone through the recording by hand. Wraps, so it can never read past the loop's end. |
| **Scan** | ±2 /loop | **Extra** passes through the loop per loop duration, added to morph's own. Small values drift a frozen drone; negative runs the read head backwards; −1 exactly freezes a fully pulsed scan. |
| **Spray** | 0–500 ms | Per-grain read-position randomness. Unlike morph's own jitter this survives at the pulsed end — it is how you loosen a locked grid without giving up the beat. |

### Presets

The preset bar at the top of the Grains stores the whole voice — morph
plus every control below it, including the window shape — under a name. It works
the same way the cutter's does, deliberately, so the two windows share muscle
memory.

- **Save** writes `granular/<name>.scd` in your megalooper folder
  (`~/Library/Application Support/SuperCollider/megalooper/`). The name is slugged, so "Frozen
  Cathedral" becomes `frozen-cathedral.scd`; typing a new name is how you "save
  as". Saving back the preset you *loaded* is one click — the button reads
  **Save** — because the file it replaces is the one you have open. Typing the
  name of a preset you did **not** load reads **Overwrite** and takes a second
  click; that confirmation waits as long as you do.
- **Recall** is a single click in the preset menu and applies **live** — a
  running granular layer follows without stopping, because every value is written
  through the model's setters straight to the playing synth. Recalling with the
  layer off just loads the settings, and they are used the next time you press
  `G`.
- **Revert** re-reads the selected preset from disk, discarding edits since it
  was loaded. **Delete** removes the file (two clicks). **↻** rescans the folder
  for files added outside megalooper.
- Preset files are plain SuperCollider literals, safe to hand-edit or commit.
  Out-of-range numbers are clipped, non-numbers and missing fields fall back to
  their defaults, and an unrecognised window shape falls back to Hann — all with
  one summary warning in the post window. Only a file that isn't a preset at all
  is refused, and then the granulator is untouched. A file saved by a newer
  version of megalooper is refused rather than half-understood.
- The **window shape is stored by name**, not by index, so adding a shape in a
  later version cannot silently re-point presets saved before it.

> Recall **includes morph**, unlike **Reset tweaks** which deliberately leaves it
> alone: a preset is "this exact sound", where Reset is "undo my edits". Note
> that morph, level, pitch, grain size, density and position are also on MIDI
> CCs — a recall moves the values but not your faders, so those are stale until
> you next touch them.

### How the controls combine

Two conventions are worth knowing, because they are why the controls behave the
way they do:

- **Multiplicative where morph's base is never zero** (size, density),
  **additive where it is zero at one pole** (scan, spray). A multiplier on scan
  would be dead exactly where you want it: no amount of scaling gets a frozen
  drone to drift.
- The two multipliers have **geometric ranges centred on 1×** (⅛–8, ¼–4), so the
  middle of the slider — and CC 64 — is neutral. An off-centre neutral makes a
  multiplier impossible to return to by feel.

Density is clipped at **16 overlaps** in the SynthDef. `Warp1` runs one grain
stream per overlap and this is the parameter that runs the server up; 16 is
already past musically useful, and the clip keeps a full-tilt slider from
stalling the audio thread mid-take.

Grain interpolation is **cubic** (`Warp1`'s `interp: 4`). It was `1` (none),
which was fine while the layer only ever played at unity rate; with
transposition exposed, no interpolation aliases audibly.

The pane is a view like any other: sliders write to the model only, and the
`SimpleController` in `gui-wiring.scd` writes back. That is what keeps a MIDI CC,
the Reset button and the slider itself all showing the same number — including
while the Sound view is hidden, because panes are built once and kept alive
rather than rebuilt on every view switch. Rebuild it alone with
`~buildGranularPane.()` followed by `~wireLooperController.()`; the loop and a
running granular layer are both untouched.

## BBCut layer

Press `B` (or the TSMega's Program Change 18, or click the BBCut button
in the GUI) to algorithmically re-splice the current loop, in tempo, using
[Nick Collins's BBCut library](https://github.com/nhthn/BBCut). When BBCut is
on, the straight engine output is muted; you hear cuts of the loop instead.

The cutter is a **multi-voice instrument**: each voice is an independent cutter
(its own procedure, cut synth, effects, and clock) layered over one shared
snapshot of the loop. Full controls live in the **BBCut window** (open it with
the "Voices / procs / fx…" button in the main window).

- **Polyrhythm** — each voice runs on its own clock at `baseBps × ratio`, where
  `baseBps = 1 / tau` (one tick per detected pulse) and `ratio` is chosen per
  voice (`1:1`, `3:2`, `2:3`, `4:3`, `3:4`, `1:2`, `2:1`). All voices are
  phase-aligned to the same loop downbeat at start, so non-unity ratios produce
  true cross-rhythm. Add/remove voices in the BBCut window (up to 4).
- **Cut procedure** (per voice) — choose from a curated set: **Break/Repeat
  (guitar)** (the default, see below), **BBCutProc11** (d&b-derived 3+3+2
  splicing), **WarpCutProc1** (Warp-Records pitched rolls), **ChooseCutProc**
  (cut/repeat/roll chooser), **SQPusher1** (Squarepusher-style drum
  programming). The proc's own parameters are rendered as controls; for
  Break/Repeat, BBCutProc11 and ChooseCutProc they update live at the next
  phrase, others rebuild the voice on change.
- **Cut synth** (per voice) — **CutBuf1** (cheap head-jumping, no envelope),
  **CutBuf2** (enveloped grain per cut, default), **CutBuf3** (uses the buffer's
  analysed event positions).
- **Effects** (per voice) — toggle any of **Bit** (decimator), **Comb**, **BPF**,
  **BRF**, **Mod** (ring mod), **Rev** (reverb); inserted between the cut synth
  and the voice mixer.
- **Amp / Pan** (per voice) — live via the voice's `CutMixer` (no rebuild).
- The cut buffer's `beatlength` is the total pulse count in the loop
  (`numerator × sub × k`). For 7/8 (one bar) that's 7 beats.
- **Phrase** is in **beats** on every procedure, as an integer-stepped slider.
  Break/Repeat and BBCutProc11 additionally *snap* it to a whole number of loop
  passes, because both read repeats at `phrasepos % beatlength` while
  `phrasepos` resets to zero each phrase — a partial pass would restart the
  cutter's read head mid-loop and pull it out of alignment with the dry loop.
  Warp and Choose take the beat count literally; they cut continuously rather
  than tracking the dry loop, so nothing depends on the alignment.
- Phase-aligned: BBCut starts on the next loop downbeat.
- Snapshot semantics: enabling BBCut captures the current loop region to a
  temp WAV (`/tmp/megalooper_bbcut.wav`). Subsequent overdubs/multiply/undo
  do **not** refresh the snapshot — toggle off and on again to pick up new
  audio. Structural changes (proc/synth/fx/ratio, add/remove voice) while the
  cutter is on rebuild it in place. Re-recording or clearing the loop turns
  BBCut off automatically.
- Each voice's clock is independent of the MIDI Clock sent to Live, so over many
  bars they can phase-drift if the analyzer BPM is slightly off.

### Break/Repeat — the guitar-oriented cut procedure

The classic BBCut procedures chop continuously, which suits a drum break but
buries a played loop. `LooperBreakProc` (menu name **Break/Repeat (guitar)**,
the default for a new voice) inverts that: it mostly lets the loop through
untouched and only now and then grabs a block and repeats it, like stepping on
a beat-repeat pedal for a bar.

| Control | What it does |
| --- | --- |
| **Cut chance** | Probability, rolled once per block, that a repeat happens at all. 0 leaves the loop completely alone; 0.25 gives an occasional interruption; 1 repeats continuously. |
| **Min / Max block** | Size of the repeated chunk, in pulses (loop beats), 1–16. Set them equal for a fixed size, spread them for variety. This is what makes big repeats possible — a whole bar rather than a stutter. |
| **Repeats** | How many times the chunk plays. 2 = it plays, then repeats once. |
| **Phrase** | Phrase length in loop passes (1–4). Raise it when a long block will not fit inside one pass of the loop. |
| **Roll chance** | Probability that a repeat comes out as a double-speed roll instead of a plain repeat. Leave at 0 for straight beat-repeat behaviour. |

How it interacts with the mix mode: a block that is *not* cut is emitted as a
single cut, which the mixer and the insert gate both read as "no repetition".
So in **Mix** and **Insert** the cutter stays silent between breaks and you hear
your dry loop; in **Gate** the cutter plays the straight blocks itself, so the
loop is continuous either way.

Repeats replay the audio at the block's own position in the loop, and the
phrase is pinned to a whole number of loop passes, so the cutter stays lined up
with the dry loop before and after a break. A repeat that would overrun the
phrase end is fitted in by dropping repeats first and only then trimming the
chunk (possibly below **Min block**) — without that, on a short loop most
breaks would silently vanish and Cut chance would read far lower than it is set.

Every parameter is live: changes take effect at the next block with no rebuild.

### Presets

The preset bar at the top of the BBCut window stores a whole cutter setup —
every voice (procedure, cut synth, effects, ratio, amp, pan and all proc
parameters) plus the Mix/Insert/Gate mode — under a name.

- **Save** writes `bbcut/<name>.scd` in your megalooper folder
  (`~/Library/Application Support/SuperCollider/megalooper/`). The name is slugged, so
  "Broken 3/2" becomes `broken-3-2.scd`; typing a new name is how you "save as".
  Saving back the preset you *loaded* is one click (**Save**); typing the name
  of a preset you did **not** load reads **Overwrite** and takes a second click,
  which waits as long as you do.
- **Recall** is a single click in the preset menu, and applies **live**: voices
  are added/removed to match and each is rebuilt on the next beat. The dry loop
  keeps playing, the cut buffer is not re-written, and nothing is torn down.
  Recalling with the cutter off just loads the settings.
- **Revert** re-reads the selected preset from disk, discarding edits since it
  was loaded. **Delete** removes the file (two clicks) and leaves the running
  cutter alone. **↻** rescans the folder for files added outside megalooper.
- Preset files are plain SuperCollider literals, safe to hand-edit or commit.
  Unknown procedures/synths/effects, out-of-range numbers, parameters left over
  from another procedure and missing parameters are all corrected on load, with
  one summary warning in the post window; only a file that isn't a preset at all
  is refused, and then the running cutter is untouched. A file saved by a newer
  version of megalooper is refused rather than half-understood.
- A hand-edited `ratio` that isn't in the menu's list still plays as written; the
  menu just shows the nearest entry.

Requires the BBCut quark:

```supercollider
Quarks.install("https://github.com/nhthn/BBCut.git");
// then recompile the class library: Cmd+Shift+L
```

## Live integration

When AbletonOSC is installed and selected as a Control Surface in Live's
preferences, after every successful analysis megalooper pushes three OSC
messages to `127.0.0.1:11000`:

- `/live/song/set/tempo <bpm>`
- `/live/song/set/signature_numerator <num>`
- `/live/song/set/signature_denominator <denom>`

So Live's tempo and time signature follow the loop you just recorded. The loop's
[onset notes](#onset-notes) travel over the same IAC bus when enabled. MIDI
Clock is also emitted continuously while the looper plays — Live needs the
**EXT** button (next to the tempo display in the main toolbar) **on** to
follow it for transport sync, not just for the tempo display.

### Recording the set

Two recordings, because they answer to different clocks and are read by
different people — and beside them a log of what happened, which is what turns
the recordings into something that can be analysed afterwards.

**The archive — SuperCollider, from the stomp.** Program Change 20 (the TSMega's map), or
the **SET REC** tile in the top bar, writes three files into `sessions/`:

| File | What it is |
| --- | --- |
| `<stamp>-<tempo>-master.wav` | what the room heard — stereo, Live's master routed back to SC on `sessionChannel` |
| `<stamp>-<tempo>-tap.wav` | the dry guitar, mono, straight off the analysis tap |
| `<stamp>-<tempo>-events.jsonl` | what happened: every record press, every take with the onsets it was analysed from and the readings it was offered, every next-reading press and where it landed, every threshold change — one JSON object per line, times in seconds from the stomp |

**The names say what to set Live to**: `261007_143012-165.04bpm-7-8-master.wav`
is the set stomped at 14:30:12 on 7 Oct 2026, at 165.04 BPM in 7/8. The tempo
and the signature are the first in force while the set was recorded (the loop
playing when it began, or the first take, overdub detection or reading that
applied). They are not known until the set has a loop, so the files are written
under the stamp alone and renamed when the set stops. A set that never had a
tempo keeps `<stamp>-master.wav`. The stop also prints a line for Live: *"In
Live: 165.04 BPM, 7/8. Drop the files at 1.1.1."*

On **Megalooper SA** a set also leaves the parts of the mix as heard (`-guitar`,
`-loop`, `-drums` and `-onset.wav`, after their faders, so they sum to the
master) and `-drums.mid`, every drum hit for Live's own racks. Their names carry the tempo and
signature to set Live to before you drag them in.

It has **no relationship to the transport**, which is the whole point: it is
already running while you play the take that *produces* the first loop, and
Live's arrangement cannot be. Every file of a set starts from the same server
block, so they line up against each other to the sample. The master and the
tap are int24 WAV; SA's stems are 32-bit float.

The dry tap is not there to listen to. It is there so onset detection can be
re-run offline at any threshold — every gig becomes labelled corpus, which is
the largest lever on meter detection that does not involve touching
`MeterAnalyzer`. The event log is what makes that possible: without it the tap
is audio nobody can place a take in, which is what the sets recorded before it
existed turned out to be. See [Replaying a set](#replaying-a-set).

`sessionChannel` is set on **`\bhTsMega`** (BlackHole 1–2) and nil on the other
profiles, because it needs a matching track in the Ableton set — **Audio From:
Resampling, Monitor: In, Audio To: Ext. Out 1/2** — and a rig with the number
set but not the track records silence into the master file. See
[docs/routing.md](routing.md) for the setup. Where it is nil the recorder
writes the dry tap alone and the SET REC tile says
*"dry tap + events only"*.

**The production copy — Live's arrangement, from the transport.** A *separate*
footswitch, **Program Change 21**, arms Live's Arrangement Record over AbletonOSC
(`/live/song/set/record_mode`), so Live starts recording the moment megalooper
starts the transport. That gives you every track separately plus the onset-note
MIDI, so drum racks can be swapped and the set mixed afterwards.

Two switches rather than one, because the two recorders cannot start at the same
moment: PC 20 begins writing instantly, PC 21 can only arm. Wiring them together
would have made one switch lie about the other. **For a set you mean to keep,
press both.**

Live's record state here is *optimistic* — megalooper posts what it last sent
and never reads Live back, so toggling the button by hand in Live desyncs the
footswitch, and one more press puts it right.

It cannot start earlier, and this is not an implementation gap:

> **Live's 1.1.1 is defined by the first loop.** megalooper is the phase master —
> it cannot send MIDI Start until it knows the tempo *and* where the downbeat
> falls, and it knows neither until a take has been committed. There is no grid
> to record against before the loop exists.

What megalooper does guarantee is that the recording is never destroyed once it
starts. MIDI Start relocates Live to its cue point, so **while a session
recording is running and the clock is already going, a later analysis keeps its
tempo to itself** — the loop plays, the meter is detected, the readouts update,
and the transport is left alone. Without that guard, recording a second take
mid-set would jump Live back to 1.1.1 and overwrite the arrangement.

### Replaying a set

`scripts/replay-session.scd` reads a set's event log, cuts every take out of the
dry tap at the press, renders it through the recorder's own onset chain in
scsynth non-realtime at a sweep of thresholds, runs each onset list through
`MeterAnalyzer` and the Looper's own snapping, and reports which thresholds
would have agreed with you. No audio device is touched, so it can run beside
the playing instrument.

```
sclang scripts/replay-session.scd                # the newest set
~replaySession = "260928_183000";                # one set, by stamp, whatever tempo it was renamed with
~replayThresholds = [0.3, 0.5, 0.7];             # the sweep; the stage threshold is always added
~replayCsv = "/tmp/replay.csv";                  # every cell, for a spreadsheet
~replaySelfTest = true;                          # a synthetic set, rendered and asserted
```

The labels come from the [next reading](#the-next-reading) switch, and cost
nothing to collect:

| A take you… | is | and its label is |
| --- | --- | --- |
| played on as heard | **accepted** | the analyser's reading — a weak label: right, or wrong and not noticed |
| moved with the switch | **corrected** | the reading it settled on; the analyser was wrong on this take |
| moved and moved back | **reverted** | none; the analyser was wrong and the truth was not on its list |
| undid | **discarded** | none |

Per take the report shows what was heard on stage, what you settled on, and the
reading at every threshold; the summary counts, per threshold, how many
corrected takes come out right and how many accepted ones still agree, and
names the takes that come out wrong at every threshold — those are the
analyser's limit, not the threshold's. A reading with the same tempo and loop
under another barring, 2/4 in two bars against 4/4 in one, is shown as ≈ rather
than counted wrong: Live gets the same BPM and the loop the same pulse, only the
bar line differs. It also checks itself: at the threshold
that was in force on stage the replay should reproduce the stage reading, and
the fidelity line says on how many takes it did. First takes only for now; an
overdub detection folds its onsets onto the loop's phase, which the replay does
not reproduce, so those are listed and not scored.

Every take also gets a `logged` row: the onsets the stage heard, run through
today's analyser. A reading that moved there moved because the analyser
changed, not the threshold. A take whose tap peak sat 30 dB or more under the
recorded input is marked **STARVED** and counted in the summary — the recorder
warns about the same take live, and the threshold table means little for it.

A set started over a playing loop still yields that loop. The log's header
carries the take it came from — the raw length, the onsets from the press, the
analyser's answer and its list, the reading in force — and the report lists it
as *loop in force when the set began*: no audio to re-detect, but the stage
onsets go through today's analyser and the readings pressed during the set
label it like any other. Still, press **Record set before the first take**
whenever you can; only then is the take itself in the tap.

A tap recorded before the log existed can still be replayed with the takes
placed by hand — `~replayTap = "…-tap.wav"; ~replayManual = [[startSec, durSec], …]`
— but with nothing to score against; the report then shows readings only.

### Tightening Live's timing

Slaved to MIDI clock, Live's transport lands ~10–20 ms late (inherent to its
clock-follower). Two adjustable offsets pull it back:

- **Live sync (ms)** in the GUI (`~looper.abletonSyncMs`) shifts when SC sends
  the Start/clock relative to the loop. Negative pulls Live earlier. It's applied
  to the Start on the next play, and folded into the running clock stream live
  (Live's follower slews to it), so you can sweep it by ear against Live's
  metronome while a loop plays.
- Live's own **MIDI Clock Sync Delay** (Preferences → Link/Tempo/MIDI, per input)
  is the purpose-built per-input trim and can also go negative.

Dial either until the loop's downbeat sits on Live's click. (Ableton Link was
evaluated as an alternative but doesn't fit a looper-as-master workflow — Link is
peer-to-peer and can't let SC drive Live's phase.)

## Calibrating the rig — the wizard

The **Calibrate** tab walks the whole procedure one step at a time, which is
how a new interface gets its numbers without anyone having to remember this
document. It shows every step and which ones are answered, and for the step you
are on: why it exists, what has to be true in the room before you press
anything, and what to do.

| Step | Needs | Sets |
| --- | --- | --- |
| Check the rig | — | re-runs the device preflight |
| Onset threshold | the guitar | `onsetThreshold` |
| Overdub round trip | Live, and a cable from the main out into the guitar input | `latencyMs` |
| Live's downbeat | Live playing a loop | `abletonSyncMs` |
| Drum hits against the loop | Live, a loop, a drum rack | `onsetNoteOffsetMs` |
| Loop-chain alignment *(optional)* | a chained loop | `chainRecOffsetMs` |
| Write it down | — | prints the line for the profile |

Three things worth knowing before you run it:

- **Only the first two work without Ableton Live.** The other numbers have
  Live's plugin chains inside them — that is why changing the chain invalidates
  them — and a delay a plugin contributes cannot be measured without running the
  plugin. The onset threshold needs nothing but a guitar, because the clean tap
  reads the hardware directly and Live is not in that path at all.
- **The round trip wants a patch cable**, from the interface's main output into
  the guitar input, with the guitar unplugged. That cable stands in for "you
  hear the loop and play in response", which is the only part of the round trip
  with no delay of its own. Mute the guitar track's path to master first, or the
  cable is a feedback loop.
- **Measuring and applying are separate buttons on purpose.** A measurement you
  can see but have not applied is how you notice one that is obviously wrong.
- **SC hears Live only on the loopback pairs**, and only what Live actually
  routes there — Live's Main Out goes to the speakers (17/18 on the `bh*` rigs)
  and never reaches SC. The two steps that listen to Live therefore each want a
  **free loopback pair of their own**, which is what the unused BlackHole
  channels (1–8, 15–16) are for:
  - **Live's downbeat** uses the metronome, which follows Live's **Cue Out** —
    routable independently of Main Out, in the Main track's I/O. Point Cue Out
    at 5/6 (**SC channel 4**) and the click arrives on its own.
  - **Drum hits** use the drum rack track's **Audio To**; 7/8 (**SC channel 6**)
    keeps it clear of everything else.

  Each of those steps has its own **Listen on ch** box, because the two pairs
  are different, and a **Scan inputs** button that prints the peak level on
  every input channel for four seconds — route something in Live, press it, and
  the channel with a number beside it is the one.

Give them their own pairs and nothing has to be muted. Send either to the return
pair (13/14) instead and you must mute the loop-return track first: our own loop
comes back on that pair, and the measurement would lock onto it and report the
audio round trip as a transport offset. Both steps refuse rather than return
that number — a click once a bar is nearly all silence, a returning guitar loop
is not, and they check.

Each measurement repeats itself and reports the **spread** across the trials as
well as the number. That is the diagnostic that matters: one reading always
produces a number, but eight that disagree is a clock problem — the aggregate's
clock source, drift correction, or a member at the wrong sample rate — and the
wizard says so rather than averaging it into a plausible-looking latency.

Nothing is saved. The wizard applies what it measures to the running session and
prints the line to paste into `~routingProfiles` in `scripts/setup-routing.scd`,
because a rig that silently re-calibrates itself is a rig you cannot check
against what it did last time.

## Calibrating overdub latency

1. Record a clear pulse (e.g., 4 hits on the beat).
2. Start overdubbing (trigger while playing) and play *on the beat* of what
   you hear.
3. Listen back. If your overdub lands *late*, raise the **Overdub lat (ms)**
   slider; if it lands *early*, lower it. Typical values:
   - Straight into an interface, no Live in the path: 5–15 ms on pro audio
     (e.g. RME Fireface), 20–40 ms on MacBook built-in audio.
   - Through a BlackHole aggregate with the loop coming back out of Live —
     which is how the `bh*` profiles run — expect **much** higher, because
     Live's own buffers are inside the round trip being compensated for.
     Measured by ear: 54 ms on `bhTsMega`, 68 ms on `bhBuiltin`.
4. Once dialed in, the value sticks across loops, undo/redo, granular toggle,
   and reverse mode (the shift direction follows the playback rate).

## File structure

```
megalooper/
  classes/
    Looper.sc            -- state machine, SynthDefs, MIDI/OSC plumbing
    LooperBreakProc.sc   -- house BBCut procedure: occasional block repeats
    LooperCutGate.sc     -- drives the Insert-mode duck bus from each cut block
    LooperSessionRecorder.sc -- records the whole set to disk, from the stomp
    LooperMidiMap.sc     -- a MIDI map's rules: lookup, switches and knobs, hysteresis, the file
    LooperMidiLearn.sc   -- learning a mapping: which message a control takes
    LooperCalibrator.sc  -- the calibration wizard's steps, flow and arithmetic
    LooperBar.sc         -- the window's flat bar slider (with the arc's tick, a neutral mark)
    LooperTile.sc        -- the window's flat tile: its buttons, switches and action tiles
    LooperSeg.sc         -- the window's segmented rows: every option of a short choice in sight
    MeterAnalyzer.sc     -- pure analysis: pulse fit + accent-template meter selection
    PitchAnalyzer.sc     -- pure analysis: per-segment chord/pitch detection
  scripts/
    boot.scd             -- orchestrator: pick the rig, load the parts, call them in order
    setup-routing.scd    -- ~routingProfiles table + the device / sample-rate guards
    setup-midi.scd       -- MIDI I/O and the log
    setup-miditargets.scd -- every control a MIDI binding can drive
    setup-midimap.scd    -- the MIDI router: maps as files, learning, the responders, the proxy
    setup-model.scd      -- the Looper instance + the analysis/chord callbacks
    gui-const.scd        -- ranges, menu contents, lifetimes; no window
    gui-theme.scd        -- the stage theme: palettes, type, tiles, bars, segmented rows
    gui-presets.scd      -- the preset bar's logic, shared by every preset family
    gui-status.scd       -- the status band and strip + the MIDI monitor panel
    gui-perform.scd      -- Perform: the layers, the actions, the macros
    gui-bbcut.scd        -- the Cutter (Sound): voices, procedures, params, effects
    gui-granular.scd     -- the Grains (Sound): the Warp1 layer's full controls
    gui-analysis.scd     -- Analysis (Setup): monitor feed, counts, onset notes, export
    gui-rig.scd          -- Rig (Setup): routing, timing, SA's levels, the MIDI map
    gui-midimap.scd      -- the MIDI map section: inputs, maps, bindings, learning
    gui-mapmode.scd      -- MIDI Map mode: the MIDI MAP button, masks, the map bar
    gui-calibrate.scd    -- the Calibrate wizard, and its summary on Setup
    calibrate-measure.scd -- the wizard's measurements; needs the rig
    gui-shell.scd        -- THE window: top bar, status band, views, footer, keys
    gui-wiring.scd       -- SimpleController wiring + ~doExport
    launcher.scd         -- rig picker shown by the Desktop icon
    check.scd            -- static check: parse + load every script, no server
    check-gui.scd        -- boots a rig, builds the window, asserts on it, quits
    check-gui-midimap.scd -- builds the MIDI map section headless, drives it and MIDI Map mode, exits
    check-gui-maptags.scd -- builds the whole window headless: is every control tagged for MIDI Map mode?
    eval_meter_analyzer.scd  -- score the analyzer against labelled training loops
    probe-meter.scd          -- the analyzer's perception map: every meter, tempo and
                                kind of damage, headless
    replay-session.scd       -- replay a recorded set's dry tap through detection at a
                                threshold sweep, scored against the next-reading presses
    check-onset-notes.scd    -- walk the chain from detection to Live accepting notes
    check-insert.scd         -- why Insert mode sounds like Gate: the duck's duty cycle
    check-chain-align.scd    -- measure a chained loop against the loop underneath
    check-loop-phase.scd     -- measure the engine's phase against loopStartTime
    tests/
      run-tests.scd      -- headless test suite, exits non-zero on failure
      _harness.scd       -- assertions + the server-free Looper fixture
      test-*.scd         -- one file per area (see Testing)
  tools/
    make-app.sh          -- build megalooper.app (Desktop icon)
    make-icon.py         -- render the app icon, stdlib only
    midi-log-streams.py  -- cut the TSMega's CC streams from the MIDI log, for the tests
  docs/
    manual.md            -- this file
    standalone.md        -- Megalooper SA: the effect chains, sounds and plugins
    drums.md             -- the drums' kits
    routing.md           -- full rig setup: Fireface, Loopback bridge, BlackHole
    midi-maps.md         -- the MIDI map file format
  presets/
    bbcut/               -- the cutter setups megalooper ships; yours are in your megalooper folder
    midi/                -- the MIDI maps megalooper ships (JSON): tsmega, keys-and-knobs
    sa/                  -- Megalooper SA: the effects' variations, the drum patterns, the kits' maps
  training-data/         -- exported labelled loops (WAV gitignored, JSON kept)
```

Each `setup-*` / `gui-*` file only **defines** functions, so loading one is free
and the call order in `boot.scd` is the entire startup sequence. That is what
makes a single window rebuildable in isolation.

Presets work the same way in both windows because they are the same code.
`gui-presets.scd` is the bar — menu, name field, two-click Save/Delete, status
line — and each window registers a *family spec* giving the label, one line of
help text, and which `Looper` methods to call; state and widgets live in that
family rather than in per-window globals. On the model side, storage is one
implementation driven by `Looper.prPresetFamilies`, with a one-line named
method per family (`saveGranularPreset` and friends) because that reads better
at a call site than passing a family symbol around.

Inside `Looper`, the SynthDefs are built from shared graph pieces rather than
written out once per variant. `prOnsetTrig` and `prOnsetStrength` are the single
definitions of the onset-detection chain and its salience envelope, used by both
recorders, the analysis monitor and the overdub analyser — so the tuning lamp
cannot drift from what a take will actually detect. `prRecGraph`,
`prRecPlainGraph` and `prEngineGraph` are each one graph function instantiated
twice, under a mono and a stereo name. The mono/stereo split has to work this
way: `SoundIn`'s channel count is fixed when the graph is built, so it can never
be an argument inside a single def.

## How meter detection works

`MeterAnalyzer.analyze(loopDur, onsetTimes, onsetStrengths)` enumerates over:

- A list of standard meters: `2/4 3/4 4/4 5/4 6/4 7/4 5/8 6/8 7/8 9/8 11/8 12/8`.
- Bar counts K = 1..4 (multi-bar loops).
- Pulse subdivisions (1, 2, 4) — to handle e.g. 8th-note triggering for a 4/4.

For each candidate, an iterative least-squares fit picks the pulse period
`tau` that best places onsets on a grid. The fit with the lowest residual
*and* a BPM in `[50, 220]` wins, with a soft tiebreaker toward BPMs near 110.
If nothing fits, a 4/4 fallback is reported with an `\error` field set.

### Accent analysis

The grid fit alone only pins down the *number of pulses* and their period — it
cannot tell, say, one bar of 4/4 from two bars, because both lay the same
onsets on the same grid. To break that ambiguity from the music rather than
from priors, each onset carries a **strength** (a fast-attack amplitude sampled
at the onset, captured in the record SynthDef and passed through as the third
argument). For every candidate the strengths are folded into one bar and
correlated against that meter's **accent template** — a metrical-weight profile
where the downbeat dominates, beat-group heads are accented, and plain
subdivisions sit lowest. Compound (x/8 grouped in threes) and irregular
(5/8 → 2+3, 7/8 → 2+2+3, 11/8 → 2+2+2+3) meters get distinct templates, so e.g.
6/8 and 3/4 — which share a pulse grid — are told apart by accent shape.

The correlation is maximized over every phase offset, which yields two things
the bare grid fit could not:

- **Bar count from the audio.** When loud hits recur at half the loop, a second
  downbeat appears, so `K = 2` outscores `K = 1` on accent alignment — decided
  by where the accents fall, not by a prior.
- **Downbeat phase.** The best-matching phase is reported as `result.phase` (in
  pulses) and `result.downbeatOffset` (in seconds): where beat 1 sits relative
  to the first onset.

The accent term is *additive*. When no strengths are supplied, or the playing
has no dynamic accents, it contributes nothing and scoring falls back to the
prior-only behavior, so previously-working results are unchanged.

### Snapping to whole bars

Once the take has a reading, `Looper.snapAnalysisToLoop` makes the loop a whole
number of its bars, which mends a stop press that came a little early or late.
It may move the loop by **half an eighth at most, and never more than 100 ms**
(`MeterAnalyzer.snapLimit`, `snapLimitSecs`). Further than that is not the
hand: it is a bar that was played longer or shorter, like the 8/8 that ends
7/8 7/8 7/8 8/8, and rounding it away would cut it off. A reading that would
move the loop further gives way to the best reading that does not, and with none
the take is length-anchored at its own length. Readings that would move it are
not offered by the next-reading switch. The Post window says when this happens,
and the take's log has it as `snapRefused`.

### Uneven bars

A loop can be bars that are not all alike: three of 7/8 and one of 8/8, say,
written `7+7+7+8/8`. A reading like that carries its bars (`bars: [7, 7, 7, 8]`,
in units of the denominator; `numerator` is the commonest bar, `k` the count),
and everything that counts bars follows them:

- **The bar grid and the counter.** The fourth bar is drawn an eighth longer, and
  the counter goes `BAR 4/4 · BEAT 8/8` there.
- **The drums.** With Auto Retrigger on, as in the set, the step lanes start
  again on the first step of every bar, so a 7/8 bar plays 14 steps of a
  16-step lane and the 8/8 bar all 16. This is new for even bars too: Live's
  device waited for "pseudo-bars" of *numerator* quarter notes, so in plain 7/8 a
  lane used to reshape itself over four bars. `MegaSADrums.retrigAt = \live`
  (on `~megaSA.drums`) brings Live's way back.
- **The click** accents every bar line; **the snap** makes a loop whole cycles of
  the bars, never whole bars of 7/8; **the dissolve** counts the mean bar.
- **Live**, where it is used, is sent one bar per cycle (`29/8`), so its bar line
  still meets the loop's.

**Found by the analyser.** After a first take the analyser also looks for
uneven bars (`MeterAnalyzer.analyzeUneven`): the pulse that fits the onsets over
the whole take, the period at which the riff repeats, then every way of
barring the take into bars of that period with one or two of them up to two
pulses longer or shorter, scored by how alike the bars are and how strong the
hits on their bar lines, an odd bar last a little ahead. When no ordinary meter
fits the take (29 eighths fit none), its answer is the take's reading instead
of the fallback. When one does (7+7+7+9 is also three bars of 5/4), the meter
stays the answer and the uneven bars come **second**, one press of the
next-reading switch away. It never answers with even bars of its own, so
straight takes read as they always did. It is tuned on synthetic takes so far;
the duo's labelled takes will tune it (see below).

**Given by hand**, when the analyser missed them: on the Analysis tab, **Bars
by hand**, type one cycle (`7 7 7 8`), choose the denominator and press **Set
bars**. The loop's length sets the tempo, and the reading in force decides how
many cycles the loop holds. The reading lands on the next loop boundary like the
next reading; the header says **TAKE · BARS BY HAND**, the next-reading switch
passes through it, and **Revert** goes back to the analyser's answer. Bars the
analyser already offers are armed as they are.

**Labelled takes.** With **Record set** on, a take whose bars were given by
hand (or reached with the switch) keeps them as its label in the set's log, and
`scripts/replay-session.scd` scores today's analyser against them. That is how
the detection gets tuned on real playing.

The session recorder still names files and writes the drums' MIDI file with the
commonest bar (7/8).

## Exporting training data

The analyzer is only as good as the data it is tuned against, so the GUI can
capture **labelled** loops. After recording, the export fields (in the main
window, below "Fallback meter") pre-fill with the analyzer's guess; correct the
**signature** and **bar length** if they are wrong, type a descriptive **name**,
and click **Export → training-data** (or press `E`). Each export writes two files
to `training-data/`:

- A 24-bit WAV of the loop region, named
  `name_sig_bars_bpm_time.wav` — e.g. `funky-groove_7-8_4bars_112bpm_260717-143022.wav`.
  Fields are `_`-separated (the name is sanitised so it never contains `_`); the
  BPM is derived from the labels + loop length. This is the ground truth: the
  intended signature and bar length can be read straight off the filename.
- A JSON sidecar (same basename) holding the exact onset times/strengths the
  analyzer saw (`analyzerInput`), the raw onsets, the analyzer's guess at export
  time (`detected`), and the ground-truth labels (`groundTruth`).

> **With the clean analysis tap on**, the WAV and the sidecar no longer describe
> the same signal: the WAV is the recorded (processed) loop, while `analyzerInput`
> holds the onsets detected on the dry tap. Replaying the sidecar is unaffected —
> that is the detector's actual input — but re-running *onset detection* over the
> WAV offline measures the processed guitar instead, so it is no longer a faithful
> proxy for the live path. Record with **Analysis in** set to *Same as input* when
> exporting loops meant for detector-parameter sweeps.

Because `MeterAnalyzer` works on onsets, not audio, the sidecar is what makes
retuning possible without re-recording. `scripts/eval_meter_analyzer.scd` reads
the folder, replays `MeterAnalyzer.analyze` on the captured onsets, reproduces
the Looper's bar snapping, and reports per-loop PASS/FAIL plus a summary
accuracy against the filename ground truth:

```
~trainingDir = "/path/to/loops";   // optional; defaults to ./training-data
// then evaluate scripts/eval_meter_analyzer.scd
```

Tweak the analyzer's classvars/scoring in `MeterAnalyzer.sc` and re-run it to see
the accuracy move. That harness *prints* accuracy for tuning; the pass/fail lock
that protects refactoring is `scripts/tests/test-meter-corpus.scd`, which runs
the same corpus through `Looper.snapAnalysisToLoop` — the real decision path —
and fails if any loop's outcome changes. Both call the same code, so they cannot
disagree about what the app would have decided.

The third instrument is `scripts/probe-meter.scd`, which needs no recordings at
all: it plays the analyzer every standard meter at twelve tempos over one, two
and four bars, then damages each take the way a room does — jitter, dropped and
ghost onsets, flams, flat or inverted accents, an early or late stop press — and
reports where the answer flips and which wrong answers are stable. It asserts
nothing; it says what the analyzer is *like*. Its first run
found a stack-corrupting compiler fault in `analyze` that no recording had ever
triggered (see the comment in `MeterAnalyzer:analyze`).

The fourth is `scripts/replay-session.scd`, which closes the loop the other
three cannot: it works on what was actually played at a gig, labelled by what
you did about it with the next-reading switch. See
[Replaying a set](#replaying-a-set).

## Testing

Two headless gates, no server, no windows, no MIDI, no audio hardware. Both
exit non-zero on failure, so either works as a pre-commit hook:

```sh
sclang scripts/check.scd            # do the scripts still hold together?
sclang scripts/tests/run-tests.scd  # does the model still compute what it did?
```

`check.scd` parses every script, loads the part-files and asserts that
everything `boot.scd` calls exists — the failure it exists to prevent is a typo
that only surfaces halfway through a boot which has already freed the previous
Looper. `run-tests.scd` runs ~270 assertions over `Looper`'s language-side logic
in about a quarter of a second.

### How the model is testable at all

`Looper.newCopyArgs` builds an instance **without running `init`**, and sclang
still applies the class's declared instance-variable defaults. So a test gets a
real Looper carrying exactly the values it boots with, minus the buffers,
busses and OSC responders. `~tLooper` in `_harness.scd` wraps that up with a
one-key Event standing in for the server (Events answer any selector by key
lookup, which is the whole stub the sample-rate-only methods need).

### What each file covers

| File | Covers |
| --- | --- |
| `test-onset-notes.scd` | pattern building, velocity mapping, gain independence, MIDI range clipping |
| `test-chain-timing.scd` | the "free multiply" start wait — a regression file, see below |
| `test-granular-presets.scd` | capture, serialise, validate, recall; hostile and stale input |
| `test-bbcut-presets.scd` | the same for voices, procs, fx chains and per-proc params |
| `test-gesture-fuzz.scd` | random sequences of the footswitch/pedal vocabulary, against invariants |
| `test-calibrator.scd` | the calibration wizard's flow, and its arithmetic against known signals |
| `test-meter-analyzer.scd` | synthetic onset grids, clean and irregular |
| `test-meter-corpus.scd` | the real loops in `training-data/`, through the real decision path |
| `test-ranges.scd` | the three definitions of every granular range still nest |
| `test-synthdefs.scd` | every SynthDef's compiled graph, fingerprinted against a baseline |
| `test-preset-storage.scd` | the storage both families share, on real files |
| `test-preset-bar.scd` | the shared preset bar driven end to end with stub widgets |
| `test-session-recorder.scd` | set recording: file naming with the set's tempo, refusals, the transport guard, SA's stems, the stop and the WAVs' clock, and the event log — its JSON, the takes and labels read back from it, and what the looper and the drums write |
| `test-session-midi.scd` | the set's `.mid`: the MIDI file writer and reader, ticks at the file name's tempo, the three tracks |
| `test-midimap.scd` | the MIDI router: a map's rules (lookup, checks, what a press or a knob does), its controls, the map the numbers make, its responders, and the pedal's hysteresis on its own streams from the MIDI log |
| `test-midimap-learn.scd` | learning a mapping: the 3 steps, bursts, two presses, on the TSMega's own streams |
| `test-midimap-store.scd` | maps as files: shipped and yours, backups, Keep, settings, the boot's choice, learning through the responders |
| `test-midi-equivalence.scd` | the router against a copy of the responders it replaced (`legacy-midi-bindings.scd`, never run on its own): the same messages make the same calls, sends and log lines |
| `test-source-guards.scd` | the collapsed duplication stays collapsed |

`test-chain-timing.scd` exists because that arithmetic got the chained loops
wrong once: a positive calibrated offset made the recorder start a whole
repetition early, and at the time the expression was inline in a Routine next to
`Synth.tail`, so there was no way to test it. `Looper:prChainStartWait` and
`Looper:prChainRecOffset` were extracted so there is.

### Testing GUI code without a GUI

The preset bar talks to its widgets through plain accessors — `menu.items`,
`field.string`, `button.states_`, `text.string_` — and an `Event` answers any of
those by key lookup. So `test-preset-bar.scd` installs an Event per widget and
drives the whole flow against a real `Looper` writing real files: rescan, save,
overwrite-confirm, recall, delete-confirm, revert, and a preset vanishing from
disk underneath the menu. It is worth the trouble because that file is now the
single copy of logic both windows depend on, and none of it is visible from a
static check.

### Testing the SynthDefs without a server

`SynthDef` builds its graph in the *language*; only `.add` sends anything, and
an unbooted server just means the message goes nowhere. So all eleven defs can
be built headlessly and their compiled bytes fingerprinted —
`test-synthdefs.scd` locks those fingerprints. Nothing about how they *sound*
can be asserted this way, but a graph rewrite that changes no bytes cannot
change any audio, and that turns out to be enough to refactor the graphs with
confidence.

It is how the mono/stereo and detection-chain duplication was collapsed: the
defs were dumped before and after, and all eleven were byte-identical. The
fingerprint is an order-sensitive rolling checksum rather than a byte count —
reintroducing a divergent detection chain changes the bytes without changing
how many there are.

`test-source-guards.scd` then keeps the source honest by reading
`classes/Looper.sc` as text: one `Onsets.kr` call site, one salience envelope,
one place that decides between a doubled mono input and a stereo pair, and each
graph builder instantiated exactly twice. It used to police four *agreeing*
copies of the detection chain; now it asserts nobody has reintroduced a second
one.

### Known issues are recorded, not hidden

`~tXfail` marks a defect we know about and have chosen not to fix. It states the
*current* (wrong) behaviour, so the suite stays green while the bug is on the
record, and says so loudly if it ever stops reproducing. Two are marked today:

- meter detection reports **double tempo** on a dense even subdivision
  (16 eighths of 4/4 at 87 comes out 4/4 at 174);
- signature accuracy on the training corpus is **1 of 4**. Bar count — which
  decides the loop's *length*, so it is audible immediately — is 4 of 4 and is
  asserted, not tolerated.

`~tSkip` marks a part that can't run where the suite is running, and why. It is
neither a pass nor a failure; the summary counts and lists the skips. The MIDI
router's tests put messages through real MIDI responders, so beside a running
megalooper in the IDE they skip that part. In a headless run there is nothing
to skip for, and a MIDI responder left registered fails them instead.

### What is not covered

Everything that needs scsynth: SynthDef graphs, real onset detection, actual
latency, and the GUI. Those still need the rig, and the `check-*.scd` scripts
are the tools for measuring them there.

## Known limitations

- One bar per loop is the design assumption; multi-bar K is supported but only
  up to 4 bars.
- BPM is always reported as the quarter-note equivalent. Compound meters (e.g.
  6/8 dotted-quarter) are the user's interpretation.
- Compound-vs-simple meters that share a pulse grid (e.g. 6/8 vs 3/4) are now
  *detected* by the accent analysis, but the final label is still gated by the
  subdivision tiebreaker, so a strongly-accented 3/4 can still report as 6/8.
  Tune the scoring weights against a labelled dataset captured via the GUI
  export (see [Exporting training data](#exporting-training-data)).
- The detected downbeat phase (`result.phase`) is reported but not yet wired
  into the metronome / BBCut alignment, which still assume the first onset is
  the downbeat.
- The BPM-near-110 tiebreaker can pick the wrong octave for very fast or very
  slow material.
- MIDI Start always restarts Live from the cue point (typically 1.1.1). In
  "Start only" transport mode, recording a second loop while Live is running
  will jump Live back to the top. The workaround is to swap `midiOut.start`
  for an AbletonOSC `/live/song/continue_playing` call — not wired up by
  default.
- Switching transport mode mid-play is not gracefully handled. Switch between
  loops, not during.

## License

**GPL-3.0-or-later** — see [LICENSE](../LICENSE).

megalooper's cutter layer subclasses BBCut and is written against its API, so
the project as a whole is GPL. [NOTICE](../NOTICE) records why, lists every
dependency and its licence, and notes which BBCut version terms apply.

No third-party code is redistributed here; the installer fetches each dependency
from upstream. `classes/MeterAnalyzer.sc` and `classes/PitchAnalyzer.sc` depend
on nothing but the SuperCollider class library, if the odd-meter detection is
the part you want.
