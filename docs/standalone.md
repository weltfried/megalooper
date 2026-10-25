# Megalooper SA: megalooper on its own

Megalooper SA plays the instrument's effects, the bass's, the loop's effects and
the drums itself, so no Ableton Live is needed. This guide covers the effect chains,
sounds and plugins. The looper, the cutter, the grains and the MIDI map work
as [the manual](manual.md) says on every rig.

## Starting it

Pick a rig whose profile has SA switched on:

- **saSystem**, megalooper's own and the one the launcher offers first, uses
  the system's input and output, with your instrument on input 1 and the mix on
  outputs 1 and 2. Nothing about your interface is changed.
- A profile of your own in `profiles.scd`, for an interface with more
  channels, a bass, or a fixed sample rate: [Rigs and
  routing](routing.md#adding-a-rig) says how to write one.

**A bass.** A rig of yours with a bass on its own input says so in its
profile: `bassChannel: 1` for input 2. The bass then plays through its own chain, the **BASS** row on the FX view, onto a strip of
its own: **Bass** under Levels on Setup's Rig page and on Perform, with a MIDI
target for its level and its mute. Recording the set (Record set) writes it
as a stem of its own (`-bass.wav`). The loop records the instrument only; looping
the bass is not there yet. saSystem has no bass input, because on a laptop
input 2 is the microphone.

Then open the **FX** view (key **3**) for the effects. The drums have a view
of their own, **Drums** (key **4**).

**Set the latency once.** saSystem assumes 30 ms for the way out and back in.
Run the round-trip step on the Calibrate view ([Calibrate](#calibrate)), or
overdubs will land late or early.

## Calibrate

Once per rig, open **Calibrate** (key 6, or from Setup's Rig page). Without
Ableton Live it has four steps:

1. **Check the rig.** What megalooper found: the interface, its rate and
   block size, and whether VSTPlugin is there.
2. **Input level.** Press Measure and play hard for eight seconds. Turn the
   interface's input gain until the loudest hit comes in between -12 and
   -3 dBFS. Too quiet and soft notes go unnoticed; clipped and every hit
   looks the same.
3. **Onset threshold.** Set it on Setup's Analysis page while you
   play, then press Done.
4. **Overdub round trip.** Stop the loop. With an interface, patch a cable
   from output 1 into the instrument input (the instrument is muted while it
   measures, so there is no feedback); on a computer's own speakers and
   microphone there is nothing to patch. Press Measure, then Apply. If it
   cannot be measured, set Overdub latency by ear on Setup's Rig page and
   press **Start with this**.

What you apply is kept for that rig in `calibration.json` in your megalooper
folder, and every start begins with it. **Forget** on the Calibrate view goes
back to the rig's own numbers.

## The chains

- **The instrument chain** (the **INSTRUMENT** row) is what you play through. The loop records its output.
- **The bass chain** is what the bass plays through, on a rig with a bass
  input. It goes to the mix only: the loop does not record it.
- **The loop chain** plays the recorded loop.
- **The drums chain** plays the drums' steps, before their reverb. It starts
  empty. The onset kit does not pass through it.

Each chain is a row of tiles, played left to right.

![The FX view](images/fx.png)

*Fig: The FX view (3) on saSystem, with Dual Delay, Envelope Filter, Tape Echo and Drive switched on, and the Envelope Filter's panel open under the chains.*

| To | Do this |
|---|---|
| Edit an effect | Click its tile: its settings appear below |
| Switch it on or off | Click the square in its tile's corner (■ on, □ off), or press its footswitch. A click anywhere else on the tile never changes the sound |
| Add an effect or a plugin | Press **+** at the end of the chain |
| Move an effect | Drag its tile along the chain, or onto the other chain. Esc lets go |
| Move or remove it by menu | Click its tile, then press **⋯** |
| Put a setting back to its default | Double-click it, or **Reset** for the whole effect |
| Keep an effect's settings | Type a name beside **Save variation**, under the effect's title, and press it. The variation holds every setting, and the menu beside it lists it for every effect of that type (both Delays, say). The same name again replaces it; **Delete:** in the menu removes it |
| Try out a random sound | **Random** beside Reset: every setting of the effect at a random value. Output levels (and the Envelope Filter's Makeup) stay where they are, and **Reset** brings the starting values back. Random and Reset are also MIDI targets, so a footswitch can draw a new sound |
| Undo an edit | Cmd+Z. Shift+Cmd+Z redoes |

Edits are safe while a loop plays: the chain cross-fades to its new order.
An effect brought back by Undo keeps its settings.

The built-in effects are Pitch Shift, Dual Delay, Envelope Filter, Pitch
Loops, Tape Echo, Drive and Crusher. You can add any of them more than once.
[The effects](effects.md) says what each one does, with every setting.

### Variations

Each effect's menu lists the variations from the Live set megalooper was built
after (Dual Delay, Envelope Filter, Pitch Loops, Drive and Crusher have some), then yours,
marked **· yours**. A Live set variation sets only the settings its rack's
macros drove; one of yours sets them all. Yours are kept in
`sa/fx-variations.json` in your megalooper folder, apart from the sounds; a
Live set variation's name cannot be taken for one of yours.

## Sounds

A sound is all the chains as one file: which effects in which order, every switch
and setting, and each plugin's own state.

- **Save and recall.** The bar above the chains saves the sound under a name
  and recalls it from the menu. A recall with the same effects changes only
  settings and never flips a switch. One with other effects rebuilds the
  chains, also while a loop plays.
- **Start with this** makes this sound the one megalooper starts with. A dot on the
  tile means something is not kept yet.
- **While a loop plays, a plugin's own sound is not written.** Writing it
  would silence the plugin for a moment. megalooper keeps the chains and says
  so; stop the loop and press again to keep the plugin's sound too.
- **Recover.** If you edited the chains and quit without keeping them, the
  next start offers them back. Nothing is loaded by itself.

Sounds are in `sa/sounds/` in your megalooper folder
(`~/Library/Application Support/SuperCollider/megalooper/`), and the kept one
is `sa/kept.json`. The last five kept sounds are in `sa/backups/kept/`. You
can copy a sound's `.json` file and its `.states` folder to another Mac.

## Plugins

megalooper hosts VST2 and VST3 effects through
[VSTPlugin](https://git.iem.at/pd/vstplugin). `./tools/install.sh` fetches
version 0.6.2 into SuperCollider's Extensions, unless a copy is there
already. Without VSTPlugin megalooper plays its built-in effects and lists no
plugins.

### Installing VSTPlugin by hand

On macOS:

1. Download VSTPlugin 0.6.2 from
   <https://git.iem.at/pd/vstplugin/-/releases>.
2. Put the `VSTPlugin` folder from the zip's `sc` folder into
   `~/Library/Application Support/SuperCollider/Extensions`.
3. Delete `VSTPlugin_supernova.scx` from that folder's `plugins` folder.
4. A copy downloaded in a browser is quarantined, and macOS refuses to run
   it. Clear the flag:
   ```bash
   xattr -dr com.apple.quarantine "$HOME/Library/Application Support/SuperCollider/Extensions/VSTPlugin"
   ```
5. Restart megalooper.

On Linux, put the `VSTPlugin` folder from the Linux zip's `sc` folder into
`~/.local/share/SuperCollider/Extensions`. Steps 3 and 4 are macOS's alone.

megalooper checks all of this at every start and names what is wrong, in the
post window or in `~/Library/Logs/megalooper.log`.

### Finding and adding plugins

1. Stop the loop, press **+** on a chain and choose **Scan for plugins…**.
   The scan runs beside megalooper and can take a minute. What it did is in
   `sa/plugins/scan.log` in your megalooper folder.
2. Press **+** again. Your plugins are listed by maker, under the built-in
   effects.
3. Choose one. Its tile appears at the end of the chain, and the status line
   under the chains says when it is open.
4. To see the plugin's own window, click its tile and press **⋯**, then
   **Open its window**.

What to expect:

- **Effects only.** Instruments are not listed. Audio Units are not hosted.
- **Intel-only plugins are greyed.** megalooper does not use VSTPlugin's
  bridge yet.
- **A plugin that adds delay is held back.** With more than 64 samples of
  reported delay, the chain plays without it and its tile says why.
- **A plugin that is not on this Mac keeps its place.** A sound that names
  one shows it as missing and keeps its state, so nothing is lost when you
  save the sound again.
- **A plugin that crashed megalooper is skipped once.** The next start leaves
  it closed and says so; the start after that tries it again.

### An amp for the guitar

megalooper has no amp simulator of its own, and a DI guitar through the
built-in effects alone sounds thin. Add an amp plugin to the instrument chain.
These are free and come as VST3. None of them was tested with megalooper:

- [Neural Amp Modeler](https://www.neuralampmodeler.com/)
- [AmpliTube 5 CS](https://www.ikmultimedia.com/products/amplitubecs/)
- [Guitar Rig Player](https://www.native-instruments.com/en/products/komplete/guitar/guitar-rig-7-player/)
- [Blue Cat's Free Amp](https://www.bluecataudio.com/Products/Product_FreeAmp/)

## MIDI

Every switch, every knob and each effect's Reset can be mapped: press
**MIDI MAP** in the top bar, click the control, and move a knob or press a
switch on your controller. A second Dual Delay gets its own entries.
[The manual](manual.md#midi) has the details.

### A footswitch for something inside a plugin

A plugin's own switches, such as an amp simulator's scenes, are learnt
inside the plugin from a MIDI controller. A hosted plugin hears none of your
controllers, because megalooper does. So megalooper sends:

1. Click the plugin's tile. Its page has a row **MIDI to the plugin**, with
   the numbers 1 to 8.
2. In the plugin's own window, start its MIDI learn for the thing to switch.
3. Click a number in megalooper. The plugin learns the controller it sends
   (CC 20 to 27).
4. Press **MIDI MAP**, click that number, and press your footswitch.

A plugin's knobs cannot be mapped yet.

## On a slower computer

- **Switch off what you don't play.** Once it has faded out, a switched-off
  Envelope Filter, Drive or Crusher stops computing, and so does any plugin:
  it costs nothing until you switch it on again. Dual Delay, Tape Echo, Pitch
  Loops and Pitch Shift keep running while off, so that switched on they
  already hold the last seconds of your playing.
- **The drums rest when they are quiet.** Their reverb and the onset kit's
  chain stop a second after the last drum has rung out, and the next hit
  wakes them. While a device on the drums' chain is on, the reverb stays
  awake for it.
- **A bigger buffer.** If you hear clicks or gaps, pick 256 frames under
  **Buffer** in the launcher. At 48 kHz that adds about 5 ms each way, so run
  the round-trip step on the Calibrate view again afterwards.
- The **CPU** figure in the top bar is the audio server's load. It turns red
  past 60 %.

## When something is wrong

- **The status line** under the chains names a plugin that failed, is
  missing or is held back.
- **Copy diagnostics**, at the end of the **⋯** menu, puts megalooper's
  state on the clipboard: versions, the chains, each plugin's state. Paste it
  into a bug report.
- **Cmd+Period** stops the server and everything on it. Start megalooper
  again afterwards.
