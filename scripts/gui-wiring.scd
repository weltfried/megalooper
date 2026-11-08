// megalooper — how a view hears its model (~guiWatch), and the export action
// the keyboard shares.
//
// Loaded LAST by boot.scd; defines only, runs nothing. Entry points:
//   ~guiWatch, ~guiUnwatch — the one way a view hears a model (below)
//   ~wireLooperController — every pane's watch on the Looper, again. Each pane
//                           keeps its own (gui-status.scd's ~statusWatch,
//                           gui-perform.scd's ~performWatch, and so on); this
//                           runs them all after the window is built, after a
//                           pane is rebuilt, and when ~looper is another.
//   ~doExport             — export the current loop using the export fields
//
// A model says `changed(\key, val)`; a view's watch hears it, on AppClock: a
// MIDIdef callback fires from another thread, and touching a Qt view from
// there is a crash rather than a glitch.
//
// EVERY widget reach is nil-guarded. A pane builder that throws half way
// leaves its globals pointing at destroyed Qt objects, and an unguarded
// handler would then throw on every model event for the rest of the session,
// which is a far worse failure than a control that quietly stops tracking.
// The painters (gui-status.scd, gui-perform.scd) guard themselves.
(
// Export the current loop using whatever is in the export fields. Shared by the
// Export button (Setup) and the 'e' key binding; evaluated at call time so the
// fields need only exist by then.
~doExport = {
    ~exportNameField !? {
        ~looper !? { |l|
            l.exportTrainingLoop(
                ~trainingDataDir,
                ~exportNameField.string,
                ~exportNumField.value.asInteger,
                ~exportDenoms[~exportDenomField.value],
                ~exportBarsField.value.asInteger);
        };
    };
};

// A bar and its readout from the model, unless the mouse is holding the bar:
// the drag and the model would fight over it.
~wireBar = { |bar, label, pos, text|
    bar !? { |b| if(b.isClosed.not and: { (b.respondsTo(\held) and: { b.held }).not }) { b.value = pos } };
    label !? { |t| if(t.isClosed.not) { t.string_(text) } };
};

// A paint that a knob or a pedal can ask for a hundred times a second runs at
// most once per 50 ms: the first ask schedules it, the asks after it until it
// runs join it. Painters check their views, so one landing after a rebuild is
// harmless.
~guiSoonQueued = IdentitySet.new;
~guiSoon = { |key, f|
    if(~guiSoonQueued.includes(key).not) {
        ~guiSoonQueued.add(key);
        AppClock.sched(0.05, { ~guiSoonQueued.remove(key); f.value; nil });
    };
};

// ---- One rule for how a view hears its model ------------------------------------
// docs/dev/architecture.md, 5, step 4. A view hears a model's changes through
// ~guiWatch, and only through it:
//   ~guiWatch.(owner, model, (key: { |model, what ... args| }, ...))
//       one SimpleController on `model`, every handler run on AppClock (a
//       model may say a change from any thread: MIDI's, OSC's, a routine's),
//       kept under `owner` (a pane: \perform, \status, \granular ...)
//   ~guiUnwatch.(owner)
//       every controller `owner` holds, removed. A pane's watch removes its
//       own first, so watching again after a rebuild never doubles one up;
//       the window's teardown removes every owner's.
// Several owners may watch the same key of the same model: each has its own
// controller (SimpleController.put replaces by key within one controller, so
// one shared controller made two panes on one key overwrite each other).
~guiWatchers = ~guiWatchers ? IdentityDictionary.new;
~guiWatch = { |owner, model, handlers|
    var c;
    model !? {
        c = SimpleController(model);
        handlers.keysValuesDo { |key, fn|
            c.put(key, { |m, what ... args| { fn.valueArray([m, what] ++ args) }.defer });
        };
        ~guiWatchers[owner] = (~guiWatchers[owner] ? List.new).add(c);
    };
    c
};
~guiUnwatch = { |owner|
    (~guiWatchers[owner] ? []).do { |c| c.remove };
    ~guiWatchers.removeAt(owner);
};
~guiTeardowns = ~guiTeardowns ? ();
~guiTeardowns[\watch] = { ~guiWatchers.keys.copy.do { |owner| ~guiUnwatch.(owner) } };

// Every pane's watch on the Looper, again: after ~looper is another, or a pane
// was rebuilt. Each pane holds its own handlers, in its own file, for the
// keys that touch its own widgets (gui-status.scd, gui-perform.scd,
// gui-granular.scd, gui-bbcut.scd, gui-rig.scd, gui-analysis.scd,
// gui-shell.scd). Until 2026-11-08 this was one controller that knew every
// pane's widgets.
~wireLooperController = {
    [\statusWatch, \performWatch, \granularWatch, \bbcutWatch, \rigWatch, \analysisWatch, \shellWatch]
        .do { |k| currentEnvironment[k] !? { |f| f.value } };
};
)
