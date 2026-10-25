# The effects

Megalooper SA has seven effects of its own: **Pitch Shift**, **Dual Delay**,
**Envelope Filter** and **Pitch Loops**, made for the instrument, and **Tape
Echo**, **Drive** and **Crusher**, made for the loop. Each was built after a
device in the Ableton Live set megalooper grew up on, and is tuned to sound
the way that set did.

How to add, move, switch and save them is in
[The chains](standalone.md#the-chains), in the Megalooper SA guide. Here is
what each one does, and every setting it has.

## What they have in common

- **Any chain, any number.** An effect goes in any chain (the instrument's, the
  bass's, the loop's, the drums' or the synth's) and as often as you like: a
  second one is called "Dual Delay 2".
- **Mono or stereo.** The four instrument effects are mono: they hear both sides
  of their chain mixed and play their effect on both, while the dry signal
  passes as it came. The three loop effects are stereo, each side on its own.
- **A switch never clicks.** On and off crossfade over 30 ms, so a
  footswitch can switch an effect on the beat.
- **Off costs nothing, mostly.** Once faded out, a switched-off Envelope
  Filter, Drive or Crusher stops computing. Pitch Shift, Dual Delay, Pitch
  Loops and Tape Echo keep running while off, so switched on they already
  hold the last moments of your playing, and a delay starts with its
  repeats.
- **Tempo.** The Envelope Filter's LFO and the Tape Echo's times follow the
  loop's tempo, which every new reading sets. Their changes glide.
- **Random** sets every setting at random but the output levels and the
  Envelope Filter's Makeup, so a new sound comes out about as loud.
  **Reset** puts the defaults back.
- **Feedback** stops at 90 % on every effect that has it, and what goes
  round is softened, so nothing can run away.
- **Footswitches.** In MIDI MAP mode, map a switch on your controller to
  an effect's square, any of its settings, Random or Reset. A second Dual
  Delay gets entries of its own.

megalooper's own sound, before you keep one of yours, has the instrument's four
in its instrument chain and the loop's three in its loop chain, in that order,
all switched off.

Every setting below is a knob or a menu on the effect's panel; hover over it
for the same words. Double-click a knob for its default.

## Pitch Shift

Shifts the instrument's pitch, up or down two octaves. With **Dry/Wet** at
100 % it replaces your note; lower, it plays beside it: a harmony at big
shifts, a chorus at small ones.

It has two ways to shift (**Mode**). *PitchShift*, the default, cuts the
sound into short overlapping grains and plays them faster or slower; its
grains are what **Window** and the two spreads shape. *FFT* keeps a steadier
pitch and smears attacks a little less, but its notes come about 8 ms
later. Every
change of mode or window crossfades, so you can make it while playing.

| Setting | Range | Default | What it does |
|---|---|---|---|
| **Coarse** | −24 to 24 st | 0 | The shift in semitones. 12 is an octave; big upward shifts get fizzy |
| **Fine** | −100 to 100 ct | 0.5 | The shift in cents, on top |
| **Mode** | PitchShift, FFT | PitchShift | How it shifts (above) |
| **Window** | 10 to 200 ms | 40 ms | PitchShift's grain length. Shorter smears attacks less but buzzes on low notes; longer is smoother and smears more |
| **Pitch spread** | 0 to 25 % | 0 | Each grain's pitch off by up to this much, at random. A little thickens, a lot warbles |
| **Time spread** | 0 to 100 % | 0 | Each grain starts up to this share of the window late, at random. Some breaks up the metallic sound of evenly spaced grains; a lot smears |
| **Dry/Wet** | 0 to 100 % | 100 % | Your instrument against the shifted one |

Pitch Shift is the one built-in effect that delays the sound: a little, and
more the further it shifts.

## Dual Delay

Two delay taps whose times wobble, slowly and at random, in opposite
directions. At its defaults the first tap is 1 ms, a near-dry copy, and the
second 438 ms, an echo the wobble detunes: a wide, slightly seasick double
of everything you play. With **Feedback** up it becomes an ordinary
repeating delay, still wobbling.

| Setting | Range | Default | What it does |
|---|---|---|---|
| **L Time** | 1 ms to 2.5 s | 1 ms | The first tap |
| **R Time** | 1 ms to 2.5 s | 438 ms | The second tap. A change glides, so the pitch bends while you turn it |
| **Feedback** | 0 to 90 % | 0 % | Each tap back into itself |
| **Dry/Wet** | 0 to 100 % | 100 % | At 100 % only the two taps; lower keeps the plain note under them |
| **LFO > Time** | 0 to 5 % | 0.5 % | How far the wobble pulls the taps' times |
| **LFO Rate** | 0.05 to 40 Hz | 9.45 Hz | How often the wobble picks a new speed. The speeds glide from one to the next |
| **Wobble Min** | 0.01 to 10 Hz | 0.01 Hz | The slowest wobble |
| **Wobble Max** | 0.01 to 40 Hz | 1.2 Hz | The fastest wobble |

Variations: *long*, *short* and *delay*.

## Envelope Filter

A filter that your picking opens and an LFO sweeps in time with the loop.
Every note opens it by how hard you play it, then it closes over the
**Release**; the LFO moves it once a beat on top of that. At its defaults it
is mostly a low-pass at 311 Hz, a dark quack that brightens on every pick.

All its types are 24 dB per octave. *Morph*, the default, slides from
low-pass through band-pass to high-pass as **Morph** goes from 0 to 100 %.

| Setting | Range | Default | What it does |
|---|---|---|---|
| **Type** | Low-pass, High-pass, Band-pass, Notch, Morph | Morph | The filter |
| **Frequency** | 30 Hz to 18 kHz | 311 Hz | The cutoff. The envelope and the LFO move it from here |
| **Res** | 0 to 100 % | 31 % | Resonance |
| **Morph** | 0 to 100 % | 16 % | With Type Morph: 0 % low-pass, 50 % band-pass, 100 % high-pass |
| **Envelope** | −100 to 100 % | +76 % | How far your picking moves the cutoff; 100 % is four octaves. Negative moves it down instead |
| **Sense** | 0.5 to 30× | 3× | How hard a pick has to be to reach the top of the envelope. Higher reacts to softer playing |
| **Release** | 10 ms to 3 s | 250 ms | How fast the envelope lets go after a note |
| **LFO Wave** | Sine, Triangle, Saw, Square, Ramp Up, Ramp Down, Wander, S&H | Ramp Up | The LFO's shape. Wander glides at random; S&H jumps at random |
| **LFO Amt** | 0 to 100 % | 89 % | How far the LFO moves the cutoff; 100 % is three octaves each way |
| **LFO Sync** | Free, 1/64 to 2/1 | 1/4 | One LFO cycle per this note value at the loop's tempo, triplets (T) and dotted (D) too. It runs from its own phase, not from the bar line |
| **LFO Rate** | 0.05 to 20 Hz | 1 Hz | The LFO's speed while Sync is Free |
| **Makeup** | 0 to 100 % | 0 % | Brings a quiet filtered sound back towards the instrument's level, by up to 26 dB |
| **Output** | −24 to 0 dB | 0 dB | The level after a soft clip |

Variations: *low pass*, *notch*, *fast*, and five more by number.

## Pitch Loops

Replays pieces of the last few seconds of your playing in two voices, behind
you. The first plays each piece **reversed a fifth up**, starting about
800 ms back; the second plays it **forwards an octave up**, a little behind
you. Together they make a shimmering, backwards halo that follows what you
play.

Each voice has its own pitch, how far back its pieces start (**Position**),
how long they are (**Segment**), and an LFO and a random amount that push
each piece further back. Positions and segments are held to what fits its
six-second memory, so a low pitch with long pieces may not go as far back
as the knob says. **Feedback** puts the two voices back into the memory, so
each pass is shifted again and the sound climbs.

| Setting | Range | Default | What it does |
|---|---|---|---|
| **Dry/Wet** | 0 to 100 % | 37 % | Your instrument against the two voices |
| **Pitch L** | −24 to 24 st | +7 st | The reversed voice's transposition |
| **Position L** | 10 ms to 1.5 s | 796 ms | How far behind your playing each reversed piece starts |
| **Segment L** | 20 to 900 ms | 289 ms | How much audio each reversed piece holds; played in less as the pitch goes up |
| **LFO Rate L** | 0.01 to 10 Hz | 1.98 Hz | The sine LFO on the reversed voice's start |
| **LFO Depth L** | 0 to 1 s | 688 ms | How much further back that LFO can push a piece, taken once per piece |
| **Rand. L** | 0 to 200 ms | 0 | A random extra distance for each reversed piece |
| **Pitch R** | −24 to 24 st | +12 st | The forward voice's transposition |
| **Position R** | 10 ms to 1.5 s | 130 ms | How far the forward voice trails. A voice pitched up is held far enough back not to catch up with you (290 ms at +12) |
| **Segment R** | 20 to 900 ms | 289 ms | Audio per piece of the forward voice |
| **LFO Rate R** | 0.01 to 10 Hz | 1 Hz | The sine LFO on the forward voice's start |
| **LFO Depth R** | 0 to 1 s | 0 | How much further back that LFO can push a piece |
| **Rand. R** | 0 to 200 ms | 33 ms | A random extra distance for each forward piece |
| **Feedback** | 0 to 90 % | 0 % | The voices back into the memory |
| **Hi Cut** | 500 Hz to 18 kHz | 11 kHz | A high cut on both voices |
| **Output** | −36 to 6 dB | −5.5 dB | The two voices' level |

Five variations, by number.

## Tape Echo

An echo on the loop, timed in note values at the loop's tempo, with the
irregularity of tape. Its repeats are band-limited (only the middle,
520 Hz to 3.1 kHz, comes back), get a little reverb of their own, and
**duck** under the loop: while the loop is loud they drop by 14 dB, and they
come up in its gaps.

At its defaults it runs **Mid/Side**: the first line times the middle of the
stereo picture and the second the sides. A mono loop has no sides, so only
the first line is heard, a slap a dotted 1/32 late (about 68 ms at
165 BPM). Choose **Stereo** to hear both lines, left and right.

Its **Dry/Wet** is a plain crossfade: at the default 66 % the loop itself
drops to a third while the Tape Echo is on, and the repeats sit on top.

| Setting | Range | Default | What it does |
|---|---|---|---|
| **L Synced** | 1/64 to 1/2 | 1/32 D | The first line's note value, triplets (T) and dotted (D) too |
| **R Synced** | 1/64 to 1/2 | 1/8 D | The second line's |
| **Channels** | Stereo, Mid/Side | Mid/Side | Left and right lines, or middle and sides (above) |
| **Feedback** | 0 to 90 % | 16.7 % | How much of each repeat comes round again |
| **HP Freq** | 20 Hz to 18 kHz | 520 Hz | Cuts the lows from the repeats |
| **LP Freq** | 20 Hz to 18 kHz | 3.1 kHz | Cuts the highs from the repeats; the echo's LFO sweeps it, once every two beats |
| **Duck Thr** | −60 to 0 dB | −29 dB | While the loop is louder than this, the repeats drop. 0 dB never ducks |
| **Duck Rel** | 20 ms to 1.5 s | 98 ms | How soon the repeats come back after the loop falls |
| **Reverb** | 0 to 100 % | 19.8 % | The echo's own reverb on the repeats |
| **Rev Decay** | 0 to 100 % | 27.3 % | How long that reverb rings |
| **Wobble** | 0 to 100 % | 23.4 % | Tape-like irregularity in the time |
| **Output** | −24 to 12 dB | +6 dB | Gain on the repeats |
| **Dry/Wet** | 0 to 100 % | 66 % | The loop against the repeats, a linear crossfade |

## Drive

A saturation for the loop that drives the lows hardest. Before the curve it
boosts the lows a lot (**Amt Lo**) and a band around 108 Hz some more
(**Amt Hi**); after it, it takes both boosts out again. So the low notes
distort without booming, and the tone stays about where it was.

| Setting | Range | Default | What it does |
|---|---|---|---|
| **Type** | Analog Clip, Soft Sine, Medium, Hard Curve, Sinoid Fold, Digital Clip | Medium | The curve. Medium is smooth; Hard Curve and Digital Clip are harder; Sinoid Fold folds loud peaks back over |
| **Amount** | −36 to 36 dB | +6.5 dB | Gain into the curve |
| **Amt Lo** | −36 to 36 dB | +35.8 dB | How much harder the lows, below 250 Hz, hit the curve |
| **Frequency** | 30 Hz to 18 kHz | 108 Hz | The centre of the Amt Hi band |
| **Width** | 5 to 100 % | 84 % | The width of that band |
| **Amt Hi** | −24 to 24 dB | +8.6 dB | How much harder that band hits the curve |
| **Output** | −36 to 0 dB | −9.6 dB | The level after the curve. Turn it down as Amount goes up |
| **Dry/Wet** | 0 to 100 % | 57 % | The plain loop against the driven one |

Variations: *brutal*, *loop-playback*, *gut mit redux*, *obertöne*, and two
more by number.

## Crusher

Fewer samples and fewer bits: the loop sampled about 7,200 times a second
at 5 bits, the grit of an early sampler. The sample rate jitters a little
at random, which keeps it from sounding too clean.

| Setting | Range | Default | What it does |
|---|---|---|---|
| **Sample Rate** | 0.05 to 40 kHz | 7.2 kHz | How often the loop is sampled. Lower is grittier |
| **Jitter** | 0 to 100 % | 2.5 % | Randomness in the sample rate |
| **Bit Depth** | 1 to 16 | 5 | Fewer bits, coarser steps |
| **DC Shift** | Off, On | On | On: even silence sits half a step off zero, so quiet playing buzzes instead of cutting out |
| **Pre-Filter** | Off, On | Off | Smooths the loop before it is sampled: less fizz and fewer stray tones |
| **Post-Filter** | Off, On | Off | A low-pass after the crusher, at Post Freq |
| **Post Freq** | −4 to 4 oct | −3 oct | Where the post-filter cuts, in octaves from half the sample rate |
| **Dry/Wet** | 0 to 100 % | 80 % | The plain loop against the crushed one |

Variations: *heavy distorted*, *loop-playback*, and one more by number.
