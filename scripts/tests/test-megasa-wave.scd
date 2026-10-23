// The Wave synth (MegaSAWave, docs/dev/synth.md Phase 2): its tables (which
// partials each holds, band by band, and where each lies), its settings, the
// message that plays a note, and its place in MegaSA: the synth's chain,
// strip and stem, its tables built with the rest, the sequencer's notes
// played by it, and what a note knows of the one before (glide, legato).
// The sound itself is rendered and checked by scripts/sa/nrt-wave.scd.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-megasa-wave");

// ---------------------------------------------------------------- tables --
{
var c = MegaSAWave, msgs, gens, worst, limits, w, m;
~tEq.("five sets (four and yours) of eight tables, in nine octave bands: 360 buffers", c.numBuffers, 360);
~tEq.("buffers lie set by set, band by band, table by table",
    [c.bufnum(100, 0, 0, 0), c.bufnum(100, 0, 0, 7), c.bufnum(100, 0, 1, 0), c.bufnum(100, 1, 0, 0), c.bufnum(100, 3, 8, 7)],
    [100, 107, 108, 172, 387]);
~tEq.("the sine is one partial", c.partials(0, 0, 100), [[1, 1, 0]]);
~tEq.("the saw every partial at 1/n", c.partials(0, 2, 4), [[1, 1, 0], [2, 0.5, 0], [3, 1 / 3, 0], [4, 0.25, 0]]);
~tEq.("the square the odd ones", c.partials(0, 3, 6).collect(_[0]), [1, 3, 5]);
~tEq.("the triangle the odd ones at 1/n squared, every other one inverted", c.partials(0, 1, 5).collect(_[1]), [1, -1 / 9, 1 / 25]);
~tAssert.("a pulse is cosines", c.partials(0, 5, 20).every { |p| p[2] == 0.5pi });
~tEq.("Harmonics: more partials table by table", (0..7).collect { |k| c.partials(1, k, 1000).size }, [1, 2, 3, 5, 8, 13, 24, 64]);
~tEq.("Organ: drawbars up to 1'", c.partials(3, 7, 100).collect(_[0]), [1, 2, 3, 4, 6, 8, 10, 12, 16]);
~tEq.("...and where no bar fits, the fundamental: no table is silent", c.partials(3, 0, 1), [[1, 1, 0]]);

msgs = c.tableMsgs(0);
gens = msgs.select { |x| x[1] == \sine3 or: { x[2] == \sine3 } };
~tEq.("every table allocated, then generated: wavetable form, normalized, cleared",
    [msgs.size, msgs.count { |x| x[0] == \b_alloc }, msgs.select { |x| x[0] == \b_alloc }.collect { |x| [x[2], x[3]] }.asSet.asArray,
        msgs.select { |x| x[0] == \b_gen }.collect { |x| [x[2], x[3]] }.asSet.asArray],
    [720, 360, [[4096, 1]], [[\sine3, 7]]]);
~tEq.("...the buffers 0 to 359, each once", msgs.select { |x| x[0] == \b_alloc }.collect(_[1]), (0..359));
~tEq.("...yours, with none loaded, Analog's", c.partials(4, 2, 50), c.partials(0, 2, 50));
// The highest partial of every table times its band's top: never above 20 kHz.
worst = 0;
msgs.select { |x| x[0] == \b_gen }.do { |x|
    var band = (x[1] / 8).floor.asInteger % 9, top = c.bandTops[band];
    var parts = x.copyToEnd(4).clump(3);
    worst = worst.max(parts.collect(_[0]).maxItem * top);
};
~tAssert.("no table holds a partial that would sound above 20 kHz at its band's top", worst <= 20000, worst.asString);
limits = c.bandTops.collect { |top, b| msgs[(c.bufnum(0, 0, b, 2) * 2) + 1].copyToEnd(4).clump(3).size };
~tEq.("...the saw keeps as many as fit, band by band", limits, [363, 181, 90, 45, 22, 11, 5, 2, 1]);
~tAssert.("...and the low band holds hundreds (2048 points take 1023)", limits[0] > 300);
}.value;

// ------------------------------------------------------------ your table --
// WAVs written here with known cycles: a sine, a saw of 50 partials, a
// square of the odd ones to 49, and cos(3t); read back into the eight
// positions, each cycle's partials as they were put in.
{
var dir = ~tTempPath.("wave-tables"), c = MegaSAWave, n = 2048, was = MegaFiles.rootOverride;
var write = { |path, sig|
    var sf = SoundFile.new.headerFormat_("WAV").sampleFormat_("float").numChannels_(1).sampleRate_(48000);
    sf.openWrite(path);
    sf.writeData(sig.as(FloatArray));
    sf.close;
};
var cyc = { |f| Signal.fill(n, { |i| f.(2pi * i / n) }) };
var sine = cyc.({ |t| sin(t) });
var saw = cyc.({ |t| (1 .. 50).sum { |m| sin(m * t) / m } });
var square = cyc.({ |t| (1, 3 .. 49).sum { |m| sin(m * t) / m } });
var cos3 = cyc.({ |t| cos(3 * t) });
var stub = ~tStubServer.(), w, cycles, parts, got, said = List.new, f;
File.mkdir(dir);
write.(dir +/+ "four.wav", sine ++ saw ++ square ++ cos3);
write.(dir +/+ "short.wav", Signal.fill(600, { |i| sin(2pi * i / 600) }));
write.(dir +/+ "noise.txt", Signal.fill(10, { 0 }));
cycles = c.cyclesOf(dir +/+ "four.wav");
~tEq.("a Serum-style file: its cycles of 2048", [cycles.size, cycles[0].size], [4, 2048]);
parts = c.analyse(cycles);
~tEq.("eight positions, spread over the four cycles (0 0 1 1 2 2 3 3)",
    parts.collect { |p| p.size }, [1, 1, 50, 50, 25, 25, 1, 1]);
~tAssert.("the sine: one partial, at 1, in phase", (parts[0][0][0] == 1) and: { (parts[0][0][1] - 1).abs < 1e-4 }
    and: { parts[0][0][2].abs < 1e-4 }, parts[0].asString);
~tAssert.("the saw: every partial at 1/n", parts[2].every { |p| (p[1] - (1 / p[0])).abs < 1e-4 }, parts[2].keep(3).asString);
~tAssert.("the square: the odd ones only", parts[4].every { |p| p[0].odd });
~tAssert.("cos(3t): partial 3, a quarter turn on", (parts[6][0][0] == 3) and: { (parts[6][0][2] - 0.5pi).abs < 1e-4 },
    parts[6].asString);
got = c.analyse(c.cyclesOf(dir +/+ "short.wav"));
~tAssert.("a single cycle shorter than 2048, stretched: still its partial 1, at every position",
    got.every { |p| var top = p.detect { |x| x[1] == p.collect(_[1]).maxItem }; top[0] == 1 });
~tAssert.("what is no sound file is refused, saying why", c.cyclesOf(dir +/+ "noise.txt").isString
    and: { c.cyclesOf(dir +/+ "missing.wav").isString });
~tEq.("your set keeps a band's limit: a saw cycle at the top band, its fundamental alone",
    c.partials(4, 2, 1, parts).collect(_[0]), [1]);

MegaFiles.rootOverride = dir +/+ "user";
protect {
    w = MegaSAWave(stub);
    MegaSAWave.loadSynthDefs;
    w.build;
    f = { |obj, what ... args| said.add([what] ++ args) };
    w.addDependant(f);
    stub[\bundles].clear;
    ~tEq.("import: copied into your wavetables folder, and loaded", [w.importTable(dir +/+ "four.wav"), w.tableName,
        File.exists(MegaSAWave.tableDir +/+ "four.wav")], [true, "four.wav", true]);
    got = stub[\bundles].collect(_[1]).flatten(1);
    ~tEq.("...its 72 tables made again on the server, over the buffers there (no new ones)",
        [got.count { |x| x[0] == \b_gen }, got.count { |x| x[0] == \b_alloc },
            got.select { |x| x[0] == \b_gen }.collect(_[1]).asSet.asArray.sort == (0 .. 71).collect { |i| w.base + 288 + i }],
        [72, 0, true]);
    ~tEq.("...and it says so", said.last, [\waveTable, "four.wav"]);
    ~tEq.("imported again: the same file, not a second copy", [w.importTable(dir +/+ "four.wav"),
        (MegaSAWave.tableDir +/+ "*.wav").pathMatch.size], [true, 1]);
    ~tEq.("a kept table by its name", [w.loadTableNamed("four.wav"), w.userPartials.size], [true, 8]);
    ~tAssert.("one that is not there: refused, the table as it was",
        w.loadTableNamed("gone.wav").isString and: { w.tableName == "four.wav" });
    w.clearTable;
    ~tEq.("cleared: none, the set Analog's again", [w.tableName, w.userPartials, said.last], [nil, nil, [\waveTable, nil]]);
    w.removeDependant(f);
    w.free;
} {
    MegaFiles.rootOverride = was;
    ~tRemoveTree.(dir);
};
}.value;

// -------------------------------------------------------------- settings --
{
var stub = ~tStubServer.(), w = MegaSAWave(stub), said = List.new, f, m, a, rec;
~tEq.("every setting starts at its default", w.settings.size, MegaSAWave.params.size);
~tEq.("...the line plays the saw-ish table, its filter part open, at -6 dB",
    [\waveASet, \waveAPos, \waveCutoff, \waveLevel].collect { |k| w[k] }, [0, 0.3, 3000, -6]);
~tAssert.("every setting's name is the voice's control",
    MegaSAWave.params.every { |p| SynthDescLib.global[\megaSAWaveVoice].isNil or: {
        SynthDescLib.global[\megaSAWaveVoice].controlNames.includes(p[\name]) } });
f = { |obj, what ... args| said.add([what] ++ args) };
w.addDependant(f);
~tEq.("a setting is held to its range and step", [w.set(\waveCutoff, 1e6), w.set(\waveAOctave, 1.4), w.set(\waveASet, 9)], [18000, 1, 4]);
~tEq.("...and says so", said.first, [\waveSetting, \waveCutoff, 18000]);
~tEq.("one it has not is refused", [w.set(\waveSize, 1), w.set(\waveCutoff, "loud"), w[\waveCutoff]], [nil, nil, 18000]);
w.set(\waveLevel, 3);
w.set(\waveGlide, 0.2);
w.randomize;
~tEq.("Random leaves the level and the glide", [w[\waveLevel], w[\waveGlide]], [3, 0.2]);
~tAssert.("...and moves the rest within their ranges", MegaSAWave.params.every { |p| MegaSAWave.constrain(p[\name], w[p[\name]]) == w[p[\name]] });
w.reset;
~tEq.("Reset: every default back", w[\waveCutoff], 3000);
w.removeDependant(f);

rec = (note: 69, vel: 127, gate: 0.1, from: 57, legato: true);
a = (group: 1004, out: 24, ring: 3200, choke: 4138, hitId: 9);
~tEq.("no note before the tables are built", w.voiceMsgs(rec, a), []);
MegaSAWave.loadSynthDefs;
w.build;
~tAssert.("built: a block of 360 buffers, their messages sent", w.built and: { w.base.notNil }
    and: { stub[\bundles].collect(_[1]).flatten(1).count { |x| x[0] == \b_gen } == 360 });
m = w.voiceMsgs(rec, a)[0];
a = ().putPairs(m.copyToEnd(5));
~tEq.("a note: the voice at the tail of the synth's group", m.keep(5), [\s_new, \megaSAWaveVoice, -1, 1, 1004]);
~tEq.("...its pitch, the one it glides from, its length and legato",
    [a[\freq], a[\fromFreq], a[\dur], a[\legato]], [440.0, 220.0, 0.1, 1]);
~tEq.("...its level by velocity (squared, 0.5 at the top)", a[\amp], 0.5);
~tEq.("...its cancel bus, the choke bus, its id, the tables and its bus", [a[\cancelBus], a[\chokeBus], a[\hitId], a[\base], a[\out]],
    [3200, 4138, 9, w.base, 24]);
~tAssert.("...and every setting", MegaSAWave.params.every { |p| a[p[\name]] == w[p[\name]] });
a = ().putPairs(w.voiceMsgs((note: 60, vel: 64, gate: 0.2), (group: 1, out: 0, ring: 0, choke: 0, hitId: 1))[0].copyToEnd(5));
~tEq.("a first note glides from itself, not legato", [a[\fromFreq], a[\legato]], [60.midicps, 0]);
w.free;
~tEq.("freed: its buffers go", [w.built, w.base, stub[\msgs].count { |x| x[0] == \b_free }], [false, nil, 360]);
}.value;

// ------------------------------------------------------------- in MegaSA --
{
var stub = ~tStubServer.(), sa, kids, t, d, l, w, sent;
MegaSA.loadSynthDefs;
sa = ~tMegaSA.(stub);
d = sa.drums;
~tEq.("MegaSA has a Wave synth, a synth chain on its own bus, a strip and a stem",
    [sa.wave.isKindOf(MegaSAWave), sa.synthChain.track, sa.synthChain.bus === sa.synthBus, sa.strips[\synth].notNil,
        sa.stemBus(\synth).notNil, sa.stemSpecs.last[\role]], [true, \synth, true, true, true, \synth]);
~tNear.("...the strip at -6 dB", sa.level(\synth).ampdb, -6, 1e-6);
~tEq.("...its tables built with the rest", sa.wave.built, true);
t = ~tNodeTree.(stub);
kids = (t[\children][sa.drumGroup.nodeID] ? []).asArray;
~tAssert.("in the drum group: the drums' effects, then the sequencer's voices, then the synth's chain",
    (kids.indexOf(d.fxSynth.nodeID) ? 99) < (kids.indexOf(d.synthGroup.nodeID) ? -1)
        and: { (kids.indexOf(d.synthGroup.nodeID) ? 99) < (kids.indexOf(sa.synthChain.group.nodeID) ? -1) }, kids.asString);
~tAssert.("a device goes onto the synth's chain as onto any other",
    sa.insertDevice(\synth, nil, \echo).notNil and: { sa.synthChain.devices.size == 1 });

// The sequencer's notes, played by the Wave synth into the synth's bus.
l = ~tLooper.();
~tPut.(l, \state, \playing);
~tPut.(l, \loopFrames, 96000);
~tPut.(l, \loopStartTime, 90.0);
~tPut.(l, \lastResult, (numerator: 4, denominator: 4, k: 1, bpm: 120, loopDur: 2.0));
w = 91.9;
sent = List.new;
d.wallClock = { w };
d.sender = { |at, msgs| sent.add([at, msgs]) };
d.attach(l);
d.setNoteValues(\length, 100 ! 16);
d.setNotesOn(true, w);
d.transportStart(w);
while { w < 92.6 } { w = w + 0.01; d.pump(w) };
sent = sent.collect(_[1]).flatten(1).select { |m| (m[0] == \s_new) and: { m[1] == \megaSAWaveVoice } }
    .collect { |m| ().putPairs(m.copyToEnd(5)).put(\group, m[4]) };
~tAssert.("notes were played", sent.size >= 4, sent.size.asString);
~tEq.("...by the Wave synth, in the sequencer's group, onto the synth's bus",
    [sent[0][\group], sent[0][\out]], [d.synthGroup.nodeID, sa.synthBus.index]);
~tEq.("...the first not legato, the next (100 % long) legato, each from the note before",
    sent.keep(3).collect { |a| [a[\legato], a[\fromFreq].cpsmidi.round] }, [[0, 60], [1, 60], [1, 67]]);
d.setNoteValues(\length, 50 ! 16);
while { w < 93.2 } { w = w + 0.01; d.pump(w) };
sa.free;
}.value;
