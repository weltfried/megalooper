// The router (setup-midimap.scd) against the responders it replaced, copied
// into legacy-midi-bindings.scd: the same messages, put through MIDIIn as
// CoreMIDI delivers them, must make the same calls on the looper, Megalooper
// SA and Live's recorder, send Live the same messages, and log the same lines.
// On a Live rig and on SA, then twice more with parts missing (no SA built, no
// Live recorder, no laws loaded, the proxy off or no IAC bus) and the
// responders rebuilt halfway through. docs/dev/midi-map.md, 10.4.
//
// Two differences are meant, and asserted as such: the proxy no longer turns
// a program change numbered as the break macro's CC (100) into that CC on
// channel 16, and within one message the router acts before the proxy sends
// and the log prints (they came the other way round). So each of the three
// streams is compared on its own. And the router runs with its knob defaults
// at none: since phase 4 every knob CC has a step of hysteresis unless its
// binding says (decision 7), which the old responders never had.
//
// The models are stubs that write down every call: Events, which answer any
// message by key. An Event's own `clear` (Dictionary's) can't be taken over,
// so the looper's clear is seen by what it does to the stub, which it empties.
//
// It goes through MIDIIn, so it runs only where no MIDI responder is
// registered: a running megalooper's would get these messages too, and
// program 5 clears its loop. In the IDE beside one it is skipped; in a
// headless run a registered responder is a test that forgot to free one, and
// fails. Each side's responders are made, fed and freed in turn.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-midi-equivalence");

{
var dir = thisProcess.nowExecutingPath.dirname;
var scripts = dir.dirname;
var src = 1001, iac = 666;
var calls, state, looper, fillLooper, makeSA, out, msgs, streams, feed, run, saved, results, from;
var model, proxy, logs, pc100, plain, at4, idx, compare;
var midiLive = AbstractResponderFunc.allEnabled.keys.any { |k| k.asString.beginsWith("MIDI") };

case
{ midiLive and: { Platform.ideName == "none" } } {
    ~tFail.("no MIDI responder is registered before this test, in a headless run",
        "an earlier test left one: " ++ AbstractResponderFunc.allEnabled.keys.asArray);
}
{ midiLive } {
    ~tSkip.("the router against the old responders", "MIDI responders run in this interpreter (a megalooper?)");
}
{
    if(~routingProfiles.isNil) { (scripts +/+ "setup-routing.scd").load };
    (scripts +/+ "setup-midi.scd").load;
    (scripts +/+ "setup-sa.scd").load;
    (scripts +/+ "setup-miditargets.scd").load;
    (scripts +/+ "setup-midimap.scd").load;
    if(~onsetThresholdSpec.isNil) { (scripts +/+ "gui-const.scd").load };
    if(~granularParams.isNil) { (scripts +/+ "gui-granular.scd").load };
    (dir +/+ "legacy-midi-bindings.scd").load;
    saved = [~looper, ~megaSA, ~midiOut, ~liveRecordToggle, ~midiLog, ~midiMonitorPush, ~rp,
        ~iacSources, ~midiProxy, ~onsetThresholdSpec, ~granularParams, ~midiUserRootOverride];
    // Never the real folder of yours: a scratch one, empty.
    ~midiUserRootOverride = ~tTempPath.("midimap-user");

    // ---- the stubs: every call written down, in order ----
    // [\model, who, selector, args..., from], [\proxy, selector, args..., from],
    // [\log, line, from]: `from` is the input the message came from.
    fillLooper = {
        [\trigger, \stopPlayback, \multiply, \undo, \reverse, \fireBreak, \toggleDissolve,
            \toggleSessionRecording, \recordNextLoop, \nextReading, \toggleGranular].do { |sel|
            looper.put(sel, { |self ... args| calls.add([\model, \looper, sel] ++ args ++ [from]); self });
        };
        [\bbcut, \onsetNotes].do { |k|
            looper.put(k, { |self| state[k] });
            looper.put(k.asSetter, { |self, v| calls.add([\model, \looper, k.asSetter, v, from]); state.put(k, v); self });
        };
        ([\granularMorph, \feedback, \onsetThreshold, \intensity, \granularAmp] ++ ~granularCcMap).do { |k|
            looper.put(k.asSetter, { |self, v| calls.add([\model, \looper, k.asSetter, v, from]); self });
        };
    };
    makeSA = {
        var drums = ();
        drums.put(\toggleOn, { |self ... args| calls.add([\model, \drums, \toggleOn] ++ args ++ [from]); self });
        drums.put(\on, true);
        (toggleFx: { |self, key| calls.add([\model, \sa, \toggleFx, key, from]); self },
            fx: { |self, key| false }, drums: drums)
    };
    out = ();
    [\noteOn, \noteOff, \control, \program, \bend, \touch, \polyTouch].do { |sel|
        out.put(sel, { |self ... args| calls.add([\proxy, sel] ++ args ++ [from]); self });
    };

    // ---- the messages ----
    // From a controller and from an IAC bus (which the proxy must not send on),
    // on channels 1 and 2: every note at velocities 1, 64 and 127, at 0 (which
    // MIDIIn makes a note off, as CoreMIDI does) and off; every program; every
    // CC at 0, 1, 63, 64, 126 and 127; poly touch, bend and touch. Then the
    // pedal's own streams from the log on its two CCs.
    msgs = List.new;
    [src, iac].do { |input|
        [0, 1].do { |chan|
            (0..127).do { |n|
                [1, 64, 127, 0].do { |v| msgs.add([\noteOn, input, chan, n, v]) };
                msgs.add([\noteOff, input, chan, n, 0]);
                msgs.add([\program, input, chan, n]);
                [0, 1, 63, 64, 126, 127].do { |v| msgs.add([\cc, input, chan, n, v]) };
                msgs.add([\polytouch, input, chan, n, 30]);
            };
            [0, 8192, 16383].do { |v| msgs.add([\bend, input, chan, v]) };
            msgs.add([\touch, input, chan, 40]);
        };
    };
    streams = try {
        File.readAllString(dir +/+ "fixtures" +/+ "pedal-streams.json").parseJSON["streams"]
    } { nil };
    ~tAssert.("the pedal's streams from the MIDI log are read", streams.isKindOf(Array) and: { streams.size == 4 });
    (streams ? []).do { |s|
        var num = s["cc"].asInteger;
        s["values"].do { |v| msgs.add([\cc, src, 0, num, v.asInteger]) };
    };

    // Every message through MIDIIn. `rebuild`, if given, runs once at
    // `rebuildAt`, as re-running the responders mid-set would.
    feed = { |rebuild, rebuildAt|
        msgs.do { |m, i|
            if(rebuild.notNil and: { i == rebuildAt }) { rebuild.value };
            from = m[1];
            try {
                case
                { m[0] == \noteOn } { MIDIIn.doNoteOnAction(m[1], m[2], m[3], m[4]) }
                { m[0] == \noteOff } { MIDIIn.doNoteOffAction(m[1], m[2], m[3], m[4]) }
                { m[0] == \program } { MIDIIn.doProgramAction(m[1], m[2], m[3]) }
                { m[0] == \cc } { MIDIIn.doControlAction(m[1], m[2], m[3], m[4]) }
                { m[0] == \polytouch } { MIDIIn.doPolyTouchAction(m[1], m[2], m[3], m[4]) }
                { m[0] == \bend } { MIDIIn.doBendAction(m[1], m[2], m[3]) }
                { m[0] == \touch } { MIDIIn.doTouchAction(m[1], m[2], m[3]) };
            } { |err| calls.add([\threw, m, err.errorString]) };
            // The looper's clear empties the stub: write it down, fill it again.
            if(looper.isEmpty) { calls.add([\model, \looper, \clear, from]); fillLooper.value };
        };
    };

    // One side on one rig: its responders made as boot.scd made them, fed
    // every message, then freed. `world` takes parts away: noSA (no MegaSA
    // built), noLive (no Live recorder), noLaws (no threshold spec, no
    // granular table), noOut (no IAC bus to send on), proxyOff, rebuild (the
    // responders made again halfway). Answers what was written down, and what
    // the router said it caught (nil for the old side).
    run = { |side, rigName, world|
        var before = MIDIdef.all.keys, laws = [~onsetThresholdSpec, ~granularParams], caught, setup;
        world = world ? ();
        ~rp = ~routingProfiles[rigName];
        state = IdentityDictionary[\bbcut -> false, \onsetNotes -> false];
        looper = ();
        fillLooper.value;
        ~looper = looper;
        ~megaSA = if((~rp[\sa] == true) and: { world[\noSA] != true }) { makeSA.value };
        ~midiOut = if(world[\noOut] == true) { nil } { out };
        ~midiProxy = world[\proxyOff] != true;
        ~liveRecordToggle = if(world[\noLive] == true) { nil } { { calls.add([\model, \live, \toggle, from]); true } };
        if(world[\noLaws] == true) { ~onsetThresholdSpec = nil; ~granularParams = nil };
        ~midiLog = false;
        ~midiMonitorPush = { |line| calls.add([\log, line, from]) };
        setup = {
            if(side == \legacy) {
                ~legacySetupMidiBindings.();
                if(~rp[\sa] == true) { ~legacySetupSABindings.() };
            } {
                ~setupMidiBindings.(LooperMidiMap(~midiMapFromConstants.(), "test"));
                ~midiDefaults = (hysteresis: 0, takeover: \none);
            };
            ~iacSources = [iac];
        };
        protect {
            setup.value;
            calls = List.new;   // the router says how many bindings it has; not a message's
            feed.(if(world[\rebuild] == true) { setup }, msgs.size div: 2);
            caught = if(side == \router) { ~midiWarned.copy };
        } {
            MIDIdef.all.keys.reject { |k| before.includes(k) }.do { |k| MIDIdef.all[k] !? { |d| d.free } };
            ~midiKnobDefaults !? { |d| ~midiDefaults = d.copy };
            ~onsetThresholdSpec = laws[0];
            ~granularParams = laws[1];
        };
        [calls.asArray, caught]
    };

    // Both sides on one rig and world, stream by stream. Answers the router's
    // calls.
    compare = { |label, rigName, world, busy = true|
        var legacy = run.(\legacy, rigName, world);
        var router = run.(\router, rigName, world);
        var of = { |cs, k| cs.select { |c| c[0] == k } };
        var isPc100 = { |c| (c[0] == \proxy) and: { c[1] == \control } and: { c[2] == ~pcCcChannel }
            and: { c[3] == ~breakMacroCc } };
        ~tEq.(label ++ ": nothing throws on the old side, and the router catches nothing",
            [of.(legacy[0], \threw).size, of.(router[0], \threw).size, router[1].asArray], [0, 0, []]);
        model = [of.(legacy[0], \model), of.(router[0], \model)];
        ~tAssert.(label ++ ": the router makes the same " ++ model[0].size ++ " model calls, in the same order",
            (model[0].size > 100) and: { model[0] == model[1] },
            "old " ++ model[0].size ++ ", router " ++ model[1].size
                ++ "; first difference at " ++ model[0].detectIndex { |c, i| c != model[1][i] });
        proxy = [of.(legacy[0], \proxy), of.(router[0], \proxy)];
        pc100 = proxy[0].select(isPc100);
        if(busy) {
            ~tAssert.("...sends Live the same " ++ proxy[1].size ++ " messages",
                (proxy[1].size > 5000) and: { proxy[0].reject(isPc100) == proxy[1] },
                "old " ++ proxy[0].size ++ ", router " ++ proxy[1].size);
            ~tAssert.("...but for program 100, which went out as the break macro's CC "
                ++ pc100.size ++ " times and now does not",
                (pc100.size == 2) and: { proxy[1].count(isPc100) == 0 });
        } {
            ~tEq.("...and with nothing to send on, neither sends Live anything", [proxy[0].size, proxy[1].size], [0, 0]);
        };
        // The router's lines say what each message did (docs/dev/midi-map.md 7.4,
        // "  → Clear"); before that mark they are the old lines.
        logs = [of.(legacy[0], \log), of.(router[0], \log).collect { |c|
            [c[0], c[1].find("  → ") !? { |i| c[1].copyRange(0, i - 1) } ? c[1], c[2]] }];
        ~tAssert.("...and logs the same " ++ logs[1].size ++ " lines",
            (logs[1].size > 5000) and: { logs[0] == logs[1] },
            "old " ++ logs[0].size ++ ", router " ++ logs[1].size);
        if(busy) {
            ~tAssert.("...each line of a message that did something saying what it did",
                of.(router[0], \log).count { |c| c[1].contains("  → ") } == model[1].size,
                of.(router[0], \log).count { |c| c[1].contains("  → ") }.asString ++ " lines, "
                    ++ model[1].size ++ " calls");
        };
        router[0]
    };

    protect {
        results = IdentityDictionary.new;
        ("  (" ++ msgs.size ++ " messages a run)").postln;
        results.put(\bhTsMega, compare.("on a Live rig", \bhTsMega));
        results.put(\sa, compare.("on SA", \sa));
        compare.("on SA with no SA built, no Live recorder, no laws loaded, the proxy off, rebuilt halfway",
            \sa, (noSA: true, noLive: true, noLaws: true, proxyOff: true, rebuild: true), false);
        compare.("on a Live rig with no IAC bus to send on, rebuilt halfway",
            \bhTsMega, (noOut: true, rebuild: true), false);

        // What the comparison stands on: the rigs differ where they should.
        plain = { |rigName| results[rigName].select { |c| c[0] == \model } };
        ~tAssert.("on a Live rig program 8 switches the cutter, and SA's effects and drums are not reached",
            plain.(\bhTsMega).every { |c| [\sa, \drums].includes(c[1]).not }
                and: { plain.(\bhTsMega).any { |c| c[2] == \bbcut_ } });
        ~tAssert.("on SA its seven effects and its drums are reached",
            (plain.(\sa).select { |c| c[1] == \sa }.collect { |c| c[3] }.asSet.size == 7)
                and: { plain.(\sa).any { |c| c[1] == \drums } });
        ~tAssert.("an IAC bus's messages still reach the bindings, as before, but never go on to Live",
            results[\bhTsMega].any { |c| (c[0] == \model) and: { c.last == iac } }
                and: { results[\bhTsMega].every { |c| (c[0] != \proxy) or: { c.last != iac } } });

        // Within one message the router acts first, then the proxy, then the log.
        at4 = results[\bhTsMega];
        idx = at4.detectIndex { |c| (c[0] == \log) and: { c[1] == "program  prog=4 chan=0  → Trigger" } };
        ~tEq.("within one message: the action, then what goes to Live, then the log line",
            idx !? { at4.copyRange(idx - 3, idx).collect { |c| c[0] } },
            [\model, \proxy, \proxy, \log]);
    } {
        ~looper = saved[0]; ~megaSA = saved[1]; ~midiOut = saved[2]; ~liveRecordToggle = saved[3];
        ~midiLog = saved[4]; ~midiMonitorPush = saved[5]; ~rp = saved[6]; ~iacSources = saved[7];
        ~midiProxy = saved[8]; ~onsetThresholdSpec = saved[9]; ~granularParams = saved[10];
        ~tRemoveTree.(~midiUserRootOverride);
        ~midiUserRootOverride = saved[11];
    };
};

}.value;
