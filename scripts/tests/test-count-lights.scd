// The count's lights (gui-status.scd, ~countLightStep): Perform's count on a
// controller's button lights, sent on the beat. What a light is to the map
// and to learning (LooperMidiMap, LooperMidiLearn), the three controls
// (setup-miditargets.scd), and the clock's step on the server-free fixture,
// the poll's answer put in by hand, the controller an Event that writes down
// what it is sent.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-count-lights");

{
var scripts = thisProcess.nowExecutingPath.dirname.dirname;
var h = LooperMidiMap;
var keys, saved, l, learn, out, sent, open, step, sends, settings, now, r78, uneven, b;

if(~setupMidiIO.isNil) { (scripts +/+ "setup-midi.scd").load };
if(~midiTargetsBuild.isNil) { (scripts +/+ "setup-miditargets.scd").load };
if(~midiRouteWith.isNil) { (scripts +/+ "setup-midimap.scd").load };
if(~countLightStep.isNil) { (scripts +/+ "gui-status.scd").load };

// ---- what a light is to the map ---------------------------------------------------
b = (msg: \note, num: 64, chan: 0);
~tEq.("a light: nothing its button sends acts, a press, a release, a CC, a program change",
    [h.decide(\light, b, \noteOn, 127, nil)[0], h.decide(\light, b, \noteOff, 0, nil)[0],
        h.decide(\light, (msg: \cc, num: 40, switch: \pressRelease), \cc, 127, nil)[0],
        h.decide(\light, (msg: \program, num: 3), \program, 3, nil)[0]], [nil, nil, nil, nil]);
~tEq.("...it is sent back as a light, on a note or a CC of any switch; on a program change or pitch bend, nothing",
    [h.backKind(b, \light), h.backKind((msg: \cc, num: 40), \light), h.backKind((msg: \cc, num: 40, switch: \oneMessage), \light),
        h.backKind((msg: \program, num: 3), \light), h.backKind((msg: \bend), \light)], [\light, \light, \light, nil, nil]);
~tEq.("...127 lit, 0 dark", [true, false, nil].collect { |v| h.backValue(b, \light, v) }, [127, 0, nil]);

// ---- learning one --------------------------------------------------------------------
learn = LooperMidiLearn('count.beatLight', \light, 10);
learn.feed(\noteOn, 0, 64, 127, 1002, nil, nil, 10.1);
out = learn.tick(10.2);
~tEq.("a light learns a note at once", out !? { |o| [o[\msg], o[\num], o[\chan]] }, [\note, 64, 0]);
learn = LooperMidiLearn('count.beatLight', \light, 10);
learn.feed(\program, 0, 3, nil, 1002, nil, nil, 10.1);
out = learn.tick(10.2);
~tEq.("...but not a program change: it lights nothing", [out.notNil and: { out[\refused].notNil }, learn.refusals.size > 0],
    [false, true]);
learn = LooperMidiLearn('count.beatLight', \light, 10);
learn.feed(\cc, 0, 40, 127, 1002, 0, 9, 10.1);
~tEq.("...a CC button is counted, as a toggle's: one press is not yet learned", learn.tick(10.2), nil);

// ---- the three controls ----------------------------------------------------------------
{ |t|
    ~tEq.("the count's lights: three controls on Perform, lights all",
        [t.keys.asArray.sort, t.values.collect { |x| [x[\kind], x[\path], x[\group]] }.asSet.asArray],
        [['count.beatLight', 'count.countInLight', 'count.oddBarLight'], [[\light, "Perform", "Count lights"]]]);
    ~countLights = (beatLight: true, countInLight: false, oddBarLight: false);
    ~tEq.("...each says what its light shows", [t['count.beatLight'][\get].value, t['count.countInLight'][\get].value,
        t['count.beatLight'][\format].value(true)], [true, false, "lit"]);
}.value(~midiTargetsBuild.(\count).select { |x, id| id.asString.beginsWith("count.") });

// ---- the clock's step ------------------------------------------------------------------
keys = [\looper, \countAnchor, \countDelay, \countLightDelay, \countLights, \countLightEdge, \countLightOff,
    \midiMap, \midiTargets, \midiSources, \midiDestinations, \midiBackOpen, \midiBackClock, \midiNow,
    \midiBackSrcs, \midiBackTo, \midiBackOuts, \midiBackSent, \midiBackFor, \midiBackStale, \midiLearning,
    \midiBackOwners, \midiBackBySlot, \midiBackFree, \midiBackLastSent, \midiChanged, \midiUserRootOverride,
    \midiSettings, \midiWriteSync, \midiWarned];
saved = keys.collect { |k| currentEnvironment.at(k) };
protect {
    ~midiUserRootOverride = ~tTempPath.("count-lights-user");
    ~midiWriteSync = true;
    ~midiSettings = nil;
    now = 100.0;
    sent = List.new;
    open = { |uid|
        var o = (uid: uid);
        [\control, \noteOn, \noteOff].do { |sel| o.put(sel, { |self ... args| sent.add([sel] ++ args); self }) };
        o
    };
    ~midiTargets = ~midiTargetsBuild.(\count);
    ~midiMap = h.new([
        (msg: \note, num: 64, chan: 0, device: "UC4", target: 'count.beatLight'),
        (msg: \cc, num: 40, chan: 0, device: "UC4", target: 'count.countInLight', switch: \pressRelease),
        (msg: \note, num: 65, chan: 0, device: "UC4", target: 'count.oddBarLight')
    ], "lights");
    ~midiSources = IdentityDictionary[1002 -> ["UC4", "UC4"]];
    ~midiDestinations = IdentityDictionary[2002 -> ["UC4", "UC4"]];
    ~midiBackOpen = open;
    ~midiBackClock = { };
    ~midiChanged = { };
    ~midiNow = { now };
    ~midiLearning = nil;
    ~midiWarned = IdentitySet.new;
    ~midiBackOuts = IdentityDictionary.new; ~midiBackSent = Dictionary.new; ~midiBackFor = nil;
    ~midiBackLastSent = Dictionary.new; ~midiBackFree = IdentityDictionary.new;
    settings = (sendBack: Dictionary["UC4" -> true]);
    ~midiBackFrom.(settings);
    ~countLights = (beatLight: false, countInLight: false, oddBarLight: false);
    ~countLightEdge = nil;
    ~countLightOff = nil;
    ~countLightDelay = 0;
    // 7/8, two bars, an eighth 0.25 s; the poll answered phase 0 at 100.
    r78 = (numerator: 7, denominator: 8, tau: 0.25, sub: 1, k: 2, loopDur: 3.5, bpm: 120, n: 14, phase: 0);
    l = ~tLooper.();
    ~tPut.(l, \state, \playing);
    ~tPut.(l, \loopFrames, (3.5 * 48000).asInteger);
    ~tPut.(l, \lastResult, r78);
    ~looper = l;
    ~countAnchor = (phase: 0, at: 100.0, dur: 3.5);
    step = { |t| now = t; ~countLightStep.(t) };
    sends = { var a = sent.asArray; sent.clear; a };

    ~tEq.("sent back to the UC4: the clock works the lights out", ~countLightsBound.(), true);
    out = step.(100.001);
    ~tEq.("bar 1's first beat: the beat light, the long flash", sends.(), [[\noteOn, 0, 64, 127]]);
    ~tNear.("...the clock looks again a tenth on at most", out, 0.1, 1e-9);
    step.(100.2);
    ~tEq.("...still lit 0.2 s on: nothing sent", sends.(), []);
    step.(100.251);
    ~tEq.("...dark at the next beat line", sends.(), [[\noteOff, 0, 64, 0]]);
    out = step.(100.501);
    ~tEq.("group 2's first beat: a short flash", sends.(), [[\noteOn, 0, 64, 127]]);
    ~tNear.("...the clock looks again at its end", out, 0.1, 0.002);
    step.(100.503);
    ~tEq.("...the same beat line again: no second flash", sends.(), []);
    step.(100.602);
    ~tEq.("...dark after a tenth", sends.(), [[\noteOff, 0, 64, 0]]);
    step.(101.06);
    ~tEq.("a step 60 ms late for group 3's first beat: no flash, as it would say the beat was later", sends.(), []);

    // The next loop armed: its boundary 103.5, counted from loopStartTime.
    ~tPut.(l, \loopStartTime, 100.0);
    ~tPut.(l, \nextRecState, \armed);
    step.(101.6);
    ~tEq.("armed, still bar 1: no count-in light", sends.(), []);
    step.(101.751);
    ~tEq.("bar 2, the last before the boundary: the count-in light, and the bar's beat flash",
        sends.().asSet, [[\control, 0, 40, 127], [\noteOn, 0, 64, 127]].asSet);
    step.(102.01);
    sends.();
    ~tPut.(l, \nextRecState, \recording);
    step.(103.501);
    ~tEq.("past the boundary, recording: the count-in light goes out, and the loop's first beat flashes",
        sends.().asSet, [[\control, 0, 40, 0], [\noteOn, 0, 64, 127]].asSet);
    ~tPut.(l, \nextRecState, \idle);

    // 7+7+7+8: the odd bar light through the third bar.
    uneven = MeterAnalyzer.readingOfBars(29 * 0.25, [7, 7, 7, 8], 8);
    ~tPut.(l, \lastResult, uneven);
    ~tPut.(l, \loopFrames, (29 * 0.25 * 48000).asInteger);
    ~countAnchor = (phase: 0, at: 110.0, dur: 29 * 0.25);
    ~countLightOff = nil;
    step.(110.3);
    sends.();
    step.(110.0 + (14 * 0.25) + 0.001);
    ~tEq.("7+7+7+8, bar 3: the odd bar light (and the bar's flash)", sends.().asSet,
        [[\noteOn, 0, 65, 127], [\noteOn, 0, 64, 127]].asSet);
    step.(110.0 + (14 * 0.25) + 0.3);
    sends.();
    step.(110.0 + (21 * 0.25) + 0.001);
    ~tEq.("...out in the odd bar itself (and its flash)", sends.().asSet,
        [[\noteOff, 0, 65, 0], [\noteOn, 0, 64, 127]].asSet);

    // Nothing to count: what is lit goes dark.
    ~tPut.(l, \state, \stopped);
    step.(110.0 + (21 * 0.25) + 0.05);
    ~tEq.("the loop stopped: the lit beat light goes dark", sends.(), [[\noteOff, 0, 64, 0]]);
    ~tPut.(l, \state, \playing);

    // Not sent back to: the clock only waits.
    ~midiBackFrom.((sendBack: Dictionary["UC4" -> false]));
    ~tEq.("not sent back to: no lights to work out, the clock looks again in a quarter second",
        [~countLightsBound.(), step.(121.0), sends.()], [false, 0.25, []]);

    // A delay: the lights wait for the beat to be heard.
    ~midiBackFrom.(settings);
    ~countAnchor = (phase: 0, at: 130.0, dur: 29 * 0.25);
    ~countLights = (beatLight: false, countInLight: false, oddBarLight: false);
    ~countLightOff = nil;
    ~countLightEdge = nil;
    ~countLightDelay = 0.025;
    step.(130.024);
    ~tEq.("with the light delay 25 ms, the loop's first beat is not lit 24 ms after the engine plays it",
        sends.(), []);
    step.(130.026);
    ~tEq.("...but at 26 ms, as it is heard", sends.(), [[\noteOn, 0, 64, 127]]);
} {
    ~tRemoveTree.(~midiUserRootOverride);
    keys.do { |k, i| currentEnvironment.put(k, saved[i]) };
};
}.value;
