// megalooper — the Drums pane: Megalooper SA's drums as the Live set played
// them (docs/dev/megalooper-sa.md, Phase 4). Rhythmic Steps' two patterns on the
// step grid the device shows, their timing, the two kits with their trims, and
// the drums' part of the mix.
//
// Loaded by boot.scd after gui-sa.scd and gui-effects.scd; defines only, runs
// nothing. Entry point:
//   ~buildDrumsPane — builds the pane against the EXISTING ~megaSA's drums (a
//                     MegaSADrums) and swaps it into the shell's holder. Only
//                     an SA rig has the tab (gui-shell.scd), and the pane says
//                     so if it is built without the drums.
//
// The lanes read like the device: a strip per lane, sixteen steps, each step a
// value 0..6 drawn as a bar, and page tiles above choosing what the bars are
// (Chance, Alt, Velo, Roll; Slide is kept in the patterns but not shown, as
// one-shots ignore it). The Main | Break tiles choose which of the set's two
// devices the strips show. Which one PLAYS is the header's switch, which the
// Looper's break throws as Live's CC 100 did; the playhead says it too, bright
// on the pattern being heard and dim on the other, which keeps running
// silently as Live's switched-off device did.
//
// As everywhere in this GUI, a widget writes to the model only and the model's
// notifications paint it back, so a preset recall, Reset pattern, PC 17 and the
// Looper's break reach the widgets the way the mouse does. Every widget the
// model paints is in one table, ~drumsWidgets, with a function that reads its
// value from the model at paint time: one painter serves them all, and showing
// the other pattern or page is a repaint, never a rebuild.
(
// ---- Sizes ----------------------------------------------------------------
// The step lanes have a fixed size, so a pane that was never shown (headless,
// check-gui-drums.scd) has the geometry the mouse handlers compute with:
// sixteen 56 px steps beside a 110 px label column, in the Drums view. (44
// px each while the drums shared a view with the effects; on a view of their
// own the lanes had a third of the window empty beside them.)
~drumsLabelWidth = 110;
~drumsCellWidth = 56;
~drumsLaneHeight = 44;
~drumsKnobWidth = 58;      // a timing knob with its label and readout
~drumsTrimWidth = 54;      // a trim knob
~drumsTrimsPerRow = 14;
~drumsPlayheadHz = 20;     // playhead polls a second, only while the tab shows

// What the lanes show. Survives a rebuild, as the Effects tab's selection does,
// so rebuilding the window does not throw away the page you were on.
~drumsPattern = ~drumsPattern ? \main;
~drumsPage = ~drumsPage ? \chance;

// The rows the pane draws, by name (MegaSASteps' tables). check.scd asserts
// each one resolves: a renamed row would otherwise throw when the tab builds,
// at boot.
~drumsParamNames = [\clockSpeed, \rollRate, \autoRetrigger, \autoTriggerRate, \shuffleLength,
    \globalShuffle] ++ (1..8).collect { |n| ("shuffle" ++ n).asSymbol };
~drumsLaneParamNames = [\note, \altNote, \delay, \mute, \lock, \globalLength, \length];

// ---- The model -------------------------------------------------------------
// MegaSA's drums, or nil: no SA, or a MegaSA from before it had drums. An
// Event standing in for MegaSA (check-gui-drums.scd) answers `drums` by key.
~drumsModel = {
    ~megaSA !? { |m|
        if(m.isKindOf(Dictionary) or: { m.respondsTo(\drums) }) { m.drums }
    }
};

// The drums for the preset bar, only once they keep presets: a model without
// them leaves an empty bar rather than one that throws at its first rescan.
~drumsPresetModel = {
    ~drumsModel.() !? { |d| if(d.respondsTo(\savePreset)) { d } }
};

// ---- Geometry (pure) ---------------------------------------------------------
// The only arithmetic the mouse handlers do, kept out of them so it can be
// checked without a window (Pen draws only inside a paint, so the picture
// cannot be): the step under x, and the value at height y of a strip h tall,
// the top seventh being 6 and the bottom 0. Both are held to the strip, so a
// drag that leaves it paints the step at its edge.
~drumsStepAt = { |x| ((x / ~drumsCellWidth).floor.asInteger).clip(0, 15) };
~drumsValueAt = { |y, h| (((h - y) / h) * 7).floor.asInteger.clip(0, 6) };
// The column a lane's playhead is in: its lane step wrapped on the page's
// length, as the device reads it (every page wraps on its own).
~drumsColumnAt = { |ls, len| MegaSASteps.laneIndex(ls, len) };

// ---- Words -----------------------------------------------------------------
~drumsPatternLabels = (main: "Main", break: "Break");
~drumsPageLabels = (chance: "Chance", alt: "Alt", velo: "Velo", roll: "Roll");
// What a page's bars mean, from MegaSASteps' rules: a step plays when its
// Chance beats a die of 0..5, Alt is the same draw for the other pad, Velo
// indexes the device's velocity table and Roll counts extra hits.
~drumsPageHints = (
    chance: "Chance: how likely each step plays, from 0 (never) to 6 (always), a die drawn per step.",
    alt: "Alt: how likely the step plays the lane's Alt pad instead of its Note, its own die.",
    velo: "Velo: the step's velocity, 0..6 = 10, 29, 49, 68, 88, 107, 127 (0 still plays).",
    roll: "Roll: extra hits after the note, 0..6, at the Roll rate, each 0.7 times as loud."
);
// The bars' colours, one per page, so a glance says which page is showing.
// The device draws its alternative pad in blue.
~drumsPageColors = (
    chance: Color.new(0.4, 0.78, 0.48),
    alt: Color.new(0.42, 0.62, 0.95),
    velo: Color.new(0.95, 0.68, 0.3),
    roll: Color.new(0.76, 0.52, 0.92)
);

// A setting as the device shows it: a choice's label, On or Off, or the number
// in its units, with as many decimals as its size deserves.
~drumsFormat = { |p, val|
    var c = p[\choices], shown;
    case
    { val.isNil } { "—" }
    { p[\bool] == true } { if(val == true) { "On" } { "Off" } }
    { c.notNil } { (c.detect { |pair| pair[0] == val } !? { |pair| pair[1] }) ? val.asString }
    {
        shown = case
            { p[\spec].step >= 1 } { val.round.asInteger.asString }
            { val.abs >= 10 } { val.round(0.1).asString }
            { val.round(0.01).asString };
        (if((p[\centered] == true) and: { val > 0 }) { "+" } { "" }) ++ shown ++ (p[\units] ? "")
    }
};

~drumsDbText = { |db|
    var v = (db ? 0).round(0.5);
    (if(v > 0) { "+" } { "" }) ++ v.asString
};

// A control's tooltip. (It once added the original device's own help text,
// which is Ableton's to publish, not ours; `device` is kept for the callers.)
~drumsTip = { |tip, device| tip ? "" };

// "42 HiHat Closed Carbon · F#1": the note, the slot's pad on it ("(empty)"
// where the kit in force has none, nothing with no kit), and the note in
// Live's octave numbering (~midiNoteName, gui-analysis.scd) last, so a menu
// too narrow for all of it cuts the least telling part.
~drumsNoteText = { |d, note, slot = \steps|
    var name = d !? { |dd| dd.padName(slot, note) };
    var kit = d !? { |dd| dd.kitFor(slot) };
    var noteName = ~midiNoteName !? { |f| f.(note) };
    [note.asString, name ?? { if(kit.notNil) { "(empty)" } }].reject(_.isNil).join(" ")
        ++ ((noteName !? { |n| " · " ++ n }) ? "")
};
~drumsNoteItems = { |d| (36..51).collect { |n| ~drumsNoteText.(d, n) } };

// A pad's name cut to its first word, for a 50 px knob: "HiHat", "Kick". The
// tooltip has the whole name.
~drumsPadShort = { |name| (name ? "").split($ ).first ? "" };

// ---- Kits --------------------------------------------------------------------
// Is there a kit to play on this Mac? megalooper ships every kit's map and
// never its samples: the kits it was built on play Ableton's. With none the
// pane says so and shows nothing else (~buildDrumsPane). The folder is read
// again before it says no, so kits made while megalooper runs show at the
// next build (a theme switch, or a boot).
~drumsKitsHere = { |d|
    d.respondsTo(\kitsWithAudio).not or: { d.kitsWithAudio.notEmpty }
        or: { d.rescanKits; d.kitsWithAudio.notEmpty }
};
~drumsNoKitsText = { |d|
    var mac = MegaFiles.isMac;
    "The drums are hidden: no kit on this " ++ (if(mac) { "Mac" } { "machine" }) ++ " has its samples.\n\n"
    "megalooper ships each kit's map (" ++ ((d.kitDir ? "presets/sa/drums/kits") +/+ "<kit>.json") ++ ") but not its audio: "
    "the kits it was built on play Ableton's samples, which cannot be passed on.\n\n"
    ++ (if(mac) { "With Ableton Live on this Mac, python3 tools/export-live-set.py kits copies them into that folder. " }
        { "Kits you exported on a Mac can be copied here: each kit's folder beside its .json. " })
    ++ "Then start megalooper again.\n\n"
    "A kit of your own samples needs no restart: Import samples… below takes a folder of one-shots. "
    "docs/drums.md says how their names place them."
};

~drumsKitName = { |d, key|
    var info = d.kitInfo(key);
    if(info.isNil) { key.asString } {
        info[\name] ++ (if(info[\readable] == true) { "" } { " (unreadable)" })
    }
};

~drumsKitStates = (
    ready: "ready",
    partial: "partial: some samples did not load (see the post window)",
    loading: "loading…",
    missing: "missing: no samples here (python3 tools/export-live-set.py kits)",
    failed: "failed: the server did not read them (see the post window)",
    unset: "no kit: this part is silent"
);

// What a slot plays, in a line: its state, and once it plays, how many pads,
// and for the onset kit the pad the Looper's onset notes land on.
~drumsKitLine = { |d, slot|
    var state = d.kitState(slot), kit = d.kitFor(slot);
    var text = ~drumsKitStates[state] ? state.asString;
    if(#[\ready, \partial].includes(state) and: { kit.notNil }) {
        text = text ++ " · " ++ kit.notes.size ++ " pads";
        if(slot == \onset) {
            text = text ++ " · onset notes play "
                ++ ~drumsNoteText.(d, (~looper !? { |l| l.onsetNote }) ? 36, \onset);
        };
    };
    text
};
~drumsKitLineBad = { |d, slot| #[\partial, \missing, \failed].includes(d.kitState(slot)) };

~drumsKitTip = { |slot|
    var d = ~drumsModel.(), info;
    info = d !? { |dd| dd.kit(slot) !? { |k| dd.kitInfo(k) } };
    (if(slot == \steps) {
        "The kit the step sequencer plays. The set plays Kit-Carbon over a KJ Sawka 9 layer;\n"
        "Kit-Carbon + layer is that, with Core Library stand-ins for the KJ samples\n"
        "(Live's are encrypted)."
    } {
        "The kit the Looper's onset notes play. The set plays the One Hit Kit; One Hit Kit\n"
        "here has Core Library stand-ins for its samples (Live's are encrypted).\n"
        "The drums' footswitch does not switch it."
    }) ++ ((info !? { |i|
        "\n\n" ++ i[\name] ++ ": " ++ (i[\description] ? "")
            ++ ((i[\source] !? { |s| "\nFrom " ++ s }) ? "")
    }) ? "") ++ "\n— none —: no kit, so this part is silent; presets and Keep keep it that way."
        ++ "\nKits are presets/sa/drums/kits/*.json, made by python3 tools/export-live-set.py kits,"
        ++ "\nor from a folder of your own samples by Import samples… at the top."
};

// ---- Importing a kit ---------------------------------------------------------
// "Import samples…" in the drums' header, and on the note a clone shows
// instead of the drums: choose a folder of one-shots, and
// tools/export-live-set.py makes a kit of it (the command docs/drums.md
// gives), which the Steps part then plays. The tool runs beside megalooper,
// so the drums play on meanwhile. (It was under the kit menus, below the
// lanes and Timing, where a rig with kits did not find it.)
~drumsImporting = false;
~drumsImportSaid = ~drumsImportSaid ? "";
~drumsImportBad = ~drumsImportBad ? false;
~drumsImportViews = nil;

// The folder dialog, the search for python3 and the run of the tool: each a
// function, so a check can stand its own in.
~drumsImportAsk = { |action|
    FileDialog({ |got| action.(if(got.isString) { got } { got.asArray.first }) }, { }, 2, 0, true);
};
~drumsImportPython = { MegaFiles.commandPath(["python3"]) };
~drumsImportRunner = { |cmd, done|
    var log = PathName.tmp +/+ ("megalooper-import-" ++ thisProcess.pid ++ "-" ++ UniqueID.next ++ ".log");
    (cmd ++ " > " ++ log.shellQuote ++ " 2>&1").unixCmd({ |code|
        var said = MegaFiles.readText(log) ? "";
        if(File.exists(log)) { File.delete(log) };
        { done.(code, said) }.defer;
    }, false);
};

// A kit's key from a folder's name: lower-case letters, digits and dashes,
// which is what the tool takes.
~drumsImportSlug = { |name|
    var s = name.asString.toLower.collect { |c|
        if(c.ascii.inclusivelyBetween(48, 122) and: { c.isAlphaNum }) { c } { $- } };
    while { s.contains("--") } { s = s.replace("--", "-") };
    while { s.beginsWith("-") } { s = s.drop(1) };
    while { s.endsWith("-") } { s = s.drop(-1) };
    if(s.isEmpty) { "kit" } { s }
};
// The tool writes the folder a kit was made from as its source.
~drumsImportSameFolder = { |info, folder|
    info[\source].notNil and: {
        info[\source].asString.standardizePath.withoutTrailingSlash == folder.standardizePath.withoutTrailingSlash }
};
// A kit of that key made from something else keeps its place, and this one
// gets -2, -3 …. The same folder again replaces its own kit: rename the files
// the tool could not place, and import again.
~drumsImportKey = { |d, folder|
    var base = ~drumsImportSlug.(folder.withoutTrailingSlash.basename), key, n = 1, info;
    key = base;
    while { info = d.kitInfo(key); info.notNil and: { ~drumsImportSameFolder.(info, folder).not } and: { n < 99 } } {
        n = n + 1;
        key = base ++ "-" ++ n;
    };
    key
};
// The tool writes into <out>/drums/kits: the folder the drums read, or nil
// when that is no such folder.
~drumsImportOut = { |d|
    var dir = d.kitDir !? { |k| k.withoutTrailingSlash };
    if(dir.notNil and: { dir.endsWith("drums" +/+ "kits") }) { dir.dirname.dirname }
};
~drumsImportCommand = { |d, folder, key|
    var python = ~drumsImportPython.(), out = ~drumsImportOut.(d);
    var tool = (~megalooperRoot ?? { Looper.repoRoot }) +/+ "tools" +/+ "export-live-set.py";
    if(python.isNil or: { out.isNil }) { nil } {
        python.shellQuote ++ " " ++ tool.shellQuote ++ " kits --folder " ++ folder.shellQuote
            ++ " --key " ++ key.shellQuote ++ " --out " ++ out.shellQuote
    }
};
// What the tool said: the files it could not place, and why it stopped.
~drumsImportReport = { |key, code, said|
    var lines = (said ? "").split($\n).collect(_.stripWhiteSpace).reject(_.isEmpty);
    var mark = key ++ "  unmapped: ";
    var why = lines.detect(_.beginsWith("kits: "));
    (ok: code == 0,
        unmapped: lines.select(_.beginsWith(mark)).collect { |l| l.copyToEnd(mark.size) },
        why: (why !? { |w| w.copyToEnd(6) })
            ?? { lines.last ?? { "the tool said nothing (exit " ++ code ++ ")" } })
};
~drumsImportText = { |name, pads, unmapped|
    "Imported " ++ name ++ ": " ++ pads ++ (if(pads == 1) { " pad" } { " pads" }) ++ ". The Steps part plays it."
        ++ if(unmapped.isEmpty) { "" } {
            " Not placed: " ++ unmapped.keep(4).join(", ")
                ++ (if(unmapped.size > 4) { " and " ++ (unmapped.size - 4) ++ " more" } { "" })
                ++ ". Name a file after its drum (kick, snare, hat closed …) and import again."
        }
};

// The line under the header shows only once there is something to say
// (`hideEmpty`). Its visibility is set only once a pane holds it (`placed`):
// a view made visible before it has a parent opens as a window of its own.
~drumsImportShow = {
    ~drumsImportViews !? { |v|
        if(v[\line].isClosed.not) {
            v[\line].string_(~drumsImportSaid).stringColor_(if(~drumsImportBad) { ~gt[\rec] } { ~guiHintColor });
            if((v[\hideEmpty] == true) and: { v[\placed] == true }) {
                v[\line].visible_(~drumsImportSaid.notEmpty);
            };
        };
        if(v[\button].isClosed.not) { v[\button].enabled_(~drumsImporting.not) };
    };
};
~drumsImportSay = { |text, bad = false|
    ~drumsImportSaid = text;
    ~drumsImportBad = bad;
    if(bad) { ("megalooper: " ++ text).warn } { ("megalooper: " ++ text).postln };
    ~drumsImportShow.();
};

// The tool is done. A kit it made is read, shown in the menus (the pane is
// built again: on a clone's note that is the drums themselves appearing) and
// given to the Steps part, and to the onset part too where that has no kit
// that sounds, as a boot would (setup-sa.scd).
~drumsImportDone = { |key, code, said|
    var d = ~drumsModel.(), r = ~drumsImportReport.(key, code, said), info;
    ~drumsImporting = false;
    case
    { d.isNil } { ~drumsImportShow.() }
    { r[\ok].not } { ~drumsImportSay.("Not imported: " ++ r[\why], true) }
    {
        d.rescanKits;
        info = d.kitInfo(key.asSymbol);
        if(info.isNil or: { info[\audio] != true }) {
            ~drumsImportSay.("Not imported: the tool made no kit " ++ key ++ " that megalooper can read.", true);
        } {
            ~drumsImportSay.(~drumsImportText.(info[\name], info[\pads].size, r[\unmapped]));
            ~buildDrumsPane.();
            d.setKit(\steps, key.asSymbol);
            if(d.kitEmptied(\onset).not and: { d.kit(\onset).isNil or: { d.kitState(\onset) == \missing } }) {
                d.setKit(\onset, key.asSymbol);
            };
        };
    };
};

// A folder of one-shots, imported. One at a time.
~drumsImport = { |folder|
    var d = ~drumsModel.(), key, cmd;
    case
    { d.isNil or: { ~drumsImporting } or: { folder.isNil } } { nil }
    { ~drumsImportOut.(d).isNil } {
        ~drumsImportSay.("Not imported: megalooper's kits folder (" ++ d.kitDir
            ++ ") is not a drums/kits folder, where the tool writes.", true);
    }
    { ~drumsImportPython.().isNil } {
        ~drumsImportSay.("Not imported: python3 is not installed, and the import runs "
            "tools/export-live-set.py with it.", true);
    }
    {
        key = ~drumsImportKey.(d, folder);
        cmd = ~drumsImportCommand.(d, folder, key);
        ~drumsImporting = true;
        ~drumsImportSay.("Importing " ++ folder.withoutTrailingSlash.basename ++ " …");
        ~drumsImportRunner.(cmd, { |code, said| ~drumsImportDone.(key, code, said) });
    };
};

// The button and the line that says how the last import went: one pair at a
// time, the pane's. `header`: the button sized and coloured as the header's
// others, and the line under the header, hidden while it is empty
// (~drumsImportShow).
~drumsImportViewsMake = { |header = false|
    var button = ~drumsButton.().cycles_(false).fixedWidth_(150)
        .fixedHeight_(if(header) { 34 } { 28 })
        .states_([["Import samples…", ~gt[\ink], if(header) { ~gt[\panel] }]])
        .toolTip_("A kit from a folder of your own one-shots (wav, aif, flac, ogg): choose the folder,\n"
            "and its files go onto pads by the words in their names: kick, snare, rim, clap,\n"
            "hat closed, hat open, tom, crash, ride, perc. The Steps part then plays the kit.\n"
            "Files it cannot place are listed here: rename them and import the folder again.\n"
            "The samples are copied into megalooper's kits folder. docs/drums.md has the table.")
        .action_({ ~drumsImportAsk.({ |folder| ~drumsImport.(folder) }) });
    var line = StaticText().font_(~guiHintFont);
    ~drumsImportViews = (button: button, line: line, hideEmpty: header);
    ~drumsImportShow.();
    ~drumsImportViews
};
// On the note: the button with its line beside it.
~drumsImportRow = {
    var v = ~drumsImportViewsMake.();
    HLayout(v[\button], [v[\line], stretch: 1]).spacing_(8)
};
// The pane holds the views now: the line may be shown or hidden.
~drumsImportPlaced = {
    ~drumsImportViews !? { |v| v[\placed] = true };
    ~drumsImportShow.();
};

// ---- Trims -------------------------------------------------------------------
~drumsTrimSpec = ControlSpec(-24, 12, \lin, 0.5, 0, " dB");

// The kit playing in a slot if it is the one asked for: trims are kept per kit
// key, so while another kit loads there is nothing honest to trim.
~drumsKitInForce = { |d, slot|
    var kit = d.kitFor(slot);
    if(kit.notNil and: { kit.key == d.kit(slot) }) { kit }
};

// The groups a layer trim is for: every group but the kit's main one (the one
// most pads play first). Kit-Carbon + layer gets one, for the KJ stand-ins
// under Kit-Carbon, whose balance Live's files cannot tell (both sources are
// normalised); a kit of one group gets none.
~drumsLayerGroups = { |kit|
    var counts = IdentityDictionary.new, main;
    if(kit.groupKeys.size < 2) { [] } {
        kit.pads.do { |pad|
            pad[\layers].first !? { |l| counts.put(l[\group], (counts[l[\group]] ? 0) + 1) };
        };
        main = counts.keys.asArray.sort.maxItem { |g| counts[g] };
        kit.groupKeys.reject { |g| g == main }
    }
};

// The notes the patterns play: every lane's Note and Alt, in both patterns.
~drumsUsedNotes = { |d|
    var notes = Set.new;
    [\main, \break].do { |w|
        4.do { |lane|
            [\note, \altNote].do { |k| d.laneParam(w, lane, k) !? { |n| notes.add(n) } };
        };
    };
    notes.asArray.sort
};

~drumsTrimKey = { |slot, note| ("trim_" ++ slot ++ "_" ++ note).asSymbol };
~drumsGroupKey = { |group| ("trimGroup_" ++ group).asSymbol };

// ---- View state ----------------------------------------------------------------
// Emptied on close and on every rebuild, so a notification arriving after the
// pane is gone finds nothing to write to rather than a destroyed view. Loading
// this file again first removes the controllers a pane already hung on the
// model, or they would stay subscribed with nothing to paint; the pane must
// then be rebuilt, as the Effects pane must.
(~drumsControllers ? []).do(_.remove);
~drumsControllers = [];
~drumsWidgets = IdentityDictionary.new;   // key -> (kind:, view:, get:, ...), see ~drumsPaint
~drumsLanes = IdentityDictionary.new;     // lane -> its step strip
// lane -> where its drag last was, (x:, y:), or \live after a double-click
// (~drumsLanePress, ~drumsLaneMove).
~drumsLaneDrag = IdentityDictionary.new;
~drumsTiles = IdentityDictionary.new;     // \main \break and the pages -> tile
~drumsLevels = IdentityDictionary.new;    // strip -> gui-sa.scd's row widgets
~drumsTrimHolder = nil;
// The knob or slider the mouse is holding. The model does not reposition it
// while held: Knob.value_ does not snap to the spec's step, so a stepped
// value pushed back under the hand would never move.
~drumsHeld = nil;
// The playhead last painted: the shown pattern's (which:, n:, ls:), and
// whether that pattern is the one being heard.
~drumsPlayhead = nil;
~drumsPlayheadHeard = false;
~drumsPlayShown = nil;
// The pane's own generation: a newer pane, a reload or the teardown retires
// the playhead poll. Never ~guiGen, which would stop the shell's position
// routine as well.
~drumsGen = (~drumsGen ? 0) + 1;

~guiTeardowns = ~guiTeardowns ? ();
~guiTeardowns[\drums] = {
    ~drumsControllers.do(_.remove);
    ~drumsControllers = [];
    ~drumsWidgets = IdentityDictionary.new;
    ~drumsLanes = IdentityDictionary.new;
    ~drumsLaneDrag = IdentityDictionary.new;
    ~drumsTiles = IdentityDictionary.new;
    ~drumsLevels = IdentityDictionary.new;
    ~drumsTrimHolder = nil;
    ~drumsHeld = nil;
    ~drumsPlayhead = nil;
    ~drumsPlayShown = nil;
    ~drumsGen = ~drumsGen + 1;
};

// ---- Presets -------------------------------------------------------------------
// The shared bar (gui-presets.scd) over MegaSADrums' preset methods. A preset
// is both patterns, the kits (a slot set to "— none —" as well: it comes back
// empty), their trims, Beat Repeat, the reverb and the offset; the on/off
// switch, the break and the mixer levels stay where the footswitches and
// faders put them.
~definePresetFamily.(\saDrums, (
    label:      "Drums",
    statusIdle: "Pick a preset to recall it · Save keeps both patterns, the kits and their trims",
    dirKey:     \saDrumsPresetDir,
    names:      \presetNames,
    slug:       \presetSlug,
    save:       \savePreset,
    load:       \loadPreset,
    delete:     \deletePreset,
    model:      { ~drumsPresetModel.() }
));

// ---- Model -> view -------------------------------------------------------------
// Paint one widget from the model. `get` reads its value (at paint time, so
// the pattern and page shown are the current ones); `index` turns a value into
// a menu item; `format` writes the readout; `enabled`, `tip` and `color` are
// optional functions painted with it (`groove`, a slider's own groove colour,
// goes grey with `enabled`). A held knob or slider keeps its place, and its
// readout still follows.
~drumsPaint = { |key|
    var w = ~drumsWidgets[key], view, v, i, en;
    if(w.notNil) {
        view = w[\view];
        if(view.notNil and: { view.isClosed.not }) {
            v = w[\get].value;
            switch(w[\kind],
                \knob, { if((~drumsHeld != key) and: { v.notNil }) { view.value = w[\spec].unmap(v) } },
                \slider, { if((~drumsHeld != key) and: { v.notNil }) { view.value = w[\spec].unmap(v) } },
                \menu, {
                    i = w[\index].value(v);
                    if(i.notNil and: { i >= 0 } and: { i < view.items.size }) { view.value = i };
                },
                \button, { view.value = (v == true).binaryValue },
                \number, { if(v.notNil) { view.value = v } },
                \text, { view.string_((v ? "").asString) },
                // Beat Repeat's switch: off and on where the steps kit has
                // it, a plain "none" where it has not (a two-state button
                // would cycle on a click there).
                \repeats, {
                    if(w[\available].value == true) {
                        view.states_([["Repeats off", ~gt[\ink], ~gt[\panel]],
                            ["REPEATS", ~gt[\onacc], ~gt[\drum]]]);
                        view.value = (v == true).binaryValue;
                        view.enabled_(true);
                    } {
                        view.states_([["no repeats", ~gt[\mute], ~gt[\panel]]]);
                        view.enabled_(false);
                    };
                }
            );
            w[\readout] !? { |r| r.string_(w[\format].value(v)) };
            w[\enabled] !? { |f|
                en = f.value == true;
                view.enabled_(en);
                w[\readout] !? { |r| r.stringColor_(if(en) { ~guiInk } { ~gt[\mute] }) };
                // A bar's groove (its own colour, kept as `groove`) greys too.
                w[\groove] !? { |c| view.background_(if(en) { c } { ~gt[\line] }) };
            };
            w[\tip] !? { |f| view.toolTip_(f.value) };
            w[\color] !? { |f| view.stringColor_(f.value) };
        };
    };
};

// A lane strip repaints itself from the model; this asks it to. Counted, so a
// check can tell a repaint that was asked for from one that was not (a hidden
// view never paints).
~drumsRefreshLane = { |lane|
    ~drumsLanes[lane] !? { |v|
        if(v.isClosed.not) {
            ~drumsLaneRefreshes = (~drumsLaneRefreshes ? 0) + 1;
            v.refresh;
        };
    };
};
~drumsRefreshLanes = { 4.do { |lane| ~drumsRefreshLane.(lane) } };

~drumsLaneKey = { |name, lane| (name ++ lane).asSymbol };
~drumsKitKey = { |slot| ("kit_" ++ slot).asSymbol };
~drumsKitLineKey = { |slot| ("kitLine_" ++ slot).asSymbol };

~drumsRefreshLaneRow = { |lane|
    [\label, \note, \altNote, \len, \lock, \delay, \mute].do { |k| ~drumsPaint.(~drumsLaneKey.(k, lane)) };
};

// A page of the shown pattern is edited when a step or its length is off the
// Live set's.
~drumsPageEdited = { |d, which, page|
    var live = MegaSASteps.livePattern(which);
    (0..3).any { |lane|
        (d.length(which, page, lane) != live[\lengths][page][lane])
            or: { (0..15).any { |i| d.step(which, page, lane, i) != live[\steps][page][lane][i] } }
    }
};

// The tiles: dark while selected, a dot while off the Live set's (a pattern
// anywhere in it, a page in the pattern shown).
~drumsRefreshTiles = {
    var d = ~drumsModel.();
    ~drumsTiles.keysValuesDo { |key, b|
        var isPattern = ~drumsPatternLabels.includesKey(key);
        var sel = if(isPattern) { key == ~drumsPattern } { key == ~drumsPage };
        var edited = d.notNil and: {
            if(isPattern) { d.edited(key) } { ~drumsPageEdited.(d, ~drumsPattern, key) } };
        if(b.isClosed.not) {
            b.states_([[(~drumsPatternLabels[key] ? ~drumsPageLabels[key]) ++ (if(edited) { " •" } { "" }),
                if(sel) { ~gt[\bg] } { ~gt[\ink] },
                if(sel) { ~gt[\ink] } { ~gt[\bg] }]]);
        };
    };
};

// The menus name the steps kit's pads, so they follow the kit in force.
~drumsRefreshNoteItems = {
    var d = ~drumsModel.(), items;
    if(d.notNil) {
        items = ~drumsNoteItems.(d);
        4.do { |lane|
            [\note, \altNote].do { |k|
                ~drumsWidgets[~drumsLaneKey.(k, lane)] !? { |w|
                    if(w[\view].isClosed.not) { w[\view].items_(items) };
                };
                // items_ resets the menu to its first item.
                ~drumsPaint.(~drumsLaneKey.(k, lane));
            };
        };
    };
};

// Everything that shows the pattern being edited.
~drumsRefreshPattern = {
    4.do { |lane| ~drumsRefreshLaneRow.(lane) };
    ~drumsParamNames.do { |name| ~drumsPaint.(name) };
    ~drumsPaint.(\timingTitle);
    ~drumsPaint.(\pageHint);
    ~drumsRefreshTiles.();
    ~drumsRefreshLanes.();
};

~drumsRefreshAll = {
    var m = ~megaSA;
    [\on, \breakActive, \repeats, \reverbMix, \reverbState, \offsetMs].do { |k| ~drumsPaint.(k) };
    [\steps, \onset].do { |slot|
        ~drumsPaint.(~drumsKitKey.(slot));
        ~drumsPaint.(~drumsKitLineKey.(slot));
    };
    ~drumsRefreshNoteItems.();
    ~drumsRefreshPattern.();
    ~drumsRebuildTrims.();
    ~drumsLevels.keysDo { |k|
        ~saPaintLevel !? { |f| f.(~drumsLevels, k, m !? { |mm| mm.level(k) }) };
        ~saPaintMute !? { |f| f.(~drumsLevels, k, m !? { |mm| mm.mute(k) }) };
    };
};

// A kit settled in a slot: the names the steps kit gives the lanes and
// menus, its Beat Repeat, and the trims, which belong to the kit in force. A
// kit that did not load says so on the bar's status line as well as its own.
~drumsKitChanged = { |slot, state|
    // The MIDI controls for the new kit's pads, under its names, before the
    // trims are built again and tagged (setup-midimap.scd).
    ~midiTargetsRefresh !? { |f| f.value };
    if(slot == \steps) {
        ~drumsRefreshNoteItems.();
        4.do { |lane| ~drumsRefreshLaneRow.(lane) };
        ~drumsPaint.(\repeats);
    };
    ~drumsRebuildTrims.();
    if(#[\partial, \missing, \failed].includes(state)) {
        ~presetSetStatus.(\saDrums, "The " ++ (if(slot == \steps) { "steps" } { "onset" })
            ++ " kit is " ++ state ++ ": see its line under Kits.", true);
    };
};

// Show the other pattern or page. Only what the pane shows changes: the model
// is not touched. The widgets' MIDI Map tags name the pattern and page shown
// (~drumsParamId, ~drumsLaneId), so their tooltips and masks follow too.
~drumsShowPattern = { |which|
    ~drumsPattern = which;
    ~drumsHeld = nil;
    ~drumsRefreshPattern.();
    ~mapRelabel !? { |f| f.value };
    // The playhead is the shown pattern's, and dim when it is not the one heard.
    ~drumsPollPlayhead.(true);
};

~drumsShowPage = { |page|
    ~drumsPage = page;
    4.do { |lane| ~drumsPaint.(~drumsLaneKey.(\len, lane)) };
    ~drumsPaint.(\pageHint);
    ~drumsLanes.do { |v| if(v.isClosed.not) { v.toolTip_(~drumsStripTip.()) } };
    ~drumsRefreshTiles.();
    ~drumsRefreshLanes.();
    ~mapRelabel !? { |f| f.value };
};

// ---- The playhead --------------------------------------------------------------
// Polled, never notified: the drums decide a step every 16th, and a deferred
// handler per step would be the per-step stream this GUI never subscribes to.
// The shell's Drums tab is the only place it shows, so it is read only while
// that tab is up (a pane with no shell around it counts as shown), and the
// lanes repaint only when the step, the pattern or whether it is heard moved.
~drumsVisible = { ~guiStack.isNil or: { ~guiStack.index == ~guiTabIndex.(\drums) } };

~drumsPollPlayhead = { |force = false|
    var d = ~drumsModel.(), ph, key;
    if(d.notNil and: { ~drumsVisible.() }) {
        ph = d.playheadAt(nil, ~drumsPattern);
        key = ph !? { |p|
            [~drumsPattern, p[\ls], d.on and: { d.breakActive == (~drumsPattern == \break) }] };
    };
    if((force == true) or: { key != ~drumsPlayShown }) {
        ~drumsPlayShown = key;
        ~drumsPlayhead = ph;
        ~drumsPlayheadHeard = (key !? { |k| k[2] }) ? false;
        ~drumsRefreshLanes.();
    };
};

// Three ways to stop: a newer pane, a reload or a teardown (gen), the window
// gone, or the pane destroyed without either.
~drumsStartPlayhead = { |gen|
    AppClock.sched(0, {
        if((gen != ~drumsGen) or: { ~guiWindow.isNil } or: { ~guiWindow.isClosed }
            or: { ~drumsPane.isNil } or: { ~drumsPane.isClosed }) {
            nil
        } {
            ~drumsPollPlayhead.();
            ~drumsPlayheadHz.reciprocal
        };
    });
};

// ---- The step lanes ------------------------------------------------------------
~drumsStripTip = {
    (~drumsPageHints[~drumsPage] ? "") ++ "\n\n"
        ++ "Click or drag up and down to set a step, drag across to paint a run.\n"
        ++ "Double-click: the default. Steps past L are dimmed: the page wraps there.\n"
        ++ "The frame is the playhead, dim while this pattern is not the one heard."
};

// One lane's strip, drawn from the model at every paint: the page's sixteen
// values as bars, steps past its length dimmed (they never play), a line at
// the length, and the playhead's column framed.
~drumsPaintLane = { |lane|
    var d = ~drumsModel.(), w = ~drumsCellWidth, h = ~drumsLaneHeight;
    var which = ~drumsPattern, page = ~drumsPage;
    var len, muted, col, hue, x, val, bh, inLen, bg;
    ~drumsPaints = (~drumsPaints ? 0) + 1;     // check-gui.scd counts the paints
    if(d.notNil) {
        len = d.effectiveLength(which, page, lane) ? 16;
        muted = d.laneParam(which, lane, \mute) == true;
        col = ~drumsPlayhead !? { |p| ~drumsColumnAt.(p[\ls], len) };
        // The drums' colour, and a muted lane in \mute: it still runs, but
        // nothing of it is heard.
        hue = if(muted) { ~gt[\mute] } { ~gt[\drum] };
        16.do { |i|
            x = i * w;
            inLen = i < len;
            val = d.step(which, page, lane, i) ? 0;
            // Steps past the page's length never play: the ground shows.
            bg = if(inLen) { ~gt[\panel2] } { ~gt[\panel] };
            Pen.fillColor = bg;
            Pen.addRect(Rect(x + 2, 0, w - 3, h));
            Pen.fill;
            // A velocity of 0 still plays (at 10), so it gets a sliver.
            bh = if(val > 0) { (h * val) / 6 } { if(page == \velo) { 2 } { 0 } };
            if(bh > 0) {
                Pen.fillColor = if(inLen) { hue.copy.alpha_(0.75) } { hue.copy.alpha_(0.25) };
                Pen.addRect(Rect(x + 2, h - bh, w - 3, bh));
                Pen.fill;
            };
        };
        // The beats, four steps each, 2 px of \ink; the length's end the same.
        Pen.fillColor = ~gt[\ink];
        [4, 8, 12].do { |k| if(k < len) { Pen.addRect(Rect(k * w, 0, 2, h)) } };
        if(len < 16) { Pen.addRect(Rect(len * w, 0, 2, h)) };
        Pen.fill;
        col !? { |c|
            Pen.strokeColor = if(~drumsPlayheadHeard == true) { ~gt[\ink] } { ~gt[\ink].copy.alpha_(0.35) };
            Pen.width = 2;
            Pen.strokeRect(Rect((c * w) + 3, 1, w - 5, h - 2));
        };
    };
};

// A click sets the step under the mouse to the value at its height, and a
// drag every step the pointer crosses. Qt sends a drag about once a display
// frame, so a quick swipe jumps cells: each one jumped gets the height the
// pointer crossed its middle at, on the straight line between the two
// events. A double-click puts the Live set's value back, and the lane then
// ignores the drag until the next press, so a tremor of the hand before the
// release cannot paint over what it put back. The model notifies only a
// change, so a drag over one value repaints nothing.
~drumsLanePress = { |lane, x, y, clicks|
    var d = ~drumsModel.(), i = ~drumsStepAt.(x);
    d !? {
        if(clicks == 2) {
            ~drumsLaneDrag.put(lane, \live);
            d.setStep(~drumsPattern, ~drumsPage, lane, i, d.liveStep(~drumsPattern, ~drumsPage, lane, i))
        } {
            ~drumsLaneDrag.put(lane, (x: x, y: y));
            d.setStep(~drumsPattern, ~drumsPage, lane, i, ~drumsValueAt.(y, ~drumsLaneHeight))
        };
    };
};

~drumsLaneMove = { |lane, x, y|
    var d = ~drumsModel.(), last = ~drumsLaneDrag[lane], i = ~drumsStepAt.(x);
    var w = ~drumsCellWidth, h = ~drumsLaneHeight, from, dir, k, t;
    if(d.notNil and: { last !== \live }) {
        // A drag whose press this pane did not see starts where it is.
        last = last ? (x: x, y: y);
        from = ~drumsStepAt.(last[\x]);
        dir = (i - from).sign;
        // The cells strictly between: their middles lie between the two
        // events, so t is within 0..1 (and x is not last's x).
        ((i - from).abs - 1).max(0).do { |n|
            k = from + ((n + 1) * dir);
            t = ((((k + 0.5) * w) - last[\x]) / (x - last[\x])).clip(0, 1);
            d.setStep(~drumsPattern, ~drumsPage, lane, k, ~drumsValueAt.(last[\y] + (t * (y - last[\y])), h));
        };
        d.setStep(~drumsPattern, ~drumsPage, lane, i, ~drumsValueAt.(y, h));
        ~drumsLaneDrag.put(lane, (x: x, y: y));
    };
};

~drumsLaneView = { |lane|
    var view = UserView().canFocus_(false)      // UserView.new makes it focusable
        .fixedSize_(Size(~drumsCellWidth * 16, ~drumsLaneHeight))
        .background_(~gt[\panel])
        .toolTip_(~drumsStripTip.())
        .drawFunc_({ |uv| ~drumsPaintLane.(lane) })
        .mouseDownAction_({ |uv, x, y, mods, button, clicks| ~drumsLanePress.(lane, x, y, clicks); true })
        .mouseMoveAction_({ |uv, x, y| ~drumsLaneMove.(lane, x, y); true });
    ~drumsLanes.put(lane, view);
    view
};

// ---- A lane's settings ---------------------------------------------------------
~drumsLaneGet = { |lane, name| { ~drumsModel.() !? { |d| d.laneParam(~drumsPattern, lane, name) } } };
~drumsLaneSet = { |lane, name, v| ~drumsModel.() !? { |d| d.setLaneParam(~drumsPattern, lane, name, v) } };
// A lane setting's control in the MIDI map (setup-miditargets.scd, which
// numbers the lanes 1-4), asked when it is mapped (~mapTag): the pattern
// shown's, and for L the page shown's, so a mapping names the one clicked.
~drumsLaneId = { |lane, name|
    { ("sa.drums." ++ ~drumsPattern ++ ".lane" ++ (lane + 1) ++ "." ++ name).asSymbol } };
~drumsLengthId = { |lane|
    { ("sa.drums." ++ ~drumsPattern ++ ".lane" ++ (lane + 1) ++ ".length." ++ ~drumsPage).asSymbol } };

// The steps kit's name for the lane's pad.
~drumsLaneLabel = { |lane|
    var d = ~drumsModel.(), note;
    if(d.isNil) { "" } {
        note = d.laneParam(~drumsPattern, lane, \note);
        d.padName(\steps, note) ?? { if(d.kitFor(\steps).notNil) { "(empty)" } { "Pad " ++ note } }
    }
};

~drumsLaneTip = { |lane|
    var d = ~drumsModel.();
    if(d.isNil) { "" } {
        "Lane " ++ (lane + 1) ++ " of the " ++ ~drumsPatternLabels[~drumsPattern] ++ " pattern: it plays "
            ++ ~drumsNoteText.(d, d.laneParam(~drumsPattern, lane, \note))
            ++ ",\nor " ++ ~drumsNoteText.(d, d.laneParam(~drumsPattern, lane, \altNote))
            ++ " when its Alt step wins (Note and Alt below)."
            ++ (if(d.laneParam(~drumsPattern, lane, \mute) == true) {
                "\nMuted: it keeps drawing its dice, so it comes back in place." } { "" })
    }
};

// L is the page's length as it plays. While the lane is locked that is its
// Global Len, so L edits that, every page at once, as in the device; the
// page's own length stays and comes back on unlocking.
~drumsSetLength = { |lane, n|
    var d = ~drumsModel.();
    d !? {
        if(d.laneParam(~drumsPattern, lane, \lock) == true) {
            d.setLaneParam(~drumsPattern, lane, \globalLength, n)
        } {
            d.setLength(~drumsPattern, ~drumsPage, lane, n)
        };
    };
};

~drumsLiveLength = { |lane|
    var d = ~drumsModel.(), live = MegaSASteps.livePattern(~drumsPattern);
    if((d !? { |dd| dd.laneParam(~drumsPattern, lane, \lock) }) == true) {
        live[\globalLength][lane]
    } {
        live[\lengths][~drumsPage][lane]
    }
};

~drumsLengthTips = (chance: \lengthChance, alt: \lengthAlt, velo: \lengthVelo, roll: \lengthRoll);
~drumsLengthTip = {
    var row = MegaSASteps.laneParamSpec(\length);
    ~drumsTip.((row[\tips][~drumsPage] ? row[\tip]) ++ "\n" ++ row[\tip]
        ++ "\nWhile Lock is on, L is the lane's Global Len: every page at once."
        ++ "\nDrag it up or down; double-click: the default (16).",
        ~drumsLengthTips[~drumsPage])
};

~drumsNoteMenu = { |lane, name|
    var p = MegaSASteps.laneParamSpec(name);
    var menu = ~mapTag.(~drumsMenu.(PopUpMenu()).fixedWidth_(230)
        .items_(~drumsNoteItems.(~drumsModel.()))
        .action_({ |mn| ~drumsLaneSet.(lane, name, mn.value + 36) }), ~drumsLaneId.(lane, name),
        ~drumsTip.(p[\tip] ++ "\nBy default: " ++ ~drumsNoteText.(nil, p[\live][lane]) ++ "."));
    ~drumsWidgets.put(~drumsLaneKey.(name, lane), (kind: \menu, view: menu,
        get: ~drumsLaneGet.(lane, name), index: { |v| v !? { (v - 36).clip(0, 15) } }));
    menu
};

// A lane: its pad's name and its strip, then its settings in the device's
// order (Note, Alt, Length, Lock, Delay, Mute: the device says L, D, M).
~drumsLaneRows = { |lane|
    var label = StaticText().fixedSize_(Size(~drumsLabelWidth, ~drumsLaneHeight))
        .align_(\left).font_(~guiSans.(15, true));
    // Its tag has no tip: its tooltip follows the page (~drumsLengthTip).
    var len = ~mapTag.(~drumsBox.(NumberBox()).fixedWidth_(38)
        .clipLo_(2).clipHi_(16).step_(1).scroll_step_(1).decimals_(0)
        .action_({ |nb| ~drumsSetLength.(lane, nb.value.round.asInteger) })
        .mouseDownAction_({ |nb, x, y, mods, button, clicks|
            if(clicks == 2) { ~drumsSetLength.(lane, ~drumsLiveLength.(lane)); true } { nil } }),
        ~drumsLengthId.(lane));
    var lock = ~mapTag.(~drumsButton.().fixedWidth_(48)
        .states_([["Lock", ~gt[\mute], nil], ["Lock", ~gt[\onacc], ~gt[\drum]]])
        .action_({ |b| ~drumsLaneSet.(lane, \lock, b.value == 1) }), ~drumsLaneId.(lane, \lock),
        ~drumsTip.(MegaSASteps.laneParamSpec(\lock)[\tip], \lock));
    var delay = ~mapTag.(~drumsBox.(NumberBox()).fixedWidth_(46)
        .clipLo_(0).clipHi_(50).step_(0.5).scroll_step_(0.5).decimals_(1)
        .action_({ |nb| ~drumsLaneSet.(lane, \delay, nb.value) })
        .mouseDownAction_({ |nb, x, y, mods, button, clicks|
            if(clicks == 2) {
                ~drumsLaneSet.(lane, \delay, MegaSASteps.laneParamSpec(\delay)[\live][lane]);
                true
            } { nil } }), ~drumsLaneId.(lane, \delay),
        ~drumsTip.(MegaSASteps.laneParamSpec(\delay)[\tip]
            ++ "\nDrag it up or down; double-click: the default (0 ms).", \delay));
    var mute = ~mapTag.(~drumsButton.().fixedWidth_(52)
        .states_([["Mute", ~gt[\ink], nil], ["Muted", Color.white, ~gt[\rec]]])
        .action_({ |b| ~drumsLaneSet.(lane, \mute, b.value == 1) }), ~drumsLaneId.(lane, \mute),
        ~drumsTip.(MegaSASteps.laneParamSpec(\mute)[\tip], \mute));
    // The device's two dice, for this lane on the page shown: every step
    // anew, or every step moved by one at most (MegaSADrums.randomizeLane).
    var rand = ~drumsButton.().fixedWidth_(52).cycles_(false).states_([["Rand", ~gt[\ink], nil]])
        .toolTip_("Randomize: every step of this lane, on the page shown, gets a new value\n"
            "(the device's big dice). All 16 steps, whatever the length.\n"
            "Save a preset first to keep what is there.")
        .action_({ ~drumsRandomize.(lane, \all) });
    var randLess = ~drumsButton.().fixedWidth_(62).cycles_(false).states_([["Rand ±1", ~gt[\ink], nil]])
        .toolTip_("Randomize less: every step of this lane, on the page shown, moves one up,\n"
            "one down or stays (the device's small dice). Press it again to wander further.")
        .action_({ ~drumsRandomize.(lane, \less) });
    var muted = { ((~drumsModel.() !? { |d| d.laneParam(~drumsPattern, lane, \mute) }) == true) };
    ~drumsWidgets.put(~drumsLaneKey.(\label, lane), (kind: \text, view: label,
        get: { ~drumsLaneLabel.(lane) }, tip: { ~drumsLaneTip.(lane) },
        color: { if(muted.()) { ~gt[\mute] } { ~guiInk } }));
    ~drumsWidgets.put(~drumsLaneKey.(\len, lane), (kind: \number, view: len,
        get: { ~drumsModel.() !? { |d| d.effectiveLength(~drumsPattern, ~drumsPage, lane) } },
        tip: ~drumsLengthTip));
    ~drumsWidgets.put(~drumsLaneKey.(\lock, lane), (kind: \button, view: lock, get: ~drumsLaneGet.(lane, \lock)));
    ~drumsWidgets.put(~drumsLaneKey.(\delay, lane), (kind: \number, view: delay, get: ~drumsLaneGet.(lane, \delay)));
    ~drumsWidgets.put(~drumsLaneKey.(\mute, lane), (kind: \button, view: mute, get: ~drumsLaneGet.(lane, \mute)));
    [
        HLayout(label, ~drumsLaneView.(lane), nil).spacing_(6).margins_(0),
        HLayout(
            ~drumsSmallLabel.("Note", ~drumsLabelWidth),
            ~drumsNoteMenu.(lane, \note),
            ~drumsSmallLabel.("Alt", 26),
            ~drumsNoteMenu.(lane, \altNote),
            // Words, not the device's letters (L, D, M): its panel has room
            // for none, this row has.
            ~drumsSmallLabel.("Length", 46),
            len,
            lock,
            ~drumsSmallLabel.("Delay", 38).toolTip_(delay.toolTip),
            delay,
            mute,
            View().fixedWidth_(8),
            randLess,
            rand,
            nil
        ).spacing_(6).margins_(0)
    ]
};

// A lane's dice: the lane of the pattern and the page shown.
~drumsRandomize = { |lane, amount|
    ~drumsModel.() !? { |d| d.randomizeLane(~drumsPattern, ~drumsPage, lane, amount) };
};

// ---- Knobs -------------------------------------------------------------------
// One knob: its label (and a smaller second line), the knob, the readout. The
// knob writes the model; the model's notification paints it back, except while
// the mouse holds it (~drumsHeld). A double-click is `live` (the Live set's
// value, the spec's default when none is given). `id` is the knob's control
// in the MIDI map, or a function answering it (~mapTag). c: (key:, id:,
// label:, sub:, spec:, get:, set:, live:, format:, tip:, centered:, enabled:,
// width:, knobSize:).
~drumsKnobCell = { |c|
    var size = c[\knobSize] ? 32;
    var readout = StaticText().align_(\center).font_(~guiMono.(11, true)).stringColor_(~guiInk);
    var knob = ~mapTag.(Knob().canFocus_(false).mode_(\vert)
        .color_([~gt[\panel2], ~gt[\drum], ~gt[\bg], ~gt[\ink]])
        .fixedSize_(Size(size, size))
        .centered_(c[\centered] == true)
        .action_({ |k| c[\set].value(c[\spec].map(k.value)) })
        .mouseDownAction_({ |k, x, y, mods, button, clicks|
            ~drumsHeld = c[\key];
            if(clicks == 2) { c[\set].value(c[\live] ? c[\spec].default); true } { nil }
        })
        .mouseUpAction_({ |k|
            ~drumsHeld = nil;
            // Now the hand is off it, show where the setting really is.
            ~drumsPaint.(c[\key]);
            nil
        }), c[\id], c[\tip] ? "");
    var labels = [StaticText().string_(c[\label]).align_(\center).toolTip_(c[\tip] ? "")
            .font_(~guiSans.(12, true)).stringColor_(~gt[\ink])]
        ++ ((c[\sub] !? { |s| [StaticText().string_(s).align_(\center).toolTip_(c[\tip] ? "")
            .stringColor_(~guiHintColor).font_(~guiSans.(11))] }) ? []);
    ~drumsWidgets.put(c[\key], (kind: \knob, view: knob, readout: readout, get: c[\get],
        spec: c[\spec], format: c[\format], enabled: c[\enabled]));
    ~drumsPaint.(c[\key]);
    View().fixedWidth_(c[\width] ? ~drumsKnobWidth).layout_(VLayout(*(labels
        ++ [HLayout(nil, knob, nil), readout])).margins_(1).spacing_(1))
};

// ---- Timing --------------------------------------------------------------------
// Each pattern keeps its own timing, as each of Live's two devices did (the
// set's agree), so these show and edit the pattern shown.
~drumsParamGet = { |name| { ~drumsModel.() !? { |d| d.param(~drumsPattern, name) } } };
~drumsParamSet = { |name| { |v| ~drumsModel.() !? { |d| d.setParam(~drumsPattern, name, v) } } };
// Its control in the MIDI map: the pattern shown's, asked when it is mapped
// (~mapTag), so a mapping names the pattern it was made on.
~drumsParamId = { |name| { ("sa.drums." ++ ~drumsPattern ++ "." ++ name).asSymbol } };

~drumsParamTip = { |p, knob = false|
    var live = MegaSASteps.getParam(MegaSASteps.livePattern(\main), p[\name]);
    ~drumsTip.(p[\tip] ++ "\nBy default: " ++ ~drumsFormat.(p, live)
        ++ (if(knob) { "; double-click for it." } { "." }),
        if(p[\index].notNil) { \shuffle } { p[\name] })
};

~drumsParamMenu = { |name, width|
    var p = MegaSASteps.paramSpec(name);
    var menu = ~mapTag.(~drumsMenu.(PopUpMenu()).fixedWidth_(width)
        .items_(p[\choices].collect { |pair| pair[1] })
        .action_({ |mn| ~drumsParamSet.(name).value(p[\choices][mn.value][0]) }),
        ~drumsParamId.(name), ~drumsParamTip.(p));
    ~drumsWidgets.put(name, (kind: \menu, view: menu, get: ~drumsParamGet.(name),
        index: { |v| p[\choices].collect { |pair| pair[0] }.indexOfEqual(v) }));
    menu
};

~drumsParamButton = { |name, width|
    var p = MegaSASteps.paramSpec(name);
    var b = ~mapTag.(~drumsButton.().fixedWidth_(width)
        .states_([["Off", ~gt[\mute], nil], ["On", ~gt[\onacc], ~gt[\drum]]])
        .action_({ |bt| ~drumsParamSet.(name).value(bt.value == 1) }),
        ~drumsParamId.(name), ~drumsParamTip.(p));
    ~drumsWidgets.put(name, (kind: \button, view: b, get: ~drumsParamGet.(name)));
    b
};

~drumsParamNumber = { |name, width|
    var p = MegaSASteps.paramSpec(name);
    var nb = ~mapTag.(~drumsBox.(NumberBox()).fixedWidth_(width)
        .clipLo_(p[\spec].minval).clipHi_(p[\spec].maxval)
        .step_(1).scroll_step_(1).decimals_(0)
        .action_({ |n| ~drumsParamSet.(name).value(n.value.round.asInteger) }),
        ~drumsParamId.(name), ~drumsParamTip.(p));
    ~drumsWidgets.put(name, (kind: \number, view: nb, get: ~drumsParamGet.(name)));
    nb
};

// A shuffle dial past the Shuffle Length is never read: disabled, not hidden,
// so the row keeps its shape when the length moves.
~drumsParamKnob = { |name|
    var p = MegaSASteps.paramSpec(name);
    ~drumsKnobCell.((key: name, id: ~drumsParamId.(name), spec: p[\spec], centered: p[\centered],
        label: if(p[\index].notNil) { (p[\index] + 1).asString } { "Global" },
        tip: ~drumsParamTip.(p, true),
        get: ~drumsParamGet.(name), set: ~drumsParamSet.(name),
        format: { |v| ~drumsFormat.(p, v) },
        enabled: p[\index] !? { |ix| {
            ((~drumsModel.() !? { |d| d.param(~drumsPattern, \shuffleLength) }) ? 8) > ix } },
        width: ~drumsKnobWidth, knobSize: 32))
};

// ---- Builders ------------------------------------------------------------------
~drumsRowLabel = { |str| ~guiText.(str, 14, ~gt[\mute]).fixedWidth_(~drumsLabelWidth) };
~drumsSmallLabel = { |str, width| ~guiText.(str, 14, ~gt[\mute]).align_(\right).fixedWidth_(width) };
// The stage look for the pane's stock widgets: a switch is a tile, a menu and
// a box take the theme's ground and ink.
~drumsButton = { LooperTile().border_(~gt[\line]).font_(~guiSans.(13)).fixedHeight_(28).pad_(6) };
~drumsMenu = { |m| m.canFocus_(false).font_(~guiSans.(13)).background_(~gt[\panel]).stringColor_(~gt[\ink]) };
~drumsBox = { |nb| nb.canFocus_(false).font_(~guiMono.(13, true)).background_(~gt[\panel])
    .normalColor_(~gt[\ink]).align_(\center) };

// A section's title, in the caption's voice; with a key, painted like any
// other widget.
~drumsTitle = { |str, key, get|
    var t = ~guiMonoText.(str.toUpper, 11, ~gt[\mute]);
    key !? { ~drumsWidgets.put(key, (kind: \text, view: t, get: get)) };
    t
};

// Keep: the drums as they are, for the next boot (setup-sa.scd's
// ~saKeepDrums, which answers false or nil when it could not). A kit slot set
// to "— none —" is kept empty, and the next boot leaves it silent rather than
// loading the default kit into it; the message says so when there is one.
~drumsKeep = {
    var res, d = ~drumsModel.(), empty, tail;
    if(~saKeepDrums.isNil) {
        ~presetSetStatus.(\saDrums, "Nothing keeps the drums in this build (no ~saKeepDrums in setup-sa.scd).", true);
    } {
        res = ~saKeepDrums.value;
        if(res.isNil or: { res == false }) {
            ~presetSetStatus.(\saDrums, "The drums were not kept: see the post window.", true);
        } {
            empty = [\steps, \onset].select { |slot| d.notNil and: { d.kit(slot).isNil } };
            tail = case
                { empty.size == 2 } { ", with no kits." }
                { empty.size == 1 } { ", with no " ++ empty[0] ++ " kit." }
                { "." };
            ~presetSetStatus.(\saDrums, "Kept: the next boot starts with these drums" ++ tail);
        };
    };
};

// `importButton`: Import samples…, on the right with the other actions: the
// first row the view opens on, so another kit is a click away.
~drumsHeaderRow = { |importButton|
    // Its label carries the program its footswitch sends, as the map has it.
    // Its tooltip says what drives it already, so its tag has no tip.
    var on = ~midiWatch.(~mapTag.(LooperTile().border_(~gt[\drum]).font_(~guiMono.(14, true))
        .fixedSize_(Size(130, 34))
        .action_({ |b| ~drumsModel.() !? { |d| d.setOn(b.value == 1) } }), 'sa.drums.on'), { |b|
            var tag = ~midiProgram.('sa.drums.on') !? { |n| " · PC " ++ n } ? "";
            var was = b.value;
            b.states_([["OFF" ++ tag, ~gt[\mute], nil],
                ["ON" ++ tag, ~gt[\onacc], ~gt[\drum]]]);
            b.value = was;
            b.toolTip_("The steps on or off, as their footswitch does, from the moment you hear it.\n"
                "The onset kit is not switched: it plays the Looper's onset notes."
                ++ (~midiWords.('sa.drums.on') !? { |w| "\nMIDI: " ++ w } ? ""));
        });
    // "plays": the Edit tiles below say Main and Break too, and they only
    // choose what the lanes show.
    var brk = ~mapTag.(~drumsButton.().fixedSize_(Size(116, 34)).font_(~guiSans.(14, true))
        .states_([["Main plays", ~gt[\ink], nil], ["BREAK plays", Color.new255(243, 243, 241), Color.new255(11, 11, 12)]])
        .action_({ |b|
            ~drumsModel.() !? { |d|
                d.setBreakPattern(b.value == 1);
                // Lit by what the drums did, not by the click.
                b.value = d.breakActive.binaryValue;
            };
        }), 'sa.drums.breakPattern',
        "Which pattern plays: lit while the Break pattern does. The Looper's break\n"
        "switches it in and out, as the set's CC 100 did; a click switches it by hand until\n"
        "the Looper's next break edge.");
    // The pattern shown's, so its tag is a function of it, as the knobs' are.
    var live = ~mapTag.(~drumsButton.().fixedSize_(Size(110, 34)).cycles_(false)
        .states_([["Reset pattern", ~gt[\ink], ~gt[\panel]]])
        .action_({ ~drumsModel.() !? { |d| d.resetPattern(~drumsPattern) } }),
        { ("sa.drums.livePattern." ++ ~drumsPattern).asSymbol },
        "The pattern shown below (Main or Break) back as megalooper ships it: every\n"
        "step, length, lane setting and its timing. A double-click on a step does it for one.\n"
        "Save a preset first to keep an edit.");
    var keep = ~drumsButton.().fixedSize_(Size(140, 34)).cycles_(false)
        .states_([["Start with this", ~gt[\ink], ~gt[\panel]]])
        .toolTip_("Keep the drums as they are now (both patterns, the kits, trims, repeats,\n"
            "reverb and offset): the next boot starts with them instead of megalooper's own.\n"
            "A kit set to — none — is kept so: that part starts silent.")
        .action_({ ~drumsKeep.() });
    ~drumsWidgets.put(\on, (kind: \button, view: on, get: { ~drumsModel.() !? { |d| d.on } }));
    ~drumsWidgets.put(\breakActive, (kind: \button, view: brk,
        get: { ~drumsModel.() !? { |d| d.breakActive } }));
    HLayout(~guiTitle.("Drums", 26), on, brk, nil, importButton, live, keep).spacing_(14)
};

~drumsKitMenu = { |d, slot|
    var keys = d.kitKeys;
    var menu = ~drumsMenu.(PopUpMenu()).fixedWidth_(220)
        .items_(["— none —"] ++ keys.collect { |k| ~drumsKitName.(d, k) })
        .action_({ |mn|
            ~drumsModel.() !? { |dd| dd.setKit(slot, if(mn.value == 0) { nil } { keys[mn.value - 1] }) } });
    ~drumsWidgets.put(~drumsKitKey.(slot), (kind: \menu, view: menu,
        get: { ~drumsModel.() !? { |dd| dd.kit(slot) } },
        index: { |v| (keys.indexOf(v) ? -1) + 1 },
        tip: { ~drumsKitTip.(slot) }));
    menu
};

~drumsKitLineText = { |slot|
    var t = StaticText().font_(~guiHintFont);
    ~drumsWidgets.put(~drumsKitLineKey.(slot), (kind: \text, view: t,
        get: { ~drumsModel.() !? { |d| ~drumsKitLine.(d, slot) } },
        color: { if((~drumsModel.() !? { |d| ~drumsKitLineBad.(d, slot) }) == true) {
            ~gt[\rec] } { ~guiHintColor } }));
    t
};

// Lit from the drums' own switch (\repeats), whatever it starts as.
~drumsRepeatsButton = {
    var b = ~mapTag.(~drumsButton.().fixedWidth_(130)
        .action_({ |bt| ~drumsModel.() !? { |d| d.setRepeats(bt.value == 1) } }), 'sa.drums.repeats',
        "Kit-Carbon's repeats, as the Live set has them on every Carbon pad: now and then\n"
        "a pad's 16th repeats five times through a 2-bar cycle, falling in pitch and level.\n"
        "The KJ layer is not repeated (it is not in the pads' chains).\n"
        "On in the set, yet Live's recordings hold about one stutter in 12 minutes of drums,\n"
        "far fewer than these dice give, so here it starts off: switch it on to hear them.");
    ~drumsWidgets.put(\repeats, (kind: \repeats, view: b,
        get: { ~drumsModel.() !? { |d| d.repeats } },
        available: { (~drumsModel.() !? { |d|
            d.kit(\steps) !? { |k| d.kitInfo(k) !? { |i| i[\hasRepeats] } } }) == true }));
    b
};

~drumsGroupTrimCell = { |kit, group|
    var name = kit.groupName(group) ? group.asString;
    ~drumsKnobCell.((key: ~drumsGroupKey.(group), id: ("sa.drums.groupTrim.steps." ++ group).asSymbol,
        label: "Layer", sub: ~drumsPadShort.(name),
        spec: ~drumsTrimSpec, width: ~drumsTrimWidth, knobSize: 28,
        get: { ~drumsModel.() !? { |d| d.groupTrim(\steps, group) } },
        set: { |v| ~drumsModel.() !? { |d| d.setGroupTrim(\steps, group, v) } },
        format: ~drumsDbText,
        tip: name ++ ": every layer of it on every pad, in dB (-24..+12), kept with this kit\n"
            "and in presets. Live's balance against the rest cannot be read from its files\n"
            "(both are normalised), so set it by ear. Double-click: 0 dB."))
};

~drumsPadTrimCell = { |slot, kit, note, label, sub|
    var name = kit.padName(note) ? "";
    ~drumsKnobCell.((key: ~drumsTrimKey.(slot, note), id: ("sa.drums.trim." ++ slot ++ "." ++ note).asSymbol,
        label: label, sub: sub,
        spec: ~drumsTrimSpec, width: ~drumsTrimWidth, knobSize: 28,
        get: { ~drumsModel.() !? { |d| d.padTrim(slot, note) } },
        set: { |v| ~drumsModel.() !? { |d| d.setPadTrim(slot, note, v) } },
        format: ~drumsDbText,
        tip: name ++ " (" ++ ~drumsNoteText.(nil, note) ++ ") in the "
            ++ (if(slot == \steps) { "steps" } { "onset" }) ++ " kit, " ++ kit.name ++ ":\n"
            ++ "its level in dB (-24..+12), kept with this kit and in presets."
            ++ (if(slot == \onset) { "\nThe pad the onset notes play: the Note under Onset notes (Setup)." } { "" })
            ++ "\nDouble-click: 0 dB."))
};

// The trims for the kits in force: the steps kit's layer, the pads the lanes
// play, then the onset kit's pad for the onset notes. Rebuilt when a kit, a
// lane's pad or the onset note changes, so it never offers a knob for a pad
// nothing plays.
~drumsTrimRow = { |d|
    var steps = ~drumsKitInForce.(d, \steps), onset = ~drumsKitInForce.(d, \onset);
    var onsetNote = (~looper !? { |l| l.onsetNote }) ? 36;
    var stepsCells = List.new, onsetCells = List.new, cells, rows;
    steps !? { |kit|
        ~drumsLayerGroups.(kit).do { |g| stepsCells.add(~drumsGroupTrimCell.(kit, g)) };
        ~drumsUsedNotes.(d).do { |n|
            if(kit.pad(n).notNil) {
                stepsCells.add(~drumsPadTrimCell.(\steps, kit, n, n.asString, ~drumsPadShort.(kit.padName(n))));
            };
        };
    };
    onset !? { |kit|
        if(kit.pad(onsetNote).notNil) {
            onsetCells.add(~drumsPadTrimCell.(\onset, kit, onsetNote, "Onset",
                onsetNote.asString ++ " " ++ ~drumsPadShort.(kit.padName(onsetNote))));
        };
    };
    cells = stepsCells.asArray
        ++ (if(stepsCells.notEmpty and: { onsetCells.notEmpty }) { [View().fixedWidth_(6)] } { [] })
        ++ onsetCells.asArray;
    if(cells.isEmpty) {
        View().layout_(HLayout(~guiHint.("No kit in force to trim."), nil).margins_(0))
    } {
        rows = cells.clump(~drumsTrimsPerRow + 1).collect { |row|
            HLayout(*(row ++ [nil])).spacing_(2).margins_(0) };
        View().layout_(VLayout(*rows).margins_(0).spacing_(2))
    }
};

~drumsRebuildTrims = {
    var d = ~drumsModel.(), h = ~drumsTrimHolder;
    if(~drumsHeld.notNil and: { ~drumsHeld.asString.beginsWith("trim") }) { ~drumsHeld = nil };
    // The old knobs go from the table first: they are about to be destroyed.
    ~drumsWidgets.keys.select { |k| k.asString.beginsWith("trim") }.do { |k| ~drumsWidgets.removeAt(k) };
    if(d.notNil and: { h.notNil } and: { h.isClosed.not }) {
        h.children.copy.do { |c| c.remove };
        h.layout.add(~drumsTrimRow.(d));
    };
};

~drumsKitRows = { |d|
    [
        ~drumsTitle.("Kits"),
        HLayout(~drumsRowLabel.("Steps kit:"), ~drumsKitMenu.(d, \steps), ~drumsKitLineText.(\steps),
            ~drumsRepeatsButton.()).spacing_(4),
        HLayout(~drumsRowLabel.("Onset kit:"), ~drumsKitMenu.(d, \onset),
            ~drumsKitLineText.(\onset)).spacing_(4),
        ~drumsTrimHolder = View().layout_(VLayout().margins_(0).spacing_(0)),
        ~guiHint.("Trims in dB, kept per kit: a layer's balance, the pads the lanes play, the onset pad.")
    ]
};

~drumsTile = { |key, action, tip|
    var b = LooperTile().cycles_(false).font_(~guiSans.(14)).fixedSize_(Size(76, 32))
        .toolTip_(tip)
        .states_([[~drumsPatternLabels[key] ? ~drumsPageLabels[key]]])
        .action_(action);
    ~drumsTiles.put(key, b);
    b
};

// The line between two of the pane's sections, with room above and below.
~drumsSectionRule = { [View().layout_(VLayout(~guiRule.()).margins_([0, 8, 0, 8]))] };

~drumsPatternRows = {
    var pageHint = ~guiHint.("");
    ~drumsWidgets.put(\pageHint, (kind: \text, view: pageHint, get: { ~drumsPageHints[~drumsPage] ? "" }));
    [
        ~drumsTitle.("Step sequencer"),
        HLayout(*([~drumsRowLabel.("Edit")]
            ++ [\main, \break].collect { |w|
                ~drumsTile.(w, { ~drumsShowPattern.(w) },
                    "Show the " ++ ~drumsPatternLabels[w] ++ " pattern below: the set's "
                    ++ (if(w == \main) { "main pattern" } { "break pattern, switched in by the Looper's break" })
                    ++ ".\nShowing it changes nothing that plays. A dot: edited off the default.")
            }
            ++ [View().fixedWidth_(14), ~drumsSmallLabel.("Page", 40), View().fixedWidth_(10)]
            ++ MegaSASteps.pages.collect { |pg|
                ~drumsTile.(pg, { ~drumsShowPage.(pg) },
                    (~drumsPageHints[pg] ? "") ++ "\nA dot: this page is edited off the default.")
            }
            ++ [nil])).spacing_(2),
        pageHint
    ] ++ (0..3).collect { |lane| ~drumsLaneRows.(lane) }.flatten(1)
};

~drumsTimingRows = {
    [
        ~drumsTitle.("Timing", \timingTitle, {
            "Timing · " ++ (~drumsPatternLabels[~drumsPattern] ? "") ++ " pattern" }),
        HLayout(
            ~drumsRowLabel.("Clock"), ~drumsParamMenu.(\clockSpeed, 76),
            ~drumsSmallLabel.("Roll", 30), ~drumsParamMenu.(\rollRate, 72),
            ~drumsSmallLabel.("Retrig", 50), ~drumsParamButton.(\autoRetrigger, 48),
            ~drumsParamMenu.(\autoTriggerRate, 78),
            ~drumsSmallLabel.("Shuffle len", 70), ~drumsParamNumber.(\shuffleLength, 40),
            nil
        ).spacing_(4),
        HLayout(*([~drumsRowLabel.("Shuffle")]
            ++ ~drumsParamNames.select { |n| MegaSASteps.paramSpec(n)[\spec].step < 1 }
                .collect { |n| ~drumsParamKnob.(n) }
            ++ [nil])).spacing_(2),
        ~guiHint.("Global scales every dial: at the set's 0 % the steps play straight 16ths, "
            "whatever the dials say.")
    ]
};

// ---- Mix -------------------------------------------------------------------------
~drumsReverbSpec = ControlSpec(0, 1, \lin, 0, 0.1508);
~drumsOffsetSpec = ControlSpec(-15, 50, \lin, 0.5, 0);
~drumsStripLabels = (drums: "Drums:", onsetKit: "Onset kit:");
~drumsStripTips = (
    drums: "The drums' strip in MegaSA's mixer: the step sequencer's kit, its repeats and reverb.\n"
        "Live's fader was -10.6 dB. Setup shows the same strip.",
    onsetKit: "The onset kit's strip: the One Hit Kit and its chain, playing the Looper's onset\n"
        "notes. Live's fader was -15.7 dB. Setup shows the same strip."
);

~drumsHasStrip = { |m, key| m.notNil and: { m.level(key).notNil } };

// The reverb as the drums run it, in a line under its row. Only \ready is
// wet: before that, and whenever its impulse responses are missing or did
// not load, the drums play dry whatever the mix says (MegaSADrumsFx: the wet
// is gated by irOn). The drums' reverbState is \none until they are built,
// \dry until the impulse responses are in or when there are none to be had,
// then \loading and \ready; the folder tells which kind of dry it is.
~drumsReverbStates = (
    ready: "wet: the set's Hybrid Reverb, from its impulse responses",
    loading: "loading the impulse responses…",
    noIR: "dry: no impulse responses (python3 tools/export-live-set.py kits)",
    dry: "dry: the impulse responses did not load (see the post window)",
    none: "dry: the drums are not built (see the post window)"
);
~drumsReverbWet = { |d| (d !? { |dd| dd.reverbState }) == \ready };
~drumsReverbLine = { |d|
    var state = d !? { |dd| dd.reverbState }, key;
    key = case
        { (state == \ready) or: { state == \loading } } { state }
        { state == \dry } { if(MegaSADrumsFx.irInfo(d.kitDir).isNil) { \noIR } { \dry } }
        { \none };
    ~drumsReverbStates[key]
};
// Red while dry, as a kit line is red while its kit does not play.
~drumsReverbBad = { |d|
    #[\ready, \loading].includes(d !? { |dd| dd.reverbState }).not };

// A setting of the drums' own as a slider row, laid out like the strips'.
// `enabled`: optional, greys the slider and its readout while it answers
// false. `id`: optional, its control in the MIDI map (~mapTag); the Offset,
// a setting of the rig's, has none (docs/dev/midi-map.md 4.3).
~drumsMixSlider = { |name, label, spec, get, set, live, format, tip, enabled, id|
    var readout = ~guiMonoText.("", 13, ~guiInk).fixedWidth_(70).align_(\right);
    var slider = ~guiBar.(\drum, 16)
        .action_({ |sl| set.value(spec.map(sl.value)) })
        .mouseDownAction_({ |sl, x, y, mods, button, clicks|
            ~drumsHeld = name;
            if(clicks == 2) { set.value(live); true } { nil }
        })
        .mouseUpAction_({ ~drumsHeld = nil; ~drumsPaint.(name); nil });
    if(id.isNil) { slider.toolTip_(tip) } { ~mapTag.(slider, id, tip) };
    ~drumsWidgets.put(name, (kind: \slider, view: slider, readout: readout, get: get, spec: spec,
        format: format, enabled: enabled, groove: enabled !? { slider.background }));
    HLayout(~drumsRowLabel.(label.replace(":", "")).toolTip_(tip),
        slider, readout, View().fixedWidth_(70)).spacing_(10)
};

// The reverb's state, under its row and lined up with its slider.
~drumsReverbStateRow = {
    var t = StaticText().font_(~guiHintFont);
    ~drumsWidgets.put(\reverbState, (kind: \text, view: t,
        get: { ~drumsReverbLine.(~drumsModel.()) },
        color: { if(~drumsReverbBad.(~drumsModel.())) { ~gt[\rec] } { ~guiHintColor } }));
    HLayout(StaticText().fixedWidth_(~drumsLabelWidth), t)
};

~drumsMixRows = { |d, m|
    var strips = [\drums, \onsetKit].select { |k| ~drumsHasStrip.(m, k) and: { ~saLevelRow.notNil } };
    [~drumsTitle.("Mix")]
    ++ strips.collect { |k|
        ~saLevelRow.(m, k, ~drumsStripLabels[k], ~drumsLevels, ~drumsLabelWidth, ~drumsStripTips[k]) }
    ++ (if(strips.isEmpty) { [~guiHint.("This MegaSA has no strips for the drums, so their levels are not here.")] } { [] })
    ++ [
        ~drumsMixSlider.(\reverbMix, "Reverb:", ~drumsReverbSpec,
            { ~drumsModel.() !? { |dd| dd.reverbMix } },
            { |v| ~drumsModel.() !? { |dd| dd.setReverbMix(v) } },
            0.1508, { |v| ((v ? 0) * 100).round(0.1).asString ++ " %" },
            "The drums' reverb, Live's Hybrid Reverb on the drums group: 15.08 % wet in the\n"
            "set (linear), on the steps kit only. Double-click: back to it.\n"
            "Greyed while the drums play dry, whatever the mix says: the line under it says why.",
            { ~drumsReverbWet.(~drumsModel.()) }, 'sa.drums.reverbMix'),
        ~drumsReverbStateRow.(),
        ~drumsMixSlider.(\offsetMs, "Offset:", ~drumsOffsetSpec,
            { ~drumsModel.() !? { |dd| dd.offsetMs } },
            { |v| ~drumsModel.() !? { |dd| dd.setOffsetMs(v) } },
            0, { |v| ~drumsDbText.(v) ++ " ms" },
            "Every drum hit later (or earlier) by this much, -15..+50 ms: the drums' alignment to\n"
            "the loop as you hear it, both kits. Double-click: 0.")
    ]
};

// ---- Wiring ----------------------------------------------------------------------
// The drums' notifications, MegaSA's levels and mutes, and the Looper's onset
// note. Deferred: the drums notify from the pump's thread, MIDI from its own.
~drumsWire = { |d, m|
    var ctls = [
        SimpleController(d)
            .put(\on, { { ~drumsPaint.(\on); ~drumsPollPlayhead.(true);
                ~guiRefreshTabs !? { |f| f.value } }.defer })
            .put(\playing, { { ~drumsPollPlayhead.(true); ~guiRefreshTabs !? { |f| f.value } }.defer })
            .put(\breakActive, { { ~drumsPaint.(\breakActive); ~drumsPollPlayhead.(true) }.defer })
            .put(\step, { |obj, what, which, sub, lane|
                { if((which == ~drumsPattern) and: { sub == ~drumsPage }) { ~drumsRefreshLane.(lane) };
                    ~drumsRefreshTiles.() }.defer })
            .put(\steps, { |obj, what, which|
                { if(which == ~drumsPattern) { ~drumsRefreshLanes.() }; ~drumsRefreshTiles.() }.defer })
            .put(\pattern, { |obj, what, which|
                { if(which == ~drumsPattern) { ~drumsRefreshPattern.() }; ~drumsRebuildTrims.();
                    ~drumsRefreshTiles.() }.defer })
            .put(\length, { |obj, what, which, sub, lane|
                { if((which == ~drumsPattern) and: { sub == ~drumsPage }) {
                    ~drumsPaint.(~drumsLaneKey.(\len, lane)); ~drumsRefreshLane.(lane) };
                    ~drumsRefreshTiles.() }.defer })
            .put(\lane, { |obj, what, which, lane, name|
                { if(which == ~drumsPattern) { ~drumsRefreshLaneRow.(lane); ~drumsRefreshLane.(lane) };
                    if((name == \note) or: { name == \altNote }) { ~drumsRebuildTrims.() };
                    ~drumsRefreshTiles.() }.defer })
            .put(\param, { |obj, what, which, name|
                { if(which == ~drumsPattern) {
                    ~drumsPaint.(name);
                    if(name == \shuffleLength) { ~drumsParamNames.do { |n| ~drumsPaint.(n) } };
                }; ~drumsRefreshTiles.() }.defer })
            .put(\kit, { |obj, what, slot| { ~drumsPaint.(~drumsKitKey.(slot));
                ~drumsPaint.(~drumsKitLineKey.(slot)) }.defer })
            .put(\kitState, { |obj, what, slot, state|
                { ~drumsPaint.(~drumsKitKey.(slot)); ~drumsPaint.(~drumsKitLineKey.(slot));
                    if(state != \loading) { ~drumsKitChanged.(slot, state) } }.defer })
            // Trims are kept per kit, so with one kit in both slots both
            // cells show one value.
            .put(\padTrim, { |obj, what, slot, note|
                { [\steps, \onset].do { |s| ~drumsPaint.(~drumsTrimKey.(s, note)) } }.defer })
            .put(\groupTrim, { |obj, what, slot, group| { ~drumsPaint.(~drumsGroupKey.(group)) }.defer })
            .put(\repeats, { { ~drumsPaint.(\repeats) }.defer })
            .put(\mix, { |obj, what, name| { ~drumsPaint.(name) }.defer })
            // Wet or dry: the Reverb row greys and its line says why.
            .put(\reverb, { { ~drumsPaint.(\reverbMix); ~drumsPaint.(\reverbState) }.defer })
    ];
    m !? {
        ctls = ctls.add(SimpleController(m)
            .put(\level, { |obj, what, key, amp|
                { ~saPaintLevel !? { |f| f.(~drumsLevels, key, amp) } }.defer })
            .put(\mute, { |obj, what, key, flag|
                { ~saPaintMute !? { |f| f.(~drumsLevels, key, flag) } }.defer }));
    };
    ~looper !? { |l|
        ctls = ctls.add(SimpleController(l).put(\onsetNote, {
            { ~drumsRebuildTrims.(); ~drumsPaint.(~drumsKitLineKey.(\onset)) }.defer }));
    };
    ctls
};

// ---- Pane --------------------------------------------------------------------------
~buildDrumsPane = {
    var pane = View().background_(~gt[\bg]);
    var d, m, gen, shown, imp;
    ~presetStopTimers.(\saDrums);
    ~guiTeardowns[\drums].value;
    d = ~drumsModel.();
    m = ~megaSA;
    gen = ~drumsGen;
    shown = d.notNil and: { ~drumsKitsHere.(d) };
    if(d.isNil) {
        pane.layout_(VLayout(
            ~guiBand.(\drum),
            HLayout(View().fixedWidth_(14), ~guiHint.("The drums are Megalooper SA's: start the megalooper "
                "with the SA profile to play them.")).margins_(8),
            nil).margins_(0).spacing_(0));
    } { if(shown.not) {
        pane.layout_(VLayout(
            ~guiBand.(\drum),
            HLayout(View().fixedWidth_(14), ~guiHint.(~drumsNoKitsText.(d))).margins_(8),
            HLayout(View().fixedWidth_(14), ~drumsImportRow.()).margins_(8),
            nil).margins_(0).spacing_(0));
    } {
        if(~drumsPatternLabels.includesKey(~drumsPattern).not) { ~drumsPattern = \main };
        if(MegaSASteps.pages.includes(~drumsPage).not) { ~drumsPage = \chance };
        imp = ~drumsImportViewsMake.(true);
        pane.layout_(VLayout(
            ~guiBand.(\drum),
            View().layout_(VLayout(*(
                [~drumsHeaderRow.(imp[\button]),
                    imp[\line],
                    ~guiPresetBar.(\saDrums, (
                        menu: "Saved drums: both patterns (every step, length, lane and timing setting),\n"
                            "the kits (a kit set to — none — comes back empty), their trims, the repeats,\n"
                            "the reverb and the offset. Choosing one recalls it at once. The on/off\n"
                            "switch, the break and the levels are not in it.",
                        name: "File name for Save. Anything but letters and digits becomes '-', so \"Half "
                            "Time\"\nsaves as half-time.scd.",
                        save: "Write the drums as they are now to sa/drum-presets/<name>.scd in your megalooper folder.\n"
                            "'Overwrite' asks for a second click."
                    ))]
                ++ ~drumsSectionRule.() ++ ~drumsPatternRows.()
                ++ ~drumsSectionRule.() ++ ~drumsTimingRows.()
                ++ ~drumsSectionRule.() ++ ~drumsKitRows.(d)
                ++ ~drumsSectionRule.() ++ ~drumsMixRows.(d, m)
                ++ [~guiHint.("Drag a step up or down · drag across to paint · double-click for the "
                    "default · hover for what it does"), nil]
            )).margins_([22, 14, 22, 14]).spacing_(8))
        ).margins_(0).spacing_(0));
        ~drumsImportPlaced.();
        ~drumsControllers = ~drumsWire.(d, m);
        ~drumsRefreshAll.();
    } };
    ~drumsPane = pane;
    ~guiSwapPane !? { |f| f.(\drums, pane) };
    if(shown) {
        ~presetRefreshList.(\saDrums);
        ~drumsStartPlayhead.(gen);
    };
    pane
};
)
