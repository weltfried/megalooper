# megalooper

A live looper for SuperCollider that works out the meter from what you played.
Record a phrase in free time and megalooper finds its tempo and its meter,
odd ones like 7/8 included, from the onsets in the audio.

It is a whole instrument on its own, **Megalooper SA**: beside the looper it
hosts effect chains for your instrument and the loop, your VST plugins, the
drums and a synth.

It was built for a guitar and bass duo and is used on stage, on macOS. A
Linux port is new and untried: see [megalooper on Linux](docs/linux.md).

## What it does

- **Finds the meter.** Twelve meters from 2/4 to 12/8, over one to four bars,
  with the downbeat placed by where the accents fall. And loops whose bars
  are not all alike, like three bars of 7/8 and one of 8/8, found from the
  rhythm and the notes you played, or typed in by hand.
- **Loops.** Overdub with undo, reverse, multiply, loop chaining, and
  overdubs shifted by your measured round-trip latency so they land in time.
- **Cuts and grains.** A BBCut layer and a granular layer over the loop, each
  with presets.
- **Effect chains (SA).** Chains for your instrument, the loop, the drums and
  the synth, and for a bass on a second input, with fourteen built-in effects and your VST2
  and VST3 plugins. Add, drag and remove effects while a loop plays. Random
  throws new settings at an effect, and a variation keeps the ones you like.
  A sound is one file: the chains, every setting and each plugin's state.
  See [The effects](docs/effects.md).
- **Drums (SA).** Step patterns and a kit triggered by the loop's own onsets.
  They start with a new loop, or wait until you switch them on.
- **A synth (SA).** A note sequencer of 8 or 16 steps, its seven lanes
  (pitch, octave, velocity, length, time shift, ratchet, condition) free to
  run at lengths of their own, with scales and swing, playing a built-in
  wavetable synth (on your own wavetables too) or one of your VST
  instruments. It keeps time with the loop and starts again on its bar
  lines, uneven ones too. The Synth view (7), and a column on Perform. See
  [The synth](docs/synth.md).
- **AI apps (SA, optional).** Ask an AI app such as Claude Desktop for a
  groove that fits your 7/8, a synth line over the chords you played, a
  dubbier echo or a granular drone, and hear it at once; one click reverts it. Off until you
  switch it on. See [AI apps](docs/ai.md).
- **MIDI.** Every control can be mapped to your controller by clicking it and
  moving a knob. MIDI clock and transport go out on macOS's IAC bus, for
  other apps on the Mac, when the IAC Driver is switched on in Audio MIDI
  Setup.
- **Records the set.** The audio of a whole set and a log of everything
  pressed, into `sessions/`.

## What you need

- **macOS 11 or later**, on an Apple Silicon or an Intel Mac. megalooper was
  built and measured on Apple Silicon, and installs and runs on Intel too.
  Or **Linux**, as a first port:
  [megalooper on Linux](docs/linux.md) has its own install steps.
- **SuperCollider 3.14.1 or later.** <https://supercollider.github.io/>, or
  `brew install --cask supercollider`.
- **sc3-plugins**, the release built for your SuperCollider version. The
  installer fetches it on macOS; on Linux it comes from your distribution's
  packages.
- **BBCut.** The installer fetches it.
- **VSTPlugin 0.6.2**, only if you want plugins in the chains. The installer
  fetches it. [Plugins](docs/standalone.md#plugins) says how to add it by
  hand.

Optional, for [AI apps](docs/ai.md) other than Claude Desktop only:
**Python 3.9 or later**, which runs the bridge between the app and
megalooper. Claude Desktop needs nothing: megalooper installs an extension
into it.

SuperCollider, sc3-plugins and BBCut are needed for the class library to
compile. Without any one of them nothing runs, not even the tests.

## Install

```bash
git clone https://github.com/weltfried/megalooper.git
cd megalooper
./tools/install.sh
```

The installer:

1. checks that SuperCollider is there, and says what to do if not;
2. fetches sc3-plugins, the release built for your SuperCollider, unless you
   have it;
3. fetches BBCut, at the commit megalooper is tested against;
4. fetches VSTPlugin 0.6.2, unless you have it (`--no-vstplugin` skips it);
5. links megalooper's classes into SuperCollider's Extensions;
6. runs the quick checks, which must end with `ALL CHECKS PASSED`;
7. builds the Desktop icon.

Each download is checked against the file megalooper was tested with, and
everything goes into `~/Library/Application Support/SuperCollider/Extensions`.

It deletes nothing of yours, and you can run it again, for instance after moving this
folder. `./tools/install.sh --help` lists its options.

If SuperCollider is open, restart it afterwards, or recompile the class
library (Cmd+Shift+L).

## First run

**Use headphones.** A laptop's microphone into its own speakers feeds back,
and the looper plays while it records.

1. Double-click **megalooper** on the Desktop (or run `./tools/megalooper`).
2. In the launcher, choose where your instrument comes in and where the mix
   goes: the **Input** and **Output** devices (System default follows the
   Mac's Sound settings), the input your **Instrument** is plugged into, and a
   **Bass** on an input of its own if you have one. The mix plays on the
   output's 1 and 2. megalooper keeps your choice for the next start.
   ([Audio settings](docs/routing.md))
3. Press **Start megalooper** and wait for the window. On a slower computer
   that clicks or drops out, pick 256 frames under **Buffer** first.
4. With the megalooper window in front, press **R** to record, play a
   phrase, and press **R** again. The status band shows the meter and the
   tempo it found. **S** stops, **C** clears.

From the SuperCollider IDE, open `scripts/boot.scd` and evaluate its block.
The rig then comes from `~defaultRoutingProfile` in `scripts/setup-routing.scd`.

Under the icon there is no post window. Everything megalooper says goes to
`~/Library/Logs/megalooper.log`.

## Where your files are

Everything you save lives in
`~/Library/Application Support/SuperCollider/megalooper/`, never in this
folder:

| Folder | What it holds |
|---|---|
| `profiles.scd` | Your own rigs, beside megalooper's saSystem ([Rigs of your own](docs/routing.md#rigs-of-your-own)) |
| `bbcut/`, `granular/` | The cutter's and the grains' presets |
| `midi/`, `midi/backups/` | Your MIDI maps, and the last five versions of each that **Keep** wrote over |
| `sa/kept.json`, `sa/sounds/` | The sound a boot starts with, and the sounds you saved |
| `sa/drum-presets/`, `sa/kept-drums/` | The drums' presets, and the drums a boot starts with |
| `sa/synth-presets/`, `sa/kept-synth/`, `sa/wavetables/` | The synth's presets, the synth a boot starts with, and your wavetables |
| `sa/plugins/` | The list of plugins megalooper found |
| `settings.json` | Your choices: the audio devices and inputs, the MIDI map each rig uses, which MIDI inputs megalooper listens to, the theme, the help lines, AI apps on or off |
| `calibration.json` | What the Calibrate view found, per audio setup (devices and buffer) or rig of yours |
| `remote.json`, `remote/` | While AI apps are let in: how one reaches megalooper ([AI apps](docs/ai.md)) |
| `megalooper.mcpb` | The Claude Desktop extension, made when you press **Install in Claude Desktop** |

The launcher keeps the rig you last picked in
`~/Library/Application Support/SuperCollider/megalooper-launcher.txt`; the
audio settings are in `settings.json`.

Recorded sets go to `sessions/` in this folder, which git ignores.

## Guides

| Guide | For |
|---|---|
| [Megalooper SA](docs/standalone.md) | The effect chains, sounds and plugins |
| [The effects](docs/effects.md) | The fourteen built-in effects, and every setting they have |
| [megalooper on Linux](docs/linux.md) | Installing and starting it there, and what differs |
| [Drums](docs/drums.md) | Getting a kit, and making one from your own samples |
| [The synth](docs/synth.md) | The note sequencer, the Wave synth, your wavetables and VST instruments |
| [Audio settings](docs/routing.md) | The input and output, a bass, calibration per setup, and rigs of your own |
| [The manual](docs/manual.md) | Every control, the MIDI map, the cutter, the grains, calibration, how the meter is found |
| [MIDI map files](docs/midi-maps.md) | The JSON a map is kept in, to write or share one |
| [AI apps](docs/ai.md) | Letting an AI app such as Claude Desktop read the set and change the drums, the synth, the effects, the Grains and the Cutter |

## Known limits

- **Linux is new.** It has run on one machine so far (Omarchy, on Arch).
- **No Audio Units.** Plugins are VST2 and VST3: effects in the chains, and
  an instrument for the synth. A plugin built only for Intel is listed but
  cannot be added.
- **Plugin delay is not compensated.** A plugin that reports more than 64
  samples of delay is held back: its chain plays without it and says why.
- **Effects are added by menu.** A tile moves by dragging; dragging a new
  effect in from a list is planned.
- **The drums ship without audio.** The kits megalooper was built on play
  Ableton's samples, which cannot be passed on. See [Drums](docs/drums.md).
- **The public default chain has no amp.** A DI guitar through the built-in
  effects alone sounds thin: add an amp simulator plugin
  ([some free ones](docs/standalone.md#an-amp-for-the-guitar)).

## Licence

**GPL-3.0-or-later**, the same as SuperCollider. See [LICENSE](LICENSE).

megalooper's cutter layer subclasses BBCut, so the project as a whole is GPL.
[NOTICE](NOTICE) says why, lists every dependency with its licence, and names
the trademarks megalooper mentions. No third-party code or audio is in this
repository: you install each dependency from its own source.

`classes/MeterAnalyzer.sc` and `classes/PitchAnalyzer.sc` need nothing but
SuperCollider's class library, if the meter detection is the part you want.

## Trademarks

Ableton and Live are trademarks of Ableton AG. BIAS FX is a trademark of
Positive Grid. VST is a trademark of Steinberg Media Technologies GmbH.
Claude is a trademark of Anthropic, PBC. They are named here only to say what megalooper works with; megalooper is not
affiliated with, or endorsed by, any of them.
