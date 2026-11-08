// megalooper — boot the server, build the instrument, open the windows.
//
// This file is the orchestrator and nothing else. The parts live beside it,
// listed in their order in parts.scd, the one list the checks and tests load
// too; each part only DEFINES functions, so loading is free and the call order
// below is the whole startup sequence. What each part holds is said beside its
// name there.
//
// The GUI is ONE window (docs/dev/stage-ui.md): a top bar, Perform's status band
// (folded to a strip on the other views), four views of panes — Perform,
// Sound, FX and Drums on Megalooper SA, Setup — and the Calibrate wizard, one of
// them visible at a time (keys 1-6), over a footer with the keys and a status
// line. gui-shell.scd is the only file that constructs a Window; every other
// gui file builds a View.
//
// Re-running THIS file rebuilds everything, which frees the Looper and so
// DESTROYS THE RECORDED LOOP. To iterate on one part without losing the loop,
// re-evaluate that part's file and call its builder:
//
//   ~buildGuiWindow.();       // rebuild the whole window, loop untouched
//   ~buildPerformPane.();     // rebuild one pane IN PLACE; the others, the
//   ~buildBBCutPane.();       // header and the running audio are untouched
//   ~buildGranularPane.();
//   ~buildAnalysisPane.();
//   ~buildRigPane.();
//   ~wireLooperController.(); // re-subscribe the GUI after rebuilding a pane
//   ~setupMidiBindings.();    // rebuild every MIDIdef
//
// Rig setup — the TotalMix loopback, the Loopback bridge, the BlackHole
// aggregates, and what the three channel roles mean — is in docs/routing.md.

// Project root, resolved ONCE here at top level. thisProcess.nowExecutingPath is
// nil inside deferred/async contexts (everything under s.waitForBoot), so it has
// to be captured synchronously and passed down rather than re-read later. Falls
// back to an absolute path when the script path is unknown (e.g. pasted into the
// IDE rather than opened from disk).
~megalooperRoot = thisProcess.nowExecutingPath !? { |p| p.dirname.dirname }
    ?? { Looper.repoRoot };
~megalooperScripts = ~megalooperRoot +/+ "scripts";

// A test file evaluated in this interpreter leaves megalooper's folder moved
// to a scratch one (scripts/tests/_harness.scd). A boot is the real thing:
// your own folder, and writes that do not hold the language up.
if(MegaFiles.rootOverride.notNil) {
    ("megalooper: a test left megalooper's folder moved to " ++ MegaFiles.rootOverride
        ++ "; this boot uses your own again.").warn;
    MegaFiles.rootOverride = nil;
};
MegaFiles.alwaysSync = false;
~midiWriteSync = false;
if(~midiUserRootOverride.notNil) {
    ("megalooper: megalooper's folder is moved to " ++ ~midiUserRootOverride
        ++ " (~midiUserRootOverride): kept sounds and MIDI maps are read and written there, not in your own.").warn;
};

// Where the GUI "Export" button writes labelled loops (WAV + JSON sidecar) for
// tuning MeterAnalyzer. Passed in at call time: Looper is compiled through a
// symlink in Extensions, so the class can't derive it.
~trainingDataDir   = ~megalooperRoot +/+ "training-data";
// Where a recorded set lands, two WAVs per session. Not in the repo — a gig is
// hundreds of megabytes — so .gitignore keeps it out.
~sessionDir        = ~megalooperRoot +/+ "sessions";
// What you save is yours, so it lives in your megalooper folder (in
// Application Support, beside the MIDI maps), never in the repo: nothing
// megalooper writes here is a file git tracks.
//   bbcut/, granular/    the BBCut and Granular windows' presets, one SC
//                        literal per file
//   sa/sounds/           Megalooper SA's sounds saved under a name (the
//                        Effects pane's bar; setup-sa.scd's ~saSoundsDir)
//   sa/drum-presets/     its drums' presets (the Drums tab). What that tab's
//                        Keep keeps is ~saKeptDrumsPath (setup-sa.scd).
//   sa/synth-presets/    the synth's (the Synth tab: the note sequencer's
//                        pattern and the Wave synth's sound); its Keep keeps
//                        ~saKeptSynthPath.
~userRoot          = ~midiUserRootOverride ?? { MegaFiles.userRoot };
~bbcutPresetDir    = ~userRoot +/+ "bbcut";
~granularPresetDir = ~userRoot +/+ "granular";
~saFxPresetDir     = ~userRoot +/+ "sa" +/+ "sounds";
~saDrumsPresetDir  = ~userRoot +/+ "sa" +/+ "drum-presets";
~saSynthPresetDir  = ~userRoot +/+ "sa" +/+ "synth-presets";
if(File.exists(~trainingDataDir).not) { File.mkdir(~trainingDataDir) };
if(File.exists(~sessionDir).not) { File.mkdir(~sessionDir) };
// Until the release these presets lay in the repo's presets/ folder. The
// first boot that finds a folder of yours missing makes it and copies what
// the repo's holds (the presets megalooper ships, and any of your own from
// before): once, and the old files stay where they are.
[
    [~bbcutPresetDir, "bbcut", "BBCut presets"],
    [~granularPresetDir, "granular", "Granular presets"],
    [~saDrumsPresetDir, "sa" +/+ "drum-presets", "drum presets"]
].do { |x|
    var from = ~megalooperRoot +/+ "presets" +/+ x[1];
    var took = MegaFiles.adopt(from, x[0]);
    if(took.notNil and: { took.notEmpty }) {
        ("megalooper: your " ++ x[2] ++ " are now in " ++ x[0] ++ ": " ++ took.size
            ++ " copied from " ++ from ++ ", where they stay.").postln;
    };
};
if(File.exists(~saFxPresetDir).not) { File.mkdir(~saFxPresetDir) };

// Every part, in its order (parts.scd).
(~megalooperScripts +/+ "parts.scd").load;
~megalooperLoadParts.(~megalooperScripts);

(
// A new boot: no step has run, none has failed (setup-boot.scd).
~bootReset.();

// Which rig. launcher.scd (the Desktop icon) sets ~launcherProfile from its
// dropdown and that wins; from the IDE it is nil, so the default defined
// alongside the profile table in setup-routing.scd is used. To change rigs
// from the editor, flip ~defaultRoutingProfile there.
~routingProfile = ~launcherProfile ? ~defaultRoutingProfile;

// Resolve the profile into ~rp + the channel offsets and write s.options.
// Throws with a banner if the profile's audio device is not present — booting
// on the default device would silently break every SC<->Live route.
~applyRoutingProfile.(~routingProfile);

// Then check what the device and Live ACTUALLY are, which the name guard above
// cannot see. Both must run before s.boot: channel counts are fixed the moment
// the server starts, and ~checkAudioDevice may amend s.options (dropping the
// analysis tap on an aggregate that has lost the guitar's input).
//
// ~checkAudioDevice aborts only when the SC<->Live pairs cannot exist; the rest
// is loud warnings, because a warning you can play through beats a boot you
// cannot. Re-run either at any time:
//     ~checkAudioDevice.(~routingProfile);   // CoreAudio vs the profile
//     ~checkLiveAudio.(~routingProfile);     // what Live opened, from its log
~checkAudioDevice.(~routingProfile);
~checkLiveAudio.(~routingProfile);
~checkVSTPlugin.(~routingProfile);
// saSystem on the device a rig of yours names takes over that rig's MIDI map,
// once, unless it uses a map of your own already (setup-routing.scd).
~audioMapAdopted = ~audioAdoptMap.(~rp, ~routingProfile);
~audioMapAdopted !? { |said| ("megalooper: " ++ said ++ ".").postln };

s.boot;
// What follows the server runs as named steps (setup-boot.scd): the first
// that throws stops the boot there and says where, in the post window and on
// the launcher's status line, instead of leaving it on "Booting…".
s.waitForBoot {
    ~bootStep.("the server", {
        s.meter;
        ~checkSampleRate.();
        // The buffer it runs at, for the boot line and the top bar's rig block.
        ~audioBuffer = ~audioBufferRunning.(s);
        // The round trip the devices report, which a rig without Live starts its
        // overdub latency from (setup-model.scd's ~latencyStart).
        ~latencyReport = if(~rp[\live] == false) { ~audioRoundTripReported.(s) };
    });
    ~bootStep.("MIDI", {
        // MIDI I/O first: the Looper is constructed with ~midiOut and sends its
        // MIDI clock through it.
        ~setupMidiIO.();
    });
    ~bootStep.("Megalooper SA", {
        // Megalooper SA: the mixer goes up BEFORE the Looper, which writes its
        // loop to the mixer's bus instead of the interface (~outChannel).
        // On any other rig, an SA left over from an earlier boot in this session
        // goes, so nothing (the tempo callback) talks to it.
        if(~rp[\sa] == true) { ~setupSA.() } { ~megaSA !? { |m| m.free }; ~megaSA = nil };
    });
    ~bootStep.("the looper", {
        // DESTRUCTIVE — frees any previous Looper, and with it the loop buffers.
        ~setupLooper.();
        ~wireLooperCallbacks.();

        // Constructing a Looper only STARTS the server-side work (buffer allocs, two
        // server.syncs, then the SynthDefs); the rest of this routine would otherwise
        // run to completion long before any of it lands. The analysis window starts
        // its monitor synth as it opens, so without this wait that s_new hit a server
        // that had never heard of \looperAnalysisMonitor — button on, lamp dead.
        ~looper.waitForReady;
        // SA's loop effects go right after the Looper's master synth, so nothing
        // may add synths to the default group before this.
        if(~rp[\sa] == true) { ~setupSALooper.() };
    });
    ~bootStep.("the MIDI map", {
        // Responders need ~looper to exist. The rig's MIDI map is loaded here
        // (setup-midimap.scd); a map's bindings for SA's effects and drums do
        // nothing on a rig without them.
        ~setupMidiBindings.();
        // The fallback meter on or off, as settings.json (read just above) says:
        // off unless switched on (setup-model.scd).
        ~fallbackApply.();
    });
    ~bootStep.("the window", {
        // Builds the window, its status band and every pane, in the theme kept in
        // settings.json (read by ~setupMidiBindings above). Cannot run before
        // ~applyRoutingProfile above: the Perform and Rig panes read
        // ~returnChannel and ~analysisChannel to decide what to disable.
        ~guiThemeName = ~guiThemeSaved.() ? ~guiThemeName;
        ~guiHelpShown = ~guiPrefSaved.("help") != "hidden";
        // Whether a new loop starts with the drums off, as kept beside the theme.
        if(~rp[\sa] == true) { ~saDrumsNewLoopApply.() };
        ~buildGuiWindow.();

        // Last: this one subscribes widgets from the header and EVERY pane.
        ~wireLooperController.();

        // Started again by the Rig page's Apply and restart (setup-routing.scd):
        // the status line says on what, or what gave way.
        if(~audioRestarted == true) {
            ~audioRestarted = false;
            ~say.(if((~rp[\audioNotes] ? []).notEmpty) { ~rp[\audioNotes].join(" ") }
                { "Started again on " ++ ~audioDeviceLabel.(~rp) ++ (~audioMapAdopted !? { |m| ". " ++ m } ? "") },
                if((~rp[\audioNotes] ? []).notEmpty) { \bad });
        } {
            ~audioMapAdopted !? { |m| ~say.(m) };
        };
    });
    ~bootStep.("AI apps and the action log", {
        // AI apps (setup-remote.scd): let in if the Setup view's switch says so.
        ~remoteApply.();
        // Every action logged (setup-actions.scd), if the Analysis page's switch
        // says so: after the window, whose views and preset bars it hears too.
        ~actionsApply.();
    });
    ~bootStep.("the boot's report", {
        ("Boot complete. Keys: " ++ ~controlKeysLine.() ++ " · E export.").postln;
        ("MIDI: " ++ (~midiMap !? { |m| m.name } ? "no map") ++ ", set on the Setup view; MIDI MAP (top right) maps a control. ~midiLog = false to silence the MIDI log.").postln;
        "Name fields (export, presets): click to type, Enter or Esc gives the keys back.".postln;
        ("Views: " ++ ~guiViewOrder.collect { |k| ~guiViewNumbers[k].asString ++ " " ++ ~guiViewLabels[k] }.join(" · ")
            ++ " (keys 1-6). A filled square on a tab means that part is running. T switches the theme.").postln;
        ("BBCut presets in " ++ ~bbcutPresetDir ++ " ("
            ++ ~looper.bbcutPresetNames(~bbcutPresetDir).size ++ " saved).").postln;
        ("Granular presets in " ++ ~granularPresetDir ++ " ("
            ++ ~looper.granularPresetNames(~granularPresetDir).size ++ " saved).").postln;
        ("AI apps: " ++ if(~megaRemote.notNil) { "let in (" ++ MegaRemote.handshakePath ++ ")" }
            { "off; the Setup view's AI APPS switch lets them in (docs/ai.md)" } ++ ".").postln;
        if(~rp[\sa] == true) {
            // ~inChannel is the Looper's (the guitar chain's bus) by now; the
            // guitar's own input is the profile's.
            ("megalooper on " ++ ~audioDeviceLabel.(~rp) ++ " at " ++ s.sampleRate.round ++ " Hz, "
                ++ ~audioBufferRunningLabel.(~audioBuffer) ++ ": instrument on input "
                ++ (~rp[\inChannel] + 1) ++ " through "
                ++ (~megaSA.guitarPlugin !? { |p| p.name } ? "nothing (dry)")
                ++ ", the mix on outputs 1/2.").postln;
            "The effects and their sounds: the FX view (3). The drums: the Drums view (4). Levels: Setup (5).".postln;
            ("Sounds in " ++ ~saFxPresetDir ++ " ("
                ++ ~megaSA.soundNames(~saFxPresetDir).size ++ " saved). The kept one: " ++ ~saKeptPath.() ++ ".").postln;
            // A kit still loading says so: its buffers come in the background.
            ("Drums: " ++ ~saDrumsKitLine.(\steps) ++ "; " ++ ~saDrumsKitLine.(\onset)
                ++ (~midiBindingWords.('sa.drums.on') !? { |w| ". " ++ w ++ " switches the steps on and off" } ? "") ++ ".").postln;
            ("Drum presets in " ++ ~saDrumsPresetDir ++ " ("
                ++ ~megaSA.drums.presetNames(~saDrumsPresetDir).size ++ " saved).").postln;
        };
    });
    ~bootFinish.();
};
)
