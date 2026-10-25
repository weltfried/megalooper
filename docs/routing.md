# Audio routing

Which audio devices megalooper plays on, and where your instrument comes in,
you choose in the launcher: the **Input** and **Output** devices, the input
your **Instrument** is on, a **Bass** on an input of its own, and the
**Buffer** (the manual's [Configuration](manual.md#configuration)). They are
kept in `settings.json` and make megalooper's routing profile, **`saSystem`**,
the one the rest of this page calls a profile: with nothing chosen it is the
system's default input and output.

Every other rig is a profile of your own, in `profiles.scd` in your megalooper
folder, for what the menus do not offer: an aggregate, a sample rate switched
before the start. The launcher then offers it in a **Rig** menu beside
`saSystem`: [Adding a rig](#adding-a-rig) says how to write one.

A profile drives the audio device, the server's channel count, the input the
looper records, the input the analysis listens to, and the starting values of
the rig's timing. megalooper's own is in
[`scripts/setup-routing.scd`](../scripts/setup-routing.scd). Changing the
device or the channel count needs a restart.

## What a profile says

Channels are counted from 0: input 1 of the interface is channel 0.

| Field | What it is |
| --- | --- |
| `device` | The audio device, by its exact CoreAudio name. `\systemDefault` (as on `saSystem`) is the system's default input and output, which on a laptop are two devices: the microphone and the speakers |
| `numChans` | How many channels SuperCollider opens, inputs and outputs |
| `numInChans` | Optional: more inputs than outputs, when an input you need sits above `numChans` |
| `inChannel` | Your instrument's input. The instrument chain starts here, and the looper records what comes out of the chain |
| `inChannelCount` | `2` records both sides of the instrument chain, so its stereo effects reach the loop |
| `analysisChannel` | Optional: the one input the onset and pitch detection listens to. See [The analysis tap](#the-analysis-tap) |
| `bassChannel` | Optional: a bass on an input of its own, with a chain and a strip of its own. See [A bass](#a-bass) |
| `sa`, `live` | `sa: true, live: false`, both: Megalooper SA, with its mixer, chains, drums and synth. Leave `live: false` out and the Rig page shows controls meant for another setup, and the start runs checks it does not need |
| `memSize` | `65536`: the memory the effects' delay lines need |
| `sampleRate`, `setSampleRate` | Optional: the rate the rig is wired for. With `setSampleRate: true` the device is switched to it before the start |
| `hardwareBufferSize` | Optional: the block size to start with, in frames. Smaller is a shorter round trip and more work for the computer |
| `midiMap` | Optional: the MIDI map the rig starts with, by name |
| `latencyMs`, `onsetThreshold`, `onsetNoteOffsetMs` | The rig's starting timing values. See [The calibrated values](#the-calibrated-values) |
| `chainRecOffsetMs` | Optional: where **Rec next loop** starts recording, in ms, so a chained loop is not rotated in its buffer. Measured with `scripts/check-chain-align.scd` |
| `members` | Optional, for an aggregate device: the devices it should hold, so the preflight can name one that is missing |

The loop's output, the master and the recording need no channels of yours:
Megalooper SA places them itself. The mix leaves on outputs 1 and 2, and
**Record set** records that mix as it leaves. **Rec next loop** records your
instrument plus the loop after its effects.

## The analysis tap

Meter detection sees nothing but onset times. Distortion and ambient effects
smear the attacks of your notes, and blurred onsets are the main cause of a
wrong meter: a straight 4/4 take comes out 7/8 because no pulse grid fits. So
the analysis can listen to your instrument **dry**, straight off its input,
while the looper goes on recording it through the instrument chain. What you
hear and what gets looped do not change.

`analysisChannel` is that input, one channel. On `saSystem` it is input 1,
the same input the instrument comes in on.

- **Off by channel.** Leave `analysisChannel` out and the analysis listens to
  what the looper records, effects and all. **Listen for onsets on** on Setup's
  Rig page switches between the two while you play, so you can compare a take
  against the same audio.
- **The failure to know.** A tap on the wrong input is *silent*, and silence
  looks like a musical problem: the loop records perfectly while every take
  reports 0 onsets and falls back to a meter worked out from the length alone.
  When that happens the log says so and names the channel.
- **Training exports are what was recorded.** `exportTrainingLoop` writes the
  loop as recorded, through the effects, so an exported WAV is not what the
  detector heard. The JSON beside it has the onsets the detector did hear.

## A bass

**Bass: Input 2** in the launcher (in a profile of yours, `bassChannel: 1`)
says a bass is on the interface's input 2. Megalooper SA plays it through the
bass chain (the **BASS** row on the FX view) onto a strip of its own, **Bass**
under Levels on Setup's Rig page and on Perform, and **Record set** writes it
as a stem of its own. The looper does not record it. **None** is the start:
on a laptop input 2 is the microphone. The bass's input is never the
instrument's: that would play the instrument twice, and megalooper starts
without the bass then, saying why.

## Boot-time guards

These checks run before every start, because each of these failures is
silent otherwise:

- **Device present.** If the profile's device is missing, SuperCollider would
  quietly start on the default device with the wrong channel count. Instead the
  start stops with a banner naming the rig, the device it wanted and every
  device there is. Names match leniently (either one contained in the other),
  because SuperCollider shortens long and non-ASCII names: it lists
  "Das Zwölfer Microphone" as "Das Zwölfer Microphon".
- **Sample rate.** On `saSystem` the default input and output must run at the
  same rate, or SuperCollider refuses to start: megalooper names both, and
  [Configuration](manual.md#configuration) says how to make them agree.

### The device preflight

Those checks see a device's name. Aggregate devices (several devices joined in
Audio MIDI Setup) fail more quietly than that: a member drops out and the
aggregate goes on working with fewer channels. SuperCollider asks for 17
inputs, CoreAudio grants 16, and the analysis tap reads a bus nothing fills,
for the whole session, looking exactly like a detection bug.

So before the start `~checkAudioDevice` asks the system what it actually has,
through `system_profiler SPAudioDataType -json` (about 0.2 s, nothing to
install). Run it again at any time:

```supercollider
~checkAudioDevice.(~routingProfile);
```

| Finding | What it means | Result |
| --- | --- | --- |
| Fewer channels than `numChans` | A member has dropped out, and the rig's inputs and outputs cannot all exist | **Stops**, listing which expected members CoreAudio can still see |
| Fewer channels than `numInChans` | Only the input above `numChans` is gone | **Goes on**: the tap is switched off and onset detection listens to the recorded input, and says so; the bass too, if its input is gone |
| Device rate ≠ profile rate | The aggregate trap, caught before the start instead of after | Warns |
| A `members` entry not present | The channel count still fits, so the other members have **shifted down**: every channel above the gap is now something else | Warns |
| A member at a different rate from the aggregate | CoreAudio is resampling it, the usual cause of an aggregate that works until it doesn't | Warns |

`members` builds nothing. It is there so the preflight can say *"the speakers
are present, the interface is gone"* rather than only *"this device has two
fewer channels than it should"*. Set **Clock Source** in Audio MIDI Setup to
the interface, and tick Drift Correction on every other member.

## Adding a rig

Write it into **`profiles.scd` in your megalooper folder**
(`~/Library/Application Support/SuperCollider/megalooper/` on macOS,
`~/.local/share/SuperCollider/megalooper/` on Linux). The file holds one
Event, a profile per key. An interface with your instrument on input 1 and a
bass on input 2:

```supercollider
// My rigs.
(
    myInterface: (
        device: "Exact CoreAudio Name", numChans: 2,
        inChannel: 0, analysisChannel: 0, bassChannel: 1,
        inChannelCount: 2, latencyMs: 15, sampleRate: 48000,
        memSize: 65536, sa: true, live: false)
)
```

It is read at every start, and each rig appears in the launcher beside
`saSystem`; the launcher remembers the one you pick. A file that does not read
is reported in the log (`~/Library/Logs/megalooper.log`) and megalooper starts
with its own rig; a rig that names no device is left out. A rig of yours named
`saSystem` replaces megalooper's. From the SuperCollider IDE, set
`~defaultRoutingProfile = \myInterface` in
[`scripts/setup-routing.scd`](../scripts/setup-routing.scd).

`ServerOptions.devices` in SuperCollider, or `python3 tools/coreaudio.py list`,
lists the exact names. The name must match: the check is lenient, but
`My Interface (2)` and `My Interface` do not match each other, so a rename in
Audio MIDI Setup stops the start until the profile is updated.

Some interfaces come up at 44.1 kHz when plugged in on their own.
`sampleRate: 48000, setSampleRate: true` switches the device before the start
(through `tools/coreaudio.py set-rate`), and `hardwareBufferSize: 64` starts at
64 frames, a round trip of about 9 ms on a good interface.

`./tools/run-checks.sh quick` checks your rigs with megalooper's own: a
channel outside the inputs the profile opens, a bass on the instrument's input
or the tap, a bass on a rig without SA, a timing value outside its control.
The analysis tap and the bass must each be an input the profile opens. Past
the inputs, a channel reads one of megalooper's own busses, so a tap out of
range would feed the looper's output back into the onset detection.

### The calibrated values

| Field | What it corrects | How you get it |
| --- | --- | --- |
| `latencyMs` | How far back an overdub is written, so it lands where you played it. 0 to 100 ms | Measured by the Calibrate view's round-trip step, or by ear ("Overdub latency" on Setup's Rig page) |
| `onsetThreshold` | How loud an attack must be to count as an onset. Defaults to 0.5 | The Calibrate view's threshold step, on Setup's Analysis page |
| `onsetNoteOffsetMs` | When the onset notes are played, so they sit on the loop. Defaults to 0 | By ear ("Offset" under onset notes on Setup's Analysis page) |
| `chainRecOffsetMs` | Where **Rec next loop** starts recording, so a chained loop is not rotated in its buffer. Defaults to 0; `saSystem` has 20 | Measured with `scripts/check-chain-align.scd`; the Calibrate view does not measure it |

They belong to the rig because they measure its paths: a number calibrated on
one interface is wrong on the next. The profile gives the **starting** value.
What you apply on the Calibrate view is kept for the rig in `calibration.json`
in your megalooper folder, and every start begins with it; **Forget** goes back
to the profile's numbers. A value dialled by ear on Setup is not kept that way:
write it into the profile, or the next start begins from the old one.
