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
~rp = ~routingProfiles[\saSystem];
~liveRecordToggle = { };

// The take: three bars of 7/8 and one of 8/8 at 103.2, playing, as on the
// website's status band. A hit on most eighths, the downbeats hardest.
tau = 60 / 103.2 / 2;
take = (numerator: 7, denominator: 8, bpm: 103.2, k: 4, sub: 1, n: 29, tau: tau,
    loopDur: 29 * tau, bars: [7, 7, 7, 8], phase: 0, onsetCount: 22);
~looper = ~tLooper.();
~looper.instVarPut(\lastResult, take);
~looper.instVarPut(\loopFrames, (29 * tau * 48000).round.asInteger);
~looper.instVarPut(\state, \playing);
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
    var show = { |view, name, page|
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
        grab.(name);
    };
    // A pane scrolled to its end: the ScrollView round the given widget.
    var scrollDown = { |widget|
        var p = widget;
        while { p.notNil and: { p.isKindOf(ScrollView).not } } { p = p.parent };
        p !? { |sv| sv.visibleOrigin = Point(0, 100000) };
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
        ~effectsPerRow = 7;
    } { |err| failed.add("render: " ++ err.errorString); ("FAILED: " ++ err.errorString).postln };
    ~guiWindow !? { |w| if(w.isClosed.not) { w.close } };
    ("RENDERED " ++ shots.size ++ (if(failed.isEmpty) { "" } { ", FAILED " ++ failed.size })).postln;
    wait.(0.3);
    ~tRemoveTree !? { |f| f.(tmp) };
    (if(failed.isEmpty) { 0 } { 1 }).exit;
}.play(AppClock);
)
