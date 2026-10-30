// megalooper — the preset bar, once, for both windows.
//
// The cutter window and the granular window each need the same bar: a menu of
// slugs, a name field, Save / Revert / Delete with two-click confirmation, and
// a status line. That was written out twice, ~200 lines each, and the two
// copies had already drifted apart in small ways — different grey for the idle
// status text, only one of them nil-guarding ~looper, two wordings of the same
// "nothing selected" message. None of it mattered on its own; all of it is the
// reason to have one copy.
//
// What genuinely differs between the two is a label, one line of help text, and
// which Looper methods to call. That is the family spec, registered by each
// window's own file so the wording stays next to the window it describes.
// A family whose presets belong to another object names it with `model`, a
// function answering that object (Megalooper SA's effects: { ~megaSA }); the
// default is the Looper.
//
// This file only DEFINES, like every other part, and must load BEFORE
// gui-bbcut.scd and gui-granular.scd, which register into ~presetFamilies.
//
// Each window keeps its own named globals (~saveBBCutPreset, ~loadGranular-
// Preset, …) as one-line wrappers over the functions here. They are what
// gui-main.scd and check.scd address, and `~saveBBCutPreset.()` reads better on
// a button's action than `~presetSave.(\bbcut)`.

~presetFamilies = ~presetFamilies ? ();

// State and widgets live IN the family, so the functions below are the only
// code that touches them and there is one description of the shape.
//
// `items` is index-aligned with the menu: slot 0 is the "none" sentinel (nil),
// slots 1..n are slugs. Index it directly — never menu.value - 1, which
// desyncs the moment the empty state changes the item count. Slugs are
// Strings, so every lookup uses the *Equal variants: includes and indexOf
// compare with identity, which is always false for two separately built
// Strings.
~definePresetFamily = { |key, attrs|
    var fam = (
        // --- filled in by the caller ---
        label: "Preset",        // "BBCut" / "Granular", for messages
        statusIdle: "",         // the resting help line
        dirKey: nil,            // global holding this family's directory
        names: nil, slug: nil,  // the model's selectors
        save: nil, load: nil, delete: nil,
        model: nil,             // function answering the model; nil = ~looper
        ext: ".scd",            // what a preset's file ends in (a sound's: ".json")
        // True if the model's save answers before the file is written (a
        // sound waits for its plugin's state): the list is then read again
        // by whoever hears that it is (the Effects pane), not at once, when
        // the file is not there yet.
        async: false,
        // --- view state ---
        items: [nil],
        loaded: nil,            // slug currently selected, or nil
        saveArmed: false,
        // WHICH slug the save arm was raised for. An arm that outlives the name
        // it was raised against would commit a clobber the player never
        // confirmed — type a different existing name and the stale arm would
        // write it on the first click.
        saveArmedSlug: nil,
        deleteArmed: false,
        nameFocused: false,
        // --- widgets, set by the window builder ---
        menu: nil, nameField: nil,
        saveButton: nil, revertButton: nil, deleteButton: nil,
        statusText: nil,
        // --- timers ---
        statusRoutine: nil, armRoutine: nil
    );
    attrs.keysValuesDo { |k, v| fam[k] = v };
    ~presetFamilies[key] = fam;
    fam
};

~presetFamily = { |key| ~presetFamilies[key] };

// A colour of the stage theme (gui-theme.scd), or a plain one where the theme
// is not loaded (the headless tests load this file alone).
~presetColor = { |key|
    (~gt !? { |t| t[key] }) ?? {
        (rec: Color.new(0.7, 0.15, 0.15), mute: Color.gray(0.4), ink: Color.black,
            onacc: Color.black, panel: Color.gray(0.85), armed: Color.new(0.95, 0.8, 0.2))[key]
    }
};

// Widget assignment that RETURNS THE WIDGET, so it can be used inline inside a
// layout the way `~someGlobal = Widget()` used to be.
//
// `fam[\menu] = PopUpMenu()` would NOT do: an assignment into an Event
// evaluates to the Event, not to the value, so the layout would be handed the
// family spec instead of the widget — and silently, because a layout accepts
// any object and simply shows nothing useful.
~presetWidget = { |key, slot, widget|
    ~presetFamilies[key][slot] = widget;
    widget
};

// Read at call time rather than captured: boot.scd sets these before loading
// the parts, but a window rebuilt later must still see the current value.
~presetDir = { |key| currentEnvironment[~presetFamilies[key][\dirKey]] };

// The object whose selectors the family names, read at call time like the
// directory. An if rather than `?? { ~looper }`: a family whose model is
// absent (no ~megaSA) must answer nil, never fall back to the Looper, which
// does not understand its selectors.
~presetModel = { |key|
    var fam = ~presetFamilies[key];
    if(fam[\model].notNil) { fam[\model].value } { ~looper }
};

// The hint line under the preset rows doubles as a status line. Messages clear
// themselves after a few seconds; detail goes to the post window.
// A deferred notification can arrive after its window closed (a kit that
// finishes loading as the window is rebuilt): a closed StaticText throws on
// the first write, so a closed one is skipped like a missing one.
~presetSetStatus = { |key, str, isError = false|
    var fam = ~presetFamilies[key];
    // != true, not .not: the tests' stand-in widgets answer nil to isClosed.
    var open = { |t| t.notNil and: { t.isClosed != true } };
    var out = str.asString;
    if(open.(fam[\statusText])) {
        if(out.size > 92) { out = out.copyRange(0, 88) ++ "…" };
        fam[\statusText].string_(out).stringColor_(~presetColor.(if(isError) { \rec } { \mute }));
    };
    fam[\statusRoutine] !? { |r| r.stop };
    fam[\statusRoutine] = Routine {
        4.wait;
        // Don't stomp the "Typing…" indicator while the field holds focus.
        if(fam[\nameFocused].not and: { open.(fam[\statusText]) }) {
            fam[\statusText].string_(fam[\statusIdle]).stringColor_(~presetColor.(\mute));
        };
    }.play(AppClock);
};

// Rescan the folder. Selection is preserved BY SLUG, never by index — a file
// appearing alphabetically earlier shifts every index below it.
// What an empty menu says: "— no presets yet —", in the family's own word
// for its files where it has one (the SA sounds' "sound").
~presetNoneText = { |key|
    "— no " ++ ((~presetFamilies[key] !? { |f| f[\caption] }) ? "preset") ++ "s yet —"
};
~presetRefreshList = { |key|
    var fam = ~presetFamilies[key];
    var slugs = ~presetModel.(key) !? { |l| l.perform(fam[\names], ~presetDir.(key)) } ? [];
    var idx;
    fam[\items] = [nil] ++ slugs;
    fam[\menu] !? { |m|
        if(slugs.isEmpty) {
            // items_ resets value, so set value after.
            m.items = [~presetNoneText.(key)];
            m.value = 0;
            m.enabled = false;
            fam[\loaded] = nil;
        } {
            m.items = ["— none —"] ++ slugs;
            m.enabled = true;
            idx = fam[\items].indexOfEqual(fam[\loaded]);
            if(idx.isNil) {
                if(fam[\loaded].notNil) {
                    ~presetSetStatus.(key, "'" ++ fam[\loaded]
                        ++ "' is gone from disk — selection cleared.", true);
                };
                fam[\loaded] = nil;
                idx = 0;
            };
            m.value = idx;
        };
    };
    ~presetRefreshButtons.(key);
};

// Single-state buttons whose label/colour is swapped by re-setting .states_ (a
// 2-state button would cycle on click and stick). Amber = armed, red = about
// to destroy — the same language as the Rec-next-loop button.
~presetRefreshButtons = { |key|
    var fam    = ~presetFamilies[key];
    var name   = fam[\nameField] !? { |f| f.string } ? "";
    // An empty field never reads as "Overwrite": the slugger would turn it into
    // "preset", which could collide with a real preset of that name.
    var slug   = if(name.stripWhiteSpace.isEmpty) { nil } {
        ~presetModel.(key) !? { |l| l.perform(fam[\slug], name) }
    };
    var exists = slug.notNil and: { fam[\items].includesEqual(slug) };
    // Saving back what you loaded takes one click, so it must not wear the
    // label that promises a confirmation step. Each label predicts what ONE
    // click will do: Save writes, Overwrite asks first, Overwrite? writes.
    var mine   = (slug.notNil and: { slug == fam[\loaded] });
    fam[\saveButton] !? { |b|
        b.states_(
            if(fam[\saveArmed]) {
                [["Overwrite?", Color.white, ~presetColor.(\rec)]]
            } {
                case
                { mine }   { [["Save",      ~presetColor.(\ink), ~presetColor.(\panel)]] }
                { exists } { [["Overwrite", ~presetColor.(\onacc), ~presetColor.(\armed)]] }
                { true }   { [["Save new",  ~presetColor.(\ink), ~presetColor.(\panel)]] }
            });
    };
    fam[\deleteButton] !? { |b|
        b.states_(if(fam[\deleteArmed]) {
            [["Delete — sure?", Color.white, ~presetColor.(\rec)]]
        } {
            [["Delete", ~presetColor.(\ink), ~presetColor.(\panel)]]
        });
        b.enabled = fam[\loaded].notNil;
    };
    fam[\revertButton] !? { |b| b.enabled = fam[\loaded].notNil };
};

~presetDisarm = { |key|
    var fam = ~presetFamilies[key];
    fam[\armRoutine] !? { |r| r.stop };
    fam[\armRoutine]    = nil;
    fam[\saveArmed]     = false;
    fam[\saveArmedSlug] = nil;
    fam[\deleteArmed]   = false;
    ~presetRefreshButtons.(key);
};

// Arm a destructive button: a second click commits. Stands in for the modal
// dialog this codebase has no idiom for.
//
// DELETE disarms itself after 4 s, because a delete that quietly does not
// happen fails safe — you still have the file.
//
// SAVE does NOT, and that asymmetry is the whole point of this function. It
// used to share the timeout, and a save that quietly does not happen fails
// UNSAFE: the take you just dialled in is not on disk, the status line says
// exactly what it said on the first click, and you find out when you recall the
// preset and get the old numbers back. Measured on the real code path: set a
// level, click Overwrite, wait five seconds, click again — the file still holds
// the previous value. The arm now waits as long as you do, and `saveArmedSlug`
// keeps it honest if the name changes underneath it.
~presetArm = { |key, which, msg, slug|
    var fam = ~presetFamilies[key];
    fam[\armRoutine] !? { |r| r.stop };
    fam[\armRoutine]    = nil;
    fam[\saveArmed]     = (which == \save);
    fam[\saveArmedSlug] = if(which == \save) { slug } { nil };
    fam[\deleteArmed]   = (which == \delete);
    ~presetRefreshButtons.(key);
    ~presetSetStatus.(key, msg, true);
    // The timeout clears the flags inline rather than calling ~presetDisarm —
    // that would have the routine stop itself.
    if(which == \delete) {
        fam[\armRoutine] = Routine {
            4.wait;
            fam[\deleteArmed] = false;
            fam[\armRoutine]  = nil;
            ~presetRefreshButtons.(key);
        }.play(AppClock);
    };
};

// Recall. The GUI does NOT re-render the edited controls here — the model
// writes through its own setters and the SimpleController in gui-main.scd
// repaints — so every recall path (GUI now, MIDI or a boot default later)
// refreshes through one route.
~presetLoad = { |key, slug|
    var fam  = ~presetFamilies[key];
    var dir  = ~presetDir.(key);
    var ext  = fam[\ext] ? ".scd";
    var path = dir +/+ slug ++ ext;
    var ok = false;
    if(File.exists(path).not) {
        ~presetSetStatus.(key, "Missing file: " ++ slug ++ ext, true);
        ~presetRefreshList.(key);
    } {
        ok = ~presetModel.(key) !? { |l| l.perform(fam[\load], dir, slug) } ? false;
        if(ok) {
            fam[\loaded] = slug;
            fam[\nameField] !? { |f| f.string_(slug) };
            ~presetDisarm.(key);
            ~presetSetStatus.(key, "Loaded " ++ slug);
            // Which preset, for Log every action (the parts say what it set).
            ~actionsNote !? { |f| f.value(\window, \preset, key, slug) };
        } {
            // The model refused it (bad file) and left the layer alone.
            ~presetSetStatus.(key, "Could not load " ++ slug
                ++ " — see the post window.", true);
        };
    };
    ok
};

// A preset recalled outside the bar (the AI's load, or its revert): the menu
// selects it (nil: none) and the name field shows it, as a recall from the
// menu leaves them, so Save and Revert act on what plays. A name being typed
// is left alone.
~presetShow = { |key, slug|
    var fam = ~presetFamilies[key];
    fam !? {
        fam[\loaded] = slug;
        if(fam[\nameFocused] != true) {
            fam[\nameField] !? { |f| if(f.isClosed != true) { f.string_(slug ? "") } };
        };
        ~presetDisarm.(key);
        ~presetRefreshList.(key);
        slug !? { ~presetSetStatus.(key, "Loaded " ++ slug) };
    };
};

// Save doubles as save-as: type a new name and the write creates a new file,
// which the rescan then selects.
~presetSave = { |key|
    var fam    = ~presetFamilies[key];
    var name   = fam[\nameField] !? { |f| f.string } ? "";
    var model  = ~presetModel.(key);
    var slug   = model !? { |l| l.perform(fam[\slug], name) };
    var exists = fam[\items].includesEqual(slug);
    // Saving back the preset you LOADED is the ordinary path — dial something
    // in, listen, keep it — and it is not a clobber: the file you are about to
    // replace is the one you have open. Confirming it taught the hand to
    // double-click Save, which is how an accidental overwrite of a DIFFERENT
    // preset gets waved through. The confirm is for that case only.
    var mine   = (slug == fam[\loaded]);
    // The arm only counts for the name it was raised against (see ~presetArm).
    var armed  = fam[\saveArmed] and: { fam[\saveArmedSlug] == slug };
    var written;
    case
    { model.isNil } {
        ~presetSetStatus.(key, "Nothing to save: " ++ fam[\label] ++ " is not running.", true);
    }
    { name.stripWhiteSpace.isEmpty } {
        ~presetSetStatus.(key, "Type a name first.", true);
    } {
        // Recomputed at CLICK time: the label can be stale, because buttons are
        // canFocus_(false) so clicking Save never fires the name field's
        // focusLost. This is what actually guards an overwrite.
        if(exists and: { mine.not } and: { armed.not }) {
            ~presetArm.(key, \save,
                "'" ++ slug ++ "' exists — click again to overwrite.", slug);
        } {
            // Said before the save is asked for: whoever hears that the
            // file is written may hear it before this returns, and its
            // "Saved" must come last.
            if(fam[\async] == true) { ~presetSetStatus.(key, "Saving " ++ slug ++ "…") };
            written = model.perform(fam[\save], ~presetDir.(key), name);
            ~presetDisarm.(key);
            case
            { written.isNil } {
                ~presetSetStatus.(key, "Save failed — see the post window.", true);
            }
            { fam[\async] == true } { nil } {
                fam[\loaded] = written;
                ~presetRefreshList.(key);
                ~presetSetStatus.(key, "Saved " ++ written);
            };
        };
    };
};

// Deletes the SELECTED preset, not what is typed — removing something you just
// typed would be a nasty surprise. The running layer is untouched.
~presetDelete = { |key|
    var fam  = ~presetFamilies[key];
    var slug = fam[\loaded];
    if(slug.isNil) {
        ~presetSetStatus.(key, "Nothing selected to delete.", true);
    } {
        if(fam[\deleteArmed].not) {
            ~presetArm.(key, \delete,
                "Delete '" ++ slug ++ "'? Click again to confirm.");
        } {
            var ok = ~presetModel.(key) !? { |l| l.perform(fam[\delete], ~presetDir.(key), slug) } ? false;
            ~presetDisarm.(key);
            if(ok) {
                fam[\loaded] = nil;
                ~presetRefreshList.(key);
                ~presetSetStatus.(key, "Deleted " ++ slug);
            } {
                ~presetSetStatus.(key, "Delete failed: " ++ slug, true);
            };
        };
    };
};

// Discard live edits: re-read the selected preset from disk and re-apply.
~presetRevert = { |key|
    var slug = ~presetFamilies[key][\loaded];
    if(slug.isNil) {
        ~presetSetStatus.(key, "Nothing selected to revert to.", true);
    } {
        if(~presetLoad.(key, slug)) {
            ~presetSetStatus.(key, "Reverted to " ++ slug);
        };
    };
};

// The bar's three rows for one family: the menu and its rescan, the name field
// with Save / Revert / Delete, and the status line. The cutter and grains panes
// spell theirs out (they came first); panes since use this. `tips` holds the
// wording that differs: menu, name and save, plus optional rescan, revert and
// delete. The behaviour is the same as theirs, line for line.
~presetBarRows = { |key, labelWidth, tips|
    var fam = ~presetFamilies[key];
    tips = tips ? ();
    [
        HLayout(
            StaticText().string_("Preset:").align_(\right).fixedWidth_(labelWidth),
            ~presetWidget.(key, \menu, PopUpMenu().canFocus_(false)
                .toolTip_(tips[\menu] ? "")
                .items_([~presetNoneText.(key)])
                .action_({ |m|
                    var slug = fam[\items][m.value];
                    if(slug.isNil) {
                        fam[\loaded] = nil;
                        ~presetDisarm.(key);
                    } {
                        // Never let the menu claim a preset we failed to load.
                        if(~presetLoad.(key, slug).not) {
                            m.value = fam[\items].indexOfEqual(fam[\loaded]) ? 0;
                        };
                    };
                })),
            Button().canFocus_(false).fixedWidth_(32)
                .toolTip_(tips[\rescan] ? "Rescan the folder for presets added or removed "
                    "outside megalooper.")
                .states_([["↻"]])
                .action_({
                    ~presetRefreshList.(key);
                    ~presetSetStatus.(key, "Preset list rescanned.");
                })
        ),
        HLayout(
            StaticText().string_("Name:").align_(\right).fixedWidth_(labelWidth),
            // Never takes focus at open; Enter or Escape hands the keyboard back
            // (see the cutter's and the grains' bars).
            ~presetWidget.(key, \nameField, TextField()
                .toolTip_(tips[\name] ? "")
                .string_("")
                .action_({ ~guiWindow !? { |w| w.view.focus(true) } })
                .focusGainedAction_({ |v|
                    fam[\nameFocused] = true;
                    v.background_(Color.new(1, 0.93, 0.6));
                    ~presetSetStatus.(key, "Typing… Enter or Esc to release the keyboard");
                    ~guiSetTyping !? { |f| f.(true) };
                })
                .focusLostAction_({ |v|
                    fam[\nameFocused] = false;
                    v.background_(Color.white);
                    ~presetDisarm.(key);   // a retyped target un-arms Save
                    ~guiSetTyping !? { |f| f.(false) };
                })
                .keyDownAction_({ |v, char, mods, uni|
                    if(uni == 27) {
                        ~guiWindow !? { |w| w.view.focus(true) }; true
                    } {
                        // Deferred so it reads the string after Qt applied the
                        // character: keeps the Save/Overwrite label honest.
                        { ~presetRefreshButtons.(key) }.defer(0);
                        nil
                    };
                })),
            ~presetWidget.(key, \saveButton, Button().canFocus_(false).fixedWidth_(96)
                .toolTip_(tips[\save] ? "")
                .states_([["Save new", Color.black, Color.gray(0.85)]])
                .action_({ ~presetSave.(key) })),
            ~presetWidget.(key, \revertButton, Button().canFocus_(false).fixedWidth_(66)
                .toolTip_(tips[\revert] ? "Re-read the selected preset from disk, "
                    "discarding every edit made since it was loaded.")
                .states_([["Revert"]])
                .action_({ ~presetRevert.(key) })),
            ~presetWidget.(key, \deleteButton, Button().canFocus_(false).fixedWidth_(104)
                .toolTip_(tips[\delete] ? "Delete the selected preset. Click once to arm, "
                    "again to confirm. What is playing is not touched.")
                .states_([["Delete", Color.black, Color.gray(0.85)]])
                .action_({ ~presetDelete.(key) }))
        ),
        HLayout(
            StaticText().fixedWidth_(labelWidth),
            ~presetWidget.(key, \statusText, StaticText()
                .string_(fam[\statusIdle])
                .stringColor_(Color.gray(0.4))
                .font_(Font(Font.defaultSansFace, 10)))
        )
    ]
};

// Stop both timers for one family — called when a window is rebuilt, so a
// routine from the previous incarnation cannot write to a dead widget.
~presetStopTimers = { |key|
    var fam = ~presetFamilies[key];
    fam !? {
        fam[\statusRoutine] !? { |r| r.stop };
        fam[\armRoutine]    !? { |r| r.stop };
        fam[\statusRoutine] = nil;
        fam[\armRoutine]    = nil;
    };
};
