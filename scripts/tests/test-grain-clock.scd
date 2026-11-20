// The Grains' Clock engine on the Looper's side (LooperGrains; roadmap item
// 23 idea 2, docs/dev/microsound.md): the beat groups worked out from a
// reading, the engine switch, its args, and its presets. The graph itself is
// rendered by scripts/sa/nrt-grain-clock.scd.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-grain-clock");

// ---- the beat groups (LooperGrains.groupGrid) ---------------------------------
{
var g, r;
// Two bars of 7/8 at 0.2 s an eighth: 2+2+3 twice.
r = (numerator: 7, denominator: 8, tau: 0.2, sub: 1, k: 2, n: 14);
g = LooperGrains.groupGrid(r, 2.8);
~tEq.("7/8 twice: six groups", g[\count], 6);
~tEqArray.("...their heads (0, 0.4, 0.8 a bar)", g[\heads].keep(6), [0, 0.4, 0.8, 1.4, 1.8, 2.2], 1e-9);
~tEqArray.("...their lengths (2+2+3 eighths)", g[\lens].keep(6), [0.4, 0.4, 0.6, 0.4, 0.4, 0.6], 1e-9);
~tEq.("...the beat is an eighth, as the count has it", g[\beat], 0.2);
~tAssert.("...unused heads lie past any time", g[\heads].drop(6).every { |h| h >= 1e9 });
~tEq.("...the arrays fill the buffers' slots", [g[\heads].size, g[\lens].size],
    [LooperSynthDefs.groupSlots, LooperSynthDefs.groupSlots]);

// Uneven bars, 7+7+7+8 at 0.25: three bars of 2+2+3, then 2+2+2+2.
r = (numerator: 7, denominator: 8, tau: 0.25, sub: 1, bars: [7, 7, 7, 8], k: 4);
g = LooperGrains.groupGrid(r, 29 * 0.25);
~tEq.("7+7+7+8: thirteen groups", g[\count], 13);
~tEqArray.("...the eight's four pairs at the end", g[\lens].copyRange(9, 12), [0.5, 0.5, 0.5, 0.5], 1e-9);
~tNear.("...the eight's first group on its downbeat (21 eighths in)", g[\heads][9], 21 * 0.25);

// The downbeat late in the loop: heads moved by it, wrapped, still rising.
r = (numerator: 4, denominator: 4, tau: 0.5, sub: 1, k: 1, downbeatPhase: 1.6);
g = LooperGrains.groupGrid(r, 2.0);
~tEqArray.("a downbeat at 1.6 s: the heads wrap round the loop, in order", g[\heads].keep(4), [0.1, 0.6, 1.1, 1.6], 1e-9);
~tEq.("...the grid's offset is the downbeat", g[\offset], 1.6);

g = LooperGrains.groupGrid(nil, 4.0);
~tEq.("no reading: a beat of a quarter of the loop, no groups", [g[\beat], g[\count]], [1.0, 0]);
}.value;

// ---- the engine on a Looper ------------------------------------------------------
{
var buf = { |n| (bufnum: n, numFrames: 48000 * 60, copyData: { |self ... args| self }) };
var stubBuf = { |n| (bufnum: n, setn: { |self ... args| self }) };
var r78 = (numerator: 7, denominator: 8, tau: 0.25, sub: 1, k: 2, n: 14, loopDur: 3.5, bpm: 120);
var l, old, made, srv, news;
l = ~tLooper.();
srv = ~tGet.(l, \server);
~tPut.(l, \state, \playing);
~tPut.(l, \buffer, buf.(11));
~tPut.(l, \loopFrames, 168000);
~tPut.(l, \lastResult, r78);
// The s_news sent from `from` on, as [def, node]
news = { |from| srv[\msgs].copyToEnd(from).select { |m| m[0] == 9 }.collect { |m| [m[1].asSymbol, m[2]] } };

// Off: switching sends nothing.
made = srv[\msgs].size;
l.granularEngine = 1;
~tEq.("switching while the Grains are off starts nothing", srv[\msgs].size, made);
~tEq.("...but the engine is set", l.granularEngine, 1);
l.granularEngine = 0;

// No buffers yet (a toggle racing construction): Cloud plays, not a Clock on buffer 0.
l.granularEngine = 1;
made = srv[\msgs].size;
l.toggleGranular;
~tEq.("Clock with no buffers yet: Cloud's synth plays instead", news.(made).collect(_[0]), [\looperGranular]);
~tAssert.("...given none of the Clock's args", ~tLastSet.(l, ~tGet.(l, \granularSynth), \headsBuf).isNil);
l.toggleGranular;
l.granularEngine = 0;

// With its buffers: Cloud on, then switched to Clock while it plays.
~tPut.(l, \hannBuf, stubBuf.(70));
~tPut.(l, \headsBuf, stubBuf.(71));
~tPut.(l, \lensBuf, stubBuf.(72));
l.toggleGranular;
old = ~tGet.(l, \granularSynth);
~tEq.("Cloud on: the Warp1 synth", news.(0).last[0], \looperGranular);
made = srv[\msgs].size;
l.granularDivision = 4;
l.granularEngine = 1;
~tEq.("switched to Clock while playing: a Clock synth starts", news.(made).collect(_[0]), [\looperGrainClock]);
// (The stub server gives every synth node 1000, so the old one's n_set is looked
// for as sent, before the new one's s_new.)
~tAssert.("...the old one fades (amp 0)", srv[\msgs].copyToEnd(made).any { |m|
    (m[0] == 15) and: { m[1] == old.nodeID } and: { m.copyToEnd(2) == [\amp, 0] } });
~tEq.("...the Clock's beat is the reading's eighth, in the loop's time", ~tLastSet.(l, ~tGet.(l, \granularSynth), \tau), 0.25);
~tEq.("...its group buffers and Hann window are the part's", [\headsBuf, \lensBuf, \envbuf].collect { |k|
    ~tLastSet.(l, ~tGet.(l, \granularSynth), k) }, [71, 72, 70]);
~tEq.("...and it starts from the controls set before", ~tLastSet.(l, ~tGet.(l, \granularSynth), \division), 4);

// Half-time: Cloud's window doubles, the Clock's beat stays the loop's.
made = srv[\msgs].size;
l.grainsPart.setTau(0.5);
~tEq.("half-time's tau does not reach the Clock", srv[\msgs].size, made);
~tPut.(l, \loopFrames, 336000);
l.prGranularFollow;
~tEq.("a loop change: the Clock keeps the reading's beat", ~tLastSet.(l, ~tGet.(l, \granularSynth), \tau), 0.25);

// The window menu: Hann is the Clock's own buffer, not Warp1's -1.
l.granularEnv = 1;
l.granularEnv = 0;
~tEq.("the window back to Hann on the Clock: its buffer, never -1", ~tLastSet.(l, ~tGet.(l, \granularSynth), \envbuf), 70);

// Groups: on with a reading, off without one (the grid plays).
l.granularGroups = true;
~tEq.("groups on, with a reading: the synth plays the groups", ~tLastSet.(l, ~tGet.(l, \granularSynth), \groups), 1);
~tPut.(l, \lastResult, nil);
l.granularGroups = true;
~tEq.("...with no reading there are none: the grid", ~tLastSet.(l, ~tGet.(l, \granularSynth), \groups), 0);
l.toggleGranular;
}.value;

// ---- presets ---------------------------------------------------------------------
{
var l = ~tLooper.(), data, clean, warnings = List.new;
l.granularEngine = 1;
l.granularGroups = true;
l.granularDivision = 3;
l.granularScatter = 0.4;
l.granularLength = 2;
data = l.granularPresetData("clock");
~tEq.("a Clock preset says its engine by name", data[\engine], "Clock");
clean = l.prValidateGranularPreset(data, warnings);
~tEq.("...and reads back as it was", [clean[\engine], clean[\groups], clean[\division], clean[\scatter], clean[\length]],
    [1, true, 3.0, 0.4, 2.0]);
~tEq.("...with nothing to correct", warnings.size, 0);
// A preset from before the Clock: Cloud, the Clock's controls at their defaults, no warnings.
data.removeAt(\engine); data.removeAt(\groups); data.removeAt(\division); data.removeAt(\scatter); data.removeAt(\length);
warnings = List.new;
clean = l.prValidateGranularPreset(data, warnings);
~tEq.("an older preset: Cloud, a grain a beat, on the grid, half a pulse", [clean[\engine], clean[\groups], clean[\division],
    clean[\scatter], clean[\length]], [0, false, 1.0, 0.0, 0.5]);
~tEq.("...without a warning", warnings.size, 0);
data[\engine] = "Pulsar";
warnings = List.new;
clean = l.prValidateGranularPreset(data, warnings);
~tEq.("an unknown engine: Cloud, and said", [clean[\engine], warnings.size], [0, 1]);
l.applyGranularPreset(l.granularPresetData("x").put(\engine, "Cloud"));
~tEq.("applying a Cloud preset sets the engine back", l.granularEngine, 0);
}.value;

~tReport.();
