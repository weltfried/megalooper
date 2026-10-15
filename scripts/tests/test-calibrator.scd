// The calibration wizard: the step flow, and the arithmetic that turns two
// recordings into a number of milliseconds.
//
// Neither half needs a server, and that is deliberate. The measuring functions
// are INJECTED into the calibrator, so the whole wizard — running a step,
// failing one, skipping one, applying what it found, rendering the line you
// paste into the profile — is driven here with stubs, on a machine with no
// audio interface and no Ableton Live.
//
// The arithmetic is checked against signals whose answer is known: an envelope
// with a spike where the spike was put, and a correlation against a copy of
// itself shifted by an amount this file chose. What cannot be checked here is
// whether the burst travels the path the step claims it does. That needs the
// rig, and scripts/calibrate-measure.scd is the thing to run on it.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-calibrator");

{
// A bump `width` buckets long starting at `at`, which is what a transient looks
// like once it is an envelope.
var pulse = { |n, at, width = 4|
    var a = Array.fill(n, 0);
    width.do { |j|
        var i = at + j;
        if((i >= 0) and: { i < n }) { a[i] = 1 - (j / width) };
    };
    a
};

// Interleaved stereo, as Buffer:loadToFloatArray hands it over.
var interleaved = { |frames, spikeAt, spikeLen = 8|
    var a = Array.fill(frames * 2, 0);
    spikeLen.do { |j|
        var f = spikeAt + j;
        if(f < frames) { a[f * 2] = 0.8; a[(f * 2) + 1] = 0.8 };
    };
    a
};

var cal = { |l| LooperCalibrator.new(l ? ~tLooper.()) };

// ---- the step table ---------------------------------------------------------
// The wizard is only as good as this table being coherent, and it is data, so
// it is worth asserting rather than reading.
{
    var steps = LooperCalibrator.steps;
    var keys  = LooperCalibrator.stepKeys;
    ~tAssert.("there are steps at all", steps.size > 0, steps.size.asString);
    ~tEq.("every step key is unique", keys.asSet.size, keys.size);
    ~tEq.("the preflight comes first", keys.first, \preflight);
    ~tEq.("writing it down comes last", keys.last, \writeback);

    steps.do { |s|
        var k = s[\key].asString;
        ~tAssert.(k ++ ": has a title", (s[\title] ? "").notEmpty);
        ~tAssert.(k ++ ": says why it exists", (s[\why] ? "").notEmpty);
        ~tAssert.(k ++ ": says what to do", (s[\todo] ? []).notEmpty);
        // A step the wizard cannot describe the preconditions of is a step the
        // player will run in the wrong room and get a number from anyway.
        (s[\needs] ? []).do { |n|
            ~tAssert.(k ++ ": its need '" ++ n ++ "' has a label",
                LooperCalibrator.needLabels[n].notNil,
                n.asString ++ " is not in needLabels");
        };
    };
}.value;

{
    // Every measured step writes to a real Looper setter, or applying it would
    // silently do nothing.
    var l = ~tLooper.();
    LooperCalibrator.steps.do { |s|
        s[\field] !? { |f|
            ~tAssert.(s[\key].asString ++ ": " ++ f ++ " is a real getter",
                l.respondsTo(f));
            ~tAssert.(s[\key].asString ++ ": " ++ f ++ " is a real setter",
                l.respondsTo((f ++ '_').asSymbol));
        };
    };
}.value;

{
    // The line pasted into setup-routing.scd has to cover every calibrated
    // field, including ones this run never touched.
    var c = cal.();
    var fields = c.calibratedFields;
    var covered = LooperCalibrator.steps.collect { |s| s[\field] }.reject(_.isNil);
    ~tAssert.("every step's field is one of the calibrated fields",
        covered.every { |f| fields.includes(f) },
        covered.reject { |f| fields.includes(f) }.asString);
}.value;

// ---- walking the wizard -----------------------------------------------------
{
    var c = cal.();
    ~tEq.("it starts on the first step", c.stepIndex, 0);
    ~tEq.("and reports that step's key", c.currentKey, \preflight);
    c.advance;
    ~tEq.("advance moves on", c.stepIndex, 1);
    c.back;
    ~tEq.("back moves back", c.stepIndex, 0);
    c.back;
    ~tEq.("and stops at the start rather than wrapping", c.stepIndex, 0);
    100.do { c.advance };
    ~tEq.("advance stops at the end rather than wrapping",
        c.stepIndex, c.stepCount - 1);
}.value;

{
    var c = cal.();
    ~tEq.("every step starts pending", c.statusOf(\latency), \pending);
    ~tAssert.("and nothing is complete", c.isComplete.not);
}.value;

// ---- running a step ---------------------------------------------------------
{
    var c = cal.();
    var got = nil;
    c.register(\preflight, { |l, done| done.((ok: true, value: nil)) });
    c.run({ |res| got = res });
    ~tEq.("a measurement that succeeds marks the step done",
        c.statusOf(\preflight), \done);
    ~tAssert.("and hands the result to the caller", got.notNil);
    ~tAssert.("and keeps it", c.resultOf(\preflight).notNil);
}.value;

{
    var c = cal.();
    c.register(\preflight, { |l, done| done.((ok: false, why: "nope")) });
    c.run;
    ~tEq.("a measurement that refuses marks the step failed",
        c.statusOf(\preflight), \failed);
    ~tEq.("and keeps the reason", c.resultOf(\preflight)[\why], "nope");
}.value;

{
    // The one that would strand the wizard: a measurer that throws must not
    // leave the step on \running with its button disabled and no way back.
    var c = cal.();
    c.register(\preflight, { |l, done| Error("burst failed").throw });
    ~tCheck.("a measurer that throws does not take the wizard down",
        { c.run });
    ~tEq.("the step is failed, not stuck running", c.statusOf(\preflight), \failed);
    ~tAssert.("and says what threw",
        c.resultOf(\preflight)[\why].asString.contains("burst failed"),
        c.resultOf(\preflight)[\why].asString);
}.value;

{
    // A measurer that never calls back leaves the step running — and a second
    // press must not fire a second burst into the middle of the first.
    var c = cal.();
    var calls = 0;
    c.register(\preflight, { |l, done| calls = calls + 1 });
    c.run;
    ~tEq.("a measurement in flight stays running", c.statusOf(\preflight), \running);
    c.run;
    ~tEq.("and pressing again does not start a second one", calls, 1);
}.value;

{
    var c = cal.();
    c.run;
    ~tEq.("a step with nothing wired to it fails rather than pretending",
        c.statusOf(\preflight), \failed);
}.value;

{
    var c = cal.();
    c.skip;
    ~tEq.("skip marks the step skipped", c.statusOf(\preflight), \skipped);
    ~tEq.("and moves on", c.stepIndex, 1);
}.value;

// ---- which input a step listens to ------------------------------------------
// Per step, because the two listening steps want DIFFERENT pairs: Live's
// metronome arrives wherever Cue Out points, the drum rack wherever its track
// is routed. Giving each a free loopback pair is what keeps our own loop return
// out of both measurements.
{
    var l = ~tLooper.();
    var c = cal.(l);
    ~tEq.("unset, a listening step falls back to the return channel",
        c.listenChannel(\sync), l.returnChannel);
    c.setListenChannel(\sync, 4);
    ~tEq.("it can be pointed somewhere else", c.listenChannel(\sync), 4);
    ~tEq.("without moving the other listening step",
        c.listenChannel(\noteOffset), l.returnChannel);
    c.setListenChannel(\noteOffset, 6);
    ~tEq.("which has its own", c.listenChannel(\noteOffset), 6);
    ~tEq.("and the first one is untouched", c.listenChannel(\sync), 4);
}.value;

{
    var c = cal.();
    c.goTo(LooperCalibrator.stepKeys.indexOf(\sync));
    c.setListenChannel(nil, 9);
    ~tEq.("a nil key means the step being shown", c.listenChannel(\sync), 9);
}.value;

{
    var c = cal.();
    c.setListenChannel(\sync, -3);
    ~tEq.("a negative channel is clipped rather than read as a bus", 
        c.listenChannel(\sync), 0);
    ~tCheck.("a nil channel is ignored rather than stored",
        { c.setListenChannel(\sync, nil) });
    ~tEq.("leaving the last good value", c.listenChannel(\sync), 0);
}.value;

{
    // The pane shows the channel box from this flag, so the steps that record
    // something have to declare it and the others must not.
    var c = cal.();
    ~tAssert.("the sync step listens", c.listens(\sync));
    ~tAssert.("so does the note-offset step", c.listens(\noteOffset));
    ~tAssert.("the threshold step does not", c.listens(\threshold).not);
    ~tAssert.("nor does writing it down", c.listens(\writeback).not);
}.value;

{
    // The measurer is handed the calibrator so it can read that channel.
    // sclang ignores arguments a function does not declare, which is what keeps
    // every two-argument stub in this file working.
    var c = cal.();
    var seen = nil;
    c.register(\preflight, { |lp, done, given| seen = given; done.((ok: true)) });
    c.run;
    ~tAssert.("a measurer is given the calibrator", seen === c);
}.value;

// ---- manual steps -----------------------------------------------------------
{
    // A manual step has nothing to measure: it reads back what the player did.
    var l = ~tLooper.();
    var c = cal.(l);
    l.onsetThreshold = 0.42;
    c.goTo(LooperCalibrator.stepKeys.indexOf(\threshold));
    c.confirm;
    ~tEq.("confirming a manual step marks it done", c.statusOf(\threshold), \done);
    ~tNear.("and takes the value off the looper",
        c.resultOf(\threshold)[\value], 0.42, 1e-9);
}.value;

// ---- applying what was found ------------------------------------------------
{
    var l = ~tLooper.();
    var c = cal.(l);
    c.goTo(LooperCalibrator.stepKeys.indexOf(\latency));
    c.register(\latency, { |lp, done| done.((ok: true, value: 37)) });
    c.run;
    ~tNear.("measuring does not itself change the rig", l.latencyMs, 0.0, 1e-9);
    c.apply;
    ~tNear.("applying does", l.latencyMs, 37.0, 1e-9);
}.value;

{
    // Applying a failed measurement would write a number the wizard itself does
    // not believe.
    var l = ~tLooper.();
    var c = cal.(l);
    c.goTo(LooperCalibrator.stepKeys.indexOf(\latency));
    c.register(\latency, { |lp, done| done.((ok: false, why: "too weak", value: 999)) });
    c.run;
    c.applyAll;
    ~tNear.("applyAll skips a step that failed", l.latencyMs, 0.0, 1e-9);
}.value;

{
    var l = ~tLooper.();
    var c = cal.(l);
    var idx = LooperCalibrator.stepKeys.indexOf(\sync);
    c.goTo(idx);
    c.register(\sync, { |lp, done| done.((ok: true, value: -12)) });
    c.run;
    c.applyAll;
    ~tNear.("applyAll writes every step that succeeded", l.abletonSyncMs, -12.0, 1e-9);
}.value;

// ---- the line you paste -----------------------------------------------------
{
    var l = ~tLooper.();
    var c = cal.(l);
    var line;
    l.latencyMs = 54;
    line = c.profileLine;
    c.calibratedFields.do { |f|
        ~tAssert.("the profile line carries " ++ f,
            line.contains(f.asString), line);
    };
    ~tAssert.("and the value the looper is actually carrying",
        line.contains("54"), line);
}.value;

{
    var l = ~tLooper.();
    var c = cal.(l);
    c.goTo(LooperCalibrator.stepKeys.indexOf(\latency));
    c.register(\latency, { |lp, done| done.((ok: true, value: 41)) });
    c.run;
    ~tAssert.("a measured field is reported as measured", c.wasMeasured(\latencyMs));
    ~tAssert.("an untouched one is not", c.wasMeasured(\abletonSyncMs).not);
    ~tNear.("and the line prefers the measurement over the running value",
        c.valueFor(\latencyMs), 41, 1e-9);
}.value;

// ---- completion -------------------------------------------------------------
{
    var c = cal.();
    LooperCalibrator.steps.do { |s|
        c.goTo(LooperCalibrator.stepKeys.indexOf(s[\key]));
        c.register(s[\key], { |lp, done| done.((ok: true, value: 1)) });
        c.run;
    };
    ~tAssert.("every step answered means complete", c.isComplete);
}.value;

{
    var c = cal.();
    LooperCalibrator.steps.do { |s|
        if(s[\optional] != true) {
            c.goTo(LooperCalibrator.stepKeys.indexOf(s[\key]));
            c.register(s[\key], { |lp, done| done.((ok: true, value: 1)) });
            c.run;
        };
    };
    ~tAssert.("an optional step left alone does not block completion",
        c.isComplete);
}.value;

{
    var c = cal.();
    c.goTo(LooperCalibrator.stepKeys.indexOf(\latency));
    c.register(\latency, { |lp, done| done.((ok: false, why: "x")) });
    c.run;
    ~tAssert.("a failed step does block it", c.isComplete.not);
}.value;

{
    var c = cal.();
    c.register(\preflight, { |lp, done| done.((ok: true)) });
    c.run;
    c.reset;
    ~tEq.("reset returns to the first step", c.stepIndex, 0);
    ~tEq.("and forgets what it found", c.statusOf(\preflight), \pending);
}.value;

// ---- the arithmetic ---------------------------------------------------------
{
    var raw = interleaved.(4800, 960, 8);
    var env = LooperCalibrator.envelope(raw, 48, 1, 2);
    var loud = env.maxIndex;
    ~tEq.("the envelope has one bucket per hop", env.size, 100);
    ~tEq.("and the peak lands in the bucket the spike was put in", loud, 20);
    ~tAssert.("with silence either side",
        (env[19] == 0) and: { env[21] == 0 },
        [env[19], env[20], env[21]].asString);
}.value;

{
    // Channels are summed as absolute values: an out-of-phase pair must not
    // cancel into a silence that never happened.
    var raw = Array.fill(200, 0);
    var env;
    8.do { |j| raw[(50 + j) * 2] = 0.8; raw[((50 + j) * 2) + 1] = -0.8 };
    env = LooperCalibrator.envelope(raw, 10, 1, 2);
    ~tAssert.("an out-of-phase transient is still a transient",
        env[5] > 0, env.asString);
}.value;

{
    var env = LooperCalibrator.impulseEnvelope([0.0, 0.5], 1.0, 0.01, 0.05);
    ~tEq.("a known pattern becomes one bucket per hop", env.size, 100);
    ~tAssert.("with a blip at each hit",
        (env[0] > 0) and: { env[50] > 0 }, [env[0], env[50]].asString);
    ~tAssert.("and nothing between them", env[30] == 0, env[30].asString);
    ~tAssert.("the blip decays rather than being one bucket wide",
        env[51] > 0 and: { env[51] < env[50] }, [env[50], env[51]].asString);
}.value;

{
    var a = LooperCalibrator.normalize(pulse.(100, 10));
    var mag = (a.collect { |x| x * x }.sum).sqrt;
    ~tNear.("normalising gives unit length", mag, 1.0, 1e-9);
    ~tNear.("and zero mean", a.sum, 0.0, 1e-9);
}.value;

{
    var flat = LooperCalibrator.normalize(Array.fill(20, 0.5));
    ~tCheck.("a flat signal does not divide by zero", { flat.sum });
    ~tNear.("it comes back as silence", flat.sum, 0.0, 1e-9);
}.value;

{
    // The whole measurement in miniature: b is a's content arriving later, and
    // the reported lag is by how much. Positive = later, the same sign
    // check-chain-align.scd uses, so the two tools cannot disagree.
    var a = LooperCalibrator.normalize(pulse.(200, 40));
    var b = LooperCalibrator.normalize(pulse.(200, 55));
    var r = LooperCalibrator.bestLag(a, b, 50);
    ~tEq.("a later arrival reads as a positive lag", r[0], 15);
    ~tAssert.("with a strong correlation", r[1] > 0.9, r[1].asString);
}.value;

{
    var a = LooperCalibrator.normalize(pulse.(200, 60));
    var b = LooperCalibrator.normalize(pulse.(200, 45));
    ~tEq.("an earlier arrival reads as a negative lag",
        LooperCalibrator.bestLag(a, b, 50)[0], -15);
}.value;

{
    var a = LooperCalibrator.normalize(pulse.(200, 40));
    ~tEq.("a signal against itself reads as no lag",
        LooperCalibrator.bestLag(a, a, 50)[0], 0);
}.value;

{
    // Noise against a transient must come back weak, because that score is the
    // only thing standing between a mis-routed step and a confident wrong
    // number in the profile.
    var a = LooperCalibrator.normalize(pulse.(200, 40));
    var b = LooperCalibrator.normalize(Array.fill(200, { 0.01.rand }));
    var r = LooperCalibrator.bestLag(a, b, 50);
    ~tAssert.("noise correlates weakly", r[1] < 0.5, r[1].asString);
}.value;

{
    ~tNear.("median of an odd count", LooperCalibrator.median([5, 1, 3]), 3, 1e-9);
    ~tNear.("median of an even count",
        LooperCalibrator.median([1, 2, 3, 10]), 2.5, 1e-9);
    ~tAssert.("median of nothing is nothing",
        LooperCalibrator.median([]).isNil);
    ~tNear.("median ignores one wild reading",
        LooperCalibrator.median([10, 10, 10, 10, 900]), 10, 1e-9);
}.value;

// ---- anchoring a recording to the loop --------------------------------------
// The phase channel is the loop's read position in seconds, recorded alongside
// the audio by one RecordBuf. Its first sample says where the loop already was,
// so the downbeat is whatever is left of that pass — and crucially NO wrap has
// to fall inside the recording. The first version looked for a wrap pulse, and
// failed on the rig whenever the window happened to start just after one.
{
    var phase = { |from, to, n = 100| Array.interpolation(n, from, to) };
    ~tNear.("starting at the downbeat, the next one is a whole loop away",
        LooperCalibrator.anchorFromPhase(phase.(0, 1), 3.5), 3.5, 1e-9);
    ~tNear.("starting half way, half a loop remains",
        LooperCalibrator.anchorFromPhase(phase.(1.75, 2.5), 3.5), 1.75, 1e-9);
    ~tNear.("starting just before the boundary, it is imminent",
        LooperCalibrator.anchorFromPhase(phase.(3.49, 3.5), 3.5), 0.01, 1e-9);
}.value;

{
    // A window containing no wrap at all must still anchor — that is the whole
    // point of reading the ramp rather than hunting for a pulse.
    var phase = Array.interpolation(100, 0.5, 1.2);
    ~tNear.("a recording with no wrap in it still anchors",
        LooperCalibrator.anchorFromPhase(phase, 3.5), 3.0, 1e-9);
}.value;

{
    ~tNear.("no loop length means no anchor",
        LooperCalibrator.anchorFromPhase([0.5], 0), 0, 1e-9);
    ~tNear.("a nil loop length means no anchor",
        LooperCalibrator.anchorFromPhase([0.5], nil), 0, 1e-9);
    ~tNear.("a phase past the loop clips rather than going negative",
        LooperCalibrator.anchorFromPhase([99], 3.5), 0, 1e-9);
    ~tCheck.("an empty phase channel does not throw",
        { LooperCalibrator.anchorFromPhase([], 3.5) });
}.value;

{
    // A flat phase channel means nothing was playing, or we read the wrong bus.
    // Either way there is nothing to line the audio up against, and saying so
    // beats returning a number.
    ~tAssert.("a moving phase channel is recognised",
        LooperCalibrator.phaseMoved(Array.interpolation(50, 0, 3.5)));
    ~tAssert.("a flat one is not",
        LooperCalibrator.phaseMoved(Array.fill(50, 1.2)).not);
    ~tAssert.("nor is an empty one", LooperCalibrator.phaseMoved([]).not);
    ~tAssert.("nor is nil", LooperCalibrator.phaseMoved(nil).not);
}.value;

{
    // Crest separates "distinct hits" from "our own loop coming back", which is
    // the mistake that produces a confident wrong number rather than a refusal.
    var clicks = Array.fill(400, 0);
    var dense  = Array.fill(400, { 0.4 + 0.2.rand });
    [0, 100, 200, 300].do { |i| clicks[i] = 1.0 };
    ~tAssert.("a click train has a high crest",
        LooperCalibrator.crest(clicks) > 40,
        LooperCalibrator.crest(clicks).asString);
    ~tAssert.("continuous audio does not",
        LooperCalibrator.crest(dense) < 40,
        LooperCalibrator.crest(dense).asString);
    ~tNear.("silence has no crest rather than dividing by zero",
        LooperCalibrator.crest(Array.fill(10, 0)), 0, 1e-9);
}.value;

// ---- summarising trials -----------------------------------------------------
{
    var r = LooperCalibrator.summarise(
        [[10, 0.9], [10, 0.92], [11, 0.88], [10, 0.9]], 1);
    ~tAssert.("agreeing trials are believed", r[\ok]);
    ~tNear.("and the median is the answer", r[\value], 10, 1e-9);
    ~tNear.("with the spread reported", r[\spread], 1, 1e-9);
}.value;

{
    var r = LooperCalibrator.summarise([[10, 0.1], [10, 0.12]], 1);
    ~tAssert.("a weak correlation is refused", r[\ok].not);
    ~tAssert.("and says the signal was weak",
        r[\why].asString.contains("weak"), r[\why].asString);
    ~tAssert.("while still showing the number it would have given",
        r[\value].notNil);
}.value;

{
    // The reading that matters most: eight trials that disagree is a clock
    // problem, and saying "latency = 31 ms" there would hide it.
    var r = LooperCalibrator.summarise(
        [[10, 0.9], [40, 0.9], [12, 0.9], [38, 0.9]], 1);
    ~tAssert.("trials that disagree are refused", r[\ok].not);
    ~tAssert.("and it is named as a clock problem, not a latency",
        r[\why].asString.contains("clock"), r[\why].asString);
}.value;

{
    var r = LooperCalibrator.summarise([], 1);
    ~tAssert.("no trials at all is refused rather than crashing", r[\ok].not);
    ~tAssert.("and explains itself", (r[\why] ? "").notEmpty);
}.value;

{
    var r = LooperCalibrator.summarise([[4, 0.9], [4, 0.9]], 0.5);
    ~tNear.("buckets are converted to ms by the hop", r[\value], 2, 1e-9);
}.value;

// ---- a rig with no Live (SA) -----------------------------------------------
// The steps that measure Live itself (its sync, its drum rack, its processed
// return) cannot run without it, and say so; the latency step measures the
// whole path either way, so it does not ask for Live there.
{
    var step = { |k| LooperCalibrator.stepAt(k) };
    ~tEq.("the steps that measure Live are marked so",
        LooperCalibrator.steps.select { |s| s[\liveOnly] == true }.collect(_[\key]), [\sync, \noteOffset, \chain]);
    ~tAssert.("on a Live rig every step runs", LooperCalibrator.steps.every { |s| LooperCalibrator.runsOn(s, true) });
    ~tEq.("without Live those three do not, and the rest do",
        LooperCalibrator.steps.reject { |s| LooperCalibrator.runsOn(s, false) }.collect(_[\key]), [\sync, \noteOffset, \chain]);
    ~tEq.("on a Live rig the latency step needs Live, as before",
        LooperCalibrator.needsFor(step.(\latency), true), [\live, \noLoop, \cable]);
    ~tEq.("without Live it needs no Live: the cable and a stopped loop",
        LooperCalibrator.needsFor(step.(\latency), false), [\noLoop, \cable]);
    ~tEq.("...and a step that measures Live still says it needs it",
        LooperCalibrator.needsFor(step.(\sync), false), [\live, \loop, \cueOut]);
    ~tAssert.("the cable is described for the rig: Live's Main Out with Live, the interface's output without",
        LooperCalibrator.needLabel(\cable, true).contains("Live")
            and: { LooperCalibrator.needLabel(\cable, false).contains("Live").not }
            and: { LooperCalibrator.needLabel(\cable, false).contains("output") });
}.value;

// ---- a rig without Live: its own wizard, and what it keeps ------------------
{
    var tmp = PathName.tmp +/+ ("megalooper-test-cal-" ++ thisProcess.pid), path = tmp +/+ "calibration.json";
    var noLive = LooperCalibrator.stepsFor(false), all, cal, looper, why, before, sine;
    File.mkdir(tmp);
    protect {
        ~tEq.("without Live the wizard is four steps: the rig, the input level, the threshold, the round trip",
            noLive.collect(_[\key]), [\preflight, \level, \threshold, \latency]);
        ~tAssert.("...none of which measures Live or needs it, and none asks to write anything down",
            noLive.every { |st| (st[\liveOnly] != true) and: { st[\needs].includes(\live).not } }
                and: { noLive.any { |st| st[\key] == \writeback }.not });
        ~tAssert.("...and its words name no Live, no aggregate and no profile to paste into",
            noLive.every { |st| ([st[\why]] ++ st[\todo]).every { |t| t.contains("Live").not and: { t.contains("ggregate").not }
                and: { t.contains("routingProfiles").not } } });
        ~tEq.("with Live it is the wizard it was", LooperCalibrator.stepsFor(true).collect(_[\key]),
            [\preflight, \threshold, \latency, \sync, \noteOffset, \chain, \writeback]);
        ~tEq.("the threshold and the round trip set the same looper values as with Live",
            [\threshold, \latency].collect { |k| noLive.detect { |st| st[\key] == k }[\field] }, [\onsetThreshold, \latencyMs]);

        // The level, from what came in.
        sine = { |amp| Array.fill(4800, { |i| sin(i * 0.13) * amp }) };
        ~tEq.("the level: silence is nothing coming in", LooperCalibrator.levelOf(sine.(0.001))[\verdict], \silent);
        ~tEq.("...-26 dBFS at the loudest is too quiet", LooperCalibrator.levelOf(sine.(0.05)).atAll([\verdict, \ok]), [\quiet, false]);
        ~tEq.("...-6 dBFS is good", LooperCalibrator.levelOf(sine.(0.5)).atAll([\verdict, \ok, \peakDb]), [\good, true, -6.0]);
        ~tEq.("...a sample at full scale clips", LooperCalibrator.levelOf(sine.(1.2)).atAll([\verdict, \ok]), [\clipped, false]);
        ~tAssert.("...and each says what to turn", [0.05, 1.2].every { |a| LooperCalibrator.levelOf(sine.(a))[\why].contains("input gain") });

        // Kept per rig.
        ~tAssert.("no file: nothing kept", LooperCalibrator.readKept(path).isEmpty);
        why = LooperCalibrator.keep(path, \saSystem, \latencyMs, 31.25);
        LooperCalibrator.keep(path, \saSystem, \onsetThreshold, 0.42);
        LooperCalibrator.keep(path, \standalone, \latencyMs, 12);
        all = LooperCalibrator.readKept(path);
        ~tEq.("a value kept for a rig reads back, with the others of that rig and of another",
            [why, all[\saSystem][\latencyMs], all[\saSystem][\onsetThreshold], all[\standalone][\latencyMs]], [nil, 31.25, 0.42, 12]);
        ~tAssert.("...stamped", all[\saSystem][\savedAt].isString);
        ~tAssert.("...in a file that says what it is", File.readAllString(path).contains("\"megalooper calibration\""));
        ~tAssert.("a field that is no calibration, or no number, is not kept",
            LooperCalibrator.keep(path, \saSystem, \colour, 3).notNil and: { LooperCalibrator.keep(path, \saSystem, \latencyMs, "x").notNil });
        looper = (latencyMs: 0, onsetThreshold: 0.5);
        ~tEq.("a start applies what the rig keeps to the looper",
            [LooperCalibrator.applyKept(looper, path, \saSystem).notNil, looper[\latencyMs], looper[\onsetThreshold]], [true, 31.25, 0.42]);
        ~tEq.("...and nothing for a rig that keeps nothing", LooperCalibrator.applyKept(looper, path, \sa), nil);
        looper = (latencyMs: 0, onsetThreshold: 0.5);
        ~tAssert.("a start without Live applies it, and says so",
            LooperCalibrator.applyKeptAtStart(looper, (live: false), \saSystem, tmp) !? { |said|
                said.contains("latencyMs 31.25") and: { looper[\latencyMs] == 31.25 } } ? false);
        looper = (latencyMs: 0, onsetThreshold: 0.5);
        ~tEq.("...a start with Live does not: its numbers are its profile's",
            [LooperCalibrator.applyKeptAtStart(looper, (latencyMs: 54), \saSystem, tmp), looper[\latencyMs]], [nil, 0]);
        ~tEq.("forgetting a rig leaves the others", [LooperCalibrator.forget(path, \standalone),
            LooperCalibrator.readKept(path).keys.asArray], [nil, [\saSystem]]);
        before = File.readAllString(path);
        File.use(path, "w", { |f| f.write("{\"format\": \"megalooper calibration\", \"version\": 2, \"rigs\": {}}") });
        ~tAssert.("a file from a newer megalooper is not written over", LooperCalibrator.keep(path, \saSystem, \latencyMs, 9).notNil
            and: { File.readAllString(path).contains("\"version\": 2") });
        File.use(path, "w", { |f| f.write(before) });

        // The wizard keeps what it applies, and only without Live.
        looper = (latencyMs: 30, onsetThreshold: 0.5);
        cal = LooperCalibrator(looper, false).keptPath_(path).rig_(\sa);
        ~tEq.("a calibrator without Live has the four steps and shows two numbers",
            [cal.stepCount, cal.calibratedFields, cal.keeps], [4, [\onsetThreshold, \latencyMs], true]);
        cal.register(\latency, { |l, done| done.((ok: true, value: 22.5)) });
        cal.goTo(3);
        cal.run;
        ~tEq.("...a measured round trip is kept when it is applied, not before",
            [LooperCalibrator.readKept(path)[\sa], { cal.apply; LooperCalibrator.readKept(path)[\sa][\latencyMs] }.value, looper[\latencyMs]],
            [nil, 22.5, 22.5]);
        looper[\onsetThreshold] = 0.61;
        cal.goTo(2);
        cal.confirm;
        ~tEq.("...the threshold set by hand, when Done is pressed", LooperCalibrator.readKept(path)[\sa][\onsetThreshold], 0.61);
        looper[\latencyMs] = 27;
        cal.goTo(3);
        cal.confirm;
        ~tEq.("...the round trip set by ear, with Start with this", LooperCalibrator.readKept(path)[\sa][\latencyMs], 27);
        ~tEq.("...and it answers what it keeps", cal.kept[\latencyMs], 27);
        cal.register(\level, { |l, done| done.(LooperCalibrator.levelOf(sine.(0.5))) });
        cal.goTo(1);
        cal.run;
        ~tEq.("the level step is done when the level is good, and keeps nothing", [cal.statusOf(\level), cal.kept.keys.asArray.sort],
            [\done, [\latencyMs, \onsetThreshold, \savedAt]]);
        ~tAssert.("skipping all four completes it", { cal.reset; 4.do { cal.skip }; cal.isComplete }.value);
        ~tEq.("Forget: the rig keeps nothing, and the next start begins with its profile's numbers",
            [cal.forget, cal.kept, LooperCalibrator.applyKept((), path, \sa)], [nil, nil, nil]);
        before = File.readAllString(path);
        cal = LooperCalibrator((latencyMs: 30, onsetThreshold: 0.5), true).keptPath_(path).rig_(\fireface);
        cal.register(\latency, { |l, done| done.((ok: true, value: 50)) });
        cal.goTo(2);
        cal.run;
        cal.apply;
        ~tAssert.("with Live nothing is kept: its wizard writes the line down", cal.keeps.not and: { File.readAllString(path) == before });
    } {
        if(File.exists(path)) { File.delete(path) };
        File.delete(tmp);
    };
}.value;

}.value;
