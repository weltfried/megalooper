// The command layer (setup-miditargets.scd, ~controlDo and ~controlApply):
// every input drives a control the same way. First its verbs, on controls
// made here, one of each kind: what \press means for each, \set, \position
// (on the whole travel and narrowed by a MIDI binding's range), \next, a
// control not there now, one that does not exist, and the source it keeps
// while a control acts, put back even when the control throws. Then the keys
// (~controlKeys): each presses the control its letter always pressed, on the
// real registry, making exactly the call it made before the table, and the
// words built from the table (a tile's key letter, the boot's line). No
// server, no window, no MIDI.
//
// docs/dev/architecture.md, 5, step 1.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-controls");

{
var dir = thisProcess.nowExecutingPath.dirname;
var scripts = dir.dirname;
var saved, log, state, fake, sourceSeen, got, threw, looper, calls, fillLooper, press;
var real, chars, ids;

if(~routingProfiles.isNil) { (scripts +/+ "setup-routing.scd").load };
if(~saGuitarBank.isNil) { (scripts +/+ "setup-sa.scd").load };
(scripts +/+ "setup-miditargets.scd").load;
if(~midiApply.isNil) { (scripts +/+ "setup-midimap.scd").load };
if(~onsetThresholdSpec.isNil) { (scripts +/+ "gui-const.scd").load };
if(~guiKeyDown.isNil) { (scripts +/+ "gui-shell.scd").load };

saved = [~midiTargets, ~looper, ~megaSA, ~controlSource, ~rp];

// ---- The verbs, on controls made here ---------------------------------------------
log = List.new;
state = IdentityDictionary[\tog -> false, \choice -> 0, \level -> 2, \step -> 3];
fake = IdentityDictionary.new;
fake.put('x.trig', (kind: \trigger, fire: { log.add(\fired); sourceSeen = ~controlSource; 42 }));
fake.put('x.tog', (kind: \toggle, flip: { log.add(\flipped); state[\tog] = state[\tog].not },
    get: { state[\tog] }, set: { |v| log.add([\set, v]); state[\tog] = v }));
fake.put('x.togset', (kind: \toggle, get: { state[\tog] }, set: { |v| log.add([\set, v]); state[\tog] = v }));
fake.put('x.choice', (kind: \choice, items: ["a", "b", "c"],
    get: { state[\choice] }, set: { |i| log.add([\choice, i]); state[\choice] = i }));
fake.put('x.level', (kind: \continuous, fromPos: { |c| c * 10 }, toPos: { |v| v / 10 },
    get: { state[\level] }, set: { |v| log.add([\level, v]); state[\level] = v }));
fake.put('x.step', (kind: \step, fromPos: { |c| c * 8 }, toPos: { |v| v / 8 },
    get: { state[\step] }, set: { |v| log.add([\step, v]); state[\step] = v }));
fake.put('x.gone', (kind: \trigger, fire: { log.add(\goneFired) }, available: { false }));
fake.put('x.there', (kind: \trigger, fire: { log.add(\thereFired) }, available: { true }));
fake.put('x.throws', (kind: \trigger, fire: { sourceSeen = ~controlSource; Error("on purpose").throw }));
~midiTargets = fake;
~controlSource = nil;

got = ~controlDo.('x.trig', \press, nil, \gui);
~tEq.("a trigger pressed fires once", log.asArray, [\fired]);
~tEq.("…and answers what its action answered", got, 42);
~tEq.("…with its source kept while it acts", sourceSeen, \gui);
~tEq.("…and let go afterwards", ~controlSource, nil);

log.clear;
~controlDo.('x.tog', \press, nil, \key);
~tEq.("a switch pressed flips through its own flip", log.asArray, [\flipped]);
log.clear; state[\tog] = false;
~controlDo.('x.togset', \press, nil, \key);
~tEq.("a switch with no flip of its own is set to the other state", log.asArray, [[\set, true]]);
log.clear;
~controlDo.('x.tog', \set, true);
~tEq.("a switch set where it is already is left alone", log.asArray, [[\set, true]]);

log.clear; state[\choice] = 0;
~controlDo.('x.choice');
~tEq.("a choice pressed (the default verb) steps on", log.asArray, [[\choice, 1]]);
log.clear; state[\choice] = 2;
~controlDo.('x.choice', \press);
~tEq.("…round from its last item to its first", log.asArray, [[\choice, 0]]);
log.clear;
~controlDo.('x.choice', \position, 0.9);
~tEq.("a choice at a position takes the item there", log.asArray, [[\choice, 2]]);
log.clear; state[\choice] = 1;
~controlDo.('x.choice', \next);
~tEq.("a choice's next", log.asArray, [[\choice, 2]]);

log.clear; state[\level] = 2;
~controlDo.('x.level', \press);
~tEq.("a level pressed goes to the end further from where it is (the top)", log.asArray, [[\level, 10]]);
log.clear; state[\level] = 8;
~controlDo.('x.level', \press);
~tEq.("…or the bottom", log.asArray, [[\level, 0]]);
log.clear;
~controlDo.('x.level', \set, 3.5);
~tEq.("a level set takes the value in its own units", log.asArray, [[\level, 3.5]]);
log.clear;
~controlDo.('x.level', \position, 0.25);
~tEq.("a level at a position goes along its law", log.asArray, [[\level, 2.5]]);
log.clear;
~controlDo.('x.step', \position, 0.3);
~tEq.("a count at a position is rounded to a whole step", log.asArray, [[\step, 2]]);
~tAssert.("…as an Integer", log.first[1].isKindOf(Integer));

log.clear;
got = ~controlDo.('x.gone', \press);
~tEq.("a control not there now does nothing", log.asArray, []);
~tEq.("…and answers nil", got, nil);
~controlDo.('x.there', \press);
~tEq.("one that is there acts", log.asArray, [\thereFired]);

got = ~controlDo.('x.nothing', \press, nil, \gui);
~tEq.("a control that does not exist answers nil", got, nil);
~tAssert.("…and is said once", ~controlWarned.includes('x.nothing'));

~controlSource = \before;
threw = try { ~controlDo.('x.throws', \press, nil, \ai); false } { |err| err.errorString.contains("on purpose") };
~tAssert.("a control that throws throws on to the caller", threw == true);
~tEq.("…with its source kept while it acted", sourceSeen, \ai);
~tEq.("…and the source before it put back", ~controlSource, \before);
~controlSource = nil;

// MIDI's way in: the same verbs, its source \midi, a binding's range.
sourceSeen = nil;
~midiApply.(fake['x.trig'], [\fire], (msg: \note));
~tEq.("MIDI fires through the same verbs, its source \\midi", sourceSeen, \midi);
log.clear;
~midiApply.(fake['x.level'], [\position, 0.5], (msg: \cc, min: 2, max: 6));
~tEq.("…and a binding's range narrows a position (halfway from 2 to 6)", log.asArray, [[\level, 4]]);
log.clear; state[\level] = 3;
~midiApply.(fake['x.level'], [\flip], (msg: \note, min: 2, max: 6));
~tEq.("…and its ends", log.asArray, [[\level, 6]]);
log.clear; state[\choice] = 0;
~midiApply.(fake['x.choice'], [\flip], (msg: \note));
~tEq.("…and a note on a choice steps it on", log.asArray, [[\choice, 1]]);

// One family made again with no registry yet makes every family: alone, it
// would be all a control could find.
~midiTargets = nil; ~looper = nil; ~megaSA = nil;
~rp = ~routingProfiles[~defaultRoutingProfile];
~midiTargetsRefresh.(\drumPresets);
~tAssert.("a family made again with no registry yet makes every family",
    ~midiTargets.notNil and: { ~midiTargets['looper.trigger'].notNil }, (~midiTargets ? ()).keys.asArray.keep(5));

// The registry built when nothing has built it yet.
~midiTargets = nil; ~looper = nil; ~megaSA = nil;
~rp = ~routingProfiles[~defaultRoutingProfile];
got = ~controlDo.('looper.trigger', \press, nil, \gui);
~tAssert.("a control driven before the boot's registry gets the registry built", ~midiTargets.notNil);
~tEq.("…and with no looper its trigger does nothing", got, nil);

// ---- The keys -------------------------------------------------------------------------
// The looper as a stub that writes down every call (an Event: it answers any
// message by key). An Event's own `clear` can't be taken over: the looper's
// clear is seen by what it does to the stub, which it empties.
calls = List.new;
looper = ();
fillLooper = {
    [\trigger, \stopPlayback, \multiply, \undo, \reverse, \toggleHalfTime, \toggleGranular, \fireBreak,
        \toggleDissolve, \recordNextLoop, \nextReading].do { |sel|
        looper.put(sel, { |self ... args| calls.add(sel); self });
    };
    looper.put(\bbcut, { |self| false });
    looper.put(\bbcut_, { |self, v| calls.add([\bbcut_, v]); self });
};
fillLooper.value;
~looper = looper;
~midiTargets = ~midiTargetsBuild.();
real = ~midiTargets;
press = { |char, mods = 0|
    var r;
    calls.clear;
    r = ~guiKeyDown.(char, mods, 0);
    if(looper.isEmpty) { calls.add(\clear); fillLooper.value };
    r
};
// What each letter did before the table (gui-shell.scd at 74ab307).
[
    [$r, [\trigger]], [$s, [\stopPlayback]], [$m, [\multiply]], [$u, [\undo]], [$v, [\reverse]],
    [$l, [\toggleHalfTime]], [$g, [\toggleGranular]], [$b, [[\bbcut_, true]]], [$k, [\fireBreak]],
    [$d, [\toggleDissolve]], [$c, [\clear]], [$n, [\recordNextLoop]], [$a, [\nextReading]]
].do { |k|
    got = press.(k[0]);
    ~tEq.("key " ++ k[0] ++ " makes the call it made before", calls.asArray, k[1]);
    ~tAssert.("…and answers something, as a handled key did", got.notNil);
};
press.($r, 1048576);
~tEq.("a letter with Cmd held presses nothing", calls.asArray, []);
press.($R);
~tEq.("…nor a capital", calls.asArray, []);
press.($x);
~tEq.("…nor a letter no control has", calls.asArray, []);
~looper = nil;
got = try { ~guiKeyDown.($r, 0, 0) } { \threw };
~tEq.("with no looper a key does nothing, without throwing", got, nil);
~looper = looper;

chars = ~controlKeys.collect(_[0]);
ids = ~controlKeys.collect(_[1]);
~tEq.("no key twice", chars.asSet.size, chars.size);
~tEq.("no control on two keys", ids.asSet.size, ids.size);
~tAssert.("every key a lower-case letter", chars.every { |c| c.isAlpha and: { c.isLower } });
~tAssert.("none of the window's own keys (T, H, E)", chars.includesAny([$t, $h, $e]).not);
~tAssert.("every key's control is in the registry",
    ids.every { |id| real[id].notNil }, ids.reject { |id| real[id].notNil });
~tAssert.("…and is one a press means something to (a trigger or a switch)",
    ids.every { |id| [\trigger, \toggle].includes(real[id][\kind]) });

~tEq.("a tile's key letter comes from the table", ~controlKeyFor.('looper.trigger'), "R");
~tEq.("…half-time's is L", ~controlKeyFor.('looper.halfTime'), "L");
~tEq.("…and a control with no key has none", ~controlKeyFor.('sa.drums.on'), nil);
~tAssert.("the boot's line names every key by its control's label",
    ~controlKeysLine.().contains("R Trigger") and: { ~controlKeysLine.().contains("L Half-time") },
    ~controlKeysLine.());

// ---- The registry follows the models ---------------------------------------------
// The controls made from what the models hold (SA's chains' devices, the
// kits' pads) are made again when that changes, by the control layer itself
// (setup-midimap.scd, ~midiTargetsFollow): no pane needs to be up. Made again
// here means ~midiTargetsRefresh asked, by family.
{
    var asked = List.new, refreshWas = ~midiTargetsRefresh, sa = (), d = (), mine;
    sa[\drums] = d;
    ~midiTargetsRefresh = { |family| asked.add(family) };
    ~midiTargetsStale = nil;
    ~megaSA = sa;
    ~midiTargetsFollow.();
    sa.changed(\chain, \guitar, \insert, \delay2, 1);
    ~tEq.("a chain edit marks the effects' controls to be made again", ~midiTargetsStale.asArray, [\effects]);
    sa.changed(\chain, \guitar, \move, \delay2, 0);
    ~midiTargetsFlush.();
    ~tEq.("…and a burst of edits has them made again once", asked.asArray, [\effects]);
    ~tEq.("…and nothing is marked after", ~midiTargetsStale, nil);
    asked.clear;
    sa.changed(\level, \guitar, 0.5);
    ~midiTargetsFlush.();
    ~tEq.("another notification marks nothing", asked.asArray, []);
    d.changed(\kitState, \steps, \loading);
    ~tEq.("a kit still loading marks nothing", ~midiTargetsStale, nil);
    d.changed(\kitState, \steps, \ready);
    ~midiTargetsFlush.();
    ~tEq.("a kit that settled has every control made again (its pads' trims)", asked.asArray, [nil]);
    asked.clear;
    ~midiTargetsFlush.(\effects);
    ~tEq.("a pane's flush makes its family again even with nothing marked", asked.asArray, [\effects]);
    asked.clear;
    mine = sa.dependants.size;
    ~midiTargetsFollow.();
    ~tEq.("following again lets go of what it followed before", sa.dependants.size, mine);
    sa.changed(\chain, \loop, \remove, \echo, 0);
    ~midiTargetsFlush.();
    ~tEq.("…so an edit is not marked twice", asked.asArray, [\effects]);
    ~megaSA = nil;
    ~midiTargetsFollow.();
    ~tEq.("with no SA it follows nothing, and lets go of the old one", sa.dependants.size, mine - 1);
    ~midiTargetsRefresh = refreshWas;
    ~midiTargetsStale = nil;
}.value;

~midiTargets = saved[0]; ~looper = saved[1]; ~megaSA = saved[2]; ~controlSource = saved[3]; ~rp = saved[4];
}.value;
