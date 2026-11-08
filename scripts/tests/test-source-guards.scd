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

// The same measure feeds MeterAnalyzer's accent test, the onset notes'
// velocities and the analysis window's readout, so the number on screen is
// only honest while there is one. Since 2026-11-05 it is the RMS around the
// hit, read 30 ms after the trigger (prOnsetStrength, prOnsetReport).
~tEq.("the salience measure is defined once",
    countOf.(bare, "RunningSum.rms("), 1);
~tEq.("two call sites share it (recorder, monitor) plus the overdub analyser",
    countOf.(bare, "Looper.prOnsetStrength("), 3);
~tEq.("...and all three report on the delayed trigger",
    countOf.(bare, "Looper.prOnsetReport(trig)"), 3);
~tAssert.("the old envelope at the trigger is gone",
    bare.contains("0.001, 0.1)").not,
    "Amplitude.kr(sig, 0.001, 0.1) read the waveform's phase — see prOnsetStrength");

// ---- 2b. one automatic level --------------------------------------------

// Every detector hears the tap at the same level, or the lamp lies about
// what a take will detect and an overdub detection disagrees with a take.
~tEq.("the tap gain is read in one way",
    countOf.(bare, "In.kr(bus.max(0))"), 1);
~tEq.("...by all three detectors (rec graph, monitor, overdub analysis)",
    countOf.(bare, "Looper.prTapGain(tapGainBus)"), 3);
~tEq.("...and every spawn of them passes the bus",
    countOf.(bare, "\\tapGainBus, this.prTapGainIndex"), 3);

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

// One way to drive a control (docs/dev/architecture.md, 5, step 1): the keys,
// the Perform pane, the top bar, the status band, the Grains, Cutter, Synth,
// Drums and FX panes, the SA strips and Setup's Analysis page press their
// controls through the command layer
// (~controlDo), so a key, a tile and a footswitch mean the same thing. A
// widget's action calling the Looper or SA's models itself again is the drift
// this ended: the keys calling Looper selectors of their own, Perform's drums
// tile a method its footswitch did not. Reads (a painter asking the model) are
// not actions and are left alone, and so is what no control drives yet (the
// list below): when one of those gets a control, its widget moves to
// ~controlDo and leaves the list. Only one-line actions are seen.
{
var root = thisProcess.nowExecutingPath.dirname.dirname.dirname;
var models = ["~looper !?", "~looper.", "~megaSA !?", "~megaSA.", "~drumsModel !?", "~synthModel !?",
    "~drumsModel.()", "~synthModel.()", "~synthWave.()"];
// No control drives these: the cutter's voice editor (its voices come and
// go), the onset notes' channel and offset, the chords' window, the note
// sequencer's switches and boxes that have none (triplet, dotted, scale, first,
// last), the instrument menu, the drums' repeat grid and their kept dice, and
// the chains' edits (a device inserted; moving and removing one are menu items
// that drive the models in lines this guard does not read).
var noControl = ["setVoiceSynth(", "setVoiceRatio(", "setVoiceAmp(", "onsetNoteChannel =",
    "onsetNoteOffsetMs =", "chordMinPerWindow =", "setNoteSetting(name, bt.value", "setNoteSetting(name, n.value",
    "setInstrument(", "setRepeatGrid(", "keepDice(", "insertDevice(", "insertPlugin("];
var direct = { |file, isAction|
    var found = List.new;
    (File.readAllString(root +/+ "scripts" +/+ file) ? "").split($\n).do { |line, i|
        var cut = line.find("//");
        var code = if(cut.isNil) { line } { line.copyRange(0, cut - 1) };
        if(isAction.(code) and: { models.any { |m| code.contains(m) } }
            and: { noControl.any { |n| code.contains(n) }.not }) { found.add(file ++ ":" ++ (i + 1)) };
    };
    found.asArray
};
var widget = { |code| code.contains(".action_({") or: { code.contains("action: {") } };
var widgets = ["gui-perform.scd", "gui-shell.scd", "gui-status.scd", "gui-granular.scd", "gui-bbcut.scd",
    "gui-analysis.scd", "gui-sa.scd", "gui-synth.scd", "gui-drums.scd", "gui-effects.scd"].collect { |f| direct.(f, widget) }.flatten;
var keys = direct.("gui-shell.scd", { |code| code.contains("{ char == $") });
~tAssert.("the widgets of Perform, the top bar, the status band, Grains, Cutter, Analysis, the SA strips, Synth, Drums and FX drive their controls through ~controlDo",
    widgets.isEmpty, "found at " ++ widgets.join(", "));
~tAssert.("…and the keys do too", keys.isEmpty, "found at " ++ keys.join(", "));
~tAssert.("…and the guard reads the widgets it guards",
    (File.readAllString(root +/+ "scripts" +/+ "gui-perform.scd") ? "").contains("~controlDo.(id, \\press, nil, \\gui)"));
}.value;

// A drum preset has two timings on purpose (the player's decision,
// 2026-11-08): picked from the Drums view's menu it loads at once, from its
// MIDI controls it lands on the next bar line. Not one command that drifted:
// unifying the two must not change either (docs/dev/architecture.md, 6).
{
var root = thisProcess.nowExecutingPath.dirname.dirname.dirname;
var drums = File.readAllString(root +/+ "scripts" +/+ "gui-drums.scd") ? "";
var targets = File.readAllString(root +/+ "scripts" +/+ "setup-miditargets.scd") ? "";
var family = drums.find("~definePresetFamily.(\\saDrums,") !? { |i| drums.copyRange(i, (i + 600).min(drums.size - 1)) } ? "";
~tAssert.("the Drums view's preset menu loads a preset at once (loadPreset)",
    family.contains("load:       \\loadPreset,"), family.copyRange(0, 80));
~tAssert.("…and its MIDI controls recall one on the next bar line (recallPreset)",
    targets.contains("d.recallPreset(dir.value, slug)"));
}.value;

// A pane that drives through the command layer needs it loaded: a script
// that loads one without setup-miditargets.scd finds ~controlDo nil, and a
// nil called in sclang answers nil, so every widget would do nothing without
// a word (check-gui-drums.scd did, 2026-11-08). The scripts that build the
// window's panes load every part through parts.scd now (below); this still
// holds one that would build a pane from parts it loads one by one. (Loading
// a gui file only for its functions, as some tests do for tables that belong
// lower down, needs no command layer: step 2 moves those.)
{
var root = thisProcess.nowExecutingPath.dirname.dirname.dirname;
var scripts = root +/+ "scripts";
var panes = (scripts +/+ "gui-*.scd").pathMatch.select { |path|
    (File.readAllString(path) ? "").contains("~controlDo.(")
}.collect { |path| PathName(path).fileName };
var loaders = ((scripts +/+ "*.scd").pathMatch ++ (scripts +/+ "tests" +/+ "*.scd").pathMatch
    ++ (scripts +/+ "sa" +/+ "*.scd").pathMatch).reject { |path| PathName(path).fileName.beginsWith("gui-") };
var missing = loaders.select { |path|
    var text = File.readAllString(path) ? "";
    var builds = text.contains("~buildGuiWindow.(") or: { text.findRegexp("~build[A-Z][A-Za-z]*Pane\\.\\(").notEmpty };
    builds and: { panes.any { |pane| text.contains("\"" ++ pane ++ "\"") } }
        and: { text.contains("\"setup-miditargets.scd\"").not }
        and: { text.contains("~megalooperLoadParts.(").not }
}.collect { |path| PathName(path).fileName };
~tAssert.("the panes that drive through ~controlDo are found", panes.size >= 5, panes.asString);
~tAssert.("every script that builds one of them loads the command layer (setup-miditargets.scd) too",
    missing.isEmpty, "missing in " ++ missing.join(", "));
}.value;

// One list of the parts (docs/dev/architecture.md, 5, step 3): parts.scd.
// Boot, the checks and the tests load the window's parts through it, so none
// can leave one out unknowingly. Every setup- and gui- file is in it, every
// file it lists is there, and no other script lists parts of its own: three
// part names in a row, as a list to load has them. (This file names the
// files it reads, which is no list to load.)
{
var root = thisProcess.nowExecutingPath.dirname.dirname.dirname;
var scripts = root +/+ "scripts";
var parts = (scripts +/+ "parts.scd").load;
var onDisk = ((scripts +/+ "setup-*.scd").pathMatch ++ (scripts +/+ "gui-*.scd").pathMatch)
    .collect { |path| PathName(path).fileName }.sort;
var listing = { |text|
    text.findRegexp("\"(setup|gui)-[a-z-]+\\.scd\"[ \t]*,[ \t\n]*\"(setup|gui)-[a-z-]+\\.scd\"[ \t]*,[ \t\n]*\"(setup|gui)-[a-z-]+\\.scd\"").notEmpty
};
var listers = ((scripts +/+ "*.scd").pathMatch ++ (scripts +/+ "tests" +/+ "*.scd").pathMatch
    ++ (scripts +/+ "sa" +/+ "*.scd").pathMatch).reject { |path|
    ["parts.scd", "test-source-guards.scd"].includesEqual(PathName(path).fileName)
}.select { |path| listing.(File.readAllString(path) ? "") }.collect { |path| PathName(path).fileName };
var boot = File.readAllString(scripts +/+ "boot.scd") ? "";
~tAssert.("parts.scd answers the parts", parts.isKindOf(Array) and: { parts.size >= 20 }, parts.asString);
~tEq.("every setup- and gui- file is a part, and every part is a file", (parts ? []).copy.sort, onDisk);
~tEq.("…each once", (parts ? []).asSet.size, (parts ? []).size);
~tAssert.("no script lists parts of its own", listers.isEmpty, "found in " ++ listers.join(", "));
~tAssert.("boot.scd loads every part through parts.scd",
    boot.contains("\"parts.scd\").load") and: { boot.contains("~megalooperLoadParts.(~megalooperScripts)") });
~tAssert.("…and the guard sees a list where there is one",
    listing.("[\"setup-a.scd\", \"gui-b.scd\",\n    \"gui-c.scd\"]") and: { listing.("\"gui-b.scd\"").not });
}.value;


// The setup scripts stand below the window (docs/dev/architecture.md, 5,
// step 2): none reads a global that only a gui file defines. 54 did at the
// review (a MIDI control's law was a pane's, the settings' helpers the
// theme's); 24 were named when this guard came in, 10 after step 4's first
// parts. What is left is named here, and the list only shrinks: a name no
// setup script reads from the window any more fails until it is taken off.
// Left: the window's own controls (Show a view) and its view in the set's
// header, the MIDI monitor's feed, the AI's preset shown in a bar, and the
// count's state, which the status band computes.
{
var root = thisProcess.nowExecutingPath.dirname.dirname.dirname;
var scripts = root +/+ "scripts";
var allowed = [
    // a setup script reading or showing the window itself (step 4; the
    // analysis' export fields and key, the Grains' chords line, the fallback
    // and new-loop switches, the status line's words and the AI and action
    // log switches are the window's own now, through ~app)
    \guiView, \presetShow, \presetFamilies,
    \midiMonitorPush,
    // the window's own controls, which drive the window (Show a view)
    \guiSelectView, \guiViewOrder, \guiWindow,
    // the count's state, computed in the status band
    \countLights, \countLightClock, \countPosAt
];
var code = { |path|
    (File.readAllString(path) ? "").split($\n).collect { |line|
        var cut = line.find("//");
        if(cut.isNil) { line } { line.copyRange(0, cut - 1) }
    }.join("\n")
};
var assigned = { |text|
    text.findRegexp("~[a-z][A-Za-z0-9_]*[ \t]*=[^=]").collect { |m|
        m[1].copyRange(1, m[1].size - 1).split($=).first.stripWhiteSpace.asSymbol
    }.asSet
};
var used = { |text|
    text.findRegexp("~[a-z][A-Za-z0-9_]*").collect { |m| m[1].copyRange(1, m[1].size - 1).asSymbol }.asSet
};
var setupFiles = (scripts +/+ "setup-*.scd").pathMatch;
var guiFiles = (scripts +/+ "gui-*.scd").pathMatch;
var bySetup = Set.new, byGui = Set.new, usedBySetup = Set.new, offenders = List.new, stale;
setupFiles.do { |p| bySetup = bySetup | assigned.(code.(p)) };
guiFiles.do { |p| byGui = byGui | assigned.(code.(p)) };
setupFiles.do { |p|
    var name = PathName(p).fileName;
    used.(code.(p)).do { |g|
        usedBySetup.add(g);
        if(byGui.includes(g) and: { bySetup.includes(g).not } and: { allowed.includes(g).not }) {
            offenders.add(name ++ ": ~" ++ g)
        };
    };
};
// Named, but no setup script reads it from the window any more: off the list.
stale = allowed.reject { |g| byGui.includes(g) and: { bySetup.includes(g).not } and: { usedBySetup.includes(g) } };
~tAssert.("no setup script reads a global only a gui file defines, past the named ones",
    offenders.isEmpty, offenders.asArray.sort.join(", "));
~tAssert.("…and every named one is still such a global (the list only shrinks)", stale.isEmpty,
    "no longer: " ++ stale.join(", "));
~tAssert.("…and the scan sees the window's globals", byGui.includes(\guiWindow) and: { bySetup.includes(\looper) });
}.value;
