# Audio settings

Which audio devices megalooper plays on, and where your instrument and a bass
come in, you choose from menus: in the launcher before the start, and on
Setup's Rig page while it runs (the manual's
[Configuration](manual.md#configuration) lists them). The rest of this page
is what happens behind those menus, and, at its end, rigs of your own for
what the menus do not offer.

## What the menus do

- **Kept for the next start**, in `settings.json` in your megalooper folder.
  The devices are kept by name.
- **Two devices are fine.** The input can be one device and the output
  another, the microphone and the speakers of a laptop, say: SuperCollider
  joins them itself. They must run at the same sample rate, or the audio
  server refuses to start; megalooper names both before it tries. Set them to
  one rate in Audio MIDI Setup.
- **A device that is not there** when megalooper starts gives way to the
  system's default for that side, and an input the device does not have to
  input 1 (the bass's to none). The launcher says so before you press Start,
  the Rig page says it in red, and your choice stays, so the next start with
  the device plugged in is as you left it.
- **Changing the audio means starting again.** The device is fixed when the
  audio server starts. On the Rig page, **Apply and restart** does that in
  place: megalooper quits the server and starts again on the new audio. The
  loop goes, and the effects, drums and synth come back as kept (**Keep** on
  their views). While **Record set** runs it refuses, so the set's files end
  where you chose.
- **Outputs 1 and 2.** The mix leaves on the output device's outputs 1 and 2,
  and **Record set** records it as it leaves. **Rec next loop** records your
  instrument plus the loop after its effects. Nothing else needs a channel.
- **Linux.** JACK or PipeWire connects megalooper's inputs and outputs, so
  there are no device menus ([Linux](linux.md)).

Behind the menus is megalooper's own routing profile, `saSystem` (in
[`scripts/setup-routing.scd`](../scripts/setup-routing.scd)): Megalooper SA,
the instrument recorded through both sides of its chain, the memory the
effects need. The menus fill in its devices and inputs. With nothing chosen it
is the system's default input and output.

## The analysis tap

Meter detection sees nothing but onset times. Distortion and ambient effects
smear the attacks of your notes, and blurred onsets are the main cause of a
wrong meter: a straight 4/4 take comes out 7/8 because no pulse grid fits. So
the analysis listens to your instrument **dry**, straight off the input it
comes in on, while the looper goes on recording it through the instrument
chain. What you hear and what gets looped do not change.

- **Listen for onsets on** on Setup's Rig page switches between the dry input
  (*Clean tap*) and what the looper records, effects and all (*Same as
  input*), while you play, so you can compare a take against the same audio.
- **The failure to know.** A tap on the wrong input is *silent*, and silence
  looks like a musical problem: the loop records perfectly while every take
  reports 0 onsets and falls back to a meter worked out from the length alone.
  When that happens the log says so and names the channel.
- **Training exports are what was recorded.** `exportTrainingLoop` writes the
  loop as recorded, through the effects, so an exported WAV is not what the
  detector heard. The JSON beside it has the onsets the detector did hear.

## A bass

**Bass: Input 2** says a bass is on the input device's input 2. Megalooper SA
plays it through the bass chain (the **BASS** row on the FX view) onto a strip
of its own, **Bass** under Levels on Setup's Rig page and on Perform, and
**Record set** writes it as a stem of its own. The looper does not record it.
**None** is the start: on a laptop input 2 is the microphone. The bass's input
is never the instrument's: that would play the instrument twice, and
megalooper starts without the bass then, saying why.

## The calibrated values

| Value | What it corrects | How you get it |
| --- | --- | --- |
| Overdub latency (`latencyMs`) | How far back an overdub is written, so it lands where you played it. 0 to 100 ms | Measured by the Calibrate view's round-trip step, or by ear ("Overdub latency" on Setup's Rig page) |
| Onset threshold (`onsetThreshold`) | How loud an attack must be to count as an onset. Defaults to 0.5 | The Calibrate view's threshold step, on Setup's Analysis page |
| Onset notes' offset (`onsetNoteOffsetMs`) | When the onset notes are played, so they sit on the loop. Defaults to 0 | By ear ("Offset" under onset notes on Setup's Analysis page) |
| Chain offset (`chainRecOffsetMs`) | Where **Rec next loop** starts recording, so a chained loop is not rotated in its buffer. `saSystem` has 20 ms | Measured with `scripts/check-chain-align.scd`; the Calibrate view does not measure it |

They measure the paths your audio takes, so a number calibrated on one
interface is wrong on the next. What you apply on the Calibrate view is kept
per **setup**, the input and output devices and the buffer
("My Interface @ 64 frames"), in `calibration.json` in your megalooper
folder, and every start on that setup begins with it. **Forget** lets it go.
A value dialled by ear on Setup is not kept that way.

A setup with nothing kept yet starts from:

1. a rig of yours (below) on the same device, both ways, one with Megalooper SA
   first: the numbers kept for it, else its profile's;
2. else what `saSystem` kept before there were setups;
3. else `saSystem`'s own numbers.

The Calibrate view says which. The first start on such a device also takes
over that rig's **MIDI map**, unless `saSystem` uses a map of your own
already, and the status line says so. So moving from a rig of your own to the
menus keeps your map and your latency.

## Boot-time guards

These checks run before every start, because each of these failures is
silent otherwise:

- **Sample rate.** The input and output must run at the same rate, or the
  audio server refuses to start: megalooper names both devices and their
  rates. For the system's defaults, `python3 tools/coreaudio.py
  match-default-rates` sets them to agree ([Configuration](manual.md#configuration)).
- **Device present.** A device you chose that is not there gives way to the
  system's (above). A rig of yours whose device is missing stops the start
  instead, with a banner naming the rig, the device it wanted and every device
  there is: started on another device, its channels would all be wrong. Names
  match leniently (either one contained in the other), because SuperCollider
  shortens long and non-ASCII names: it lists "Das Zwölfer Microphone" as
  "Das Zwölfer Microphon".

## Rigs of your own

The menus cover one device in, one out, the instrument's and a bass's inputs
and the buffer. A **routing profile** of your own covers the rest:

- an **aggregate device** (several joined in Audio MIDI Setup), with its
  members named so the preflight can say which one dropped out;
- a **sample rate switched** before the start;
- several **fixed setups** you switch between by name, each with its own MIDI
  map and starting numbers.

With one, the launcher shows a **Rig** menu: `saSystem` (the menus) and each
of yours, which says its own device and inputs, so the audio menus are greyed
while it is chosen, and Setup's Rig page shows its name and device instead.

### Adding a rig

Write it into **`profiles.scd` in your megalooper folder**
(`~/Library/Application Support/SuperCollider/megalooper/` on macOS,
`~/.local/share/SuperCollider/megalooper/` on Linux). The file holds one
Event, a profile per key. An interface with your instrument on input 1 and a
bass on input 2, switched to 48 kHz:

```supercollider
// My rigs.
(
    myInterface: (
        device: "Exact CoreAudio Name", numChans: 2,
        inChannel: 0, analysisChannel: 0, bassChannel: 1,
        inChannelCount: 2, latencyMs: 15, sampleRate: 48000, setSampleRate: true,
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

### What a profile says

Channels are counted from 0: input 1 of the interface is channel 0.

| Field | What it is |
| --- | --- |
| `device` | The audio device, by its exact CoreAudio name. `\systemDefault` is the system's default input and output |
| `numChans` | How many channels SuperCollider opens, inputs and outputs |
| `numInChans` | Optional: more inputs than outputs, when an input you need sits above `numChans` |
| `inChannel` | Your instrument's input. The instrument chain starts here, and the looper records what comes out of the chain |
| `inChannelCount` | `2` records both sides of the instrument chain, so its stereo effects reach the loop |
| `analysisChannel` | Optional: the one input the onset and pitch detection listens to ([The analysis tap](#the-analysis-tap)). Left out, it listens to what the looper records |
| `bassChannel` | Optional: a bass on an input of its own ([A bass](#a-bass)) |
| `sa`, `live` | `sa: true, live: false`, both: Megalooper SA, with its mixer, chains, drums and synth. Leave `live: false` out and the Rig page shows controls meant for another setup, and the start runs checks it does not need |
| `memSize` | `65536`: the memory the effects' delay lines need |
| `sampleRate`, `setSampleRate` | Optional: the rate the rig is wired for. With `setSampleRate: true` the device is switched to it before the start |
| `hardwareBufferSize` | Optional: the block size to start with, in frames. The launcher's **Buffer** wins over it |
| `midiMap` | Optional: the MIDI map the rig starts with, by name |
| `latencyMs`, `onsetThreshold`, `onsetNoteOffsetMs`, `chainRecOffsetMs` | The rig's starting values ([The calibrated values](#the-calibrated-values)). What the Calibrate view keeps for the rig wins over them |
| `members` | Optional, for an aggregate device: the devices it should hold, so the preflight can name one that is missing |

### The device preflight

The guards above see a device's name. Aggregate devices fail more quietly
than that: a member drops out and the aggregate goes on working with fewer
channels. SuperCollider asks for 17 inputs, CoreAudio grants 16, and the
analysis tap reads a bus nothing fills, for the whole session, looking
exactly like a detection bug.

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
