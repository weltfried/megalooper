// The dissolve into dust (docs/dev/microsound.md, roadmap item 23 idea 1):
// what reaches each part as the ending runs. The curves themselves are
// test-arc's; the grains' sound is scripts/sa/nrt-grains.scd's and
// nrt-grain-clock.scd's. Here: the grains are sent their dust with their
// level, a stop is said with the axis's return, MegaSA's strips follow (and
// hold after the stop), and the onset notes sent to Live thin.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-dissolve");
~tDissolveRoot = thisProcess.nowExecutingPath.dirname.dirname.dirname;

// ---- the grains --------------------------------------------------------------
{
    var l = ~tLooper.(), g = ~tStubSynth.(l, \looperGranular);
    ~tPut.(l, \state, \playing);
    ~tPut.(l, \granularSynth, g);
    l.granularAmp = 0.5;
    [0, 0.5, 0.75, 0.9, 1].do { |d|
        ~tPut.(l, \dissolvePos, d);
        l.prApplyMixes;
        ~tEq.("at " ++ d ++ " the grains are sent their dust with their level",
            [~tLastSet.(l, g, \dust), ~tLastSet.(l, g, \amp)], [l.prGrainDust, 0.5 * l.prGranularMix]);
    };
    ~tPut.(l, \dissolvePos, 0.75);
    ~tEq.("...and a synth started mid-dissolve (an engine change, a respawn) starts with it",
        ().putPairs(l.grainsPart.args)[\dust], 0.5);
    ~tPut.(l, \dissolvePos, 0);
    ~tEq.("...none when no dissolve runs", ().putPairs(l.grainsPart.args)[\dust], 0);
}.value;

// ---- the stop is said ----------------------------------------------------------
{
    var l = ~tLooper.(), said = List.new, f = { |o, what ... more| if(what == \dissolvePos) { said.add(more) } };
    ~tPut.(l, \state, \playing);
    l.addDependant(f);
    ~tPut.(l, \dissolvePos, 0.7);
    l.cancelDissolve;
    ~tEq.("an abort brings the axis home and says nothing more", said.asArray, [[0, nil]]);
    said.clear;
    ~tPut.(l, \dissolvePos, 0.7);
    l.stopPlayback;
    ~tEq.("a stop on the way, or the dissolve's own end, says so with it", said.asArray, [[0, \stop]]);
    said.clear;
    ~tPut.(l, \state, \playing);
    l.stopPlayback;
    ~tEq.("...and a stop with no dissolve says nothing", said.asArray, []);
    l.removeDependant(f);
}.value;

// ---- MegaSA's strips ----------------------------------------------------------
{
    var stub = ~tStubServer.(), sa, l, arcOf, all, step;
    MegaSA.loadSynthDefs;
    sa = ~tMegaSA.(stub);
    Synth.tail(stub[\defaultGroup], \looperMaster);
    l = ~tLooper.();
    Routine { sa.attachLooper(l) }.next;
    // What strip `key` was last told its arc was (its start's, or 1).
    arcOf = { |key|
        var id = sa.strips[key].nodeID, found;
        (stub[\writes] ?? { stub[\msgs].collect { |m| [0, m] } }).do { |w|
            var m = w[1];
            if((m[0] == 15) and: { m[1] == id }) { m.copyToEnd(2).pairsDo { |k, v| if(k == \arc) { found = v } } };
            if((m[0] == 9) and: { m[2] == id }) { m.copyToEnd(5).pairsDo { |k, v| if(k == \arc) { found = v } } };
        };
        found ? 1
    };
    all = { [\guitar, \loop, \drums, \onsetKit, \synth].collect(arcOf) };
    step = { |pos| ~tPut.(l, \dissolvePos, pos); l.prApplyMixes; l.changed(\dissolvePos, pos) };
    ~tEq.("before any dissolve every strip plays at its level", all.(), [1, 1, 1, 1, 1]);
    ~tPut.(l, \state, \playing);
    step.(0.2);
    ~tEq.("at 0.2 the drums and the onset kit half gone (with the cutter), the synth a third (with the dry loop)",
        all.().round(1e-6), [1, 1, 0.5, 0.5, (1 - (0.2 / 0.6)).round(1e-6)]);
    ~tEq.("...the faders still at their levels", [\drums, \onsetKit, \synth].collect { |k| sa.level(k) },
        [\drums, \onsetKit, \synth].collect { |k| MegaSAMixer.defaultLevels[k] });
    step.(0.4);
    ~tEq.("at 0.4 the drums and the onset kit gone", all.().round(1e-6), [1, 1, 0, 0, (1 - (0.4 / 0.6)).round(1e-6)]);
    step.(0.6);
    ~tEq.("at 0.6 the synth too; the instrument and the loop's strip never touched", all.(), [1, 1, 0, 0, 0]);
    l.cancelDissolve;
    ~tEq.("an abort brings each back at once", all.(), [1, 1, 1, 1, 1]);
    step.(1);
    l.stopPlayback;
    ~tEq.("the dissolve's stop leaves them gone (what they struck still rings)", all.(), [1, 1, 0, 0, 0]);
    ~tEq.("...the axis home all the same", l.dissolvePos, 0);
    l.changed(\state, \stopped);
    ~tEq.("...and stopped, still gone", all.(), [1, 1, 0, 0, 0]);
    ~tPut.(l, \state, \recording);
    l.changed(\state, \recording);
    ~tEq.("the next take brings them back", all.(), [1, 1, 1, 1, 1]);
    ~tPut.(l, \state, \playing);
    step.(0.3);
    l.stopPlayback;
    ~tPut.(l, \state, \playing);
    l.changed(\state, \playing);
    ~tEq.("...as Play does after a stop on the way", all.(), [1, 1, 1, 1, 1]);
    sa.free;
}.value;

// ---- the onset notes sent to Live ---------------------------------------------------
{
    var l = ~tLooper.(), o = l.onsetNotesPart;
    ~tPut.(o, \onsetNotePattern, [[0, 1], [0.25, 1], [0.5, 1], [0.75, 1]]);
    ~tPut.(o, \onsetNoteRolls, [0.1, 0.4, 0.7, 0.95]);
    ~tEq.("a hit plays below the chance, as set", (0 .. 3).collect { |i| o.plays(i) }, [true, true, true, true]);
    ~tEq.("...the dissolve's arc lowers the chance over the same draws: the last kept those a lower chance keeps",
        [1, 0.5, 0.2, 0].collect { |a| (0 .. 3).count { |i| o.plays(i, a) } }, [4, 2, 1, 0]);
    ~tPut.(l, \dissolvePos, 0.2);
    ~tNear.("...the arc the routine is given: the drums' (half gone at 0.2)", l.drumsMix, 0.5, 1e-9);
    ~tAssert.("...and it is given it (the MIDI routine asks with looper.drumsMix)",
        File.readAllString(~tDissolveRoot +/+ "classes/LooperOnsetNotes.sc").contains("this.plays(i, looper.drumsMix)"));
    ~tEq.("...the panel's count is the chance's alone", o.playingCount, 4);
}.value;

~tReport.();
