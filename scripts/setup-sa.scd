// megalooper — Megalooper SA: the guitar chain, the mixer, the drums and the
// busses around the Looper.
//
// Loaded by boot.scd; defines only, runs nothing. Used when the routing
// profile says `sa: true` (docs/dev/megalooper-sa.md): no Live, one device, and SC
// is the whole instrument. boot.scd calls ~setupSA BEFORE ~setupLooper,
// because the Looper records from the guitar chain's bus and plays into the
// mixer's, and both are made here.
//
// From the IDE once it runs (levels are amplitudes, 1 = unity):
//     ~megaSA.setLevel(\guitar, 0.8);   // \guitar, \loop, \drums, \onsetKit or \master
//     ~megaSA.setMute(\guitar, true);   // \guitar, \loop, \drums or \onsetKit
//     ~megaSA.setFxParam(\filterFreq, 800); // any of MegaSAFx.params
//     ~megaSA.guitarEditor;             // Bias FX's own window
//     ~saKeepSound.();                  // the next boot starts with this sound
//     ~megaSA.saveSound(~saSoundsDir.(), "Warm"); // a sound under a name; loadSound recalls it
//     ~megaSA.drums.toggleOn;           // the drums' steps on or off, as PC 17
//     ~megaSA.drums.setKit(\steps, 'core-909'); // or \onset; ~megaSA.drums.kitKeys
//     ~saKeepDrums.();                  // the next boot starts with these drums
(
// The guitar's plugin: the VST2 build, which is what the Live set hosts, so
// the bank exported from the set loads into it unchanged.
~saGuitarPlugin = "/Library/Audio/Plug-Ins/VST/BIAS FX 2.vst";

// Where the guitar's banks lay before the chains: what tools/export-live-set.py
// wrote from the Live set, and what Start with this kept there (current.fxb, Bias
// FX's bank, and current.scd, every effect setting). Not in git. Read once
// now, by ~saMigrate.
~saGuitarBankDir = { (~megalooperRoot ?? { Looper.repoRoot }) +/+ "presets" +/+ "sa" +/+ "biasfx" };

// The bank the migration takes: the kept one if there is one, else the Live
// export.
~saGuitarBank = { |dir|
    var saved = dir +/+ "current.fxb";
    if(File.exists(saved)) { saved } {
        (dir +/+ "*.fxb").pathMatch.sort.reject { |p| p == saved }.first
    }
};

// ---- The sound's files (docs/dev/device-chains.md, section 11) -----------------
// A sound is both chains as one JSON file, with the plugin's state in a
// folder beside it (MegaSASound). Yours live in your Application Support
// folder, beside the MIDI maps, never in the repo:
//   sa/kept.json, sa/kept.states/   what a boot starts with (Start with this)
//   sa/backups/kept/                the five kept before
//   sa/sounds/                      the sounds saved under a name
//   sa/recovery.json                chain edits not kept yet
// ~midiUserRootOverride moves them, as it moves the MIDI maps: the tests use
// a scratch folder.
~saUserDir = { (~midiUserRootOverride ?? { MegaFiles.userRoot }) +/+ "sa" };
~saKeptPath = { ~saUserDir.() +/+ "kept.json" };
~saKeptBackupDir = { ~saUserDir.() +/+ "backups" +/+ "kept" };
~saSoundsDir = { ~saUserDir.() +/+ "sounds" };
~saRecoveryPath = { ~saUserDir.() +/+ "recovery.json" };

// The kept sound made once from what was kept before the chains. kept.json
// being there is the marker, and so is a backup of one (a kept sound moved
// away must not bring the files of before the chains back): with either,
// nothing happens. Without:
//   - the settings of presets/sa/biasfx/current.scd, if it is there and
//     reads, on megalooper's default chains (else every setting's default);
//   - the plugin's device if `pluginName` says there is a plugin, its state
//     the bank ~saGuitarBank picks, copied into kept.states.
// Everything is copied; the old files stay where they are. Answers the
// path written, or nil when there was nothing to do or it failed.
~saMigrate = { |pluginName|
    var path = ~saKeptPath.(), dir = ~saGuitarBankDir.(), old = dir +/+ "current.scd";
    var settings, bank, sound, states, why, from = List.new;
    if(File.exists(path) or: { (~saKeptBackupDir.() +/+ "*.json").pathMatch.notEmpty }) { nil } {
        if(File.exists(old)) {
            settings = Looper.readPresetFile(old, { |w| ("megalooper: " ++ old.basename ++ " is not migrated: " ++ w ++ ".").warn });
            if(settings.isKindOf(Dictionary).not or: { (settings[\version] ? 1) > MegaSA.fxPresetVersion }) {
                if(settings.notNil) { ("megalooper: " ++ old.basename ++ " is no preset this build reads: not migrated.").warn };
                settings = nil;
            } { from.add("the settings of " ++ old.basename) };
        };
        sound = if(settings.notNil) { MegaSASound.fromSettings(settings, pluginName) } { MegaSASound.default(pluginName, "kept") };
        bank = if(pluginName.notNil) { ~saGuitarBank.(dir) };
        states = MegaSASound.statesDirFor(path);
        if(bank.notNil) {
            File.mkdir(states);
            if(File.exists(states +/+ bank.basename).not) { File.copy(bank, states +/+ bank.basename) };
            sound.device(\plugin1).put(\state, (kind: \bank, file: bank.basename));
            from.add("the bank " ++ bank.basename);
        };
        why = MegaFiles.writeNow(path, sound.named("kept", Date.getDate.stamp).fileString,
            { |read| MegaSASound.parse(read ? "") !? { |x| if(x.isString) { x } } });
        if(why.notNil) {
            ("megalooper: the kept sound was not written to " ++ path ++ " (" ++ why ++ ").").warn;
            nil
        } {
            ("megalooper: your kept sound is now " ++ path
                ++ if(from.isEmpty) { ": megalooper's default chains." } {
                    ", from " ++ from.join(" and ") ++ " in " ++ dir ++ ". Those files stay where they are." }).postln;
            path
        }
    }
};

// The kept sound at boot: (sound:, refused:). A file that is missing or
// does not read falls back to the newest backup that does, and says so; one
// from a newer megalooper is refused whole and never written over (refused
// says why, and Start with this is off until the file is moved away).
~saReadKept = {
    var path = ~saKeptPath.(), sound, out = (), backup;
    if(File.exists(path).not) {
        backup = (~saKeptBackupDir.() +/+ "*.json").pathMatch.sort.reverse.detect { |p| MegaSASound.read(p).isString.not };
        backup !? { |b|
            ("megalooper: there is no kept sound at " ++ path ++ ": the chains start from the one kept before ("
                ++ b.basename ++ ").").warn;
            sound = MegaSASound.read(b);
            sound.statesDir = MegaSASound.statesDirFor(path);
            out.put(\sound, sound);
        };
    } {
        sound = MegaSASound.read(path);
        case
        { sound.isString and: { sound.contains("newer megalooper") } } {
            out.put(\refused, sound);
            ("megalooper: your kept sound (" ++ path ++ ") is not read: " ++ sound
                ++ ". The chains start as megalooper ships them, and Start with this writes nothing until that file is moved away.").warn;
        }
        { sound.isString } {
            backup = (~saKeptBackupDir.() +/+ "*.json").pathMatch.sort.reverse.detect { |p| MegaSASound.read(p).isString.not };
            ("megalooper: your kept sound (" ++ path ++ ") is not read: " ++ sound ++ ". "
                ++ if(backup.notNil) { "The chains start from the one kept before (" ++ backup.basename ++ ")." }
                    { "The chains start as megalooper ships them." }).warn;
            backup !? { |b|
                sound = MegaSASound.read(b);
                sound.statesDir = MegaSASound.statesDirFor(path);
                out.put(\sound, sound);
            };
        }
        {
            sound.problems.do { |p| ("megalooper: your kept sound: " ++ p ++ ".").warn };
            out.put(\sound, sound);
        };
    };
    out
};

// Whether the loop is stopped: only then is the plugin's state written
// (writing it suspends the plugin, and the guitar's DI would be heard).
~saLoopStopped = { ~looper.isNil or: { #[\empty, \stopped].includes(~looper.state) } };

// Keep the sound for the next boot: both chains, and the plugin's state if
// the loop is stopped (else the state last kept stays, and the action is
// told). `action` gets (ok, why, withStates).
~saKeepSound = { |action|
    var m = ~megaSA, stopped = ~saLoopStopped.();
    case
    { m.isNil } { action.value(false, "Megalooper SA is not running", stopped) }
    { ~saKeptRefused.notNil } {
        ("megalooper: the kept sound is not written: the one on disk " ++ ~saKeptRefused ++ ".").warn;
        action.value(false, "the kept sound on disk is from a newer megalooper", stopped);
    }
    {
        m.writeSound(~saKeptPath.(), "kept", stopped, ~saKeptBackupDir.(), { |ok, why, written|
            var bare = ~saPluginLeftOut.();
            if(ok) {
                // Kept is what was written: a knob moved while the file
                // went to disk stays unkept.
                ~saRecoveryClear.();
                m.markKept(written);
                ("megalooper: sound kept" ++ if(stopped) { "." } { " (the plugin's own sound as last kept: the loop was playing)." }).postln;
                if(bare) {
                    ("megalooper: the kept sound has no plugin in the guitar chain, so the next boot hosts none. "
                        ++ "~megaSA.undo brings it back now if it was just removed; ~saRestorePlugin.() puts it back into the kept sound.").warn;
                };
            } { ("megalooper: the sound was not kept: " ++ why ++ ".").warn };
            action.value(ok, why, stopped, bare);
        }, ~midiWriteSync == true);
    };
};

// Whether this rig has a plugin (~saGuitarPlugin is there) that the guitar
// chain does not hold: kept so, the next boot hosts none, and no menu brings
// it back before phase 5.
~saPluginLeftOut = {
    File.exists(~saGuitarPlugin) and: { \VSTPlugin.asClass.notNil }
        and: { (~megaSA !? { |m| m.guitarChain.devices.any(_.isPlugin) }) != true }
};

// The plugin's device put back into the kept sound on disk, for the next
// boot: the one the newest backup that has one holds (its state with it, if
// that file is still there), else a new one with no state. Nothing running
// changes. Answers true if the kept sound was written.
~saRestorePlugin = {
    var path = ~saKeptPath.(), sound = MegaSASound.read(path), states = MegaSASound.statesDirFor(path), spec, at, why;
    case
    { sound.isString } { ("megalooper: the kept sound is not changed: " ++ sound ++ ".").warn; false }
    { sound.devices(\guitar).any { |d| d[\type] == \plugin } } {
        "megalooper: the kept sound has its plugin already.".postln; false }
    {
        (~saKeptBackupDir.() +/+ "*.json").pathMatch.sort.reverse.do { |p|
            var old = MegaSASound.read(p);
            if(spec.isNil and: { old.isString.not }) {
                spec = old.devices(\guitar).detect { |d| d[\type] == \plugin };
                at = spec !? { old.devices(\guitar).indexOf(spec) };
            };
        };
        spec = (spec ?? { (id: \plugin1, type: \plugin, name: PathName(~saGuitarPlugin).fileNameWithoutExtension, on: true, layout: [1, 1]) }).copy;
        spec[\state] !? { |st| if(File.exists(states +/+ st[\file]).not) { spec.removeAt(\state); spec.removeAt(\stateExtras) } };
        if(sound.device(spec[\id]).notNil) { spec.put(\id, ("plugin" ++ (sound.nextIds[\plugin] ? 1)).asSymbol) };
        // Where it stood in that backup, as far as the chain still reaches.
        at = (at ? sound.devices(\guitar).size).min(sound.devices(\guitar).size);
        sound.track(\guitar).put(\devices, sound.devices(\guitar).asArray.insert(at, spec));
        sound.nextIds.put(\plugin, max(sound.nextIds[\plugin] ? 1, 2));
        why = MegaFiles.writeNow(path, sound.fileString, { |read| MegaSASound.parse(read ? "") !? { |x| if(x.isString) { x } } },
            ~saKeptBackupDir.() +/+ Date.getDate.stamp ++ ".json");
        if(why.notNil) { ("megalooper: the kept sound was not written (" ++ why ++ ").").warn; false } {
            ("megalooper: " ++ spec[\name] ++ " is back in the kept sound, at place " ++ (at + 1) ++ " of the guitar chain"
                ++ if(spec[\state].isNil) { ", with no sound of its own" } { "" } ++ ": run the boot again to host it.").postln;
            true
        }
    }
};

// ---- The plugin catalog ---------------------------------------------------------
// Which plugins megalooper can host (MegaSAPlugins; docs/dev/device-chains.md,
// 8.1): found by a scan with an offline server, kept as VSTPlugin's cache
// file in sa/plugins/ of megalooper's folder, and read from there at every
// boot. ~saPlugins holds the entries.
~saPluginsDir = { ~saUserDir.() +/+ "plugins" };
~saReadPlugins = { ~saPlugins = MegaSAPlugins.read(~saPluginsDir.()); ~saPlugins };
// The keys of the plugins megalooper can host, for
// ~megaSA.insertPlugin(\loop, nil, key) until the window has its browser.
~saPluginKeys = { MegaSAPlugins.offered(~saPlugins ? []).select { |e| e[\why].isNil }.collect { |e| e[\key] } };
// Scan the system's plugin folders (or `dirs`), then read the catalog again
// and have the server read it. Refused while a loop plays: a scan opens
// every plugin once, which takes the processor a set needs. `action` gets
// (ok, why, how many were found).
~saScanPlugins = { |action, dirs|
    var refuse = { |why| ("megalooper: no plugin scan: " ++ why ++ ".").warn; action.value(false, why, 0); false };
    case
    { MegaSAPlugins.available.not } { refuse.("VSTPlugin is not installed") }
    { ~saLoopStopped.().not } { refuse.("a loop is playing") }
    { ~saScanning == true } { refuse.("a scan is running already") }
    {
        ~saScanning = true;
        "megalooper: scanning for plugins, a moment for each…".postln;
        MegaSAPlugins.scan(~saPluginsDir.(), dirs, { |ok, why|
            ~saScanning = false;
            if(ok) {
                ~saReadPlugins.();
                ("megalooper: " ++ ~saPlugins.size ++ " plugins found; megalooper can host "
                    ++ MegaSAPlugins.offered(~saPlugins).count { |e| e[\why].isNil } ++ " of them.").postln;
                // The live server reads it too, so an open needs no probe,
                // and MegaSA adds from the new catalog at once.
                ~megaSA !? { |m|
                    m.catalog = ~saPlugins;
                    MegaSAPlugins.readCacheMsg(~saPluginsDir.()) !? { |msg| m.server.sendMsg(*msg) };
                };
            } { ("megalooper: the plugin scan failed: " ++ why ++ ".").warn };
            action.value(ok, why, (~saPlugins ? []).size);
        });
        true
    };
};

// ---- The recovery file ---------------------------------------------------------
// Chain edits are not kept until Start with this. So that a crash, a Cmd-period or
// a quit does not lose them, the chains go to sa/recovery.json a moment after
// each structural edit that leaves them unkept, and the file goes again once
// they are kept (or edited back). A boot that finds one says so and offers
// it (~saRecallRecovery): it is never loaded silently. One from a newer
// megalooper is left as it is, neither read, deleted nor written over
// (~saRecoveryRefused), and edits are then not saved to it.
~saRecoveryCheck = {
    var path = ~saRecoveryPath.(), read = if(File.exists(path)) { MegaSASound.read(path) };
    ~saRecoveryRefused = read.isString and: { read.contains("newer megalooper") };
    if(~saRecoveryRefused) {
        ("megalooper: the recovery file (" ++ path ++ ") is from a newer megalooper: it is left as it is, "
            ++ "and chain edits are not saved to it until it is moved away.").warn;
    };
    ~saRecoveryRefused
};
~saRecoveryClear = {
    ~saRecovery = nil;
    if((~saRecoveryRefused != true) and: { File.exists(~saRecoveryPath.()) }) { File.delete(~saRecoveryPath.()) };
};
~saRecoveryWrite = {
    ~saRecoveryPending = false;
    // Moved away as the warning asked: edits are saved again.
    if((~saRecoveryRefused == true) and: { File.exists(~saRecoveryPath.()).not }) { ~saRecoveryRefused = false };
    ~megaSA !? { |m|
        if(~saRecoveryRefused == true) { nil } {
        if(m.dirty) {
            MegaFiles.write(~saRecoveryPath.(), m.sound("recovery").fileString, nil, nil, { |ok, why|
                if(ok.not) { ("megalooper: the recovery file was not written (" ++ why ++ ").").warn };
            }, ~midiWriteSync == true);
        } { ~saRecoveryClear.() };
        };
    };
};
~saWatchRecovery = {
    ~saRecoveryCheck.();
    // A Cmd-period clears the clock a write waits on: a new boot starts anew.
    ~saRecoveryPending = false;
    ~saRecoveryController !? { |c| c.remove };
    ~saRecoveryController = ~megaSA !? { |m|
        SimpleController(m).put(\chain, {
            // An edit after a boot's offer is the player's answer: the
            // offer is over, and the file follows the chains again.
            ~saRecovery = nil;
            if(~saRecoveryPending != true) {
                ~saRecoveryPending = true;
                if(~midiWriteSync == true) { ~saRecoveryWrite.() } { AppClock.sched(0.5, { ~saRecoveryWrite.(); nil }) };
            };
        })
    };
};
// At boot, once the chains stand: a recovery file that differs from them is
// kept in ~saRecovery and said; one that does not is deleted. Answers the
// sound offered, or nil.
~saRecoveryOffer = {
    var path = ~saRecoveryPath.(), sound;
    ~saRecovery = nil;
    if(File.exists(path) and: { ~megaSA.notNil } and: { ~saRecoveryCheck.().not }) {
        sound = MegaSASound.read(path);
        if(sound.isString or: { sound.contentString == ~megaSA.sound.contentString }) { ~saRecoveryClear.() } {
            // Its states are the kept sound's: the recovery file writes none.
            sound.statesDir = MegaSASound.statesDirFor(~saKeptPath.());
            ~saRecovery = sound;
            ("megalooper: the chains were edited and not kept when megalooper last stopped. "
                ++ "To get them back: ~saRecallRecovery.() (or the Effects pane's Recover). "
                ++ "An edit or Start with this drops them.").postln;
        };
    };
    ~saRecovery
};
// The chains come back; the plugin's own sound stays as it is (the recovery
// file holds no state of its own, and what the plugin has is newer).
~saRecallRecovery = { |action|
    var sound = ~saRecovery, done, answer;
    if(sound.isNil or: { ~megaSA.isNil }) { action.value(false); false } {
        // The offer is over before the answer is given: the pane paints
        // its Recover tile from it.
        done = ~megaSA.applySound(sound, { |ok, notes| answer = [ok, notes] }, false);
        if(done) { ~saRecovery = nil; action.value(*(answer ? [true, []])) } { action.value(false) };
        done
    }
};

// The effect racks' macro states from the Live set, as MegaSAFx settings:
// "as saved" (what the macros were left at, and the defaults) and each rack's
// own variations. Written by `python3 tools/export-live-set.py variations`.
// effect -> [[name, (setting -> value)], ...]; parseJSON hands numbers over as
// strings, so they are converted here once.
~saFxVariationsFile = { (~megalooperRoot ?? { Looper.repoRoot }) +/+ "presets" +/+ "sa" +/+ "fx-variations.json" };
~saLoadFxVariations = {
    var path = ~saFxVariationsFile.();
    var out = IdentityDictionary.new;
    // A broken file must not stop the boot (this part loads on every rig).
    if(File.exists(path)) {
        try {
            (File.readAllString(path).parseJSON["effects"] ? ()).keysValuesDo { |fx, entry|
                out.put(fx.asSymbol, entry["variations"].collect { |v|
                    var settings = IdentityDictionary.new;
                    // parseJSON hands numbers over as strings; one that is no
                    // number is left out, not read as 0.
                    v["settings"].keysValuesDo { |k, x|
                        if("^-?[0-9]+(\\.[0-9]*)?([eE][-+]?[0-9]+)?$".matchRegexp(x.asString)) {
                            settings.put(k.asSymbol, x.asFloat)
                        } {
                            ("megalooper: " ++ path.basename ++ ": " ++ fx ++ " '" ++ v["name"] ++ "' "
                                ++ k ++ " is no number (" ++ x ++ "); left out.").warn;
                        };
                    };
                    [v["name"], settings]
                });
            };
        } { |err|
            ("megalooper: " ++ path.basename ++ " is unreadable (" ++ err.errorString
                ++ "); the effects have no Live variations.").warn;
            out = IdentityDictionary.new;
        };
    };
    out
};
~saFxVariations = ~saLoadFxVariations.();

// Put one device's settings where a variation of its type has them; the
// switches and every setting the rack does not drive stay. `id` is the
// device's (an effect's key is its first device's). True if there was one to
// apply. The variations are megalooper's factory presets for a type: they
// are read from the repo and never written.
~saApplyVariation = { |id, name|
    var device = ~megaSA !? { |m| m.device(id) };
    var found = device !? { |d| (~saFxVariations[d.type] ? []).detect { |v| v[0] == name } };
    if(found.isNil) { false } {
        found[1].keysValuesDo { |setting, x| ~megaSA.setParam(id, setting, x) };
        true
    }
};

// ---- The drums ------------------------------------------------------------
// MegaSA makes them (MegaSADrums: Rhythmic Steps' two patterns and the onset
// kit) and the Looper drives them once it is attached; what is set here is
// what a boot starts them with.

// The kits: one JSON file per kit, with its audio beside it (git-ignored), as
// `python3 tools/export-live-set.py kits` writes them.
~saDrumsKitDir = { (~megalooperRoot ?? { Looper.repoRoot }) +/+ "presets" +/+ "sa" +/+ "drums" +/+ "kits" };

// The kit each slot starts with, by key: for Rhythmic Steps the set's
// Kit-Carbon with stand-ins for the KJ Sawka kit layered under it, for the
// onset notes stand-ins for the One Hit Kit. Kept drums bring their own.
~saDrumsDefaultKits = (steps: 'carbon-layer', onset: 'one-hit');

// The kit a slot starts with: its default, or, when that kit's samples are
// not on this Mac and another kit's are, the first of those (a Mac with only
// some of the kits made). With no samples at all it is the default: the slot
// is silent and says why.
~saDrumsStartKit = { |d, slot|
    var key = ~saDrumsDefaultKits[slot];
    var here = if(d.respondsTo(\kitsWithAudio)) { d.kitsWithAudio } { [] };
    if(key.isNil or: { here.isEmpty } or: { here.includes(key) }) { key } { here.first }
};

// Where Keep keeps the drums between boots: both patterns, the kits, their
// trims and the mix in one file, written and read by the drums themselves
// (MegaSADrums.keep / loadKept). Yours, so in your megalooper folder, beside
// the kept sound.
~saKeptDrumsPath = { ~saUserDir.() +/+ "kept-drums" +/+ "drums.scd" };
// Where it lay until the release: in the repo. The first boot copies it
// over, once (MegaFiles.adopt: the new folder being there is the marker),
// and the old file stays.
~saKeptDrumsBefore = { (~megalooperRoot ?? { Looper.repoRoot }) +/+ "presets" +/+ "sa" +/+ "kept" };
~saAdoptKeptDrums = {
    var to = ~saKeptDrumsPath.().dirname, from = ~saKeptDrumsBefore.();
    var took = MegaFiles.adopt(from, to);
    if(took.notNil and: { took.notEmpty }) {
        ("megalooper: your kept drums are now in " ++ to ++ ", copied from " ++ from ++ ", where they stay.").postln;
    };
    took
};

// Keep the drums for the next boot (the Drums tab's Keep). `action` gets true
// once they are written, false if they were not; it answers the same.
~saKeepDrums = { |action|
    var path = ~saKeptDrumsPath.();
    var d = ~megaSA !? { |m| m.drums };
    var ok = false;
    case
    { d.isNil } { "megalooper: there are no drums to keep.".warn }
    { d.respondsTo(\keep).not } { "megalooper: these drums cannot be kept.".warn }
    {
        if(File.exists(path.dirname).not) { File.mkdir(path.dirname) };
        ok = try { d.keep(path) } { |err|
            ("megalooper: the drums were not kept (" ++ err.errorString ++ ").").warn;
            false
        };
        ok = ok.notNil and: { ok != false };
    };
    action.value(ok);
    ok
};

// The kept drums, at boot (~setupSADrums). Nothing to do if nothing was kept.
// Fail-soft: a file that does not load leaves the drums as they were, and the
// boot goes on. Answers true if the kept drums are in.
~saLoadKeptDrums = {
    var path = ~saKeptDrumsPath.();
    var d = ~megaSA !? { |m| m.drums };
    var ok = false;
    if(d.notNil and: { File.exists(path) } and: { d.respondsTo(\loadKept) }) {
        ok = try { d.loadKept(path) == true } { |err|
            ("megalooper: the kept drums (" ++ path.basename ++ ") did not load ("
                ++ err.errorString ++ "); the drums are left as they were.").warn;
            false
        };
        if(ok) { "megalooper: the drums start as kept.".postln };
    };
    ok
};

// One kit slot in words, for the post window: "steps kit Kit-Carbon + layer:
// ready", or "no onset kit". slot is \steps or \onset.
~saDrumsKitLine = { |slot|
    var d = ~megaSA !? { |m| m.drums };
    var key = d !? { |x| x.kit(slot) };
    var info = key !? { |k| try { d.kitInfo(k) } { nil } };
    if(key.isNil) { "no " ++ slot.asString ++ " kit" } {
        slot.asString ++ " kit " ++ ((info !? { |i| i[\name] }) ? key).asString
            ++ ": " ++ d.kitState(slot).asString
    }
};

// The drums at boot, once MegaSA is ready: the kit folder, the kept drums if
// there are any, then the default kit in every slot they did not name (or
// gave a kit that is no longer there); a slot they kept empty ("none") stays
// empty. In that order so a kept kit is loaded once, not after a default it
// replaces. Fail-soft: a kit that cannot be read leaves its slot silent and
// says so, and whatever goes wrong here, the boot goes on to the Looper. A kit
// loads in the background; each default one posts what it loaded once it is in.
~setupSADrums = {
    var d = ~megaSA !? { |m| m.drums };
    d !? {
        try {
            d.kitDir = ~saDrumsKitDir.();
            ~saAdoptKeptDrums.();
            ~saLoadKeptDrums.();
            [\steps, \onset].do { |slot|
                if((d.respondsTo(\kitEmptied) and: { d.kitEmptied(slot) }).not
                    and: { d.kit(slot).isNil or: { d.kitState(slot) == \missing } }) {
                    ~saDrumsStartKit.(d, slot) !? { |key|
                        d.setKit(slot, key, { ("megalooper: " ++ ~saDrumsKitLine.(slot) ++ ".").postln });
                    };
                };
            };
        } { |err|
            ("megalooper: the drums' kits did not load (" ++ err.errorString
                ++ "); choose them on the Drums view.").warn;
        };
    };
    d
};

~setupSA = {
    var plugin = ~saGuitarPlugin, kept, sound, bank;
    if(File.exists(plugin).not) {
        ("megalooper: no plugin at " ++ plugin ++ "; the guitar plays without one.").warn;
        plugin = nil;
    };
    // The kept sound is read before MegaSA is built, so the chains are built
    // once, as kept: first made from the files of before the chains, if
    // there is none yet.
    ~saMigrate.(plugin !? { |p| PathName(p).fileNameWithoutExtension });
    kept = ~saReadKept.();
    sound = kept[\sound];
    ~saKeptRefused = kept[\refused];
    // With no kept sound to read, or one that holds no state for the plugin,
    // the plugin opens with the bank of before the chains, if there is one,
    // not at its default patch.
    bank = if(plugin.notNil and: { sound.isNil or: {
        sound.devices(\guitar).any { |d| (d[\type] == \plugin) and: { d[\state].isNil } } } }) { ~saGuitarBank.(~saGuitarBankDir.()) };
    if(plugin.notNil and: { sound.notNil } and: { bank.isNil }
        and: { sound.devices(\guitar).any { |d| (d[\type] == \plugin) and: { d[\state].isNil } } }) {
        ("megalooper: the kept sound holds no state for the plugin; it opens at its default sound. "
            ++ "Run python3 tools/export-live-set.py biasfx for the Live set's bank, or set it up and Start with this.").warn;
    };
    if(plugin.notNil and: { \VSTPlugin.asClass.notNil } and: { sound.notNil }
        and: { sound.devices(\guitar).any { |d| d[\type] == \plugin }.not }) {
        ("megalooper: the kept sound has no plugin in the guitar chain, so " ++ PathName(plugin).fileNameWithoutExtension
            ++ " is not hosted. ~saRestorePlugin.() puts it back into the kept sound for the next boot.").warn;
    };
    ~megaSA !? { |m| m.free };
    // The plugin catalog: read here and by the server, so that an open by
    // key needs no probe. With none yet, said.
    ~saReadPlugins.();
    if(MegaSAPlugins.available) {
        if(MegaSAPlugins.hasCache(~saPluginsDir.())) { s.sendMsg(*MegaSAPlugins.readCacheMsg(~saPluginsDir.())) } {
            "megalooper: no plugin catalog yet. ~saScanPlugins.() makes one, with the loop stopped (a moment per plugin).".postln;
        };
    };
    // The chain reads the guitar's own hardware input, which is also the
    // dry tap the onset analysis keeps reading (the profile's analysisChannel).
    ~megaSA = MegaSA(s, ~inChannel, 0, plugin, bank, sound, ~saPlugins);
    ~megaSA.statesAllowed = { ~saLoopStopped.() };
    // A plugin that crashed megalooper while it opened stays closed at the next boot.
    ~megaSA.markerDir = ~saPluginsDir.() +/+ "opening";
    // The Looper records the chain and plays into the mixer; loop chaining
    // records the guitar plus the loop after its effects, as it did from Live's
    // processed return; the session recorder's "master" is the mix itself.
    ~inChannel      = ~megaSA.looperInChannel;
    ~outChannel     = ~megaSA.loopBus.index;
    ~returnChannel  = ~megaSA.returnInChannel;
    ~sessionChannel = ~megaSA.recordInChannel;
    ~megaSA.waitForReady;
    // What stands now is what was kept: Keep's mark starts clean.
    ~megaSA.markKept;
    ~saWatchRecovery.();
    sound !? { |x| ("megalooper: the chains start as kept (" ++ x.devices.size ++ " devices, kept "
        ++ (x.savedAt ? "at an unknown time") ++ ").").postln };
    // Before ~setupSALooper attaches the Looper, which can start them.
    ~setupSADrums.();
    ~megaSA
};

// The session recorder's stems on SA: every strip after its fader
// (MegaSA.stemSpecs), recorded beside the master and the dry tap. A boot makes
// a new Looper, and with it a new recorder, so they go over with every attach;
// a rig that is not SA never hands any, and its recorder records the master
// and the tap alone. A recorder that takes no stems is said, not thrown: the
// set is still recorded. Answers the recorder, or nil.
~saHandStems = { |looper|
    var rec = looper !? { |l| l.sessionRec };
    var specs = ~megaSA !? { |m| m.stemSpecs };
    if(rec.notNil and: { specs.notNil } and: { (~rp !? { |r| r[\sa] == true }) == true }) {
        try { rec.stems = specs } { |err|
            ("megalooper: the session recorder takes no stems (" ++ err.errorString
                ++ "); sets record the master and the tap only.").warn;
        };
    };
    rec
};

// The rest, once the Looper is up: the loop's effects after its master synth,
// its session recorder after the mixer, with the stems, and the drums on its
// transport and its onset notes. boot.scd calls it right after
// ~looper.waitForReady, before anything else adds synths to the default group.
// megalooper's build, for a session's header: git's description of the
// checkout ("chains-2-5-g2a69c34", "-dirty" with uncommitted changes), or
// nil where there is no git. Asked once, at boot: it takes a shell.
~saBuild = {
    var root = ~megalooperRoot ?? { Looper.repoRoot }, out;
    out = try { ("git -C " ++ root.shellQuote ++ " describe --tags --always --dirty 2>/dev/null").unixCmdGetStdOut } { nil };
    out = (out ? "").select { |c| c.isPrint and: { c != $  } };
    if(out.isEmpty) { nil } { "git " ++ out }
};

// What SA adds to a session's header (Looper.sessionExtras): the sound's
// name, both chains with every switch and setting, each chain's delay, and
// the build.
~saSessionExtras = {
    ~megaSA !? { |m|
        var info = m.sessionInfo;
        ~saBuildId !? { |b| info.put(\build, b) };
        info
    }
};

// A session's log gets every footswitch (\fx: id, on) and every chain edit
// (\fxChain: track, op, id, index, and the chain's ids after it), so a take
// can be followed through its chain. With no set recording they go nowhere.
~saWatchSession = {
    ~saSessionController !? { |c| c.remove };
    ~saSessionController = ~megaSA !? { |m|
        var log = { |ev, fields| ~looper !? { |l| l.sessionRec.logEvent(ev, fields) } };
        SimpleController(m)
            .put(\fx, { |obj, what, id, on| log.(\fx, (id: id, on: on)) })
            .put(\chain, { |obj, what, track, op, id, index|
                log.(\fxChain, (track: track, op: op, id: id, index: index,
                    ids: m.chainFor(track) !? { |c| c.ids }));
            })
    };
};

~setupSALooper = {
    ~megaSA !? { |m|
        m.attachLooper(~looper);
        ~saHandStems.(~looper);
        ~saBuildId = ~saBuildId ?? { ~saBuild.() };
        ~looper.sessionExtras = { ~saSessionExtras.() };
        ~saWatchSession.();
        // Both chains stand now: chain edits a last run left unkept are offered.
        ~saRecoveryOffer.();
    }
};
)
