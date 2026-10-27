// What a controller's messages do to megalooper's controls: LooperMidiMap's
// rules, the router's controls and map (setup-midimap.scd), and its
// responders. No MIDIClient, no server, no window. That the router does what
// the responders before it did is test-midi-equivalence.scd's.
//
// The pedal's hysteresis runs on its own streams from the MIDI log
// (fixtures/pedal-streams.json, cut by tools/midi-log-streams.py): its
// one-step flicker must not set the onset threshold.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-midimap");

{
var dir = thisProcess.nowExecutingPath.dirname;
var scripts = dir.dirname;
var h = LooperMidiMap;
var replay, streams, stream, flicker, sweep, out, v, m, b, d, slots, problem, act, actK, glide, mouse;
var targets, map, calls, stub, route, warned, srcs, t0, t1, savedRp, savedLooper, savedMegaSA, savedLive;
var before, saved, l, seen, ctl, fn, feed, built, sent, kinds, lines, old, near, same, rounding, count, menu;

if(~setupMidiIO.isNil) { (scripts +/+ "setup-midi.scd").load };
// The numbers megalooper was bound to before the maps were files, and the
// map phase 1 made of them.
if(~midiMapFromConstants.isNil) { (dir +/+ "legacy-midi-bindings.scd").load };
if(~midiTargetsBuild.isNil) { (scripts +/+ "setup-miditargets.scd").load };
if(~midiRouteWith.isNil) { (scripts +/+ "setup-midimap.scd").load };
if(~saGuitarBank.isNil) { (scripts +/+ "setup-sa.scd").load };
if(~routingProfiles.isNil) { (scripts +/+ "setup-routing.scd").load };
if(~onsetThresholdSpec.isNil) { (scripts +/+ "gui-const.scd").load };
if(~granularParams.isNil) { (scripts +/+ "gui-granular.scd").load };

// Equal, numbers to within 1e-9, however nested: the router's calls carry
// floats that arithmetic along a law can leave a hair off.
near = { |a, b|
    if(a.isArray and: { b.isArray }) {
        (a.size == b.size) and: { a.every { |x, i| near.(x, b[i]) } }
    } {
        if(a.isNumber and: { b.isNumber }) { (a - b).abs < 1e-9 } { a == b }
    }
};
same = { |label, got, want| ~tAssert.(label, near.(got, want), "got " ++ got ++ ", want " ++ want) };

// A stream's values through the hysteresis, from a CC never seen: answers
// the values that moved the control, and its largest distance from the pedal.
replay = { |values, steps = 1|
    var at, moved = List.new, worst = 0;
    values.do { |x|
        var move = h.hysteresis(at !? { |a| a[0] }, (at !? { |a| a[1] }) ? 0, x, steps);
        if(move.notNil) { at = move; moved.add(x) };
        worst = worst.max((x - at[0]).abs);
    };
    [moved.asArray, worst]
};

// ------------------------------------------------------- the hysteresis --
~tEq.("a CC's first value moves the control", h.hysteresis(nil, 0, 68), [68, 0]);
~tEq.("the same value again does not", h.hysteresis(68, 0, 68), nil);
~tEq.("nor does one step, either way, before the direction is known",
    [h.hysteresis(68, 0, 69), h.hysteresis(68, 0, 67)], [nil, nil]);
~tEq.("two steps do, and give the direction", h.hysteresis(68, 0, 70), [70, 1]);
~tEq.("then one step on that way moves", h.hysteresis(70, 1, 71), [71, 1]);
~tEq.("one step back does not", h.hysteresis(71, 1, 70), nil);
~tEq.("two steps back do, and turn the direction", h.hysteresis(71, 1, 69), [69, -1]);
~tEq.("downwards the same", [h.hysteresis(69, -1, 68), h.hysteresis(68, -1, 69)], [[68, -1], nil]);
~tEq.("with 0 steps every change moves, either way, and the same value still does not",
    [h.hysteresis(68, 0, 69, 0), h.hysteresis(69, 1, 68, 0), h.hysteresis(68, -1, 68, 0)],
    [[69, 1], [68, -1], nil]);
~tEq.("with 2 steps, turning round takes three",
    [h.hysteresis(70, 1, 68, 2), h.hysteresis(70, 1, 67, 2), h.hysteresis(70, 1, 71, 2)],
    [nil, [67, -1], [71, 1]]);

flicker = Array.fill(40, { |i| if(i.even) { 68 } { 69 } });
~tEq.("a, b, a, b by one step moves the control once, at the first value",
    replay.(flicker)[0], [68]);
~tEq.("...and every time with 0 steps", replay.(flicker, 0)[0], flicker);
sweep = (0..126) ++ (125..0);
out = replay.(sweep);
~tEq.("a sweep up and down skips one step at the start and one at the turn",
    out[0], [0] ++ (2..126) ++ (124..0));
~tEq.("...so the control is never more than a step from the pedal", out[1], 1);

// ---------------------------------------------------- the pedal's streams --
streams = try {
    File.readAllString(dir +/+ "fixtures" +/+ "pedal-streams.json").parseJSON["streams"]
} { nil };
~tAssert.("the pedal's streams from the MIDI log are read",
    streams.isKindOf(Array) and: { streams.size == 4 });
stream = { |name|
    (streams ? []).detect { |s| s["name"] == name } !? { |s| s["values"].collect(_.asInteger) } ? []
};

v = stream.("sa-resting");
out = replay.(v);
~tAssert.("the pedal untouched on the SA rig hops between 68 and 69 (" ++ v.size ++ " messages)",
    (v.size > 1000) and: { v.asSet.asArray.sort == [68, 69] });
~tEq.("...and moves the control once", out[0].size, 1);
v = stream.("sa-resting-wide");
out = replay.(v);
~tAssert.("untouched, reaching 70 now and then (" ++ v.size ++ " messages)",
    (v.size > 200) and: { v.asSet.asArray.sort == [68, 69, 70] });
~tEq.("...it moves the control twice", out[0], [68, 70]);
v = stream.("cc4-resting");
~tEq.("CC 4 parked at the toe moves it once", replay.(v)[0], [125]);
v = stream.("sa-played");
out = replay.(v);
~tAssert.("played on the SA rig (" ++ v.size ++ " messages, " ++ v.minItem ++ " to " ++ v.maxItem ++ ")",
    (v.size > 2000) and: { (v.maxItem - v.minItem) > 60 });
~tEq.("...the control is never more than a step from the pedal", out[1], 1);
~tAssert.("...and reaches within a step of both its ends",
    ((out[0].minItem - v.minItem) <= 1) and: { (v.maxItem - out[0].maxItem) <= 1 });
~tAssert.("...moving for fewer than a tenth of the pedal's messages, the rest being flicker ("
    ++ out[0].size ++ ")", out[0].size < (v.size / 10));

// -------------------------------------------------------------- the map --
~tAssert.("a message's key is one per type, channel and number",
    [h.key(\note, 0, 60), h.key(\note, 1, 60), h.key(\note, nil, 60), h.key(\cc, 0, 60),
        h.key(\program, 0, 60), h.key(\bend, 0, nil), h.key(\note, 0, 61)].asSet.size == 7);
~tEq.("...and none for a type that is not one", h.key(\sysex, 0, 1), nil);

problem = { |binding| h.bindingProblem(binding) };
~tEq.("a whole binding has no problem", problem.((msg: \cc, num: 7, target: 'x.y')), nil);
[
    [nil, "not a binding"], [(num: 7, target: 'x'), "message type"],
    [(msg: \sysex, num: 7, target: 'x'), "message type"],
    [(msg: \cc, target: 'x'), "number"], [(msg: \cc, num: 128, target: 'x'), "number"],
    [(msg: \cc, num: 7.5, target: 'x'), "number"], [(msg: \bend, num: 3, target: 'x'), "no number"],
    [(msg: \cc, num: 7, chan: 16, target: 'x'), "channel"], [(msg: \cc, num: 7), "control"],
    [(msg: \cc, num: 7, target: "x"), "control"], [(msg: \cc, num: 7, target: 'x', device: 3), "device"],
    [(msg: \cc, num: 7, target: 'x', port: "A"), "port but no device"],
    [(msg: \cc, num: 7, target: 'x', min: "low"), "min"],
    [(msg: \cc, num: 7, target: 'x', inLo: 10, inHi: 10), "empty"],
    [(msg: \cc, num: 7, target: 'x', inHi: 200), "input range"],
    [(msg: \cc, num: 7, target: 'x', hysteresis: -1), "hysteresis"],
    [(msg: \cc, num: 7, target: 'x', switch: \latch), "switch"],
    [(msg: \cc, num: 7, target: 'x', mode: \tap), "mode"],
    [(msg: \cc, num: 7, target: 'x', takeover: \grab), "takeover"],
    [(msg: \cc, num: 7, target: 'x', layer: 1), "layer"]
].do { |pair|
    var why = problem.(pair[0]);
    ~tAssert.("a binding is refused when " ++ pair[1].asString ++ " is wrong: " ++ (why ? "nothing said"),
        why.notNil and: { why.contains(pair[1]) });
};
~tEq.("a bend's input range may run to 16383",
    problem.((msg: \bend, target: 'x', inLo: 100, inHi: 16000)), nil);

m = h.new([
    (msg: \program, num: 4, target: 'a'), (msg: \cc, num: 200, target: 'bad'),
    (msg: \program, num: 4, target: 'b'), (msg: \program, num: 4, chan: 1, target: 'c'),
    (msg: \program, num: 5, target: 'd'), (msg: \program, num: 5, target: 'e', layer: true),
    (msg: \program, num: 6, target: 'f', device: "TSMEGA"), (msg: \program, num: 6, target: 'g', device: "UC4"),
    (msg: \note, num: 60, target: 'h')
], "test");
~tEq.("a map keeps the usable bindings", m.bindings.size, 8);
~tAssert.("...and says which one it left out, and why",
    m.problems.any { |p| p.contains("binding 2") and: { p.contains("0-127") } });
~tAssert.("...and that PC 4 is bound twice",
    m.problems.any { |p| p.contains("PC 4 is bound twice") and: { p.contains("a and to b") } });
~tAssert.("...but not PC 5, whose second binding says it is meant (layer), nor PC 6 on two devices",
    m.problems.every { |p| p.contains("PC 5").not and: { p.contains("PC 6").not } });
~tEq.("a message reaches its channel's bindings and any channel's, in the map's order",
    m.lookup(\program, 1, 4).collect { |s| s[\binding][\target] }, ['a', 'b', 'c']);
~tEq.("...and on another channel only any channel's", m.lookup(\program, 0, 4).collect { |s| s[\binding][\target] }, ['a', 'b']);
~tEq.("a message nothing is bound to reaches nothing", m.lookup(\program, 0, 99), []);
~tEq.("asked with no channel, a map answers its any-channel bindings, each once",
    m.lookup(\program, nil, 4).collect { |s| s[\binding][\target] }, ['a', 'b']);
~tAssert.("two bindings one message can reach are said, a channel's under any channel's too",
    m.problems.any { |p| p.contains("PC 4 ch 2 is bound twice") and: { p.contains("a and to c") } });
~tAssert.("...and an input's under any input's",
    h.new([(msg: \cc, num: 1, target: 'x'), (msg: \cc, num: 1, target: 'y', device: "UC4")]).problems.size == 1);
~tAssert.("...but not two that never meet: two channels, or two devices",
    h.new([(msg: \cc, num: 1, chan: 0, target: 'x'), (msg: \cc, num: 1, chan: 1, target: 'y'),
        (msg: \cc, num: 2, device: "A", target: 'x'), (msg: \cc, num: 2, device: "B", target: 'y')]).problems.isEmpty);
~tEq.("a note's binding is found for note on and note off alike (both look up \\note)",
    m.lookup(\note, 3, 60).collect { |s| s[\binding][\target] }, ['h']);
b = (msg: \cc, num: 1, target: 'x', device: "TSMEGA");
~tAssert.("a binding with no device answers every input",
    h.deviceMatches((msg: \cc, num: 1, target: 'x'), nil) and: { h.deviceMatches((msg: \cc, num: 1, target: 'x'), ["UC4", "UC4"]) });
~tAssert.("one with a device answers that device only, and not an input it can't name",
    h.deviceMatches(b, ["TSMEGA", "TSMEGA"]) and: { h.deviceMatches(b, ["UC4", "UC4"]).not } and: { h.deviceMatches(b, nil).not });
~tAssert.("...and one with a port that port only",
    h.deviceMatches(b.copy.put(\port, "Port 2"), ["TSMEGA", "Port 2"])
        and: { h.deviceMatches(b.copy.put(\port, "Port 2"), ["TSMEGA", "Port 1"]).not });
~tEq.("on a rig that proxies to Live, a binding on PC 100 (the break macro's CC) is said, a CC 100 is not",
    h.proxyProblems([(msg: \program, num: 100, target: 'a'), (msg: \cc, num: 100, target: 'b'),
        (msg: \program, num: 4, target: 'c')], 100).size, 1);
~tEq.("a binding in words", [h.describe((msg: \program, num: 8)), h.describe((msg: \cc, num: 7, chan: 0)),
    h.describe((msg: \note, num: 60)), h.describe((msg: \bend))], ["PC 8", "CC 7 ch 1", "note 60", "pitch bend"]);

// ---------------------------------------------------- knobs and switches --
~tEq.("a CC over its whole range is exactly val / 127, as the bindings always took it",
    [0, 1, 64, 127].collect { |x| h.position(x, nil, nil, 127) }, [0, 1, 64, 127] / 127);
~tEq.("an input range spreads its own travel over 0..1 and clips outside it",
    [10, 60, 110, 0, 127].collect { |x| h.position(x, 10, 110) }, [0, 0.5, 1, 0, 1]);
~tEq.("a pedal that stops at 126 reaches the end with inHi 126", h.position(126, nil, 126), 1);
~tEq.("pitch bend over 16383", h.position(16383, nil, nil, 16383), 1);
~tEq.("with no min and no max a knob covers its control's whole law",
    h.valueAt(0.5, { |c| c * 10 }, { |x| x / 10 }), 5);
same.("min and max narrow it", [0, 0.5, 1].collect { |c| h.valueAt(c, { |c| c * 10 }, { |x| x / 10 }, 2, 4) }, [2, 3, 4]);
same.("min above max turns it round", [0, 1].collect { |c| h.valueAt(c, { |c| c * 10 }, { |x| x / 10 }, 4, 2) }, [4, 2]);
~tNear.("...along the control's own law: halfway on the threshold's exponential law is the geometric mean",
    h.valueAt(0.5, { |c| ~onsetThresholdSpec.map(c) }, { |x| ~onsetThresholdSpec.unmap(x) }, 0.1, 1.0),
    0.1.sqrt, 1e-9);
~tEq.("a choice spreads the travel evenly over its items",
    [0, 0.24, 0.25, 0.74, 0.75, 1].collect { |c| h.choiceIndex(c, 4) }, [0, 0, 1, 2, 3, 3]);

// LooperMidiMap.decide, row by row (docs/dev/midi-map.md, 5.3). [action, state].
d = { |kind, binding, msg, val, state| h.decide(kind, binding, msg, val, state)[0] };
b = (msg: \note, num: 60, target: 'x');
~tEq.("a note on fires a trigger, flips a toggle, takes a knob to its far end, moves a choice on",
    [\trigger, \toggle, \continuous, \step, \choice].collect { |k| d.(k, b, \noteOn, 100) },
    [[\fire], [\flip], [\flip], [\flip], [\next]]);
~tEq.("a note off does nothing, but to a held toggle",
    [d.(\trigger, b, \noteOff, 0), d.(\toggle, b, \noteOff, 0), d.(\toggle, b.copy.put(\mode, \hold), \noteOff, 0)],
    [nil, nil, [\set, false]]);
~tEq.("...which the note on put on", d.(\toggle, b.copy.put(\mode, \hold), \noteOn, 100), [\set, true]);
b = (msg: \program, num: 4, target: 'x');
~tEq.("a program change acts as a press, and a held toggle flips on it (it has no release)",
    [\trigger, \toggle, \continuous, \choice].collect { |k| d.(k, b, \program, nil) }
        ++ [d.(\toggle, b.copy.put(\mode, \hold), \program, nil)],
    [[\fire], [\flip], [\flip], [\next], [\flip]]);
b = (msg: \cc, num: 80, target: 'x', switch: \oneMessage);
~tEq.("a one-message CC switch (the TSMega's 80, 81) acts on every message, 64 and 0 alike",
    [64, 0, 64].collect { |x| d.(\trigger, b, \cc, x) } ++ [0, 64].collect { |x| d.(\toggle, b, \cc, x) },
    [[\fire], [\fire], [\fire], [\flip], [\flip]]);
~tEq.("...and a following toggle takes 64 and up as on",
    [64, 0, 63].collect { |x| d.(\toggle, b.copy.put(\mode, \follow), \cc, x) },
    [[\set, true], [\set, false], [\set, false]]);
b = (msg: \cc, num: 20, target: 'x', switch: \pressRelease);
~tEq.("a press-and-release CC switch acts on its press, at 64 and up",
    [127, 0].collect { |x| d.(\trigger, b, \cc, x) } ++ [127, 0].collect { |x| d.(\toggle, b, \cc, x) }
        ++ [127, 0].collect { |x| d.(\choice, b, \cc, x) },
    [[\fire], nil, [\flip], nil, [\next], nil]);
~tEq.("...holds a held toggle while pressed, and takes a knob to its ends",
    [127, 0].collect { |x| d.(\toggle, b.copy.put(\mode, \hold), \cc, x) }
        ++ [127, 0].collect { |x| d.(\continuous, b, \cc, x) },
    [[\set, true], [\set, false], [\end, \max], [\end, \min]]);
b = (msg: \cc, num: 11, target: 'x');
act = { |kind, values, binding|
    var st, acts = List.new;
    values.do { |x| var r = h.decide(kind, binding ? b, \cc, x, st); st = r[1]; acts.add(r[0]) };
    acts.asArray
};
~tEq.("a knob on a trigger: its first message only says where it is",
    act.(\trigger, [100]), [nil]);
~tEq.("...then it fires as it rises to 64, not again while up, and is re-armed only at 56 or below",
    act.(\trigger, [10, 64, 100, 60, 64, 56, 64]), [nil, [\fire], nil, nil, nil, nil, [\fire]]);
~tEq.("a pedal resting at 57-63 can't fire a trigger by flickering to 64, after a rebuild either",
    act.(\trigger, [60, 64, 63, 64, 57, 64]), [nil, nil, nil, nil, nil, nil]);
~tEq.("...until it has been down at 56", act.(\trigger, [60, 56, 64]), [nil, nil, [\fire]]);
~tEq.("a knob on a toggle: on at 64 and up, off again only at 56 or below",
    act.(\toggle, [60, 64, 100, 60, 57, 56, 50, 64]),
    [nil, [\set, true], nil, nil, nil, [\set, false], nil, [\set, true]]);
~tEq.("a knob on a continuous control: every message, as val / 127, the same value again too",
    act.(\continuous, [0, 64, 64, 127]), [[\position, 0], [\position, 64 / 127], [\position, 64 / 127], [\position, 1]]);
~tEq.("...and with hysteresis 1, a, b, a once", act.(\continuous, [68, 69, 68, 69], b.copy.put(\hysteresis, 1)),
    [[\position, 68 / 127], nil, nil, nil]);
~tEq.("pitch bend sets a knob or a choice, over 16383, and leaves switches alone",
    [d.(\continuous, (msg: \bend, target: 'x'), \bend, 16383), d.(\trigger, (msg: \bend, target: 'x'), \bend, 16383),
        d.(\toggle, (msg: \bend, target: 'x'), \bend, 0)],
    [[\position, 1], nil, nil]);

// --------------------------------------------------------------- takeover --
// What a knob does to a control it is not at (docs/dev/midi-map.md 5.4), and the
// router's defaults where a binding names none (decisions 7 and 15).
same.("knobAt is valueAt backwards: on the whole law, between min and max, and beyond them",
    [h.knobAt(5, { |x| x / 10 }), h.knobAt(3, { |x| x / 10 }, 2, 4), h.knobAt(5, { |x| x / 10 }, 2, 4)], [0.5, 0.5, 1.5]);
~tNear.("...on the threshold's exponential law too",
    h.knobAt(h.valueAt(0.3, { |c| ~onsetThresholdSpec.map(c) }, { |x| ~onsetThresholdSpec.unmap(x) }, 0.1, 1.0),
        { |x| ~onsetThresholdSpec.unmap(x) }, 0.1, 1.0), 0.3, 1e-9);
// A knob turned along `knobs` (positions) against a control at `at` that
// nothing else moves: what each message sets it to, nil for nothing.
glide = { |mode, knobs, at|
    var s = (), cur = at;
    knobs.collect { |k| var p = h.takeover(mode, k, s, cur, cur); p !? { cur = p; s[\readBack] = p }; p }
};
~tEq.("none: the control jumps to the knob", glide.(\none, [0.2, 0.5], 0.8), [0.2, 0.5]);
~tEq.("pick-up: a knob away from the control moves nothing until it crosses it, then it follows",
    glide.(\pickup, [0.2, 0.4, 0.6, 0.78, 0.85, 0.9], 0.8), [nil, nil, nil, nil, 0.85, 0.9]);
~tEq.("...a fast turn that skips over the value catches it too", glide.(\pickup, [0.1, 0.95], 0.5), [nil, 0.95]);
~tEq.("...and a knob within a step of it takes it at once, as one that held it and lost what it kept does",
    glide.(\pickup, [0.5, 0.6], 0.5 - (1 / 127)), [0.5, 0.6]);
~tEq.("...but not from two steps", glide.(\pickup, [0.5], 0.5 - (2 / 127)), [nil]);
~tEq.("...from a step and a half it does: a controller sent the control's place, rounded, takes it with its first step either way",
    [glide.(\pickup, [65 / 127], 0.5), glide.(\pickup, [62 / 127], 0.5)], [[65 / 127], [62 / 127]]);
~tEq.("...a control at an end is caught within two steps of it: a pedal that stops short of 127 gets there",
    glide.(\pickup, [120, 124, 125, 110].collect(_ / 127), 1.0), [nil, nil, 125 / 127, 110 / 127]);
~tEq.("...at either end", glide.(\pickup, [10, 2].collect(_ / 127), 0.0), [nil, 2 / 127]);
~tEq.("...two steps on either side: a pedal that stops at 125 takes a control just short of the top",
    glide.(\pickup, [100, 125].collect(_ / 127), 0.994), [nil, 125 / 127]);
~tEq.("...and a knob at the top a control two steps short of it, beyond a step and a half",
    glide.(\pickup, [1.0], 1 - (2 / 127)), [1.0]);
~tEq.("...but a knob at its end doesn't take a control the mouse left mid-way",
    glide.(\pickup, [120, 124, 125, 126].collect(_ / 127), 0.4), [nil, nil, nil, nil]);
// The router's side, simulated: the control read before each message and
// read back after each set, and moved by the mouse where `moves` says.
mouse = { |knobs, start, moves, mode = \pickup|
    var s = (), value = start;
    knobs.collect { |k, i|
        var p;
        moves[i] !? { |x| value = x };
        p = h.takeover(mode, k, s, value, value);
        p !? { value = p; s[\readBack] = value };
        p
    }
};
// The same for a control that rounds what it is set to: read before each
// message as a knob position (`toPos`), read back after each set (`fromPos`
// rounds), and for pick-up the knob's band of the control's value (`same`).
// A count of 0-7, and a choice of 4 items, as the router reads them.
rounding = { |mode, knobs, value, toPos, fromPos, same|
    var s = ();
    knobs.collect { |k|
        var p = h.takeover(mode, k, s, toPos.(value), value, same !? { |f| { |c| f.(c, value) } });
        p !? { value = fromPos.(p); s[\readBack] = value };
        value
    }
};
count = [{ |v| v / 7 }, { |p| (p * 7).round }, { |c, v| (c * 7).round == v }];
menu = [{ |i| (i + 0.5) / 4 }, { |p| h.choiceIndex(p, 4) }, { |c, v| h.choiceIndex(c, 4) == v }];
~tEq.("pick-up on a choice: a knob anywhere in the band of the control's item takes it, and follows",
    rounding.(\pickup, (40, 39 .. 0) / 127, 1, *menu).last, 0);
~tEq.("...and on a count", rounding.(\pickup, ((0..50) ++ (49, 48 .. 20)) / 127, 3, *count).last, 1);
~tEq.("...moved by something else since (the mouse), the control has to be caught again",
    mouse.([0.5, 0.55, 0.6, 0.15, 0.1], 0.5, [nil, nil, 0.2, nil, nil]), [0.5, 0.55, nil, 0.15, 0.1]);
~tEq.("scale: a knob's first message only says where it is", glide.(\scale, [0.2], 0.8), [nil]);
same.("...then the control moves by the same share of the room left: up from 0.8, with the knob at 0.2",
    glide.(\scale, [0.2, 0.3, 0.6, 1.0], 0.8), [nil, 0.825, 0.9, 1.0]);
same.("...and down, knob and control meet at 0", glide.(\scale, [0.6, 0.3, 0.0], 0.9), [nil, 0.45, 0]);
~tEq.("...the same position again moves nothing", glide.(\scale, [0.6, 0.6], 0.9), [nil, nil]);
~tEq.("...on a count it goes on from where it put it, unrounded: the count moves along with the knob, not all at its end",
    rounding.(\scale, (64..127) / 127, 3, *count).atAll([32, 63]), [5, 7]);
~tEq.("...down too", rounding.(\scale, (64, 63 .. 0) / 127, 4, *count).atAll([32, 64]), [2, 0]);
~tEq.("...and on a choice", rounding.(\scale, (64..127) / 127, 1, *menu).atAll([32, 63]), [2, 3]);
~tEq.("...moved by something else since, the control takes the knob's next message as its first: a flicker at the end doesn't slam it",
    mouse.([120, 122, 124, 126, 127].collect(_ / 127), 0.5, [nil, nil, nil, nil, 0.3], \scale).last, nil);
same.("...and the one after goes on from where it is now",
    mouse.([120, 122, 124, 126, 127, 120].collect(_ / 127), 0.5, [nil, nil, nil, nil, 0.3], \scale).last,
    0.3 - (0.3 * (7 / 127)));
~tEq.("a control that can't be read jumps, whatever the takeover",
    [\pickup, \scale].collect { |x| h.takeover(x, 0.3, (), nil, nil) }, [0.3, 0.3]);
~tEq.("a control outside the knob's range is met at the knob's end",
    glide.(\pickup, [0.9, 1.0], 1.4), [nil, 1.0]);
actK = { |kind, values, binding, knob, msg = \cc|
    var st, acts = List.new;
    values.do { |x| var r = h.decide(kind, binding, msg, x, st, knob); st = r[1]; acts.add(r[0]) };
    acts.asArray
};
b = (msg: \cc, num: 11, target: 'x');
~tEq.("the router's default hysteresis is a CC's that names none: a, b, a once",
    actK.(\continuous, [68, 69, 68], b, (hysteresis: 1)), [[\position, 68 / 127], nil, nil]);
~tEq.("...a binding's own 0 is none, the default or not", actK.(\continuous, [68, 69], b.copy.put(\hysteresis, 0),
    (hysteresis: 1)), [[\position, 68 / 127], [\position, 69 / 127]]);
~tEq.("...pitch bend has none", actK.(\continuous, [8000, 8001], (msg: \bend, target: 'x'), (hysteresis: 1), \bend),
    [[\position, 8000 / 16383], [\position, 8001 / 16383]]);
~tEq.("...and with no defaults given, none (as before)", actK.(\continuous, [68, 69], b), [[\position, 68 / 127], [\position, 69 / 127]]);
~tEq.("the router's default takeover: pick-up holds a knob away from the control",
    h.decide(\continuous, b, \cc, 20, nil, (takeover: \pickup, current: 0.8, value: 8))[0], nil);
~tEq.("...and a binding's own takeover comes first", h.decide(\continuous, b.copy.put(\takeover, \none), \cc, 20, nil,
    (takeover: \pickup, current: 0.8, value: 8))[0], [\position, 20 / 127]);
~tEq.("a CC switch on a level is not a knob: no takeover", h.decide(\continuous, b.copy.put(\switch, \pressRelease),
    \cc, 127, nil, (takeover: \pickup, current: 0.2, value: 2))[0], [\end, \max]);
~tEq.("pick-up's step is one of the binding's input range: a narrow sweep's step is bigger",
    [h.decide(\continuous, b, \cc, 20, nil, (takeover: \pickup, current: (20 / 127) + 0.02, value: 2.2))[0],
        h.decide(\continuous, b.copy.put(\inLo, 0).put(\inHi, 40), \cc, 20, nil,
            (takeover: \pickup, current: 0.52, value: 5.2))[0]],
    [nil, [\position, 0.5]]);
// What the router keeps of each knob is in the map's slots, and a map swapped
// in takes it from the one in force (adopt).
{
    var b1 = (msg: \cc, num: 1, target: 'x'), b2 = (msg: \cc, num: 2, target: 'y');
    var m1 = h.new([b1, b2]), m2, m3, m4, m5;
    var st = { |m, i| m.slots[i][\states] };
    st.(m1, 0).put(1001, [(k: 0.5, caught: true)]);
    st.(m1, 1).put(1001, [(k: 0.2)]);
    m2 = m1.replacing(b2, b2.copy.put(\takeover, \pickup)).adopt(m1);
    ~tAssert.("an edit keeps what the router kept of the bindings it leaves alone", st.(m2, 0) === st.(m1, 0));
    ~tAssert.("...and of one changed only in how it acts (here its takeover)", st.(m2, 1) === st.(m1, 1));
    m3 = m2.replacing(m2.bindings[1], b2.copy.put(\inHi, 126)).adopt(m2);
    ~tAssert.("...but one whose range changed starts afresh", (st.(m3, 1) !== st.(m2, 1)) and: { st.(m3, 1).isEmpty });
    m1.adopt(m3);
    ~tAssert.("a map back from Undo brings no stale knob with it: what the map in force doesn't have starts afresh",
        st.(m1, 1).isEmpty and: { st.(m1, 0) === st.(m3, 0) });
    m4 = h.new([b1, b1.copy.put(\layer, true)]);
    m5 = h.new(m4.bindings.reverse).adopt(m4);
    ~tAssert.("...and two bindings alike each keep their own", (st.(m5, 0) === st.(m4, 1)) and: { st.(m5, 1) === st.(m4, 0) });
    m5 = h.new([b1, m4.bindings[1].copy.put(\takeover, \pickup)]).adopt(m4);
    ~tAssert.("...one of them changed takes its own, not its twin's", (st.(m5, 0) === st.(m4, 0)) and: { st.(m5, 1) === st.(m4, 1) });
    ~tEq.("...and one whose message, number, channel, input, control, min, max, input range or switch changed starts afresh",
        [(msg: \note), (num: 3), (chan: 1), (device: "UC4"), (target: 'z'), (min: 0.1), (max: 0.9), (inLo: 2), (inHi: 100),
            (switch: \pressRelease)].select { |ch| st.(m1.replacing(b1, b1.copy.putAll(ch)).adopt(m1), 0) === st.(m1, 0) },
        []);
}.value;

// ------------------------------------------------------------ the router --
// Stub controls that write down what is done to them, a map on them, and
// the router's own route.
calls = List.new;
stub = { |id, kind, more|
    var t = (id: id, kind: kind, fire: { calls.add([id, \fire, thisThread.seconds]) },
        flip: { calls.add([id, \flip]) }, set: { |x| calls.add([id, \set, x]) },
        get: { 0 }, fromPos: { |c| c * 10 }, toPos: { |x| x / 10 });
    more !? { |x| t.putAll(x) };
    t
};
targets = IdentityDictionary[
    'go' -> stub.('go', \trigger), 'sw' -> stub.('sw', \toggle), 'knob' -> stub.('knob', \continuous),
    'count' -> stub.('count', \step), 'menu' -> stub.('menu', \choice, (items: ["a", "b", "c"], get: { 2 })),
    'gone' -> stub.('gone', \trigger, (available: { false })),
    'boom' -> stub.('boom', \trigger, (fire: { Error("on fire").throw }))
];
map = h.new([
    (msg: \program, num: 1, target: 'go'), (msg: \program, num: 2, target: 'sw'),
    (msg: \cc, num: 3, target: 'knob'), (msg: \cc, num: 4, target: 'knob', hysteresis: 1, min: 2, max: 4),
    (msg: \cc, num: 5, target: 'count'), (msg: \cc, num: 6, target: 'menu'),
    (msg: \program, num: 7, target: 'gone'), (msg: \program, num: 8, target: 'nowhere'),
    (msg: \program, num: 9, target: 'boom'), (msg: \program, num: 9, target: 'go', layer: true),
    (msg: \program, num: 10, chan: 1, target: 'go'),
    (msg: \program, num: 11, device: "TSMEGA", target: 'go'),
    (msg: \cc, num: 12, target: 'sw'), (msg: \note, num: 60, target: 'menu')
], "test");
warned = IdentitySet.new;
srcs = IdentityDictionary[1001 -> ["TSMEGA", "TSMEGA"], 1002 -> ["UC4", "UC4"]];
route = { |msg, chan, num, val, src = 1001|
    calls = List.new;
    ~midiRouteWith.(map, targets, msg, chan, num, val, src, srcs, warned);
    calls.asArray
};
~tEq.("the map for the router has no problems", map.problems.asArray, []);
~tEq.("a program change fires its trigger", route.(\program, 0, 1).collect { |c| c.keep(2) }, [['go', \fire]]);
~tEq.("...and flips its toggle", route.(\program, 0, 2), [['sw', \flip]]);
same.("a CC sets its knob along the law, at once", route.(\cc, 0, 3, 127), [['knob', \set, 10]]);
same.("...between the binding's min and max", route.(\cc, 0, 4, 127), [['knob', \set, 4]]);
~tEq.("...with its hysteresis: a step back is left out", route.(\cc, 0, 4, 126), []);
same.("...per input: another controller's first value counts", route.(\cc, 0, 4, 0, 1002), [['knob', \set, 2]]);
same.("...and per channel", route.(\cc, 1, 4, 0), [['knob', \set, 2]]);
// Pick-up through the router: the control's value is read when a message
// comes, and read back after the set, so the mouse moving it is noticed.
{
    var level = 8.0, go;
    var tg = IdentityDictionary['lvl' -> (id: 'lvl', kind: \continuous, get: { level }, set: { |x| level = x },
        fromPos: { |c| c * 10 }, toPos: { |x| x / 10 })];
    var picky = h.new([(msg: \cc, num: 30, target: 'lvl')], "pickup");
    go = { |val, defaults| ~midiRouteWith.(picky, tg, \cc, 0, 30, val, 1001, srcs, warned, defaults) };
    go.(20, (hysteresis: 1, takeover: \pickup));
    ~tEq.("pick-up, the router's default: a knob away from the control leaves it", level, 8.0);
    go.(110, (hysteresis: 1, takeover: \pickup));
    ~tNear.("...crossing it, the knob takes it", level, 1100 / 127, 1e-9);
    level = 2.0;
    go.(105, (hysteresis: 1, takeover: \pickup));
    ~tNear.("...the mouse moves the control: the knob leaves it, until it catches it again", level, 2.0, 1e-9);
    go.(20, (hysteresis: 1, takeover: \pickup));
    ~tNear.("...which it does, crossing it", level, 200 / 127, 1e-9);
    go.(60, (hysteresis: 1, takeover: \none));
    ~tNear.("with the default none, the control jumps to the knob", level, 600 / 127, 1e-9);
    // A binding's own takeover, the default none (the editor's "picks up").
    picky = h.new([(msg: \cc, num: 30, target: 'lvl', takeover: \pickup)], "own");
    level = 8.0;
    go.(20, (hysteresis: 1, takeover: \none));
    ~tEq.("a binding's own pick-up holds, the router's default none or not", level, 8.0);
    // Between the binding's min and max, the knob is where it would set the
    // control: 3.5 of 2-8 is a quarter of the way, CC 32.
    picky = h.new([(msg: \cc, num: 30, target: 'lvl', min: 2, max: 8)], "range");
    level = 3.5;
    go.(44, (hysteresis: 1, takeover: \pickup));
    ~tEq.("pick-up on a binding with a min and a max: not where the control is on its whole law", level, 3.5);
    go.(32, (hysteresis: 1, takeover: \pickup));
    ~tNear.("...but where the binding would set it", level, 2 + (6 * 32 / 127), 1e-9);
    // Pitch bend, from the bottom to past the middle: its 14 bits, no hysteresis.
    picky = h.new([(msg: \bend, target: 'lvl')], "bend");
    level = 5.0;
    [0, 4000, 7900].do { |x| ~midiRouteWith.(picky, tg, \bend, 0, nil, x, 1001, srcs, warned, (takeover: \pickup)) };
    ~tEq.("pick-up on pitch bend: a wheel away from the control leaves it", level, 5.0);
    ~midiRouteWith.(picky, tg, \bend, 0, nil, 8300, 1001, srcs, warned, (takeover: \pickup));
    ~tNear.("...crossing it, it takes it", level, 83000 / 16383, 1e-9);
    // A pitch bend sender of 7 bits tops at 16256: a control at its top is
    // still taken, at the end, and a wheel within a CC's step takes it.
    picky = h.new([(msg: \bend, target: 'lvl')], "bend 7-bit");
    level = 10.0;
    [12000, 16256].do { |x| ~midiRouteWith.(picky, tg, \bend, 0, nil, x, 1001, srcs, warned, (takeover: \pickup)) };
    ~tNear.("pick-up on pitch bend from a 7-bit sender takes a control at its top", level, 162560 / 16383, 1e-9);
    picky = h.new([(msg: \bend, target: 'lvl')], "bend step");
    level = 5.0;
    ~midiRouteWith.(picky, tg, \bend, 0, nil, 8100, 1001, srcs, warned, (takeover: \pickup));
    ~tNear.("...and one within a CC's step of a control at once: pitch bend's step is never finer", level, 81000 / 16383, 1e-9);
    // A knob turned round (Swap: min 10, max 0): the control at 8 is where
    // the knob, a fifth of the way, would set it.
    picky = h.new([(msg: \cc, num: 30, target: 'lvl', min: 10, max: 0)], "swapped");
    level = 8.0;
    [95, 100, 105].do { |x| go.(x, (hysteresis: 1, takeover: \pickup)) };
    ~tEq.("pick-up on a knob turned round: a knob away from the control leaves it", level, 8.0);
    go.(25, (hysteresis: 1, takeover: \pickup));
    ~tNear.("...and at its place, turned round, it takes it", level, (1 - (25 / 127)) * 10, 1e-9);
    // A control whose read throws has no current: it jumps, as a takeover
    // can't hold it, and the binding still acts.
    tg['lvl'].put(\get, { Error("can't read").throw });
    picky = h.new([(msg: \cc, num: 30, target: 'lvl')], "throws");
    go.(20, (hysteresis: 1, takeover: \pickup));
    ~tNear.("a control that can't be read jumps to the knob, pick-up or not", level, 200 / 127, 1e-9);
}.value;
// A count of 1-8 and a choice of 4 through the router, which rounds them as
// it sets them: scale moves them along with the knob, and pick-up takes them
// anywhere in the band of their value.
{
    var n = 4, i = 1, go;
    var tg = IdentityDictionary[
        'n' -> (id: 'n', kind: \step, get: { n }, set: { |x| n = x }, fromPos: { |c| 1 + (c * 7) }, toPos: { |x| (x - 1) / 7 }),
        'i' -> (id: 'i', kind: \choice, get: { i }, set: { |x| i = x }, items: ["a", "b", "c", "d"],
            fromPos: { |c| h.choiceIndex(c, 4) }, toPos: { |x| (x + 0.5) / 4 })];
    var m = h.new([(msg: \cc, num: 30, target: 'n'), (msg: \cc, num: 31, target: 'i')], "counts");
    go = { |num, vals, mode| vals.collect { |x|
        ~midiRouteWith.(m, tg, \cc, 0, num, x, 1001, srcs, warned, (hysteresis: 1, takeover: mode));
        if(num == 30) { n } { i }
    } };
    ~tEq.("scale through the router: a count moves along with the knob, not all at its end",
        go.(30, (64..127), \scale).atAll([32, 63]), [6, 8]);
    ~tEq.("...and a choice", go.(31, (64..127), \scale).atAll([32, 63]), [2, 3]);
    m = h.new(m.bindings, "counts again");
    n = 4;
    i = 1;
    ~tEq.("pick-up through the router: a count is taken anywhere in its value's band, and follows",
        go.(30, (0..50) ++ (49, 48 .. 20), \pickup).last, 2);
    ~tEq.("...and a choice", go.(31, (40, 39 .. 0), \pickup).last, 0);
}.value;
// What the router keeps of a knob lasts through an edit of another mapping
// and through Undo, and it forgets it when it doesn't see the knob's messages:
// learning took them, the input isn't listened to, the control isn't there.
{
    var level = 5.0, here = true, state, cc, gone;
    var saved = [~midiMap, ~midiTargets, ~midiSources, ~midiDeaf, ~midiLearning, ~midiDefaults, ~midiSweep, ~midiUndo];
    protect {
        ~midiTargets = IdentityDictionary[
            'lvl' -> (id: 'lvl', kind: \continuous, get: { level }, set: { |x| level = x },
                fromPos: { |c| c * 10 }, toPos: { |x| x / 10 }, available: { here }),
            'go' -> (id: 'go', kind: \trigger, fire: { })];
        ~midiMap = h.new([(msg: \cc, num: 30, target: 'lvl'), (msg: \program, num: 1, target: 'go')], "states");
        ~midiUndo = List.new;
        ~midiSources = srcs;
        ~midiDeaf = IdentitySet.new;
        ~midiLearning = nil;
        ~midiSweep = nil;
        ~midiDefaults = (hysteresis: 1, takeover: \pickup);
        cc = { |vals, src = 1001| vals.do { |x| ~midiRoute.(\cc, 0, 30, x, src) } };
        state = { ~midiMap.lookup(\cc, 0, 30)[0][\states][1001] !? { |x| x[0] } };
        // Forgotten: the knob's place and the takeover's catch; its
        // hysteresis's last value stays.
        gone = { var st = state.(); st.notNil and: { [\k, \caught, \pos, \readBack].every { |x| st[x].isNil } }
            and: { st[\last].notNil } };
        cc.([58, 66]);
        ~tNear.("(a pick-up knob catches its control, crossing it)", level, 660 / 127, 1e-9);
        ~midiBindingChange.(~midiMap.bindings[1], (num: 2));
        // Two steps from the control: only a knob still caught takes it.
        cc.([68, 70]);
        ~tNear.("a pick-up knob keeps its control through an edit of another mapping, turned away from it",
            level, 700 / 127, 1e-9);
        ~midiMapUndo.();
        cc.([72]);
        ~tNear.("...and through Undo", level, 720 / 127, 1e-9);
        // Undo brings a binding back as it was, but not what was kept of it
        // then: its knob may have moved since, and an old last position
        // would make a crossing out of a move it never saw.
        {
            var was = ~midiMap, lv = level;
            ~midiMap = h.new([(msg: \cc, num: 30, target: 'lvl')], "undo");
            level = 2.0;
            cc.([20, 26]);
            ~midiBindingChange.(~midiMap.bindings[0], (min: 0, max: 10));
            cc.([60, 110]);
            level = 5.0;
            ~midiMapUndo.();
            cc.([111]);
            ~tNear.("Undo brings a binding back as it was, but not what was kept of it then: no false catch",
                level, 5.0, 1e-9);
            ~midiMap = was;
            level = lv;
        }.value;
        ~midiDeaf = IdentitySet[1001];
        cc.([110]);
        ~tAssert.("a knob's message from an input not listened to: its place and its catch are forgotten, its hysteresis kept",
            gone.(), state.().asString);
        ~midiDeaf = IdentitySet.new;
        cc.([111]);
        ~tNear.("...so, listened to again, a pick-up knob that moved meanwhile doesn't drag its control along",
            level, 720 / 127, 1e-9);
        cc.([80, 70]);
        ~tNear.("(it catches it again, crossing it)", level, 700 / 127, 1e-9);
        ~midiLearnArm.('go');
        cc.([100]);
        ~tAssert.("...one a learning took: forgotten too", gone.(), state.().asString);
        ~midiLearnDisarm.(nil);
        cc.([101]);
        ~tNear.("...so the control stays where it was", level, 700 / 127, 1e-9);
        cc.([80, 60]);
        here = false;
        cc.([90]);
        ~tAssert.("...and one whose control isn't there now", gone.(), state.().asString);
        here = true;
        cc.([91]);
        ~tNear.("...so, back, it stays where it was", level, 600 / 127, 1e-9);
        // An input range being swept notes only what reaches the bindings.
        ~midiSweepStart.(~midiMap.bindings[0]);
        cc.([10, 120]);
        ~midiDeaf = IdentitySet[1002];
        cc.([0, 127], 1002);
        ~midiDeaf = IdentitySet.new;
        ~midiLearnArm.('go');
        cc.([2, 125]);
        ~midiLearnDisarm.(nil);
        ~tEq.("a sweep notes what reaches the bindings: not an input not listened to, nor what a learning takes",
            [~midiSweep[\lo], ~midiSweep[\hi]], [10, 120]);
        ~midiSweepEnd.(false, "dropped");
        ~tEq.("...and dropped, it changes nothing and says why", [~midiSweep, ~midiMap.bindings[0][\inLo], ~midiLearnNote],
            [nil, nil, "dropped"]);
    } {
        ~midiMap = saved[0]; ~midiTargets = saved[1]; ~midiSources = saved[2]; ~midiDeaf = saved[3] ? IdentitySet.new;
        ~midiLearning = saved[4]; ~midiDefaults = saved[5]; ~midiSweep = saved[6]; ~midiUndo = saved[7] ? List.new;
    };
}.value;
// A takeover changed, by the mapping's own menu or the Knobs row, starts
// afresh: pick-up's catch doesn't outlive a spell of scaling, nor scale's
// place a spell of picking up, and scale's first message under it only says
// where the knob is, so a mouse move just before it isn't undone.
{
    var level = 5.0, cc, hold, c0 = 20 / 127;
    var saved = [~midiMap, ~midiTargets, ~midiSources, ~midiDeaf, ~midiLearning, ~midiDefaults, ~midiSweep, ~midiUndo];
    protect {
        ~midiTargets = IdentityDictionary['lvl' -> (id: 'lvl', kind: \continuous, get: { level }, set: { |x| level = x },
            fromPos: { |c| c * 10 }, toPos: { |x| x / 10 })];
        ~midiMap = h.new([(msg: \cc, num: 30, target: 'lvl')], "modes");
        ~midiUndo = List.new;
        ~midiSources = srcs;
        ~midiDeaf = IdentitySet.new;
        ~midiLearning = nil;
        ~midiSweep = nil;
        ~midiDefaults = (hysteresis: 1, takeover: \pickup);
        cc = { |vals| vals.do { |x| ~midiRoute.(\cc, 0, 30, x, 1001) } };
        cc.([60, 62, 64]);
        ~midiBindingChange.(~midiMap.bindings[0], (takeover: \scale));
        level = 2.0;
        cc.([92, 100, 110]);
        ~midiBindingChange.(~midiMap.bindings[0], (takeover: \remove));
        hold = level;
        cc.([111]);
        ~tEq.("a takeover changed starts afresh: pick-up's catch doesn't outlive a spell of scaling", level, hold);
        ~midiMap = h.new([(msg: \cc, num: 30, target: 'lvl')], "modes, the Knobs row");
        ~midiDefaults = (hysteresis: 1, takeover: \scale);
        level = 8.0;
        cc.([20, 30, 40]);
        ~midiDefaults = (hysteresis: 1, takeover: \pickup);
        cc.([60, 80, 100, 110, 90, 60, 40, 20]);
        ~midiDefaults = (hysteresis: 1, takeover: \scale);
        cc.([22]);
        ~tNear.("...nor scale's place a spell of picking up (the Knobs row): back on scale, the first message says where the knob is",
            level, 200 / 127, 1e-9);
        cc.([24]);
        ~tNear.("...and the next goes on from where the control is", level, (c0 + ((1 - c0) * (2 / 127) / (105 / 127))) * 10, 1e-9);
        ~midiMap = h.new([(msg: \cc, num: 30, target: 'lvl')], "modes, from jumps");
        ~midiDefaults = (hysteresis: 1, takeover: \none);
        cc.([100, 110, 120, 125]);
        ~midiDefaults = (hysteresis: 1, takeover: \scale);
        level = 3.0;
        cc.([126]);
        ~tEq.("...from jumps to scale, a mouse move between: the knob's first message doesn't take the control", level, 3.0);
    } {
        ~midiMap = saved[0]; ~midiTargets = saved[1]; ~midiSources = saved[2]; ~midiDeaf = saved[3] ? IdentitySet.new;
        ~midiLearning = saved[4]; ~midiDefaults = saved[5]; ~midiSweep = saved[6]; ~midiUndo = saved[7] ? List.new;
    };
}.value;
// What the router forgets keeps the hysteresis: the resting pedal's flicker,
// across a learning or its input switched off and on, still can't take back
// a level the mouse set (the pedal fix, 3.3). A knob on a toggle keeps its
// side; one on a trigger is disarmed, so a press made unseen never fires.
{
    var level = 5.0, on = false, fired = 0;
    var saved = [~midiMap, ~midiTargets, ~midiSources, ~midiDeaf, ~midiLearning, ~midiDefaults, ~midiSweep, ~midiUndo];
    protect {
        ~midiTargets = IdentityDictionary[
            'lvl' -> (id: 'lvl', kind: \continuous, get: { level }, set: { |x| level = x },
                fromPos: { |c| c * 10 }, toPos: { |x| x / 10 }),
            'sw' -> (id: 'sw', kind: \toggle, get: { on }, set: { |x| on = x }),
            'go' -> (id: 'go', kind: \trigger, fire: { fired = fired + 1 })];
        ~midiMap = h.new([(msg: \cc, num: 7, target: 'lvl'), (msg: \cc, num: 12, target: 'sw'),
            (msg: \cc, num: 13, target: 'go')], "flicker");
        ~midiUndo = List.new;
        ~midiSources = srcs;
        ~midiDeaf = IdentitySet.new;
        ~midiLearning = nil;
        ~midiSweep = nil;
        ~midiDefaults = (hysteresis: 1, takeover: \none);
        [68, 69, 68].do { |x| ~midiRoute.(\cc, 0, 7, x, 1001) };
        level = 3.0;
        ~midiLearnArm.('go');
        [69, 68].do { |x| ~midiRoute.(\cc, 0, 7, x, 1001) };
        ~midiLearnDisarm.(nil);
        [69, 68, 69].do { |x| ~midiRoute.(\cc, 0, 7, x, 1001) };
        ~tEq.("the resting pedal's flicker, across a learning, leaves a level the mouse set alone", level, 3.0);
        ~midiDeaf = IdentitySet[1001];
        [68, 69].do { |x| ~midiRoute.(\cc, 0, 7, x, 1001) };
        ~midiDeaf = IdentitySet.new;
        [68, 69].do { |x| ~midiRoute.(\cc, 0, 7, x, 1001) };
        ~tEq.("...and across its input switched off and on", level, 3.0);
        ~midiRoute.(\cc, 0, 12, 100, 1001);
        on = false;
        ~midiLearnArm.('go');
        ~midiRoute.(\cc, 0, 12, 99, 1001);
        ~midiLearnDisarm.(nil);
        ~midiRoute.(\cc, 0, 12, 100, 1001);
        ~tEq.("a knob on a toggle keeps its side across a learning: its flicker doesn't switch back what the mouse switched",
            on, false);
        ~midiRoute.(\cc, 0, 13, 20, 1001);
        ~midiLearnArm.('go');
        ~midiRoute.(\cc, 0, 13, 100, 1001);
        ~midiLearnDisarm.(nil);
        ~midiRoute.(\cc, 0, 13, 101, 1001);
        ~tEq.("...and one on a trigger is disarmed: a press the router didn't see never fires", fired, 0);
    } {
        ~midiMap = saved[0]; ~midiTargets = saved[1]; ~midiSources = saved[2]; ~midiDeaf = saved[3] ? IdentitySet.new;
        ~midiLearning = saved[4]; ~midiDefaults = saved[5]; ~midiSweep = saved[6]; ~midiUndo = saved[7] ? List.new;
    };
}.value;
// While a learning counts a switch's presses, another input's knob goes
// through, unless its input isn't listened to: then it is held back, and
// what its binding kept of it is forgotten too.
{
    var level = 5.0, tt = 1000.0, how, st;
    var saved = [~midiMap, ~midiTargets, ~midiSources, ~midiDeaf, ~midiLearning, ~midiDefaults, ~midiSweep, ~midiNow];
    protect {
        ~midiNow = { tt };
        ~midiTargets = IdentityDictionary[
            'lvl' -> (id: 'lvl', kind: \continuous, get: { level }, set: { |x| level = x },
                fromPos: { |c| c * 10 }, toPos: { |x| x / 10 }),
            'go' -> (id: 'go', kind: \trigger, fire: { })];
        ~midiMap = h.new([(msg: \cc, num: 30, target: 'lvl')], "counting");
        ~midiSources = srcs;
        ~midiDeaf = IdentitySet.new;
        ~midiLearning = nil;
        ~midiSweep = nil;
        ~midiDefaults = (hysteresis: 1, takeover: \pickup);
        [60, 62, 64].do { |x| ~midiRoute.(\cc, 0, 30, x, 1001) };
        ~midiRoute.(\cc, 0, 80, 0, 1002);
        ~midiLearnArm.('go');
        ~midiRoute.(\cc, 0, 80, 64, 1002);
        tt = tt + 0.05;
        ~midiLearnLive.(tt);
        ~midiDeaf = IdentitySet[1001];
        how = ~midiRoute.(\cc, 0, 30, 110, 1001);
        st = ~midiMap.slots[0][\states][1001] !? { |x| x[0] };
        ~tEq.("while a learning counts a switch's presses, a knob from an input not listened to is held back, its catch forgotten",
            [~midiLearning !? { |x| x[\learner].counting }, how, st !? { |x| x[\caught] }], [true, \deaf, nil]);
        ~midiLearnDisarm.(nil);
        ~midiDeaf = IdentitySet.new;
        ~midiRoute.(\cc, 0, 30, 111, 1001);
        ~tNear.("...so, listened to again, it doesn't drag its control along", level, 640 / 127, 1e-9);
    } {
        ~midiMap = saved[0]; ~midiTargets = saved[1]; ~midiSources = saved[2]; ~midiDeaf = saved[3] ? IdentitySet.new;
        ~midiLearning = saved[4]; ~midiDefaults = saved[5]; ~midiSweep = saved[6]; ~midiNow = saved[7] ? { Main.elapsedTime };
    };
}.value;
~tEq.("a step control is set in whole numbers", route.(\cc, 0, 5, 64), [['count', \set, 5]]);
~tEq.("a choice takes the item at the knob's place", route.(\cc, 0, 6, 127), [['menu', \set, 2]]);
~tEq.("...and a press moves it on, round from the last to the first", route.(\noteOn, 0, 60, 100), [['menu', \set, 0]]);
~tEq.("...but not on the note's release", route.(\noteOff, 0, 60, 0), []);
~tEq.("a control that is not there now does nothing", route.(\program, 0, 7), []);
~tEq.("nor does one this megalooper doesn't know", route.(\program, 0, 8), []);
~tEq.("one that throws doesn't stop the next binding on the same message",
    route.(\program, 0, 9).collect { |c| c.keep(2) }, [['go', \fire]]);
~tAssert.("...and is said once, not per message", { route.(\program, 0, 9); warned.includes('boom') }.value
    and: { warned.size == 1 });
~tEq.("a channel's binding answers that channel only", [route.(\program, 0, 10), route.(\program, 1, 10).size], [[], 1]);
~tEq.("a device's binding answers that device only, and not an input it can't name",
    [route.(\program, 0, 11).size, route.(\program, 0, 11, nil, 1002).size, route.(\program, 0, 11, nil, 9999).size],
    [1, 0, 0]);
~tEq.("a knob on a toggle switches with its own state per input",
    [route.(\cc, 0, 12, 100), route.(\cc, 0, 12, 10), route.(\cc, 0, 12, 100, 1002)],
    [[['sw', \set, true]], [['sw', \set, false]], [['sw', \set, true]]]);
~tEq.("a toggle with no set of its own flips to go where it is told, and only then",
    { var t = targets['sw'].copy.put(\set, nil).put(\get, { true }); calls = List.new;
      ~midiApply.(t, [\set, false], (msg: \cc)); ~midiApply.(t, [\set, true], (msg: \cc)); calls.asArray }.value,
    [['sw', \flip]]);
same.("a press on a knob takes it to the end further from where it is",
    { var t = targets['knob'].copy.put(\get, { 3 }); calls = List.new;
      ~midiApply.(t, [\flip], (msg: \note, min: 2, max: 9)); calls.asArray }.value,
    [['knob', \set, 9]]);
// The moment of arrival goes straight through: the drums and the break take
// it from the thread that runs the binding.
Routine { thisThread.seconds = 123.25; t0 = route.(\program, 0, 1) }.next;
~tEq.("a binding acts at the moment the message arrives, on its thread", t0 !? { |c| c[0][2] }, 123.25);
// Cost: a pedal sweep's worth of CCs through the router to a knob.
calls = List.new;
t0 = Main.elapsedTime;
10000.do { |i| ~midiRouteWith.(map, targets, \cc, 0, 3, i % 128, 1001, srcs, warned) };
t1 = Main.elapsedTime - t0;
~tAssert.("10,000 CCs go through the router in under half a second (" ++ (t1 * 1000).round(0.1) ++ " ms)",
    (t1 < 0.5) and: { calls.size == 10000 });
// ...and on a knob's whole way: ~midiRoute, the defaults, a pick-up reading
// the control, its band, and the read-back.
{
    var n = 4, saved = [~midiMap, ~midiTargets, ~midiSources, ~midiDeaf, ~midiLearning, ~midiDefaults, ~midiSweep];
    protect {
        ~midiTargets = IdentityDictionary['n' -> (id: 'n', kind: \step, get: { n }, set: { |x| n = x },
            fromPos: { |c| 1 + (c * 7) }, toPos: { |x| (x - 1) / 7 })];
        ~midiMap = h.new([(msg: \cc, num: 30, target: 'n')], "cost");
        ~midiSources = srcs;
        ~midiDeaf = IdentitySet.new;
        ~midiLearning = nil;
        ~midiSweep = nil;
        ~midiDefaults = (hysteresis: 1, takeover: \pickup);
        t0 = Main.elapsedTime;
        10000.do { |i| ~midiRoute.(\cc, 0, 30, i % 128, 1001) };
        t1 = Main.elapsedTime - t0;
        ~tAssert.("...and 10,000 picking up a count through the whole router, also in under half a second ("
            ++ (t1 * 1000).round(0.1) ++ " ms)", t1 < 0.5);
    } {
        ~midiMap = saved[0]; ~midiTargets = saved[1]; ~midiSources = saved[2]; ~midiDeaf = saved[3] ? IdentitySet.new;
        ~midiLearning = saved[4]; ~midiDefaults = saved[5]; ~midiSweep = saved[6];
    };
}.value;

// ---------------------------------------------------------- the controls --
// These sections swap globals a running megalooper uses (~looper, ~rp, the
// numbers), so each puts them back however it ends.
savedLooper = ~looper;
savedRp = ~rp;
protect {
    ~looper = nil;
    ~rp = nil;   // no rig said: one beside Live, as every rig without `live: false`
    targets = ~midiTargetsBuild.();
    kinds = #[\trigger, \toggle, \continuous, \step, \choice, \light];
    ~tEq.("the router still has the 36 controls today's numbers drive (none missing)",
        #['looper.trigger', 'looper.stop', 'looper.multiply', 'looper.undo', 'looper.clear',
            'looper.recordNextLoop', 'looper.break', 'looper.nextReading', 'looper.reverse', 'looper.dissolve',
            'looper.sessionRecording', 'looper.granular', 'looper.bbcut', 'looper.onsetNotes', 'live.record',
            'looper.feedback', 'looper.intensity', 'looper.granularMorph', 'looper.onsetThreshold',
            'looper.granularAmp', 'looper.granularPitch', 'looper.granularDetune', 'looper.granularSize',
            'looper.granularDensity', 'looper.granularSizeRand', 'looper.granularPosition', 'looper.granularScan',
            'looper.granularSpray', 'sa.fxOn.shifter', 'sa.fxOn.delay', 'sa.fxOn.filter', 'sa.fxOn.pitchLoop',
            'sa.fxOn.echo', 'sa.fxOn.saturator', 'sa.fxOn.redux', 'sa.drums.on'].reject { |id| targets.includesKey(id) },
        []);
    ~tAssert.("each knows its own id, and has a kind, a label and a tab",
        targets.keys.every { |id| var t = targets[id]; (t[\id] == id) and: { kinds.includes(t[\kind]) }
            and: { t[\label].isString } and: { t[\path].isString } });
    ~tAssert.("triggers fire, toggles flip, levels have a set and a law",
        targets.every { |t|
            case
            { t[\kind] == \trigger } { t[\fire].notNil }
            { t[\kind] == \toggle } { t[\flip].notNil }
            { t[\kind] == \light } { t[\get].notNil }
            { t[\set].notNil and: { t[\fromPos].notNil } and: { t[\toPos].notNil } } });
    ~tAssert.("every level's law goes back to where it came from (" ++ targets.count { |t| t[\kind] == \continuous } ++ " of them)",
        targets.select { |t| t[\kind] == \continuous }.every { |t|
            [0, 0.25, 0.5, 0.75, 1].every { |c| (t[\toPos].value(t[\fromPos].value(c)) - c).abs < 1e-6 } });
    ~tAssert.("with no looper the looper's controls are not there, so a stomp does nothing",
        (targets['looper.trigger'][\available].value == false) and: { targets['looper.onsetThreshold'][\available].value == false });
    ~tNear.("the threshold's law is the header slider's", targets['looper.onsetThreshold'][\fromPos].value(68 / 127),
        ~onsetThresholdSpec.map(68 / 127), 1e-12);
    ~tEq.("morph is set straight, as CC 118 always did", targets['looper.granularMorph'][\fromPos].value(0.3), 0.3);
    ~tNear.("the granular block goes through ~granularParams (Scan's squared law here)",
        targets['looper.granularScan'][\fromPos].value(0.75),
        ~granularMapValue.(~granularParams.detect { |p| p[\key] == \granularScan }, 0.75), 1e-12);
    ~tAssert.("SA's seven effects and its drums are among them",
        MegaSAFx.keys.every { |k| targets.includesKey(("sa.fxOn." ++ k).asSymbol) } and: { targets.includesKey('sa.drums.on') });
    ~tEq.("...and not there without SA", targets['sa.drums.on'][\available].value, false);
    ~rp = (sa: true, live: false);
    ~tEq.("Live's arrangement record is not offered on a rig without Live",
        ~midiTargetsBuild.().includesKey('live.record'), false);
} { ~looper = savedLooper; ~rp = savedRp };

// --------------------------------------------------- the map from numbers --
savedRp = ~rp;
old = [~granularCcBase, ~pedalCcHysteresis, ~stopNote, ~bbcutPrograms];
protect {
    ~rp = ~routingProfiles[\bhTsMega];
    m = h.new(~midiMapFromConstants.(), "test");
    ~tEq.("on a Live rig the numbers make 36 bindings, all of them usable", [m.bindings.size, m.problems.size], [36, 0]);
    ~tEq.("...PC 8 and 18 both switch the cutter", m.lookup(\program, 0, 8).collect { |s| s[\binding][\target] }
        ++ m.lookup(\program, 0, 18).collect { |s| s[\binding][\target] }, ['looper.bbcut', 'looper.bbcut']);
    ~tEq.("...on any channel and from any input", m.bindings.select { |x| x[\chan].notNil or: { x[\device].notNil } }, []);
    ~tEq.("...and the pedal's two CCs carry its hysteresis, no other",
        m.bindings.select { |x| (x[\hysteresis] ? 0) > 0 }.collect { |x| x[\num] }.sort, [~feedbackCc, ~onsetThresholdCc].sort);
    ~rp = ~routingProfiles[\sa];
    m = h.new(~midiMapFromConstants.(), "test");
    ~tEq.("on SA they make 43", [m.bindings.size, m.problems.size], [43, 0]);
    ~tEq.("...PC 8 is the delay, and only the delay", m.lookup(\program, 0, 8).collect { |s| s[\binding][\target] }, ['sa.fxOn.delay']);
    ~tEq.("...the cutter keeps 18", m.lookup(\program, 0, 18).collect { |s| s[\binding][\target] }, ['looper.bbcut']);
    ~tEq.("...and 17 is the drums'", m.lookup(\program, 0, 17).collect { |s| s[\binding][\target] }, ['sa.drums.on']);
    ~rp = ~routingProfiles[\bhTsMega];
    ~granularCcBase = 20;
    m = h.new(~midiMapFromConstants.(), "test");
    ~tEq.("the granular block follows ~granularCcBase, as it always did",
        m.lookup(\cc, 0, 20).collect { |s| s[\binding][\target] }, [("looper." ++ ~granularCcMap[0]).asSymbol]);
    ~granularCcBase = old[0];
    ~tEq.("~pedalCcHysteresis is taken as whole steps, 0 to 64 (1.5, -1, 100, 0, nil, a word)",
        [1.5, -1, 100, 0, nil, "two"].collect { |x|
            ~pedalCcHysteresis = x;
            h.new(~midiMapFromConstants.(), "test").lookup(\cc, 0, ~onsetThresholdCc).collect { |s| s[\binding][\hysteresis] } },
        [[1], [0], [64], [0], [1], [1]]);
    ~pedalCcHysteresis = old[1];
    // Two of the looper's notes on one number: the first one listed keeps it,
    // as the responders' `case` did.
    ~stopNote = ~triggerNote;
    ~bbcutPrograms = [8, 8, 18];
    m = h.new(~midiMapFromConstants.(), "test");
    ~tEq.("where two of the looper's notes share a number, the first listed keeps it, as before",
        m.lookup(\note, 0, ~triggerNote).collect { |s| s[\binding][\target] }, ['looper.trigger']);
    ~tEq.("...and a program listed twice is bound once, so one stomp is one flip",
        m.lookup(\program, 0, 8).size, 1);
    ~tEq.("...with nothing said about it in the map (check.scd says it)", m.problems.size, 0);
} {
    ~rp = savedRp;
    ~granularCcBase = old[0]; ~pedalCcHysteresis = old[1]; ~stopNote = old[2]; ~bbcutPrograms = old[3];
};

// -------------------------------------------------------- the responders --
// setup-midimap.scd's own responders, built and fed through their functions,
// and once through MIDIIn. Building them registers MIDIdefs, which would
// replace a running megalooper's: so this part runs only where no MIDI
// responder is registered, and frees what it made. In a headless run a
// registered one is a test that forgot to free it.
v = AbstractResponderFunc.allEnabled.keys.any { |k| k.asString.beginsWith("MIDI") };
case
{ v and: { Platform.ideName == "none" } } {
    ~tFail.("no MIDI responder is registered before the responders' tests, in a headless run",
        "an earlier test left one: " ++ AbstractResponderFunc.allEnabled.keys.asArray);
}
{ v } { ~tSkip.("the responders themselves", "MIDI responders run in this interpreter (a megalooper?)") }
{
    before = MIDIdef.all.keys;
    saved = [~looper, ~midiOut, ~midiLog, ~midiMonitorPush, ~liveRecordToggle, ~rp, ~iacSources,
        ~midiTargetsBuild, ~midiMap, ~midiTargets, ~midiUserRootOverride];
    // Never the real folder of yours: a scratch one, empty.
    ~midiUserRootOverride = ~tTempPath.("midimap-user");
    l = ~tLooper.();
    seen = IdentityDictionary.new;
    lines = List.new;
    sent = List.new;
    protect {
        ~looper = l;
        ~rp = ~routingProfiles[\bhTsMega];
        ~midiOut = ();
        [\noteOn, \noteOff, \control, \program, \bend, \touch, \polyTouch].do { |sel|
            ~midiOut.put(sel, { |self ... args| sent.add([sel] ++ args); self });
        };
        ~midiLog = false;
        ~midiMonitorPush = { |line| lines.add(line) };
        // An old megalooper's responder, as if this interpreter had run one.
        MIDIdef.cc(\looperOnsetThreshold, { |val| seen[\old] = true }, 7);
        built = ~tCheck.("the responders build with no MIDIClient", { ~setupMidiBindings.(LooperMidiMap(~midiMapFromConstants.(), "test")); true });
        fn = { |name| MIDIdef.all[name] !? { |x| x.func } };
        // A responder's function, called as MIDIIn calls it.
        feed = { |values, num, chan = 0, src = 1001|
            fn.(\midiInCc) !? { |f| values.do { |x| f.value(x, num, chan, src) } };
        };
        ctl = SimpleController(l);
        [\onsetThreshold, \feedback, \intensity].do { |k|
            seen.put(k, List.new);
            ctl.put(k, { |o, what, x| seen[k].add(x) });
        };
        if(built == true) {
            ~tEq.("one responder per message type, and the old ones are gone",
                MIDIdef.all.keys.reject { |k| before.includes(k) }.asArray.sort,
                [\midiInBend, \midiInCc, \midiInNoteOff, \midiInNoteOn, \midiInPolytouch, \midiInProgram, \midiInTouch]);
            MIDIIn.doControlAction(1001, 0, ~onsetThresholdCc, 100);
            ~tAssert.("a CC through MIDIIn reaches the router, and not the old responder",
                (seen[\onsetThreshold].size == 1) and: { seen[\old].isNil });
            seen[\onsetThreshold].clear;
            lines.clear; sent.clear;

            feed.(stream.("sa-resting"), ~onsetThresholdCc, 0, 1002);
            ~tEq.("CC 7 from the resting pedal sets the threshold once", seen[\onsetThreshold].size, 1);
            ~tNear.("...to the pedal's first value, through the slider's law",
                l.onsetThreshold, ~onsetThresholdSpec.map(68 / 127), 1e-6);
            l.onsetThreshold = 0.3;   // as the header slider sets it
            seen[\onsetThreshold].clear;
            feed.(stream.("sa-resting"), ~onsetThresholdCc, 0, 1002);
            ~tNear.("a threshold set with the header slider then stays through every hop",
                l.onsetThreshold, 0.3, 1e-9);
            ~tEq.("...with nothing set at all", seen[\onsetThreshold].size, 0);
            feed.([71], ~onsetThresholdCc, 0, 1002);
            ~tNear.("and the pedal moved takes it again", l.onsetThreshold,
                ~onsetThresholdSpec.map(71 / 127), 1e-6);
            seen[\onsetThreshold].clear;
            feed.(stream.("sa-played"), ~onsetThresholdCc, 0, 1003);
            ~tEq.("the played pedal sets the threshold once per move, flicker left out",
                seen[\onsetThreshold].size, replay.(stream.("sa-played"))[0].size);
            feed.(stream.("cc4-resting"), ~feedbackCc);
            ~tEq.("CC 4, the pedal's earlier number, sets the feedback once from rest", seen[\feedback].size, 1);
            // Since phase 4 every knob CC has one step of hysteresis unless
            // its binding says (decision 7): the flicker is left out of CC 11
            // too. With the default at none, every value goes through.
            feed.(flicker, ~intensityCc);
            ~tEq.("the other CCs leave the flicker out too, with the default hysteresis (CC 11 here)",
                seen[\intensity].size, replay.(flicker)[0].size);
            ~midiDefaults = (hysteresis: 0, takeover: \none);
            seen[\intensity].clear;
            feed.(flicker, ~intensityCc, 0, 1004);
            ~tEq.("...and with the default set to none they keep every value", seen[\intensity].size, flicker.size);
            ~midiDefaults = ~midiKnobDefaults.copy;
            ~tEq.("every message is logged, mapped or not", lines.size,
                (stream.("sa-resting").size * 2) + 1 + stream.("sa-played").size + stream.("cc4-resting").size
                    + (flicker.size * 2));
            ~tEq.("...and sent on to Live", sent.size, lines.size);
            // Our own output coming back from an IAC bus: acted on, never sent on.
            ~iacSources = [666];
            sent.clear;
            feed.([10, 90], ~intensityCc, 0, 666);
            ~tEq.("a CC from an IAC bus drives its control but is not sent on to Live, by the router's own proxy",
                [seen[\intensity].size, sent.size], [flicker.size + 2, 0]);
            ~iacSources = [];

            // A program change: the action, then Live, then the log line.
            old = ~midiTargets['looper.onsetNotes'];
            ~midiTargets['looper.onsetNotes'] = (id: 'looper.onsetNotes', kind: \toggle,
                flip: { lines.add("ACTION") });
            lines.clear; sent.clear;
            fn.(\midiInProgram).value(~onsetNotesProgram, 0, 1001);
            ~tEq.("a program change acts, then goes to Live, then is logged",
                lines.asArray, ["ACTION", "program  prog=" ++ ~onsetNotesProgram ++ " chan=0  → looper.onsetNotes"]);
            ~tEq.("...as itself and as the CC Live maps, on channel 16", sent.asArray,
                [[\program, 0, ~onsetNotesProgram], [\control, ~pcCcChannel, ~onsetNotesProgram, 127]]);
            sent.clear;
            fn.(\midiInProgram).value(~breakMacroCc, 0, 1001);
            ~tEq.("program 100 goes to Live as itself, but not as the CC the break's macro listens on",
                sent.asArray, [[\program, 0, ~breakMacroCc]]);
            // A part that throws can't stop the others.
            ~midiOut.put(\program, { |self| Error("the IAC bus fell over").throw });
            lines.clear;
            fn.(\midiInProgram).value(~onsetNotesProgram, 0, 1001);
            ~tEq.("when the proxy throws, the action still happens and the line is still logged",
                lines.asArray, ["ACTION", "program  prog=" ++ ~onsetNotesProgram ++ " chan=0  → looper.onsetNotes"]);
            ~tAssert.("...and it is said once", ~midiWarned.includes(\proxy));
            ~midiTargets['looper.onsetNotes'] = old;

            ~setupMidiBindings.(LooperMidiMap(~midiMapFromConstants.(), "test"));
            ~tEq.("re-run, it is still one responder per message type",
                MIDIdef.all.keys.reject { |k| before.includes(k) }.size, 7);
            // While MIDI runs, a rebuild keeps what the router kept of each
            // knob: one step on from the pedal's last 100, its hysteresis
            // holds it.
            seen[\onsetThreshold].clear;
            feed.([101], ~onsetThresholdCc);
            ~tEq.("...and what the router kept of the pedal goes on: one step on, its hysteresis holds it",
                seen[\onsetThreshold].size, 0);
            // After a Cmd-period, or in a boot (~setupMidiIO frees every
            // responder first), it saw nothing meanwhile: every knob starts
            // afresh.
            MIDIdef.all.keys.asArray.select { |k| k.asString.beginsWith("midiIn") }.do { |k| MIDIdef.all[k].free };
            ~setupMidiBindings.(LooperMidiMap(~midiMapFromConstants.(), "test"));
            seen[\onsetThreshold].clear;
            feed.([101], ~onsetThresholdCc);
            ~tEq.("...but after MIDI was dead, the pedal's hysteresis starts afresh: the first value counts again",
                seen[\onsetThreshold].size, 1);
            // Cmd-period itself: MIDI is dead from then on, and the Rig tab's
            // poll with it.
            ~midiSweepStart.(~midiMap.bindingsFor('looper.onsetThreshold')[0]);
            ~midiCmdPeriodHook.value;
            ~tEq.("Cmd-period forgets what the router kept of every knob, and ends a sweep, saying so",
                [~midiMap.slots.collect { |x| x[\states].size }.sum, ~midiSweep, ~midiLearnNote],
                [0, nil, "Range not changed: Cmd-period ended the sweep"]);
            v = ~pedalCcHysteresis;
            ~pedalCcHysteresis = 0;
            ~setupMidiBindings.(LooperMidiMap(~midiMapFromConstants.(), "test"));
            seen[\onsetThreshold].clear;
            feed.([68, 69, 68, 68], ~onsetThresholdCc);
            ~tEq.("with ~pedalCcHysteresis 0 every message sets the threshold, as before, repeats too",
                seen[\onsetThreshold].size, 4);
            ~pedalCcHysteresis = v;

            // A map that can't be made: the footswitches keep the one they had,
            // and at boot, with none, MIDI still goes to Live.
            ~setupMidiBindings.(LooperMidiMap(~midiMapFromConstants.(), "test"));
            old = ~midiMap;
            ~midiTargetsBuild = { Error("a control on fire").throw };
            ~tCheck.("a map that can't be made doesn't stop the boot", { ~setupMidiBindings.(LooperMidiMap(~midiMapFromConstants.(), "test")) });
            ~tAssert.("...the footswitches keep the map they had", ~midiMap === old);
            seen[\onsetThreshold].clear;
            feed.([30], ~onsetThresholdCc);
            ~tEq.("...and it still acts", seen[\onsetThreshold].size, 1);
            ~midiMap = nil;
            ~midiTargets = nil;
            sent.clear;
            seen[\onsetThreshold].clear;
            ~tCheck.("with no map before it either", { ~setupMidiBindings.(LooperMidiMap(~midiMapFromConstants.(), "test")) });
            feed.([40], ~onsetThresholdCc);
            ~tEq.("...the footswitches do nothing, and Live still gets every message",
                [seen[\onsetThreshold].size, sent.size], [0, 1]);
        };
    } {
        ctl !? { |c| c.remove };
        MIDIdef.all.keys.reject { |k| before.includes(k) }.do { |k| MIDIdef.all[k] !? { |x| x.free } };
        ~looper = saved[0]; ~midiOut = saved[1]; ~midiLog = saved[2]; ~midiMonitorPush = saved[3];
        ~liveRecordToggle = saved[4]; ~rp = saved[5]; ~iacSources = saved[6];
        ~midiTargetsBuild = saved[7]; ~midiMap = saved[8]; ~midiTargets = saved[9];
        ~tRemoveTree.(~midiUserRootOverride);
        ~midiUserRootOverride = saved[10];
    };
    ~tAssert.("and the responders it made are gone again",
        MIDIdef.all.keys.reject { |k| before.includes(k) }.isEmpty);
};

}.value;
