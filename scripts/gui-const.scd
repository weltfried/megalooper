// megalooper — GUI constants: ranges, menu contents, and the visual vocabulary.
//
// Loaded FIRST of the gui files by boot.scd; defines only, and deliberately
// contains no Window constructor and no builder. Two reasons that matters:
//
//   * check.scd LOADS this file (it asserts on ~syncMax and ~latencyMax), and a
//     file that opened a window at load time would open one in a headless check
//     — the rule already documented for launcher.scd in check.scd.
//   * Everything here is read at CALL time by the pane files, by gui-wiring.scd
//     and by setup-model.scd, so having it depend on nothing keeps the load
//     order of everything else free.
(
// ---- Window placement -----------------------------------------------------
// The one window is positioned with a literal Rect laid out for a large
// external display. On a laptop screen it would land partly off it, and a
// window you cannot see reads as a window that failed to open. So clamp to what
// the screen actually offers: shrink if taller or wider than the display, then
// slide back inside. Panes scroll, so the clamp only ever costs scrolling.
~fitOnScreen = { |rect|
    var screen = Window.availableBounds;
    var w = rect.width.min(screen.width);
    var h = rect.height.min(screen.height);
    var x = rect.left.clip(screen.left, screen.left + screen.width  - w);
    var y = rect.top.clip(screen.top,  screen.top  + screen.height - h);
    Rect(x, y, w, h)
};

// ---- Control ranges and menu contents ------------------------------------
~transportModes      = [\full, \startOnly, \off];
~transportModeLabels = ["Start + Stop", "Start only", "Don't touch"];

~latencyMax = 100;  // slider full-scale in ms
~declickMax = 20;   // loop-seam fade slider full-scale in ms
~syncMax    = 150;  // Live-sync slider half-range in ms (slider spans ±this,
                    // so 300 ms end to end). Raised from 100 once a rig needed
                    // -116; check.scd fails if a profile sits outside it.
// Onset threshold: the header slider's scale and the law it moves on. Onsets'
// useful range is roughly 0.1–1; 2.0 leaves headroom for a very noisy input.
// The floor matches Looper's own clip, so the slider's ends ARE the model's.
~onsetThresholdMin = 0.01;
~onsetThresholdMax = 2.0;
// EXPONENTIAL, not linear. Threshold is a level, and the settings worth
// distinguishing are bunched at the bottom: on a linear 0–2 slider everything
// from "admits ghost onsets" to "just right" lived in the first tenth of the
// travel, so setting a low threshold by hand meant nudging one pixel at a time.
// Exponential spends the travel where the decisions are: a nudge of 1% of the
// travel moves the threshold by about 5% of its CURRENT value wherever you are,
// so the control feels the same at 0.05 as at 1.0. Measured against the old
// linear slider, 1% of travel at 0.1 moves 0.005 instead of 0.02 — four times
// finer — at the cost of being coarser above ~0.4, which is the end nobody
// tunes in. The default 0.5 sits at about three quarters of the travel.
//
// One spec, mapped by the slider, the controller CC and the label alike: a
// second copy of this law anywhere would drift, and a knob that disagreed with
// the slider under it is worse than either.
~onsetThresholdSpec = ControlSpec(~onsetThresholdMin, ~onsetThresholdMax, \exp);
~inChannelCounts = [1, 2];
~inChannelLabels = ["Mono", "Stereo"];
// Meters offered for the length-anchored fallback (see MeterAnalyzer).
~fallbackMeters = [
    [4,4], [3,4], [5,4], [7,4],
    [5,8], [6,8], [7,8], [9,8], [11,8], [12,8]];
~fallbackMeterLabels = ["4/4","3/4","5/4","7/4","5/8","6/8","7/8","9/8","11/8","12/8"];
// Denominators offered in the export signature control.
~exportDenoms = [2, 4, 8, 16];

~keyHintString = "R trigger  S stop  M multiply  U undo  V reverse  L half  G grains  B cutter  K break  D dissolve  N next loop  A reading  C clear";

// ---- Visual vocabulary ----------------------------------------------------
// These colours were already in use, spelled as literals at a dozen call sites.
// Naming them is not decoration: RECORDING red and the destructive-button red
// were the same number by coincidence rather than by intent, and one of them
// moving used to mean hunting every Color.new in the tree.
~guiOn        = Color.new(0.15, 0.6,  0.25);   // a part is running
~guiOff       = Color.gray(0.88);              // a part is idle
~guiArmed     = Color.new(0.95, 0.8,  0.2);    // waiting to happen; two-click arm
~guiDanger    = Color.new(0.85, 0.2,  0.15);   // recording, and destructive actions
~guiBusy      = Color.new(0.95, 0.5,  0.1);    // overdub, paused
~guiStopping  = Color.new(0.6,  0.2,  0.5);    // chain handoff in flight
~guiCut       = Color.new(0.85, 0.3,  0.2);    // the cutter's own on colour
~guiIdleBtn   = Color.gray(0.85);              // a button that is simply off
~guiInk       = Color.gray(0.15);
~guiHintColor = Color.gray(0.4);
~guiHintFont  = Font(Font.defaultSansFace, 10);

// A dimmed one-line note under a control. Kept to a single short line —
// StaticText wraps, and a wrapped label in a VLayout gets its height computed
// badly by Qt, which is worse inside a ScrollView (see gui-shell.scd).
~guiHint = { |str|
    StaticText().string_(str).stringColor_(~guiHintColor).font_(~guiHintFont)
};

// ---- What MIDI drives a control ---------------------------------------------
// Tooltips and labels that name the message driving a control read the MIDI
// map in use (docs/dev/midi-map.md 8.6) and are rewritten when it changes:
// ~midiWatch keeps a view with a function that paints it from the map, and the
// router's repaint (~midiChanged, setup-midimap.scd) runs them all again. A
// closed view is dropped. Without the router loaded (the headless pane
// checks), the map is simply empty.
// These lists are pruned with reject, which answers an Array, and an Array's
// add does not grow it in place once it is full: an add would be lost. So a
// pruned list is made a List again (List.newFrom).
~midiWatched = List.new;
~midiWatch = { |view, fn|
    ~midiWatched.add([view, fn]);
    // A pane rebuilt again and again (the Effects editor, on every tile)
    // leaves closed views here; they go once the list has doubled.
    if(~midiWatched.size > (~midiWatchedPruneAt ? 400)) {
        ~midiWatched = List.newFrom(~midiWatched.reject { |e| e[0].isClosed });
        ~midiWatchedPruneAt = (~midiWatched.size * 2).max(400);
    };
    fn.value(view);
    view
};
~midiWatchRefresh = {
    ~midiWatched = List.newFrom(~midiWatched.reject { |e| e[0].isClosed });
    ~midiWatched.do { |e| try { e[1].value(e[0]) } };
};
// What drives a control, in words ("PC 4, note 60"), or nil. `id` is a
// control's id, or a function answering one (see ~mapTag).
~midiWords = { |id| ~midiBindingWords !? { |f| f.(id.value) } };
// The program that drives a control, or nil.
~midiProgram = { |id| ~midiProgramFor !? { |f| f.(id.value) } };

// Every view that shows a control a MIDI binding can drive, with the
// control's id (setup-miditargets.scd): MIDI Map mode (gui-mapmode.scd) lays
// a mask over each, and a click on it maps that control (docs/dev/midi-map.md
// 7.2). ~mapTag records `view` against `id`, or against a function that
// answers one when it is asked: a Drums knob edits the pattern shown, so its
// mapping is for the pattern shown when it is clicked (decision 16). With
// `tip`, the view's tooltip is `tip` and then what drives the control, kept
// as the map changes. It answers the view, so it wraps a constructor inline:
//   ~mapTag.(Button().states_(...), 'looper.trigger', "Trigger.")
// A view built while map mode is on gets its mask once laid out. A closed
// view is dropped when the tags are next read. ?-initialised, so re-loading
// this file mid-session keeps the tags of the views already built.
~mapTags = ~mapTags ? List.new;
~mapFnWatched = ~mapFnWatched ? List.new;   // the tooltips of tags that are functions
~mapTag = { |view, id, tip|
    var paint;
    ~mapTags.add([view, id]);
    if(~mapTags.size > (~mapTagsPruneAt ? 600)) {
        ~mapTags = List.newFrom(~mapTags.reject { |e| e[0].isClosed });
        ~mapTagsPruneAt = (~mapTags.size * 2).max(600);
    };
    tip !? {
        paint = { |v|
            var w = ~midiWords.(id);
            v.toolTip_(case { w.isNil } { tip } { tip.isEmpty } { "MIDI: " ++ w } { tip ++ "\nMIDI: " ++ w })
        };
        ~midiWatch.(view, paint);
        if(id.isKindOf(Function)) { ~mapFnWatched.add([view, paint]) };
    };
    ~mapTagged !? { |f| f.value(view, id) };
    view
};
// A tooltip that says what drives its control: a tag with a tip.
~midiTip = { |view, id, base| ~mapTag.(view, id, base) };
// What the tags that are functions answer has changed (the Drums tab shows
// another pattern or page): their tooltips, and their masks in map mode, say
// what drives the control they answer now.
~mapRelabel = {
    ~mapFnWatched = List.newFrom(~mapFnWatched.reject { |e| e[0].isClosed });
    ~mapFnWatched.do { |e| try { e[1].value(e[0]) } };
    ~mapRepaint !? { |f| f.value };
};

// ---- Lifetimes ------------------------------------------------------------
// With one window there are THREE lifetimes where the six-window GUI had one.
// Closing a window and rebuilding it used to be the same event, so onClose
// alone was enough to stop a repaint timer. Now a pane can be rebuilt while the
// window lives, and without a generation token the old timer keeps running and
// keeps writing into the views the rebuild just destroyed.
//
// Each builder bumps its counter and captures the value in a local var; its
// timer stops as soon as the global moves on. ?-initialised so re-loading this
// file mid-session does not reset a counter out from under a live timer.
~guiGen      = ~guiGen ? 0;
~analysisGen = ~analysisGen ? 0;
~statusGen   = ~statusGen ? 0;

// What must be undone when the window closes, keyed so a re-load replaces an
// entry rather than stacking a second copy. Same idiom as ~presetFamilies.
// Entries are registered at load time by the file that owns the resource; the
// shell fires them all from ~guiWindow.onClose.
~guiTeardowns = ~guiTeardowns ? ();
)
