// megalooper — its parts, in the order they load: the one list (docs/dev/
// architecture.md, 5, step 3). boot.scd loads them through it, and so does
// every check and test that wants the window's parts, so a check runs against
// the same definitions the app does. A check that picked its own subset could
// leave a part out and not know it: check-gui-drums.scd left the command layer
// out once, its widgets called a nil ~controlDo, and nothing said so.
//
// Loading this file defines, and answers the list:
//   ~megalooperParts         the part files, in their order
//   ~megalooperLoadParts     loads every part from a scripts folder, in order
//
// Each part only DEFINES functions and the shared data they read, so loading
// them all is cheap and runs nothing; boot.scd's own sequence (boot.scd) is
// what starts anything. The order matters three times over: gui-const.scd
// defines the ranges and colours everything else reads; gui-presets.scd must
// precede the parts that register preset families as they load (the Cutter's,
// the Grains', the effects', the drums', the synth's); and gui-shell.scd comes
// after every pane, because ~buildGuiWindow calls their builders.
//
// A new part goes here and nowhere else: test-source-guards.scd fails on a
// script that lists parts of its own, and on a setup- or gui- file that is in
// no list.
(
~megalooperParts = [
    "setup-boot.scd",         // the boot's steps: the first that throws says where
    "setup-app.scd",          // the app's own model (~app) and ~say, for the player
    "setup-routing.scd",      // ~routingProfiles, ~applyRoutingProfile, the preflights
    "setup-midi.scd",         // ~setupMidiIO, and the numbers MIDI is bound to
    "setup-model.scd",        // ~setupLooper, ~wireLooperCallbacks, ~fallbackApply
    "setup-granular.scd",     // the grains' parameters: their table, laws and readouts
    "setup-laws.scd",         // the controls' laws and readouts, for the panes and MIDI
    "setup-count.scd",        // the loop's count and its lights, for the window, MIDI and the AI
    "setup-sa.scd",           // ~setupSA: the mixer, the chains, the drums (sa: true)
    "setup-miditargets.scd",  // the controls, and the command layer that drives them
    "setup-midimap.scd",      // ~setupMidiBindings: the MIDI router and its map
    "setup-remote.scd",       // ~remoteApply: AI apps let in or not (MegaRemote)
    "setup-actions.scd",      // ~actionsApply: Log every action (MegaActionLog)
    "gui-const.scd",          // ranges, menu contents, lifetimes; no window
    "gui-theme.scd",          // the stage theme: palettes, type, tiles, bars
    "gui-presets.scd",        // the preset bar, shared by every preset family
    "gui-status.scd",         // the status band and strip, the MIDI monitor
    "gui-perform.scd",        // Perform
    "gui-bbcut.scd",          // the Cutter, Sound's left half
    "gui-granular.scd",       // the Grains, Sound's right half
    "gui-analysis.scd",       // Setup › Analysis
    "gui-sa.scd",             // the mixer's levels
    "gui-midimap.scd",        // Setup › MIDI map
    "gui-mapmode.scd",        // MIDI Map mode
    "gui-effects.scd",        // FX
    "gui-drums.scd",          // Drums
    "gui-synth.scd",          // Synth
    "gui-rig.scd",            // Setup › Rig
    "gui-calibrate.scd",      // the Calibrate wizard
    "gui-shell.scd",          // THE window: the top bar, the views, the footer
    "gui-wiring.scd"          // ~wireLooperController, ~doExport
];
~megalooperLoadParts = { |scripts|
    ~megalooperParts.do { |f| (scripts +/+ f).load };
};
~megalooperParts
)
