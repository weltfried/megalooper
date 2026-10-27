// An effect's Random (MegaSA.randomizeFx, MegaSAFx.randomValue): every
// setting of the device at a random value inside its range, on its step, one
// of its choices for a setting picked from a list, drawn along the knob's own
// curve; the levels an effect ends on (MegaSAFx.randomKeeps) and the switch
// left as they are; announced as any setting is, so the knobs follow; one
// device only; nothing for a plugin, nil for no device. Reset brings the
// starting values back.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-megasa-random");

{
var stub, sa, d, said, heard, inRange, before, others, keeps, p, draws, low;

heard = { |obj, fn|
    var got = List.new, f = { |o, what ... more| got.add([what] ++ more) };
    obj.addDependant(f);
    protect { fn.value } { obj.removeDependant(f) };
    got.asArray
};
// A value a setting can hold: one of its choices, or inside its range on its step.
inRange = { |q, v|
    if(q[\choices].notNil) { q[\choices].any { |c| c[0] == v } } {
        v.isNumber and: { v >= (q[\spec].clipLo - 1e-9) } and: { v <= (q[\spec].clipHi + 1e-9) }
            and: { (q[\spec].step == 0) or: { ((v / q[\spec].step) - (v / q[\spec].step).round).abs < 1e-6 } }
    }
};

// ---- the draw, setting by setting -------------------------------------------------
thisThread.randSeed = 4711;
~tEq.("every setting's draws are values it can hold, 50 each",
    MegaSAFx.params.reject { |q| 50.collect { MegaSAFx.randomValue(q) }.every { |v| inRange.(q, v) } }.collect { |q| q[\name] }, []);
p = MegaSAFx.param(\filterLfoWave);
draws = 400.collect { MegaSAFx.randomValue(p) };
~tEq.("a setting picked from a list draws every one of its choices", draws.asSet.size, p[\choices].size);
p = MegaSAFx.param(\filterFreq);
draws = 1000.collect { MegaSAFx.randomValue(p) };
low = draws.count { |v| v < p[\spec].map(0.5) } / draws.size;
~tAssert.("an exponential knob is drawn along its curve: about half the draws below its middle (" ++ p[\spec].map(0.5).round(1) ++ " Hz)",
    (low > 0.42) and: { low < 0.58 }, low.asString);
~tEq.("the levels an effect ends on are left alone, and each is a setting",
    MegaSAFx.randomKeeps.reject { |k| MegaSAFx.param(k).notNil }, []);

// ---- on a device ------------------------------------------------------------------
stub = ~tStubServer.();
sa = ~tMegaSA.(stub);
d = sa.device(\filter);
before = d.settings.copy;
others = sa.devices.reject { |x| x === d }.collect { |x| [x.id, x.settings.copy, x.on] };
keeps = MegaSAFx.randomKeeps.select { |k| d.settings.includesKey(k) };
said = heard.(sa, { ~tAssert.("randomizeFx answers the device", sa.randomizeFx(\filter) === d) });
~tAssert.("its settings are drawn: most of them move", d.params.count { |q| d.param(q[\name]) != before[q[\name]] } >= (d.params.size - keeps.size - 3),
    d.settings.asString);
~tEq.("...each to a value it can hold", d.params.reject { |q| inRange.(q, d.param(q[\name])) }.collect { |q| q[\name] }, []);
~tEq.("...but its levels, which stay where they were", keeps.collect { |k| d.param(k) }, keeps.collect { |k| before[k] });
~tEq.("...and its switch", d.on, false);
~tAssert.("...each change said as \\fxParam, so the knobs follow",
    said.count { |x| x[0] == \fxParam } == d.params.count { |q| keeps.includes(q[\name]).not }, said.asString);
~tEq.("no other device moves", sa.devices.reject { |x| x === d }.collect { |x| [x.id, x.settings.copy, x.on] }, others);
sa.resetFx(\filter);
~tAssert.("Reset puts the starting values back", sa.fxEdited(\filter).not);
~tEq.("no such device: nil, and nothing moves", [sa.randomizeFx(\nothing), sa.devices.collect { |x| x.settings.copy }],
    [nil, sa.devices.collect { |x| x.settings.copy }]);
d = sa.insertDevice(\guitar, nil, \saturator);
before = d.settings.copy;
sa.randomizeFx(d.id);
~tAssert.("a further device draws its own, by its id", d.edited and: { sa.device(\saturator).edited.not });

// ---- taken back (undoRandomFx) -----------------------------------------------------
sa.free;
sa = ~tMegaSA.(~tStubServer.());
d = sa.device(\filter);
sa.setParam(\filter, \filterFreq, 800);
before = d.settings.copy;
~tEq.("nothing to take back before a Random", [sa.randomBackCount(\filter), sa.undoRandomFx(\filter)], [0, nil]);
said = heard.(sa, { sa.randomizeFx(\filter) });
p = d.settings.copy;
~tEq.("a Random can be taken back, and says so", [sa.randomBackCount(\filter), said.select { |x| x[0] == \fxRandom }],
    [1, [[\fxRandom, \filter, 1]]]);
sa.randomizeFx(\filter);
sa.setParam(\filter, \filterRes, 0.123);
~tEq.("two draws and a knob moved since: the first undo puts the settings before the second draw back",
    [sa.undoRandomFx(\filter) === d, d.settings == p, sa.randomBackCount(\filter)], [true, true, 1]);
said = heard.(sa, { sa.undoRandomFx(\filter) });
~tEq.("...the second those before the first: the 800 Hz set by hand", [d.settings == before, d.param(\filterFreq)], [true, 800]);
~tAssert.("...each change said, so the knobs follow", said.any { |x| x[0] == \fxParam } and: { said.last == [\fxRandom, \filter, 0] },
    said.asString);
~tEq.("...and then nothing more", sa.undoRandomFx(\filter), nil);
20.do { sa.randomizeFx(\filter) };
~tEq.("it goes back 16 draws at most", sa.randomBackCount(\filter), MegaSA.randomBackMax);
d = sa.insertDevice(\guitar, nil, \saturator);
sa.randomizeFx(d.id);
sa.removeDevice(d.id);
~tEq.("a device removed has none to take back", [d.id, sa.randomBackCount(d.id)], [\saturator2, 0]);
sa.free;
}.value;
