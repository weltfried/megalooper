// Every SynthDef's compiled graph, fingerprinted.
//
// The SynthDefs are the part of Looper that runs on scsynth, so nothing about
// what they SOUND like can be asserted headlessly. What can be asserted is that
// the compiled bytes have not moved — and that turns out to be enough to make
// the graphs refactorable with confidence, because a graph rewrite that changes
// no bytes cannot change any audio.
//
// That is exactly how the mono/stereo and detection-chain duplication was
// collapsed: the eleven defs were dumped before and after, and all eleven were
// byte-identical. The baseline below is those same bytes, so it covers the
// graphs as they were BEFORE that refactor too.
//
// A deliberate graph change means updating the baseline — the failure line
// prints the value to paste. If ALL eleven move at once, suspect SuperCollider
// itself was upgraded (a new def-file version or UGen set changes the encoding)
// rather than the class; re-baseline in that case and say so in the commit.
//
// This works with no server because SynthDef builds its graph in the language;
// only .add sends anything, and an unbooted server just means the message goes
// nowhere.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-synthdefs");

{
// [byte count, order-sensitive rolling checksum]
var baseline = (
    // Moved 2026-09-29 from [ 1417, 508731360 ] / [ 1357, 129150009 ]: the
    // recorder now tracks the tap's and the input's peak over the take and
    // reports them on /looperLevels, for the starved-tap warning. Deliberate —
    // see the graph's comment and roadmap item 6.
    'looperRec':             [ 1844, 347506692 ],
    'looperRecMono':         [ 1784, 322503125 ],
    'looperAnalysisMonitor': [ 1059, 897460795 ],
    'looperOverdubAnalysis': [  864, 693388309 ],
    'looperRecPlain':        [  605, 125864998 ],
    'looperRecPlainMono':    [  545, 466595377 ],
    // Moved 2026-10-27 from [ 2074, 209975019 ] and [ 2014, 953598608 ]: the
    // write-back reads without interpolation, the playback read is cubic and
    // the write head's latency shift is rounded, so any rate but ±1 leaves the
    // loop as it was. Deliberate — see the graph's comment; the render
    // scripts/sa/nrt-engine-rate.scd checks that ±1 sounds as before.
    // Moved again the same day from [ 2115, 92375856 ] and [ 2055, 259924006 ]:
    // half-time's `speed`, taken on the sample a reference Phasor wraps, and
    // the playhead's Phasor reading its rate every sample. The render checks
    // that too.
    'looperEngine':          [ 2697, 25642149 ],
    'looperEngineMono':      [ 2637, 48664331 ],
    'looperClick':           [  429, 831893340 ],
    'looperMaster':          [  478, 767188786 ],
    // Moved 2026-09-25 from [ 2645, 983190439 ]: the pulsed scan now reads the
    // engine's phase bus (two new controls, phaseBus and locked, and the
    // phase-correction UGens). A deliberate change — see the graph's comment.
    // Moved 2026-10-27 from [ 3072, 748923918 ]: a `rate` control, the
    // engine's signed speed, which the one-pass phasor and morph's share of
    // the scan move at, so the lock holds reversed and at half-time.
    // Moved again the same day from [ 3088, 356440040 ]: following the
    // chords (follow, chordPeriod, chordStarts and chordRoots, 32 slots each,
    // and the shift added to the pitch; roadmap item 8). Deliberate — see the
    // graph's comment; scripts/sa/nrt-grains.scd renders it.
    'looperGranular':        [ 8824, 556604813 ]
);
// Defined here rather than leaning on ArrayedCollection:hash, so the
// fingerprint is fixed by this file and cannot shift under the test.
var fingerprint = { |bytes|
    var acc = 0;
    bytes.do { |b, i| acc = (acc * 31 + b + i) % 1000000007 };
    [bytes.size, acc]
};
var l = ~tLooper.();

~tCheck.("every SynthDef builds with no server", { l.loadSynthDefs });

baseline.keys.asArray.sort.do { |name|
    var desc = SynthDescLib.global[name];
    var got;
    if(desc.isNil or: { desc.def.isNil }) {
        ~tFail.(name ++ ": built", "not in SynthDescLib after loadSynthDefs");
    } {
        got = fingerprint.(desc.def.asBytes);
        ~tAssert.(name ++ ": graph unchanged", got == baseline[name],
            "got " ++ got.asCompileString ++ ", baseline "
                ++ baseline[name].asCompileString);
    };
};

// The mono/stereo pairs are built from ONE graph function each, so the only
// thing that may differ between a pair is the input. Equal byte counts would
// mean the input expressions had become the same — which would mean one of the
// two is reading the wrong number of channels.
[
    [\looperRec,       \looperRecMono],
    [\looperRecPlain,  \looperRecPlainMono],
    [\looperEngine,    \looperEngineMono]
].do { |pair|
    ~tAssert.(pair[0] ++ " and " ++ pair[1] ++ " still differ",
        baseline[pair[0]][0] != baseline[pair[1]][0],
        "identical byte counts suggest both read the same channel count");
    // The mono graph is the smaller one: SoundIn.ar(ch).dup needs no
    // BinaryOpUGen for ch + 1.
    ~tAssert.(pair[1] ++ " is the smaller graph (no ch + 1)",
        baseline[pair[1]][0] < baseline[pair[0]][0],
        "mono " ++ baseline[pair[1]][0] ++ " vs stereo " ++ baseline[pair[0]][0]);
};
}.value;
