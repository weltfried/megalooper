// megalooper — the manual's screenshots. Builds the whole window as
// check-gui-maptags.scd does, without a rig: a Looper with no server holding
// a staged take, a MegaSA on the harness's recording stub, real drums reading
// the shipped kits. Nothing sounds and no server is touched: the harness
// points Server.default at a port nothing listens on, and the user folder at a
// scratch one. The window is shown fully transparent (a window never shown
// cannot be grabbed), each view is selected in turn and grabbed to a PNG.
//
//   sclang -u 57900 scripts/render-screens.scd [out dir]
//
// The out dir defaults to docs/images/. Quit a running megalooper first.
(
var scripts = Looper.repoRoot +/+ "scripts";
var kitDir = Looper.repoRoot +/+ "presets" +/+ "sa" +/+ "drums" +/+ "kits";
var out = thisProcess.argv[0] ?? { Looper.repoRoot +/+ "docs" +/+ "images" };
var reader = { |srv, path, done|
    done.((bufnum: 100, path: path, numChannels: 2, sampleRate: 48000, numFrames: 48000)) };
var stub, sstub, m, d, tmp, now = 1000.0, take, tau, shots = List.new, failed = List.new;

(scripts +/+ "tests" +/+ "_harness.scd").load;
// The release as it ships, not the tests' fixtures: saSystem and no map.
~routingProfilesExtra = nil;
~midiShippedDirOverride = nil;
[
    "setup-routing.scd", "setup-midi.scd", "setup-model.scd", "setup-sa.scd", "setup-miditargets.scd", "setup-midimap.scd",
    "gui-const.scd", "gui-theme.scd", "gui-presets.scd", "gui-status.scd", "gui-perform.scd",
    "gui-bbcut.scd", "gui-granular.scd", "gui-analysis.scd", "gui-sa.scd", "gui-midimap.scd", "gui-mapmode.scd",
    "gui-effects.scd", "gui-drums.scd", "gui-synth.scd", "gui-rig.scd", "gui-calibrate.scd",
    "gui-shell.scd", "gui-wiring.scd"
].do { |f| (scripts +/+ f).load };
tmp = ~tTempPath.("render-screens");
File.mkdir(tmp);
File.mkdir(out);
~midiUserRootOverride = tmp +/+ "user";
~midiWriteSync = true;
~saFxPresetDir = tmp +/+ "fx";
~saDrumsPresetDir = tmp +/+ "drum-presets";
~saSynthPresetDir = tmp +/+ "synth-presets";
File.mkdir(~saFxPresetDir);
File.mkdir(~saDrumsPresetDir);
~midiNow = { now };
// saSystem: the rig a new user starts Megalooper SA on (the README's).
~routingProfile = \saSystem;
// The Rig page's AUDIO section lists the devices there are: a MacBook's own
// here, never this Mac's, and saSystem as the audio settings make it.
~audioDevicesNow = { (inputs: [(name: "MacBook Pro Microphone", channels: 1)],
    outputs: [(name: "MacBook Pro Speakers", channels: 2)],
    defaultIn: "MacBook Pro Microphone", defaultOut: "MacBook Pro Speakers") };
~rp = ~audioProfile.(~routingProfiles[\saSystem], (), ~audioDevicesNow.());
~liveRecordToggle = { };

// The take: three bars of 7/8 and one of 8/8 at 103.2, playing, as on the
// website's status band. A hit on most eighths, the downbeats hardest.
tau = 60 / 103.2 / 2;
take = (numerator: 7, denominator: 8, bpm: 103.2, k: 4, sub: 1, n: 29, tau: tau,
    loopDur: 29 * tau, bars: [7, 7, 7, 8], phase: 0, onsetCount: 22,
    // Its chords, a bar each, for the Grains' Chords line.
    chordSegments: [[0, 2, "D", \minor], [7, 7, "G", \minor], [14, 10, "A#", \major], [21, 9, "A", \major]]
        .collect { |c| (start: c[0] * tau, root: c[1], rootName: c[2], scale: c[3]) },
    chordPeriod: 29 * tau);
~looper = ~tLooper.();
~looper.instVarPut(\lastResult, take);
~looper.instVarPut(\loopFrames, (29 * tau * 48000).round.asInteger);
~looper.instVarPut(\state, \playing);
// A playhead the position poll can read, parked in bar 2, beat 3, so the
// count is worked out as on the rig: the poll re-anchors on it every 50 ms.
~looper.instVarPut(\engineSynth, ~tStubSynth.(~looper, \looperEngine));
~renderPhase = 9.5 * tau;
~looper.instVarPut(\phaseBus, (get: { |self, action| action.value(~renderPhase) }));
~looper.instVarPut(\onsets, List.newFrom([0, 2, 4, 6, 7, 9, 11, 13, 14, 16, 18, 20, 21, 23, 24, 26, 27, 28]
    .collect { |i| [i * tau, if([0, 7, 14, 21].includes(i)) { 1.0 } { 0.5 }] }));

// Megalooper SA on a stub (saSystem has no bass input), and real drums as
// the Drums view sees them.
stub = ~tStubServer.();
m = ~tMegaSA.(stub);
Routine { m.attachLooper(~looper) }.next;
m.drums.free;
sstub = ~tStubServer.();
d = MegaSADrums((server: sstub));
d.prUseBusses;
d.wallClock = { now };
d.sender = { |t, msgs| };
d.kitDir = kitDir;
d.kitReader = reader;
d.setKit(\steps, 'carbon-layer');
d.setKit(\onset, 'one-hit');
m.instVarPut(\drums, d);
~megaSA = m;
// What setup-sa.scd does at boot: the recorder's master is SA's own mix, so
// Record set says "master + dry tap + events" as on the rig, and loop
// chaining returns the loop after its effects, so Rec next loop is there.
~sessionChannel = m.recordInChannel;
~looper.sessionChannel = ~sessionChannel;
~returnChannel = m.returnInChannel;
~looper.returnChannel = ~returnChannel;
// A sound to look at: two effects on in each chain.
[\delay, \filter, \echo, \saturator].do { |k| m.setFx(k, true) };

~midiSources = IdentityDictionary[1001 -> ["USB MIDI Controller", "USB MIDI Controller"]];
~midiTargets = ~midiTargetsBuild.();
// saSystem names no map: a fresh install's footswitches do nothing yet.
~midiMap = LooperMidiMap([], nil);
~midiKept = ~midiMap;
~midiMapFrom = nil;
~midiMapWarning = nil;
~midiUndo = List.new;
~midiListenFrom.(~midiSettingsRead.());
~effectsSelected = \filter;

Routine {
    var wait = { |s = 0.6| s.wait };
    var grab = { |name|
        var path = out +/+ (name ++ ".png"), img;
        try {
            img = Image.fromWindow(~guiWindow);
            img.write(path, "png");
            img.free;
            shots.add(path);
            ("  wrote " ++ path).postln;
        } { |err| failed.add(name ++ ": " ++ err.errorString); ("  FAILED " ++ name ++ ": " ++ err.errorString).postln };
    };
    var goto = { |view, page|
        ~guiSelectView.(view);
        page !? { |p| ~guiSetupShow.(p) };
        wait.();
        // The bar grid: a moment in bar 2, beat 3, as if the loop played.
        ~guiLoopPhase = 9.5 * tau;
        ~guiLoopPos = Looper.loopPositionAt(~guiLoopPhase, take, ~looper.loopDuration);
        ~statusRefreshAll !? { |f| f.value };
        ~statusRepaintGrids !? { |f| f.value };
        ~rootLabel !? { |v| if(v.isClosed.not) { v.string_("Dm") } };
        wait.(0.3);
    };
    var show = { |view, name, page| goto.(view, page); grab.(name) };
    // A pane scrolled to its end: the ScrollView round the given widget.
    var scrollDown = { |widget|
        var p = widget;
        while { p.notNil and: { p.isKindOf(ScrollView).not } } { p = p.parent };
        p !? { |sv| sv.visibleOrigin = Point(0, 100000) };
    };
    // ---- Parts of the window, for the sections that explain them ----------
    // A part is a view's own rect, or a band of rows: everything between the
    // row of one label and the row of another. Labels find their views, not
    // places, so a layout change moves the crop with it.
    var rectOf = { |v|
        var at = v.mapToGlobal(0@0) - ~guiWindow.view.mapToGlobal(0@0);
        Rect(at.x, at.y, v.bounds.width, v.bounds.height)
    };
    var textOf = { |v|
        var s = try {
            if(v.respondsTo(\states) and: { v.states.notNil }) { v.states[0][0] } {
                if(v.respondsTo(\string)) { v.string } }
        };
        (s ? "").asString
    };
    var leaves = { |root|
        var found = List.new, walk;
        walk = { |v| v.children.do { |c| if(c.visible) { if(c.children.isEmpty) { found.add(c) } { walk.(c) } } } };
        walk.(root);
        found
    };
    var find = { |root, text, nth = 0| leaves.(root).select { |v| textOf.(v) == text }[nth] };
    var label = { |l| if(l.isString) { [l, 0] } { l } };
    // The page's ScrollView moved so that `v` sits near the top.
    var scrollTo = { |v|
        var sv = v.parent;
        while { sv.notNil and: { sv.isKindOf(ScrollView).not } } { sv = sv.parent };
        sv !? { |s|
            s.visibleOrigin = Point(0, (s.visibleOrigin.y + rectOf.(v).top - rectOf.(s).top - 24).max(0));
            wait.(0.3);
        };
    };
    var cropTo = { |r, name, pad = 12|
        var img, path = out +/+ (name ++ ".png"), w = ~guiWindow.view.bounds;
        r = Rect.fromPoints(Point((r.left - pad).max(0), (r.top - pad).max(0)),
            Point((r.right + pad).min(w.width), (r.bottom + pad).min(w.height)));
        try {
            img = Image.fromWindow(~guiWindow, r);
            img.write(path, "png");
            img.free;
            shots.add(path);
            ("  wrote " ++ path ++ " (" ++ r.width.round ++ " x " ++ r.height.round ++ " pt)").postln;
        } { |err| failed.add(name ++ ": " ++ err.errorString); ("  FAILED " ++ name ++ ": " ++ err.errorString).postln };
    };
    var part = { |view, name, pad = 0|
        var r;
        if(view.isNil) { failed.add(name ++ ": no view"); ("  FAILED " ++ name ++ ": no view").postln } {
            // Down to its last widget: a pane stretched to the page's foot
            // ends in nothing.
            scrollTo.(view);
            r = rectOf.(view);
            r.height = (leaves.(view).collect { |v| rectOf.(v).bottom }.maxItem ? r.bottom) + 16 - r.top;
            cropTo.(r.height_(r.height.min(rectOf.(view).height)), name, pad)
        }
    };
    // The rows from `top`'s to `bottom`'s (or up to it, with through false),
    // as wide as what they hold. A label is a string, or [string, nth].
    var band = { |root, top, bottom, name, through = true, pad = 8|
        var a, b, y0, y1, rects;
        a = find.(root, *label.(top));
        b = find.(root, *label.(bottom));
        if(a.isNil or: { b.isNil }) {
            failed.add(name ++ ": no label '" ++ (if(a.isNil) { top } { bottom }) ++ "'");
            ("  FAILED " ++ name ++ ": no label").postln;
        } {
            scrollTo.(a);
            y0 = rectOf.(a).top;
            y1 = if(through) { rectOf.(b).bottom } { rectOf.(b).top - 2 };
            // Rules (a pixel or two high) are no content: one under the
            // last row would stretch the crop to it.
            rects = leaves.(root).collect(rectOf).select { |q| (q.top < y1) and: { q.bottom > y0 } and: { q.height > 2 } };
            cropTo.(rects.inject(rects[0], { |u, q| u.union(q) }), name, pad);
        }
    };
    // One effect's panel (~effectsEditor) in a window of its own, as small
    // as its layout lets it be, grabbed down to the last widget it draws.
    var panel = { |key|
        var w, view, origin, walk, img, right = 0, bottom = 0;
        var path = out +/+ ("fx-" ++ key.asString.toLower ++ ".png");
        try {
            ~effectsSelected = key;
            ~effectsWidgets = IdentityDictionary.new;
            view = ~effectsEditor.(key);
            w = Window("panel", Rect(0, 0, 100, 100), border: false).background_(~gt[\bg]);
            w.layout_(VLayout(view).margins_(24));
            w.alpha_(0).visible_(true);
            wait.(0.5);
            origin = w.view.mapToGlobal(0@0);
            walk = { |v|
                v.children.do { |c|
                    var at;
                    if(c.visible) {
                        if(c.children.isEmpty) {
                            at = c.mapToGlobal(0@0);
                            right = max(right, at.x - origin.x + c.bounds.width);
                            bottom = max(bottom, at.y - origin.y + c.bounds.height);
                        } { walk.(c) }
                    }
                }
            };
            walk.(view);
            img = Image.fromWindow(w, Rect(0, 0, right + 24, bottom + 24));
            img.write(path, "png");
            img.free;
            shots.add(path);
            ("  wrote " ++ path ++ " (" ++ (right + 24) ++ " x " ++ (bottom + 24) ++ " pt)").postln;
        } { |err| failed.add(key ++ ": " ++ err.errorString); ("  FAILED " ++ key ++ ": " ++ err.errorString).postln };
        w !? { |x| if(x.isClosed.not) { x.close } };
    };
    try {
        // The builders whose views are parts below: kept as they are made.
        ~renderParts = IdentityDictionary.new;
        [\buildStatusBand, \buildBBCutPane, \buildGranularPane, \buildAnalysisPane, \buildDrumsPane,
            \buildSynthPane, \buildMidiMapSection, \rigAiSection].do { |k|
            var f = currentEnvironment[k];
            currentEnvironment[k] = { |...args| var v = f.valueArray(args); ~renderParts[k] = v; v };
        };
        ~buildGuiWindow.(false);
        wait.();
        ~guiWindow.alpha_(0).visible_(true);
        ~guiWindow.bounds = Rect(0, 0, 1440, 900);
        wait.(1);
        d.setNotesOn(true);
        show.(\perform, "perform");
        show.(\sound, "sound");
        show.(\fx, "fx");
        show.(\drums, "drums");
        show.(\synth, "synth");
        scrollDown.(~synthWidgets[\wave_waveCutoff][\view]);
        wait.(0.3);
        grab.("synth-wave");
        show.(\setup, "setup-rig", \rig);
        show.(\setup, "setup-analysis", \analysis);
        show.(\setup, "setup-midi", \midi);
        show.(\calibrate, "calibrate");
        // Each effect's panel on its own, for the top of its section in
        // docs/effects.md: the editor the FX view shows under the chains,
        // built in a window of its own, four settings to a row so it reads
        // at the manual's width. Cropped to what it draws.
        ~guiSelectView.(\fx);
        wait.();
        ~effectsPerRow = 4;
        MegaSAFx.keys.do { |key| panel.(key) };
        // The effects in no chain to begin with: each put in for its panel,
        // taken out again, so the other views stay as they are.
        MegaSAFx.extraKeys.do { |key|
            ~megaSA.insertDevice(\guitar, nil, key);
            wait.(0.3);
            panel.(key);
            ~megaSA.removeDevice(key);
            wait.(0.3);
        };
        ~effectsPerRow = 7;
        // Parts of views, each for the section that explains it.
        goto.(\perform);
        part.(~renderParts[\buildStatusBand], "status-band");
        // The count-in: the next loop armed, the playhead in the last bar, its
        // third group (bar 4 is 2+2+2+2), two groups to go. The boundary is
        // counted from loopStartTime, so that is put where this playhead
        // says the loop began.
        ~renderPhase = 25.5 * tau;
        ~looper.instVarPut(\loopStartTime, SystemClock.seconds - ~renderPhase);
        ~looper.instVarPut(\nextRecState, \armed);
        wait.(0.3);
        cropTo.(rectOf.(~statusCountView).union(rectOf.(~guiPositionView)), "count-in");
        ~looper.instVarPut(\nextRecState, \idle);
        ~renderPhase = 9.5 * tau;
        wait.(0.3);
        part.(find.(~guiWindow.view, "BREAK LOOPS") !? { |v| v.parent }, "perform-actions");
        part.(find.(~guiWindow.view, "○ Record set"), "record-set");
        goto.(\sound);
        part.(~renderParts[\buildBBCutPane], "cutter");
        part.(~renderParts[\buildGranularPane], "grains");
        goto.(\drums);
        band.(~renderParts[\buildDrumsPane], "KITS", "MIX", "drum-kits", false);
        goto.(\synth);
        band.(~renderParts[\buildSynthPane], "Key", "Key", "synth-key");
        band.(~renderParts[\buildSynthPane], "STEPS AND LANES", "Condition", "synth-lanes");
        goto.(\setup, \analysis);
        band.(~renderParts[\buildAnalysisPane], "Analysis", "Overdub meter detection", "onsets", false);
        band.(~renderParts[\buildAnalysisPane], "Onset notes → onset kit", "Pitch range · Hz", "onset-notes", false);
        goto.(\setup, \midi);
        part.(~renderParts[\rigAiSection], "ai-apps");
        // The MIDI parts show the shipped map, keys-and-knobs, and its tags.
        ~midiMap = ~midiMapLoad.("keys-and-knobs")[\map];
        ~midiKept = ~midiMap;
        ~midiMapFrom = \shipped;
        ~midiChanged.(\map);
        wait.(0.6);
        part.(~renderParts[\buildMidiMapSection], "midi-map");
        goto.(\perform);
        ~mapModeOn.();
        wait.(0.6);
        part.(find.(~guiWindow.view, "BREAK LOOPS") !? { |v| v.parent }, "map-mode");
        ~mapModeOff.();
    } { |err| failed.add("render: " ++ err.errorString); ("FAILED: " ++ err.errorString).postln };
    ~guiWindow !? { |w| if(w.isClosed.not) { w.close } };
    ("RENDERED " ++ shots.size ++ (if(failed.isEmpty) { "" } { ", FAILED " ++ failed.size })).postln;
    wait.(0.3);
    ~tRemoveTree !? { |f| f.(tmp) };
    (if(failed.isEmpty) { 0 } { 1 }).exit;
}.play(AppClock);
)
