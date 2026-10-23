# The drums

Megalooper SA has two drum parts, on the **Drums** view (key **4**):

- **The steps**: two step patterns, a main one and a break, locked to the
  loop's tempo and meter.
- **The onset kit**: a kit played by the loop's own onsets, so the drums
  follow the rhythm you played.

Each part plays a **kit**: a set of samples on pads.

The steps start with every new loop you record. To have them wait instead,
set **New loop** to **Drums off** on the Setup view's Rig page, under Megalooper SA's
levels. A new loop then keeps the drums in time but silent, until you switch
them on: Program Change 17, or the switch on the Drums view. Overdubs leave
them as they are. megalooper keeps the choice for the next start.

## Why the drums are hidden at first

megalooper ships each kit's map and none of its audio. The kits it was built
on play samples that come with Ableton Live, and those cannot be passed on.
Until one kit has its samples on your machine, the Drums view shows a note
and an **Import samples…** button, and nothing else.

There are two ways to get a kit. Both use `tools/export-live-set.py`, which
needs Python 3 and nothing else. The button runs it for you on a folder of
your own samples. A kit made in a terminal shows after megalooper is started
again.

## A kit from Ableton Live

With Live 12 Suite installed, this copies the samples of six drum machines
from Live's Core Library into megalooper's kits folder:

```bash
python3 tools/export-live-set.py kits --only core-808,core-909,core-707,core-c78,core-dry-session,core-flares
```

Without `--only` it also builds the kits of the set megalooper was built
after (`carbon`, `carbon-layer`, `one-hit`), which need Live's packs too.

megalooper starts each part on its usual kit. If that kit has no samples
here, it starts on the first kit that has.

## A kit from your own samples

Put one-shots (wav, aif, flac or ogg) into a folder. Then, on the Drums view:

1. Press **Import samples…**. It is at the top of the Drums view, beside
   **Reset pattern**, or on the note when no kit has its samples yet. It is
   there whenever you want another kit.
2. Choose the folder.
3. A line by the button says how many pads the kit has and which files it
   could not place. The Steps part plays the new kit at once, and
   both kit menus list it. There is no restart.

The kit is named after the folder. Its samples are copied into megalooper's
kits folder, so the folder you chose can be moved or deleted afterwards.
Importing the same folder again replaces its kit: rename the files that
were not placed, and import again. megalooper keeps playing while the
import runs.

The same from a terminal, with a key of your choice (megalooper shows the
kit at its next start):

```bash
python3 tools/export-live-set.py kits --folder ~/Samples/MyKit --key mykit
```

Either way, the files are placed on pads by words in their names:

| Word in the file name | Pads (MIDI notes) |
|---|---|
| kick | 36 |
| rim, side | 37 |
| snare | 38, 40 |
| clap | 39 |
| hat closed, chh | 42 |
| hat pedal | 44 |
| hat open, ohh | 46 |
| tom, from low to high | 41, 43, 45, 47, 48, 50 |
| crash | 49 |
| ride | 51 |
| perc, shaker, cowbell and the like | the pads still free, up to 51 |

The tool prints where each file went and lists the ones it could not place.
Rename those and run it again.

## Choosing a kit

Each part has a kit menu on the Drums pane. A kit's line says whether it is
ready, and how many pads it plays. **— none —** silences a part.

## Where things are

- **Kits** are in `presets/sa/drums/kits/` in megalooper's folder: one
  `<key>.json` per kit, with its samples in a folder of the same name. Git
  ignores the audio there. A kit you made shows up in `git status` as a new
  `.json` file.
- **Drum presets** are in `sa/drum-presets/` in your megalooper folder
  (`~/Library/Application Support/SuperCollider/megalooper/`).
- **The drums a start begins with** (the pane's **Start with this**) are in
  `sa/kept-drums/drums.scd` there.

## The kit file

A kit is JSON. The shortest one that plays:

```json
{ "version": 1, "key": "mykit", "name": "My kit",
  "pads": { "36": { "name": "Kick",
                    "layers": [ { "file": "mykit/Kick 1.wav" } ] } } }
```

`file` is relative to the kits folder. A pad can have several layers, each
with its own level, tuning and velocity range, and pads can choke each other.
Every field and its default is listed at the top of `classes/MegaSAKit.sc`.

To check every kit against its files:

```bash
python3 tools/export-live-set.py kits --check
```
