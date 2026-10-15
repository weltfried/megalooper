// One plugin hosted by VSTPlugin inside a MegaSA device's synth, with what
// SA needs around VSTPluginController: the bank loaded as soon as the plugin
// is open, the plugin bypassed whenever it is not ready (opening, missing,
// failed), so the guitar stays audible dry instead of going silent, and the
// bank saved and recalled by file (docs/dev/megalooper-sa.md, Phase 2).
//
// Its synth is one of the device SynthDefs below (*addSynthDefs), whose
// VSTPlugin UGen has the id \plugin. Two controls say whether the plugin is
// heard: `on`, the player's switch, which this class never touches, and
// `ready`, the plugin's own state, which it sets (bypass). The device cross-
// fades on their product, so an open finishing can never undo a switch the
// player turned off. Not ready, VSTPlugin is also soft-bypassed (`bypass` 2);
// what is heard then is the device's dry path.
//
// A plugin running in scsynth's own process takes scsynth down if it crashes;
// pluginCrashed below only fires for a bridged or sandboxed one.
MegaSAPlugin {
    var <synth, <id, <path, <controller;
    // \closed, \opening, \open, \failed, \crashed
    var <state = \closed;
    // The bank file last loaded or saved, and how long the last open took.
    var <bank, <loadSec;
    // The open under way: answered yet (prAnswerOpen), and whom to tell.
    var openAnswered = true, openAction;
    // Why the plugin is held off although open, or nil: it reports more
    // latency than latencyLimit, which nothing compensates before release
    // 1.2 (docs/dev/device-chains.md, section 7). Held, it stays bypassed and its
    // device passes the chain through.
    var <held;
    // The frames its device's dry path is delayed by (`lat`): its latency
    // within the limit, so switching it moves no timing. Held, it stays what
    // it was, and the chain is delayed by that, not by what it reports.
    var <dryDelay = 0;

    *new { |synth, id, path| ^super.newCopyArgs(synth, id, path).init }

    // ---- The device SynthDefs ---------------------------------------------
    // One per channel layout of the plugin's main bus: 1->1, 1->2, 2->1, 2->2.
    // The chain's bus is always two channels: a plugin taking one hears the
    // sum of its sides, (L + R) / 2, and one giving one is written to both.
    //
    //   dry   the chain's bus as it came
    //   wet   the plugin's output, sanitized: a plugin that puts out NaN or
    //         inf would otherwise poison everything after it, the loop's
    //         buffer included
    //   held  the dry path, delayed by the plugin's latency (`lat`, frames)
    //         once it reports one, so switching it never moves the timing;
    //         at 0, the dry path itself (DelayN delays by a sample at least)
    //
    // VSTPlugin's own bypass maps input i to output i and zeroes the rest
    // (sc/src/VSTPlugin.cpp), so a 1->2 plugin bypassed would lose its right
    // side: what is heard when it is not playing is always `held`, through the
    // device's own cross-fade, never VSTPlugin's pass-through. The player's
    // `on` fades over 30 ms, as a built-in's switch does; `ready` switches
    // within a block, as VSTPlugin's own bypass ramp did before the split,
    // because the guitar strip's \opening hold lets go the moment the plugin
    // is ready, and a 30 ms fade would let the dry DI out under it. Its `on`
    // and `ready` start at 0: a device made with neither passes its chain
    // through. Only with VSTPlugin installed; without it SA hosts no plugin.
    *layouts { ^[[1, 1], [1, 2], [2, 1], [2, 2]] }

    *defName { |ins = 1, outs = 1| ^("megaSADevPlugin" ++ ins ++ outs).asSymbol }

    // The longest latency the dry path can follow, in seconds; and the most a
    // plugin may report, in samples, to be heard before compensation comes in
    // release 1.2 (device-chains.md, section 7). Up to it, its device's dry
    // path is delayed by as much (`lat`), so switching it moves no timing.
    *maxLatency { ^0.1 }
    *latencyLimit { ^64 }

    *addSynthDefs {
        var vst = \VSTPlugin.asClass;
        if(vst.isNil) { ^this };
        this.layouts.do { |io|
            SynthDef(this.defName(io[0], io[1]), { |bus, on = 0, ready = 0, bypass = 0, lat = 0|
                var dry = In.ar(bus, 2);
                var input = if(io[0] == 1) { (dry[0] + dry[1]) * 0.5 } { dry };
                // Switched off and faded out, the plugin is hard-bypassed:
                // VSTPlugin no longer runs it, so a plugin switched off costs
                // no CPU (Bias FX's full load before, measured 2026-10-15).
                // Any click of its own bypass is under the faded slot, and it
                // runs again from the block its switch goes on.
                var wet = Sanitize.ar(vst.ar(input, io[1], Select.kr(MegaSAFx.faded(on), [bypass, 1]), id: \plugin));
                var held = Select.ar(lat > 0, [dry, DelayN.ar(dry, this.maxLatency, lat * SampleDur.ir)]);
                ReplaceOut.ar(bus, XFade2.ar(held, wet, ((Lag.kr(on, 0.03) * ready) * 2) - 1));
            }).add;
        };
    }

    // What a synth of those SynthDefs is sent when the plugin is ready to be
    // heard, or no longer is.
    *readyArgs { |flag| ^[\bypass, if(flag == true) { 0 } { 2 }, \ready, (flag == true).binaryValue] }

    init {
        // Through asClass: without VSTPlugin installed the class library still
        // compiles, and this plugin answers \failed when asked to open.
        controller = \VSTPluginController.asClass !? { |c| c.new(synth, id) };
        controller !? { |c|
            c.pluginCrashed = {
                this.prSetState(\crashed);
                this.bypass(true);
                ("MegaSA: " ++ this.name ++ " crashed; the guitar is dry now.").warn;
            };
            // After each open's answer and whenever the plugin reports another.
            c.latencyChanged = { |frames| this.prLatencyChanged(frames) };
        };
    }

    name { ^PathName(path).fileNameWithoutExtension }

    // Open the plugin, then load its state if one is given: (kind: \program
    // or \bank, path:), or a bank's path alone. Bypassed until the state is
    // in, so the plugin's default sound is never heard in between. `action`
    // gets (this, ok), once: ok false when it did not open, or opened but its
    // state did not load (then it is \open, playing its default patch). A
    // plugin that has not answered in `timeout` seconds (a licence dialog in
    // its probe, a hang) counts as failed, so nothing waits on it for ever; a
    // late answer is ignored and it stays bypassed.
    open { |state, action, timeout = 30|
        var started = Main.elapsedTime;
        var kind = if(state.isString) { \bank } { state !? { |x| x[\kind] } };
        var file = if(state.isString) { state } { state !? { |x| x[\path] } };
        openAnswered = false;
        openAction = action;
        if(controller.isNil) {
            this.prSetState(\failed);
            ("MegaSA: VSTPlugin is not installed, so " ++ this.name ++ " cannot open.").warn;
            ^this.prAnswerOpen(false)
        };
        this.prSetState(\opening);
        this.bypass(true);
        SystemClock.sched(timeout, { this.prOpenTimedOut(timeout); nil });
        controller.open(path, editor: true, action: { |c, ok|
            if(openAnswered.not) {
                loadSec = Main.elapsedTime - started;
                case
                { ok.not } {
                    this.prSetState(\failed);
                    ("MegaSA: could not open " ++ path ++ "; the guitar stays dry.").warn;
                    this.prAnswerOpen(false);
                }
                { file.isNil } {
                    this.prSetState(\open);
                    this.prMakeReady;
                    this.prAnswerOpen(true);
                }
                {
                    this.loadState(kind, file, { |me, bankOk|
                        if(openAnswered.not) {
                            this.prSetState(\open);
                            this.prMakeReady;
                            this.prAnswerOpen(bankOk);
                        };
                    });
                };
            };
        });
    }

    // The open's answer, given once.
    prAnswerOpen { |ok|
        var act = openAction;
        if(openAnswered.not) {
            openAnswered = true;
            openAction = nil;
            act.value(this, ok);
        };
    }

    // `timeout` seconds after an open, if it has not answered.
    prOpenTimedOut { |timeout|
        if(openAnswered.not and: { state == \opening }) {
            this.prSetState(\failed);
            this.bypass(true);
            ("MegaSA: " ++ this.name ++ " did not open in " ++ timeout ++ " s; the guitar plays without it.").warn;
            this.prAnswerOpen(false);
        };
    }

    // Both announce \bank when the plugin's bank is a different file now.
    loadBank { |file, action|
        controller.readBank(file, { |c, ok|
            if(ok) { bank = file; this.changed(\bank, bank) }
                { ("MegaSA: could not load the bank " ++ file).warn };
            action.value(this, ok);
        });
    }

    saveBank { |file, action|
        controller.writeBank(file, { |c, ok|
            if(ok) { bank = file; this.changed(\bank, bank) }
                { ("MegaSA: could not save the bank to " ++ file).warn };
            action.value(this, ok);
        });
    }

    // The plugin's state from or to a file, by kind: \program (VST2's .fxp,
    // VST3's .vstpreset; stateExtension) is what a sound keeps; \bank (VST2
    // only) is what the Live export and the sounds from before the chains
    // hold. Both say \bank, with the file, when the state is that file's.
    loadState { |kind, file, action|
        if(kind == \bank) { ^this.loadBank(file, action) };
        controller.readProgram(file, { |c, ok|
            if(ok) { bank = file; this.changed(\bank, bank) }
                { ("MegaSA: could not load the plugin's state from " ++ file).warn };
            action.value(this, ok);
        });
    }

    saveState { |kind, file, action|
        if(kind == \bank) { ^this.saveBank(file, action) };
        controller.writeProgram(file, { |c, ok|
            if(ok) { bank = file; this.changed(\bank, bank) }
                { ("MegaSA: could not save the plugin's state to " ++ file).warn };
            action.value(this, ok);
        });
    }

    isVst3 { ^(controller !? { |c| c.info } !? { |i| i.sdkVersion } !? { |v| v.find("VST 3").notNil }) ? false }

    stateExtension { ^if(this.isVst3) { ".vstpreset" } { ".fxp" } }

    // What the plugin is, for a sound's file: nil until it has opened.
    identity {
        ^controller !? { |c| c.info } !? { |i|
            (key: i.key.asString, name: i.name.asString, vendor: i.vendor.asString,
                format: if(this.isVst3) { "vst3" } { "vst2" }, uid: i.id.asString, version: i.version.asString,
                path: i.path.asString)
        }
    }

    // Bypassed: not ready to be heard (readyArgs).
    bypass { |flag| synth !? { |x| x.set(*this.class.readyArgs(flag != true)) } }

    // Open: ready to be heard, unless its latency holds it off. Read here,
    // in the open's own answer, where VSTPlugin already knows it: its
    // latencyChanged comes only after, too late not to be heard for a moment.
    prMakeReady {
        this.prLatency(this.latency);
        if(held.isNil) { this.bypass(false) };
    }

    // A latency reported (frames; nil, while it opens, counts as 0): within
    // the limit the dry path follows it, past it the plugin is held off.
    // Says \latency (frames).
    prLatency { |frames|
        var n = (frames ? 0).asInteger, sr = (synth !? { |x| x.server.sampleRate }) ? 48000;
        held = if(n > this.class.latencyLimit) {
            "it adds " ++ (n / sr * 1000).round(0.1) ++ " ms of latency (" ++ n
                ++ " samples), which nothing compensates yet: it is held off"
        };
        if(held.isNil) { dryDelay = n; synth !? { |x| x.set(\lat, n) } };
        this.changed(\latency, n);
    }

    // The plugin reports another latency while it runs: held off past the
    // limit, heard again once back within it.
    prLatencyChanged { |frames|
        var was = held;
        this.prLatency(frames);
        if(state == \open) {
            case
            { held.notNil and: { was.isNil } } {
                this.bypass(true);
                ("MegaSA: " ++ this.name ++ ": " ++ held ++ ".").warn;
            }
            { held.isNil and: { was.notNil } } { this.bypass(false) };
        };
    }

    // The loop's tempo, for a plugin's synced effects: VSTPlugin's host
    // tempo, which plugins read instead of synth controls. Only while open.
    setTempo { |bpm|
        if(bpm.notNil and: { bpm > 0 } and: { state == \open }) { controller !? { |c| c.setTempo(bpm) } };
    }

    // A MIDI controller to the plugin, as a controller plugged into it would
    // send it: what its own MIDI learn hears. megalooper hears your
    // controllers and the plugin does not, so megalooper sends. Only while
    // open; answers whether it was sent.
    sendControl { |chan = 0, num, val = 127|
        if(state != \open or: { controller.isNil } or: { num.isNil }) { ^false };
        controller.midi.control(chan, num, val);
        ^true
    }

    editor {
        if(state == \open) { controller.editor(true) } {
            ("MegaSA: " ++ this.name ++ " is " ++ state ++ "; no editor to show.").warn;
        };
    }

    latency { ^controller !? { |c| c.latency } }

    prSetState { |new|
        state = new;
        this.changed(\state, state);
    }
}
