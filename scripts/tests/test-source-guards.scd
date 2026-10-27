// Source-level guards: the duplication that was collapsed stays collapsed.
//
// These assertions used to police four agreeing copies of the onset-detection
// chain, and mono/stereo SynthDef pairs that were expected to differ only in
// their input expression. The copies are gone — each of those things has one
// definition now — so the guards assert the stronger property: that nobody has
// reintroduced a second one.
//
// This file reads classes/Looper.sc as text. What the graphs actually COMPILE
// to is covered by test-synthdefs.scd, which is the assertion that matters for
// behaviour; this one is about keeping the source honest.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-source-guards");

{
var root = thisProcess.nowExecutingPath.dirname.dirname.dirname;
var src = File.readAllString(root +/+ "classes" +/+ "Looper.sc");
var stripComments, flat, countOf, bare;

// Drop // comments to end of line. Looper's SynthDefs contain no string
// literals, so there is no "//" to protect here.
stripComments = { |text|
    text.split($\n).collect { |line|
        var i = line.find("//");
        if(i.isNil) { line } { line.copyRange(0, i - 1) };
    }.join("\n");
};

// Collapse whitespace runs to one space so indentation and line breaks cannot
// make two identical expressions compare different. Array operations rather
// than a char loop building a String with ++, which is quadratic over a file
// this size — it turned a millisecond of work into a hang.
flat = { |text|
    text.replace("\t", " ").replace("\n", " ").replace("\r", " ")
        .split($ ).reject(_.isEmpty).join(" ")
};

countOf = { |text, needle|
    var n = 0, i = 0;
    while { i.notNil } {
        i = text.find(needle, false, i);
        if(i.notNil) { n = n + 1; i = i + 1 };
    };
    n
};

bare = flat.(stripComments.(src));

// ---- 1. one onset-detection chain ---------------------------------------

// Four defs need this chain: both recorders, the analysis monitor that drives
// the tuning scope, and the overdub analyser. If the monitor ever detects
// differently from the recorder then the scope lies about what a take will
// actually detect, and onset quality is the limiting factor on meter detection.
// One definition is how that is now guaranteed rather than remembered.
~tEq.("Onsets.kr appears exactly once", countOf.(bare, "Onsets.kr("), 1);
~tAssert.("...and the chain is the calibrated one",
    bare.contains(
        "Onsets.kr(FFT(LocalBuf(512), sig), threshold, \\rcomplex, mingap: 20)"),
    "the single chain no longer reads as expected — check prOnsetTrig");
~tAssert.("the threshold is still an ARGUMENT, not a constant",
    bare.contains("*prOnsetTrig { |sig, threshold|"),
    "a hard-coded threshold would make the tuning slider a no-op");
~tEq.("three call sites share it (rec graph, monitor, overdub analysis)",
    countOf.(bare, "Looper.prOnsetTrig("), 3);

// ---- 2. one onset-salience measure --------------------------------------

// The same envelope feeds MeterAnalyzer's accent test and the analysis
// window's readout, so the number on screen is only honest while there is one.
~tEq.("the salience envelope is defined once",
    countOf.(bare, "0.001, 0.1"), 1);
~tEq.("two call sites share it (recorder, monitor) plus the overdub analyser",
    countOf.(bare, "Looper.prOnsetStrength("), 3);

// ---- 3. one way to read the loop input ----------------------------------

// Six defs read the guitar. prInput is the only place that decides whether
// that is one hardware channel doubled or a stereo pair.
~tEq.("the stereo input form appears once",
    countOf.(bare, "SoundIn.ar([ch, ch + 1])"), 1);
~tEq.("the mono input form appears once",
    countOf.(bare, "SoundIn.ar(ch).dup"), 1);
~tEq.("three graph builders share it",
    countOf.(bare, "Looper.prInput(mono,"), 3);

// ---- 4. each graph builder is instantiated exactly twice ----------------

// One graph function, two SynthDef names. This is what replaced three pairs of
// near-identical defs, and it is also why the mono/stereo choice can stay a
// language-side flag: SoundIn's channel count is fixed when the graph is built,
// so it could never have been an argument inside a single def.
[\prRecGraph, \prRecPlainGraph, \prEngineGraph].do { |builder|
    // "|mono" and not "|mono|": the engine's builder takes two more arguments
    // after it (its interpolations, 2026-10-27).
    ~tEq.(builder ++ " is defined once",
        countOf.(bare, "*" ++ builder ++ " { |mono"), 1);
    ~tEq.(builder ++ " is instantiated for stereo",
        countOf.(bare, "Looper." ++ builder ++ "(false)"), 1);
    ~tEq.(builder ++ " is instantiated for mono",
        countOf.(bare, "Looper." ++ builder ++ "(true)"), 1);
};

// And the six names still exist, because the rest of the class picks between
// them by name at spawn time.
[\looperRec, \looperRecMono, \looperRecPlain, \looperRecPlainMono,
 \looperEngine, \looperEngineMono].do { |name|
    ~tEq.(name ++ " is still defined", countOf.(bare, "SynthDef(\\" ++ name ++ ","), 1);
};
~tAssert.("the mono/stereo choice is still made from inChannelCount",
    bare.contains("inChannelCount == 1"),
    "nothing selects the mono defs any more");

// ---- 5. the dead voice-0 wrappers stay dead -----------------------------

// Four setters forwarded to voice 0 under a comment claiming existing bindings
// depended on them. Nothing referenced them: the GUI uses setVoiceParam and the
// only dynamic dispatch in the scripts is the granular parameter table.
[\bbcutSdiv_, \bbcutPhraseBars_, \bbcutStutterChance_, \bbcutStutterSpeed_].do { |sel|
    ~tEq.(sel ++ " is gone", Looper.findRespondingMethodFor(sel), nil);
};

// ---- 6. every intensity key is read through prVoiceDensity --------------

// A proc that declares an intensityKey must actually READ that parameter through
// prVoiceDensity in its build closure. Declaring the key and leaving the closure
// reading p[\key] directly would be silent: the cutter would simply ignore the
// pedal, and every unit test would still pass, because the spec table and the
// closure are only connected by this convention.
{
    var l = ~tLooper.();
    var order = l.bbcutProcOrder;
    var declared = 0;
    // Each proc's own slice of the spec table. Searching the whole file would be
    // wrong, not merely loose: `rollchance` is a parameter of BOTH break and
    // choose, so a file-wide search for a raw read finds break's legitimate one
    // and blames choose for it. That false positive is what this slicing fixes.
    var regionOf = { |proc|
        var here = bare.find(proc.asString ++ ": (");
        var i    = order.indexOf(proc);
        var next = if(i < (order.size - 1)) {
            bare.find(order[i + 1].asString ++ ": (")
        } { nil };
        if(here.isNil) { nil } {
            bare.copyRange(here, (next ? bare.size) - 1)
        };
    };
    order.do { |proc|
        var key = l.bbcutProcSpecs[proc][\intensityKey];
        if(key.notNil) {
            var region = regionOf.(proc);
            var wanted = "this.prVoiceDensity(voice, \\" ++ key.asString ++ ")";
            var raw    = "{ p[\\" ++ key.asString ++ "] }";
            declared = declared + 1;
            ~tAssert.(proc.asString ++ ": its spec was found in the source",
                region.notNil);
            if(region.notNil) {
                ~tAssert.(proc.asString ++ ": its build closure reads "
                    ++ key.asString ++ " through prVoiceDensity",
                    region.contains(wanted), "expected to find: " ++ wanted);
                // And not ALSO the raw way, which would leave two readers of one
                // parameter disagreeing about whether the pedal applies.
                ~tAssert.(proc.asString ++ ": and does not still read it raw",
                    region.contains(raw).not, "found a raw " ++ raw ++ " as well");
            };
        };
    };
    ~tAssert.("the intensity guard actually checked something", declared > 0,
        "no proc declares an intensityKey");
}.value;

// ---- 7. nobody's home directory is in the source ------------------------

// Five files used to carry one developer's absolute home path as the fallback
// for a nil thisProcess.nowExecutingPath. They are Looper.repoRoot now, which
// derives the path from where this class file actually is. The literal is easy
// to reintroduce by copy-paste from a post window, and on anyone else's machine
// it resolves to nothing, so assert it stays gone. The drum kits' JSON files
// are tracked too, and they say where their samples came from: the importer
// writes those paths with the tilde, and a home path there would put a user
// name in the repository.
//
// The needle is assembled at run time on purpose: spelled out, it would appear
// in this file and the guard would flag itself.
~tCheck.("no absolute home path in any tracked source file", {
    var needle = "/" ++ "Users" ++ "/";
    var offenders = List.new;
    [["classes", "*.sc"], ["scripts", "*.scd"], ["scripts/tests", "*.scd"], ["scripts/sa", "*.scd"],
     ["tools", "*.sh"], ["tools", "*.py"], ["presets/sa/drums/kits", "*.json"]].do { |pair|
        (root +/+ pair[0] +/+ pair[1]).pathMatch.do { |path|
            var text = File.readAllString(path);
            // That prefix only ever appears here as somebody's home directory;
            // documentation referring to ~/Library is written with the tilde.
            if(text.notNil and: { text.contains(needle) }) {
                offenders.add(PathName(path).fileName);
            };
        };
    };
    if(offenders.notEmpty) {
        Error("absolute home paths in: " ++ offenders.asArray.join(", ")).throw;
    };
});
// A folder that moved would leave its pattern matching nothing, and the guard
// passing on nothing.
~tAssert.("the scan reaches the drum kits' files and the SA scripts",
    ((root +/+ "presets/sa/drums/kits/*.json").pathMatch.size > 0)
        and: { (root +/+ "scripts/sa/*.scd").pathMatch.size > 0 });
}.value;

// ---- 8. no script frees every node on the server ------------------------
// ~calScanInputs ended with srv.freeAll, which freed every node: the Looper's
// engine and master, and on SA the guitar chain with Bias FX, the drums and
// the mixer, with nothing to rebuild them, from one button on the Calibrate
// view. A helper frees what it made. Comments are dropped first, so a note
// about freeAll does not trip this; MIDIdef.freeAll clears MIDI responders,
// not nodes, and the offline renders under scripts/sa build their own scores.
{
var root = thisProcess.nowExecutingPath.dirname.dirname.dirname;
var offenders = List.new;
(root +/+ "scripts" +/+ "*.scd").pathMatch.do { |path|
    var text = File.readAllString(path) ? "";
    text.split($\n).do { |line, i|
        var cut = line.find("//");
        var code = if(cut.isNil) { line } { line.copyRange(0, cut - 1) };
        if(code.contains(".freeAll") and: { code.contains("MIDIdef.freeAll").not }) {
            offenders.add(PathName(path).fileName ++ ":" ++ (i + 1));
        };
    };
};
~tAssert.("no script calls a server-wide freeAll", offenders.isEmpty,
    "found at " ++ offenders.asArray.join(", "));
~tAssert.("...and the scan still frees the synth it made",
    File.readAllString(root +/+ "scripts" +/+ "calibrate-measure.scd").contains("scan.free;"));
}.value;
