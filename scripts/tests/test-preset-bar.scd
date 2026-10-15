// The shared preset bar, driven end to end with stub widgets.
//
// This is GUI code, so it normally could only be checked by opening the window
// and clicking. But the bar talks to its widgets through plain accessors —
// menu.items, field.string, button.states_, text.string_ — and an Event answers
// any of those by key lookup. So an Event stands in for each widget, and the
// whole flow (rescan, save, overwrite-confirm, recall, delete-confirm, revert)
// can be exercised against a REAL Looper writing REAL files.
//
// Worth the trouble because this file is the one copy of logic that used to be
// written out twice, once per window: a regression here breaks both windows at
// once, and neither of them is visible from a headless check.
//
// IDE-safe: ~looper and the two preset directories are saved and put back, so
// evaluating this during a session cannot disturb a loaded loop or write into
// the real presets folders.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-preset-bar");

{
var dir = thisProcess.nowExecutingPath.dirname.dirname;
// This run's own folder (~tTempPath): runs at the same time do not share it.
var root = ~tTempPath.("megalooper-presetbar-tests");
var savedLooper = ~looper;
var savedBDir   = ~bbcutPresetDir;
var savedGDir   = ~granularPresetDir;
var stub, install, statusOf;

if(~definePresetFamily.isNil) { (dir +/+ "gui-presets.scd").load };
(dir +/+ "gui-bbcut.scd").load;
(dir +/+ "gui-granular.scd").load;

// An Event per widget. Reads go through [\key] rather than .key because
// Object:value would shadow the stored `value`.
stub = { () };
install = { |key|
    [\menu, \nameField, \saveButton, \revertButton, \deleteButton, \statusText]
        .do { |slot| ~presetWidget.(key, slot, stub.()) };
    ~presetFamily.(key)
};
statusOf = { |key| ~presetFamily.(key)[\statusText][\string] };

~looper = ~tLooper.();
~bbcutPresetDir    = root +/+ "bbcut";
~granularPresetDir = root +/+ "granular";
[~bbcutPresetDir, ~granularPresetDir].do { |d|
    if(File.exists(d).not) { File.mkdir(d) };
    (d +/+ "*.scd").pathMatch.do { |f| File.delete(f) };
};

// ---- the full flow, on the granular family ------------------------------

{
var fam = install.(\granular);

// Empty folder: the menu says so and disables itself, rather than offering a
// "— none —" entry that selects nothing.
~refreshGranularPresetList.();
~tEq.("empty folder: menu shows the empty label",
    fam[\menu][\items], ["— no presets yet —"]);
~tEq.("empty folder: menu is disabled", fam[\menu][\enabled], false);
~tEq.("empty folder: nothing loaded", fam[\loaded], nil);
~tEq.("empty folder: Delete is disabled", fam[\deleteButton][\enabled], false);
~tEq.("empty folder: Revert is disabled", fam[\revertButton][\enabled], false);

// An empty name field must not read as "Overwrite": the slugger would turn it
// into "preset", which could collide with a real preset of that name.
fam[\nameField][\string] = "   ";
~refreshGranularPresetButtons.();
~tEq.("blank name reads Save new",
    fam[\saveButton][\states][0][0], "Save new");
~saveGranularPreset.();
~tEq.("saving a blank name is refused", statusOf.(\granular), "Type a name first.");

// Save a real one.
fam[\nameField][\string] = "Frozen Cathedral";
~looper.granularSize = 2.5;
~saveGranularPreset.();
~tEq.("save reports the slug", statusOf.(\granular), "Saved frozen-cathedral");
~tEq.("save selects what it wrote", fam[\loaded], "frozen-cathedral");
~tEq.("the menu now lists it",
    fam[\menu][\items], ["— none —", "frozen-cathedral"]);
~tEq.("the menu is enabled", fam[\menu][\enabled], true);
~tEq.("the menu points at it", fam[\menu][\value], 1);
~tEq.("Delete is now enabled", fam[\deleteButton][\enabled], true);
~tAssert.("the file exists",
    File.exists(~granularPresetDir +/+ "frozen-cathedral.scd"), "not written");

// Saving back the preset you LOADED is one click. It is not a clobber — the
// file being replaced is the one you have open — and confirming it taught the
// hand to double-click Save, which is how an accidental overwrite of a
// DIFFERENT preset gets waved through.
~refreshGranularPresetButtons.();
~tEq.("the loaded preset's own name reads Save, not Overwrite",
    fam[\saveButton][\states][0][0], "Save");
~looper.granularSize = 3.25;
~saveGranularPreset.();
~tEq.("one click commits it", statusOf.(\granular), "Saved frozen-cathedral");
~tEq.("...without arming", fam[\saveArmed], false);
~tNear.("...and the new value is on disk",
    File.readAllString(~granularPresetDir +/+ "frozen-cathedral.scd")
        .interpret[\size], 3.25, 1e-9);
~looper.granularSize = 2.5;
~saveGranularPreset.();     // put 2.5 back, for the recall test below

// A name that exists but is NOT the loaded one is a clobber, and still needs
// two clicks. The guard that stands in for a modal dialog.
//
// Note the order: ~presetLoad writes the slug into the name field, so the
// typed name has to be set AFTER the load or the test is only checking the
// save-back path again.
fam[\nameField][\string] = "Decoy One";
~saveGranularPreset.();                        // creates it; now IT is loaded
fam[\nameField][\string] = "Decoy Two";
~saveGranularPreset.();                        // ditto; loaded = decoy-two
~loadGranularPreset.("frozen-cathedral");
fam[\nameField][\string] = "Decoy One";        // typed, not loaded
~refreshGranularPresetButtons.();
~tEq.("an existing name you did not load reads Overwrite",
    fam[\saveButton][\states][0][0], "Overwrite");
~saveGranularPreset.();
~tAssert.("first click on Overwrite only arms",
    statusOf.(\granular).contains("click again"), statusOf.(\granular));
~tEq.("...and the button says so", fam[\saveButton][\states][0][0], "Overwrite?");
~tEq.("...and the armed flag is set", fam[\saveArmed], true);
~tEq.("...and it remembers WHICH name it armed for",
    fam[\saveArmedSlug], "decoy-one");

// The arm must NOT expire. It used to time out after 4 s, and a save that
// quietly does not happen fails UNSAFE: the status line says exactly what it
// said on the first click, and you find out when you recall the preset and get
// the old numbers back. That is what made the granular Level look like it was
// never being stored.
//
// Asserted as "no expiry was scheduled" rather than by waiting: this file runs
// synchronously and AppClock never advances inside it, so a timer could not be
// observed firing here — which is exactly how the bug survived the first time.
~tEq.("the save arm schedules no expiry", fam[\armRoutine], nil);
~saveGranularPreset.();
~tEq.("second click commits", statusOf.(\granular), "Saved decoy-one");
~tEq.("...and disarms", fam[\saveArmed], false);
~tEq.("...and forgets the armed name", fam[\saveArmedSlug], nil);

// An arm raised for one name must never commit a DIFFERENT one on a single
// click: retype while armed and the new name gets its own confirmation.
~loadGranularPreset.("frozen-cathedral");
fam[\nameField][\string] = "Decoy One";
~saveGranularPreset.();                        // arms for decoy-one
~tEq.("armed for the typed name", fam[\saveArmedSlug], "decoy-one");
fam[\nameField][\string] = "Decoy Two";        // still armed, different name
~saveGranularPreset.();
~tAssert.("a stale arm does not commit a different name",
    statusOf.(\granular).contains("click again"), statusOf.(\granular));
~tEq.("...it re-arms for the new one", fam[\saveArmedSlug], "decoy-two");

// Back to one preset, so the folder assertions further down still describe it.
~presetDisarm.(\granular);
["decoy-one", "decoy-two"].do { |slug|
    File.delete(~granularPresetDir +/+ slug ++ ".scd")
};
~loadGranularPreset.("frozen-cathedral");
~refreshGranularPresetList.();
~tEq.("the decoys are gone again",
    fam[\menu][\items], ["— none —", "frozen-cathedral"]);

// Recall.
~looper.granularSize = 1;
fam[\nameField][\string] = "something else";
~tEq.("load reports success", ~loadGranularPreset.("frozen-cathedral"), true);
~tEq.("load says so", statusOf.(\granular), "Loaded frozen-cathedral");
~tNear.("load reached the model", ~looper.granularSize, 2.5, 1e-9);
~tEq.("load puts the slug in the name field",
    fam[\nameField][\string], "frozen-cathedral");

// A slug with no file behind it: report it and rescan, rather than leaving the
// menu claiming something that is gone.
~tEq.("loading a missing file reports failure", ~loadGranularPreset.("ghost"), false);
~tEq.("...and says which", statusOf.(\granular), "Missing file: ghost.scd");

// Deleted outside megalooper while OTHER presets remain: the rescan must clear
// the selection and say so, because the menu index of everything below the
// deleted file has moved.
fam[\nameField][\string] = "Keeper";
~saveGranularPreset.();
fam[\loaded] = "frozen-cathedral";
File.delete(~granularPresetDir +/+ "frozen-cathedral.scd");
~refreshGranularPresetList.();
~tAssert.("a vanished preset clears the selection, with a reason",
    statusOf.(\granular).contains("gone from disk"), statusOf.(\granular));
~tEq.("...and nothing is selected", fam[\loaded], nil);
~tEq.("...and the survivor is still listed",
    fam[\menu][\items], ["— none —", "keeper"]);

// The LAST preset vanishing is the other branch, and it clears SILENTLY: the
// menu switches to "— no presets yet —", which is its own explanation, so
// there is no status line. Asserted so the difference between the two branches
// is on the record rather than a surprise.
fam[\loaded] = "keeper";
~granularPresetSetStatus.("something else entirely");
File.delete(~granularPresetDir +/+ "keeper.scd");
~refreshGranularPresetList.();
~tEq.("the last preset vanishing clears the selection", fam[\loaded], nil);
~tEq.("...silently — the empty menu label is the explanation",
    statusOf.(\granular), "something else entirely");
~tEq.("...and the menu says it is empty",
    fam[\menu][\items], ["— no presets yet —"]);

// Revert with nothing selected.
~revertGranularPreset.();
~tEq.("revert with no selection is refused",
    statusOf.(\granular), "Nothing selected to revert to.");

// Delete: arm, then commit.
fam[\nameField][\string] = "Take Two";
~saveGranularPreset.();
~tEq.("a second preset saves", fam[\loaded], "take-two");
~deleteGranularPreset.();
~tAssert.("first click on Delete only arms",
    statusOf.(\granular).contains("Click again"), statusOf.(\granular));
~tEq.("...and the button says so",
    fam[\deleteButton][\states][0][0], "Delete — sure?");
~deleteGranularPreset.();
~tEq.("second click deletes", statusOf.(\granular), "Deleted take-two");
~tEq.("...and clears the selection", fam[\loaded], nil);
~tEq.("...and the folder is empty again", ~looper.granularPresetNames(~granularPresetDir), []);
~deleteGranularPreset.();
~tEq.("delete with no selection is refused",
    statusOf.(\granular), "Nothing selected to delete.");

// Revert re-reads from disk, discarding live edits.
fam[\nameField][\string] = "Revert Me";
~looper.granularPitch = 5;
~saveGranularPreset.();
~looper.granularPitch = -12;
~revertGranularPreset.();
~tEq.("revert says so", statusOf.(\granular), "Reverted to revert-me");
~tNear.("revert restores the saved value", ~looper.granularPitch, 5.0, 1e-9);
}.value;

// ---- the cutter family shares the code, so just prove it is wired -------

{
var fam = install.(\bbcut);
fam[\nameField][\string] = "Cutter Preset";
~looper.setVoiceProc(0, \warp);
~refreshBBCutPresetList.();
~saveBBCutPreset.();
~tEq.("bbcut save reports the slug", statusOf.(\bbcut), "Saved cutter-preset");
~tEq.("bbcut menu lists it", fam[\menu][\items], ["— none —", "cutter-preset"]);
~looper.setVoiceProc(0, \break);
~tEq.("bbcut load reports success", ~loadBBCutPreset.("cutter-preset"), true);
~tEq.("bbcut load reached the model",
    ~tGet.(~looper, \bbcutVoices)[0][\proc], \warp);
~deleteBBCutPreset.();
~deleteBBCutPreset.();
~tEq.("bbcut delete works", statusOf.(\bbcut), "Deleted cutter-preset");

// The two families must stay independent: a save in one must not show in the
// other's listing.
~tEq.("the two families do not see each other's presets",
    ~looper.granularPresetNames(~granularPresetDir).includesEqual("cutter-preset"),
    false);
}.value;

// ---- put the session back -----------------------------------------------

[\bbcut, \granular].do { |key|
    ~presetStopTimers.(key);
    [\menu, \nameField, \saveButton, \revertButton, \deleteButton, \statusText]
        .do { |slot| ~presetFamilies[key][slot] = nil };
    ~presetFamilies[key][\loaded] = nil;
    ~presetFamilies[key][\items] = [nil];
};
[~bbcutPresetDir, ~granularPresetDir].do { |d|
    (d +/+ "*.scd").pathMatch.do { |f| File.delete(f) };
};
~looper            = savedLooper;
~bbcutPresetDir    = savedBDir;
~granularPresetDir = savedGDir;
~tEq.("the session's looper is restored", ~looper, savedLooper);
~tEq.("the real preset directories are restored", ~granularPresetDir, savedGDir);
~tRemoveTree.(root);
}.value;
