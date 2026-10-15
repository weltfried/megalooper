# MIDI map files

A MIDI map is a JSON file: data only, nothing in it runs. megalooper ships two
(`presets/midi/tsmega.json`, `presets/midi/keys-and-knobs.json`), and the maps
you keep from MIDI MAP mode go to your megalooper folder. The easiest way to
make one is MIDI MAP mode (the manual's *MIDI map* section); this page is for
reading one, writing one by hand, or sharing one.

## An example

```json
{
  "format": "megalooper midi map",
  "version": 1,
  "name": "TSMega",
  "basedOn": "tsmega", "revision": 1,
  "bindings": [
    {"msg": "program", "num": 4, "device": "TSMEGA", "target": "looper.trigger"},
    {"msg": "cc", "num": 7, "device": "TSMEGA", "target": "looper.onsetThreshold", "inHi": 126, "hysteresis": 1},
    {"msg": "cc", "num": 80, "device": "TSMEGA", "target": "looper.recordNextLoop", "switch": "oneMessage"},
    {"msg": "cc", "chan": 0, "num": 21, "device": "Faderfox UC4", "port": "Faderfox UC4",
     "target": "sa.fx.echoMix", "min": 0.2, "max": 0.8, "takeover": "pickup"}
  ]
}
```

`format` must read `"megalooper midi map"`. megalooper writes one binding per
line, with its keys in a fixed order, so two versions of a map compare well.

## A binding's fields

| Field | Values | When it is missing |
|---|---|---|
| `msg` | `note`, `cc`, `program`, `bend` | required |
| `chan` | 0–15 (megalooper's screens show 1–16) | any channel |
| `num` | 0–127 | (bend has none) |
| `device`, `port` | the MIDI input's two names, as the Setup view lists them | any listening input |
| `target` | the control's id, such as `looper.trigger` or `sa.fx.echoMix`; the shipped maps in `presets/midi/` use most of them | required |
| `min`, `max` | in the control's own units; min above max turns it round | the full range |
| `inLo`, `inHi` | the controller's own range | 0, 127 |
| `hysteresis` | steps a knob must move before it counts | the map's default |
| `takeover` | `none`, `pickup`, `scale` | the global default |
| `switch` | `oneMessage`, `pressRelease`, `knob` | `knob` |
| `mode` | for switches: `press`, `hold`, `follow` | `press` |
| `layer` | `true` lets it share its message with another binding | `false` |

## Versions and mistakes

- A missing `version` reads as 1. A map from a newer megalooper is refused
  whole; new optional fields don't raise the version, and older builds
  ignore them.
- A bad binding is dropped and said in the post window and in the map's list;
  the rest of the map loads.
- A binding to a control this build doesn't know is kept, does nothing, and
  shows greyed.
- A message bound twice is reported, unless `layer` is set.
- A whole file is refused only if it isn't a map, or is newer than this
  megalooper.
