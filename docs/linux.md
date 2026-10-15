# megalooper on Linux

megalooper was written and played on macOS. The Linux support is a port
that has run on one machine so far, with Omarchy (Arch). Expect rough
edges, and please report what fails, with the log.

The installer knows two package managers: `pacman` (Arch, Omarchy) and
`apt` (Debian, Ubuntu). Its Debian and Ubuntu path was run only against
stand-ins for `apt`, never on such a system. On another distribution it
tells you which packages it needs.

## Install

```bash
git clone https://github.com/weltfried/megalooper.git
cd megalooper
./tools/install.sh
```

The script:

1. offers to install what is missing: `supercollider`, `sc3-plugins`,
   `git`, Python 3, and `pipewire-jack` (on Arch if no JACK is there; on
   Debian and Ubuntu, which also get `curl`, where PipeWire is installed);
2. fetches BBCut into SuperCollider's Extensions;
3. fetches VSTPlugin 0.6.2, which hosts VST plugins in the effect chains,
   into Extensions (x86-64 and ARM64; `--no-vstplugin` skips it);
4. links megalooper's classes into Extensions;
5. runs the quick checks;
6. adds megalooper to your application launcher.

On another distribution, install SuperCollider, sc3-plugins, git, Python 3
and a JACK (PipeWire's or JACK 2) yourself, then run the script.

### Which SuperCollider your distribution ships

megalooper is built and tested on SuperCollider 3.14.1. With an older one
the script warns and goes on, and the quick checks at its end say whether
the classes compile and the tests pass there. That megalooper plays well on
3.13 is not known: nobody has tried.

| Distribution | SuperCollider | sc3-plugins |
|---|---|---|
| Arch, Omarchy | 3.14.1 | 3.14.1 |
| Ubuntu 26.10 | 3.14.1 | 3.14.0 |
| Debian testing (forky) and unstable | 3.14.1 | 3.14.0 |
| Ubuntu 25.04, 25.10, 26.04 LTS | 3.13.0 | 3.13.0 |
| Debian 13 (trixie) | 3.13.0 | 3.13.0 |
| Ubuntu 24.04 LTS, Debian 12 (bookworm) | 3.13.0 | 3.9.1 |

(As the distributions' package lists had it in October 2026.) On a release
with 3.13, the sure way is SuperCollider 3.14.1 built from
[its source](https://github.com/supercollider/supercollider), with
sc3-plugins built against it.

### Debian and Ubuntu: PipeWire

SuperCollider's packages there are linked to JACK 2's library, which does
not reach PipeWire. `tools/megalooper` therefore starts through `pw-jack`
(from the package `pipewire-jack`) when PipeWire runs and no JACK server of
your own does, and says so in its first lines. `MEGALOOPER_PW_JACK=0` turns
that off, `1` forces it. `./tools/megalooper --dry-run` prints the command
it would run and starts nothing.

## Start

From your application launcher, or from a terminal:

```bash
./tools/megalooper
```

Pick **saSystem** for the looper with its effect chains and drums: only this
rig has the FX and Drums views. **standalone** is the looper alone, and it is
the rig the picker offers at the first start. The other rigs name audio interfaces as macOS knows
them, so they show ✗ here.

What megalooper says goes to the terminal and to
`~/.local/state/megalooper/megalooper.log`.

If no window opens under Wayland, try X11's way:

```bash
QT_QPA_PLATFORM=xcb ./tools/megalooper
```

## Small screens

The window is laid out for 1440 × 900. On a smaller screen `tools/megalooper`
scales the whole application down to fit (it sets Qt's `QT_SCALE_FACTOR` from
the size of your screen; Hyprland and macOS are read, elsewhere nothing is
scaled) and says so when it starts. A window narrower or shorter than the
layout scrolls instead of cutting it off. To choose the scale yourself:

```bash
MEGALOOPER_SCALE=0.75 ./tools/megalooper   # any number
MEGALOOPER_SCALE=1 ./tools/megalooper      # no scaling
```

## Audio

SuperCollider's server speaks JACK. With `pipewire-jack`, PipeWire answers.

- **Which input and output.** megalooper uses the first input for the
  guitar and the first two outputs. SuperCollider connects itself to JACK's
  `system` ports.
- **No sound, or no guitar.** PipeWire may name your interface's ports
  differently. Connect SuperCollider's ports to your interface in a patchbay
  such as `qpwgraph` or Helvum.
- **Block size and rate.** Ask PipeWire before starting:
  ```bash
  PIPEWIRE_LATENCY=128/48000 ./tools/megalooper
  ```
- **Latency.** Run the round-trip step on the Calibrate view once, or overdubs
  land early or late.

## What differs from macOS

- **Your files** are in `~/.local/share/SuperCollider/megalooper/`.
- **Keys.** Where a guide says Cmd, use Ctrl: Ctrl+M for MIDI MAP, Ctrl+Z to
  undo a chain edit.
- **MIDI clock out is off.** megalooper sends it to macOS's IAC bus. MIDI
  in, and the MIDI map, work through ALSA.
- **A rig for your interface.** megalooper cannot pick an interface by name
  on Linux: JACK or PipeWire has it. Write a profile with
  `device: \systemDefault` and your channel numbers
  ([Rigs and routing](routing.md)).
- **Plugins.** The installer fetches VSTPlugin's Linux build. It hosts
  Linux VST2 and VST3 plugins. If its binaries do not load on your system
  (the log says so at the start), megalooper plays its built-in effects, and
  VSTPlugin has to be built from
  [its source](https://git.iem.at/pd/vstplugin). BIAS FX 2 is not made for
  Linux.
- **Copy diagnostics** needs `wl-copy` (the package `wl-clipboard`) or
  `xclip`. Without one, the text goes to the log.
- **Drums.** The Drums view shows a note until one kit has its samples.
  There is no Ableton Live on Linux, so copy the kit folders you exported on
  a Mac (`presets/sa/drums/kits/<kit>/`, beside each kit's `.json`), or
  press **Import samples…** there and choose a folder of your own one-shots
  ([Drums](drums.md)).

## When something fails

Send the log, and say what you did before it failed:

```bash
./tools/megalooper --log    # prints where the log is
```

The checks that need no audio tell a broken install from a broken rig:

```bash
./tools/run-checks.sh quick
```
