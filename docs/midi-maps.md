# MIDI map files

A MIDI map is a JSON file: data only, nothing in it runs. megalooper ships one
(`presets/midi/keys-and-knobs.json`), and the maps you keep from MIDI MAP mode
go to your megalooper folder. The easiest way to
make one is MIDI MAP mode (the manual's *MIDI map* section); this page is for
reading one, writing one by hand, or sharing one.

## An example

A map for a floor controller: a program change for a footswitch, a CC for
the expression pedal, a CC switch, and a knob.

```json
{
  "format": "megalooper midi map",
  "version": 1,
  "name": "my-floorboard",
  "bindings": [
    {"msg": "program", "num": 4, "device": "My Floorboard", "target": "looper.trigger"},
    {"msg": "cc", "num": 7, "device": "My Floorboard", "target": "looper.intensity", "inHi": 126, "hysteresis": 2},
    {"msg": "cc", "num": 80, "device": "My Floorboard", "target": "looper.recordNextLoop", "switch": "oneMessage"},
    {"msg": "cc", "chan": 0, "num": 21, "device": "My Floorboard",
     "target": "sa.fx.echoMix", "min": 0.2, "max": 0.8, "takeover": "pickup"}
  ]
}
```

`format` must read `"megalooper midi map"`. megalooper writes one binding per
line, with its keys in a fixed order, so two versions of a map compare well.

`name` is for people; megalooper calls a map by its file's name. `basedOn`
and `revision` say which shipped map, at which revision, yours started from:
when megalooper ships a newer one, the MIDI map section says so.

To use a map someone sent you, put the file into `midi/` in your megalooper
folder and pick it under **Map**. Or press **Load from…**: that puts its
bindings into the map you use now, under that map's name, and **Keep** keeps
them.

## A binding's fields

| Field | Values | When it is missing |
|---|---|---|
| `msg` | `note`, `cc`, `program`, `bend` | required |
| `chan` | 0–15 (megalooper's screens show 1–16) | any channel |
| `num` | 0–127 | required (bend has none) |
| `device` | the MIDI input's device name, as Setup's MIDI & AI page lists it | any listening input |
| `port` | the input's port name; only with `device` | any port of the device |
| `target` | the control's id, such as `looper.trigger` or `sa.fx.echoMix`: see [Control ids](#control-ids) below | required |
| `min`, `max` | in the control's own units: a menu's item by its number from 0; a mixer level in dB. min above max turns it round | the full range |
| `inLo`, `inHi` | the controller's own range; the two must differ | 0, 127 (0, 16383 for bend) |
| `hysteresis` | 0–64: steps a knob must turn back before it counts; 0 is none | the **Knobs** row's (one step unless changed) |
| `takeover` | `none` (jump), `pickup`, `scale` | the **Knobs** row's (jump unless changed) |
| `switch` | `oneMessage`, `pressRelease`, `knob` | `knob` |
| `mode` | for switches: `press`, `hold`, `follow` | `press` |
| `layer` | `true` lets it share its message with another binding | `false` |

## Versions and mistakes

- A missing `version` reads as 1. A map from a newer megalooper is refused
  whole; new optional fields don't raise the version, and older builds
  ignore them.
- A bad binding is dropped, and the log says which and why; the rest of the
  map loads. Keep then writes the map without it.
- A binding to a control this build doesn't know is kept, does nothing, and
  shows greyed.
- A message bound twice is reported, unless `layer` is set.
- A whole file is refused only if it isn't a map, or is newer than this
  megalooper.

## Control ids

An id is a family and a name, joined by dots. The Instrument chain's controls
say `guitar` in their ids, as in `sa.level.guitar`.

**The looper** (Perform), `looper.` and:

- `trigger`, `stop`, `multiply`, `undo`, `clear`, `reverse`,
  `recordNextLoop`, `break`, `nextReading`, `revertReading`
- `dissolve`, `dissolveBars`, `breakLoops`, `sessionRecording`
- `bbcut`, `bbcutMode`, `granular`
- `intensity`, `feedback`, `onsetThreshold`, `masterAmp`

**The Grains**, `looper.` and: `granularMorph`, `granularAmp`,
`granularPitch`, `granularDetune`, `granularSize`, `granularDensity`,
`granularSizeRand`, `granularEnv`, `granularPosition`, `granularScan`,
`granularSpray`, `granularResetTweaks`.

**Analysis**, `looper.` and: `onsetNotes`, `rerollOnsetNotes`, `onsetNote`,
`onsetNoteVelLo`, `onsetNoteVelHi`, `onsetNoteDynRange`, `onsetNoteGateMs`,
`onsetNoteChance`, `analysisMonitor`, `analyzeOverdubs`,
`detectMeterFromOverdub`.

**The effects:**

| Id | What it drives |
|---|---|
| `sa.fxOn.<device>` | An effect's switch |
| `sa.fx.<setting>` | A setting of one of the seven built-in effects, as `sa.fx.echoMix` |
| `sa.fx.<device>.<setting>` | A setting of a further device of the same effect, as `sa.fx.delay2.delayMix` |
| `sa.fxReset.<device>`, `sa.fxRandom.<device>` | An effect's **Reset** and **Random** |
| `sa.fxSend.<plugin>.<1-8>` | One of a plugin's eight sends, for the plugin's own MIDI learn |

**The mixer:** `sa.level.<strip>` and `sa.mute.<strip>`. The strips are
`guitar` (shown as **Instrument**), `bass`, `loop`, `drums`, `onsetKit`,
`synth` and `master`; the master has no mute.

**The drums:** `sa.drums.on`, `sa.drums.breakPattern`, `sa.drums.repeats`,
`sa.drums.reverbMix`, `sa.drums.livePattern.<main|break>`, a pattern's
settings as `sa.drums.<main|break>.<setting>`, a lane's as
`sa.drums.<main|break>.lane<1-4>.<note|altNote|delay|mute|lock>` and
`…lane<1-4>.length.<page>` (`chance`, `alt`, `velo` or `roll`), and the
trims as `sa.drums.trim.<slot>.<note>` and `sa.drums.groupTrim.<slot>.<group>`,
where the slot is `steps` or `onset`.

**The synth:** `sa.synth.on`, `sa.synth.swing`, `sa.synth.random`,
`sa.synth.reset`, and the sequence's and the Wave synth's settings as
`sa.synth.<setting>`.

**The views:** `gui.view.` and `perform`, `sound`, `fx`, `drums`, `synth`,
`setup` or `calibrate`.

**The count's lights** (Perform): `count.beatLight`, `count.countInLight`,
`count.oddBarLight`. These are only sent: bound to a button (a note or a CC),
they light it with the count, and the button itself drives nothing. They need
the controller's **Send back** on.
