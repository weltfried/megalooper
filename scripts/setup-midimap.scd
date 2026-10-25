// megalooper — the MIDI router: the controls a controller can drive, the map
// of which message drives which, and the responders that carry every message
// to its bindings, on to Live, and into the log.
//
// Loaded by boot.scd after setup-midi.scd, setup-sa.scd and
// setup-miditargets.scd (the controls); defines only, runs nothing. One entry
// point:
//   ~setupMidiBindings — builds the controls (~midiTargets) and the map
//                        (~midiMap), and registers one responder per message
//                        type. Needs ~looper to exist. Re-run it alone to
//                        rebuild every responder without touching the server,
//                        the loop or the windows; a map's changes not kept yet
//                        stay.
//
// docs/dev/midi-map.md is the design; this is its phase 2. A rig's map is a file:
// the one its profile names (presets/midi/<name>.json, shipped) or yours of
// that name, chosen and changed on the Rig tab's MIDI section (gui-midimap.scd)
// and kept with Keep. LooperMidiMap holds the rules, LooperMidiLearn learning.
(
// ---- Map files and settings ------------------------------------------------------
// docs/dev/midi-map.md 8.2-8.5. The maps megalooper ships are presets/midi/
// <name>.json, in git. Yours live in ~/Library/Application Support/
// SuperCollider/megalooper/midi/, outside the repo: the app must not write
// files git tracks, the app bundle is tied to one checkout, and a public
// install may be read-only. Every checkout and branch on the Mac shares that
// folder. A map of yours with a shipped map's name hides the shipped one, and
// says which shipped revision it started from. Nothing is written until Keep.
// ~midiShippedDirOverride moves it for the tests, whose maps are fixtures
// (scripts/tests/fixtures/midi/: the release ships keys-and-knobs alone).
~midiShippedDir = { ~midiShippedDirOverride ?? { (~megalooperRoot ?? { Looper.repoRoot }) +/+ "presets" +/+ "midi" } };
// ~midiUserRootOverride moves the folder of yours: the tests use a scratch
// folder, and must never write the real one. The folder itself is
// MegaFiles.userRoot, which every kind of file of yours shares.
~midiUserRoot = { ~midiUserRootOverride ?? { MegaFiles.userRoot } };
~midiUserDir = { ~midiUserRoot.() +/+ "midi" };
~midiBackupDir = { ~midiUserDir.() +/+ "backups" };
~midiSettingsPath = { ~midiUserRoot.() +/+ "settings.json" };
~midiMapPath = { |dir, name| dir +/+ (name.asString ++ ".json") };
~midiBackupsKept = 5;

// A file's text, or nil when it isn't there or can't be read.
~midiReadText = { |path|
    if(File.exists(path)) { try { File.readAllString(path) } { nil } }
};

// The shipped maps' and yours' names, sorted.
~midiMapNames = { |dir|
    (dir +/+ "*.json").pathMatch.collect { |p| p.basename.splitext[0] }.sort
};

// Your backups of one map, newest first: backups/<name>/<time stamp>.json.
~midiBackups = { |name|
    (~midiBackupDir.() +/+ name.asString +/+ "*.json").pathMatch.sort.reverse
};

// settings.json: the one place for your choices (docs/dev/midi-map.md 8.4). The
// map each rig uses, by the rig's name; whether megalooper listens to each
// input, and sends values and lights back to it (5.7), by its device name;
// and the knobs' hysteresis and takeover where a binding names none
// (decisions 7 and 15: one step, none). Missing, or unreadable, is the
// defaults: every input listened to, none sent back to.
// It is read once, at boot, into ~midiSettings, and changed there: the Rig tab
// paints from that, never from the file, whose write is still under way when
// it repaints. Its version follows the maps' rule: a newer one is read for
// what this build knows and never written over, so a newer megalooper on the
// same Mac (the folder is shared by every checkout) keeps what it wrote. A
// field this build doesn't know is written back as it was.
~midiKnobDefaults = (hysteresis: 1, takeover: \none);
~midiSettingsRead = {
    var s = (maps: IdentityDictionary.new, listen: Dictionary.new, sendBack: Dictionary.new,
        knobs: ~midiKnobDefaults.copy, raw: nil, newer: false);
    var text = ~midiReadText.(~midiSettingsPath.());
    var d = text !? { |t| try { if(t.stripWhiteSpace.first == ${) { t.parseJSON } } { nil } };
    var midi, version;
    if(text.notNil and: { d.isKindOf(Dictionary).not or: { d["format"] != "megalooper settings" } }) {
        ("megalooper: " ++ ~midiSettingsPath.() ++ " can't be read; the MIDI settings are the defaults.").warn;
    };
    if(d.isKindOf(Dictionary) and: { d["format"] == "megalooper settings" }) {
        s[\raw] = d;
        version = LooperMidiMap.prInt(d["version"] ? "1") ? 1;
        if(version > 1) {
            s[\newer] = true;
            ("megalooper: " ++ ~midiSettingsPath.() ++ " is from a newer megalooper; it is read, "
                ++ "and changes made here are not written to it.").warn;
        };
    };
    midi = if(s[\raw].notNil) { d["midi"] };
    if(midi.isKindOf(Dictionary)) {
        if(midi["maps"].isKindOf(Dictionary)) {
            midi["maps"].keysValuesDo { |rig, name| name !? { s[\maps].put(rig.asSymbol, name.asString) } };
        };
        if(midi["listen"].isKindOf(Dictionary)) {
            midi["listen"].keysValuesDo { |device, on| s[\listen].put(device.asString, on.asString != "false") };
        };
        // Sent back to only where it says so: a controller may do anything
        // with what it is sent.
        if(midi["sendBack"].isKindOf(Dictionary)) {
            midi["sendBack"].keysValuesDo { |device, on| s[\sendBack].put(device.asString, on.asString == "true") };
        };
        // What can't be read is the default.
        midi["hysteresis"] !? { |x| LooperMidiMap.prInt(x) !? { |n| if(n.inclusivelyBetween(0, 64)) { s[\knobs][\hysteresis] = n } } };
        midi["takeover"] !? { |x| if(LooperMidiMap.takeovers.includes(x.asString.asSymbol)) { s[\knobs][\takeover] = x.asString.asSymbol } };
    };
    s
};

~midiSettingsString = { |s|
    var j = { |x| LooperMidiMap.jsonString(x) };
    var maps = s[\maps].keys.asArray.sort.collect { |rig| j.(rig.asString) ++ ": " ++ j.(s[\maps][rig]) };
    var listen = s[\listen].keys.asArray.sort.collect { |dev| j.(dev) ++ ": " ++ s[\listen][dev].asString };
    var back = s[\sendBack] ? Dictionary.new;
    var sendBack = back.keys.asArray.sort.collect { |dev| j.(dev) ++ ": " ++ (back[dev] == true).asString };
    // Fields this build doesn't write itself, as they were read (parseJSON
    // hands numbers over as strings, so they go back as strings: any reader
    // here takes them so).
    var raw = s[\raw] ? Dictionary.new;
    var others = { |d, skip, indent|
        if(d.isKindOf(Dictionary).not) { "" } {
            d.keys.asArray.reject { |k| skip.includesEqual(k) }.sort.collect { |k|
                ",\n" ++ indent ++ j.(k) ++ ": " ++ LooperSessionRecorder.json(d[k])
            }.join
        }
    };
    var knobs = s[\knobs] ? ~midiKnobDefaults;
    "{\"format\": \"megalooper settings\", \"version\": 1,\n \"midi\": {\"maps\": {"
        ++ maps.join(", ") ++ "},\n  \"listen\": {" ++ listen.join(", ") ++ "},\n"
        ++ "  \"sendBack\": {" ++ sendBack.join(", ") ++ "},\n"
        ++ "  \"hysteresis\": " ++ (knobs[\hysteresis] ? 1) ++ ", \"takeover\": " ++ j.((knobs[\takeover] ? \none).asString)
        ++ others.(raw["midi"], ["maps", "listen", "sendBack", "hysteresis", "takeover"], "  ") ++ "}"
        ++ others.(raw, ["format", "version", "midi"], " ") ++ "}\n"
};

// Write a file of yours the safe way (MegaFiles.write): the text into a
// file beside it, read back, then moved over the old file, so a crash leaves
// the old one or the new one, never half of either. `check` reads it back
// first (a function of its text that answers nil when it's good, else why
// not). The move runs in the shell without the interpreter waiting for it
// (docs/dev/midi-map.md 8.2), and `backup`, if given, is where the old file is
// copied first. `action` gets true, or false and why. The tests wait for it
// (~midiWriteSync): a synchronous test never gives an asynchronous one the
// chance to finish.
~midiWriteFile = { |path, text, check, backup, action|
    MegaFiles.write(path, text, check, backup, action, ~midiWriteSync == true)
};

~midiSettingsWrite = { |s, action|
    if(s[\newer] == true) {
        (action ? { }).value(false, "settings.json is from a newer megalooper");
    } {
        ~midiWriteFile.(~midiSettingsPath.(), ~midiSettingsString.(s),
            { |text| if(text.notNil and: { (try { text.parseJSON } { nil }).isKindOf(Dictionary) }) { nil } { "it didn't read back" } },
            nil, action ? { });
    };
};

// The knobs' defaults in use, from the settings (~midiRouteWith reads them
// on every message, so they are kept here, not looked up).
~midiDefaults = ~midiKnobDefaults.copy;
~midiDefaultsFrom = { |settings| ~midiDefaults = (settings[\knobs] ? ~midiKnobDefaults).copy };

// The settings in use: read at boot (~setupMidiBindings), changed in memory,
// written after.
~midiSettings = nil;
~midiSettingsNow = {
    // Read again when the folder of yours is another (the tests' scratch ones).
    if(~midiSettings.isNil or: { ~midiSettingsFrom != ~midiSettingsPath.() }) {
        ~midiSettingsFrom = ~midiSettingsPath.();
        ~midiSettings = ~midiSettingsRead.();
    };
    ~midiSettings
};
~midiSettingsSave = { |action| ~midiSettingsWrite.(~midiSettingsNow.(), action) };

// The map a rig uses: your choice for it in settings.json, else the one its
// profile names (setup-routing.scd's midiMap:), else none.
~midiMapNameFor = { |rigName, settings|
    var s = settings ?? { ~midiSettingsNow.() };
    s[\maps][rigName] ?? { ~routingProfiles !? { |p| p[rigName] !? { |r| r[\midiMap] } } }
};

// A map by name (docs/dev/midi-map.md 8.5): yours if you have one, else the
// shipped one. Answers (map:, from:, warning:), `from` one of \yours,
// \backup, \shipped or nil. A map of yours that can't be read gives way to
// its newest backup that can, never to the shipped one: a different layout
// could put Clear on a switch you now use for something else. With no such
// backup there is no map, and `warning` says so, for the header.
~midiMapLoad = { |name|
    var yours, shipped, r, make, backups, out;
    name = name !? { |n| n.asString };
    make = { |res| LooperMidiMap(res[\bindings], name, res[\basedOn], res[\revision]) };
    out = case
    { name.isNil } {
        // Not wrong, just new (a fresh clone's standalone rig): a hint, not
        // an alarm.
        (map: nil, warning: "No MIDI map — Setup › MIDI map to make one", level: \note)
    }
    { File.exists(yours = ~midiMapPath.(~midiUserDir.(), name)) } {
        r = LooperMidiMap.parse(~midiReadText.(yours));
        if(r.isString.not) {
            (map: make.(r), from: \yours, problems: r[\problems])
        } {
            backups = ~midiBackups.(name).collect { |p| [p, LooperMidiMap.parse(~midiReadText.(p))] }
                .reject { |pr| pr[1].isString };
            if(backups.notEmpty) {
                ("megalooper: your MIDI map '" ++ name ++ "' can't be read (" ++ r ++ "); its backup "
                    ++ backups[0][0].basename ++ " is loaded instead.").warn;
                (map: make.(backups[0][1]), from: \backup, problems: backups[0][1][\problems],
                    warning: "MIDI map '" ++ name ++ "' could not be read — its last backup is loaded · Setup")
            } {
                (map: nil, warning: "MIDI map '" ++ name ++ "' could not be read — footswitches are off · Setup",
                    why: r)
            }
        }
    }
    { File.exists(shipped = ~midiMapPath.(~midiShippedDir.(), name)) } {
        r = LooperMidiMap.parse(~midiReadText.(shipped));
        if(r.isString.not) {
            (map: make.(r), from: \shipped, problems: r[\problems])
        } {
            (map: nil, warning: "MIDI map '" ++ name ++ "' could not be read — footswitches are off · Setup",
                why: r)
        }
    }
    { (map: nil, warning: "There is no MIDI map '" ++ name ++ "' — footswitches are off · Setup") };
    out.put(\name, name)
};

// Keep: your map written as yours, for the next boot (docs/dev/midi-map.md 8.2).
// The old file goes into backups/ with a time stamp, the last five kept.
// `action` gets true, or false and why.
~midiMapKeep = { |map, action|
    var path = ~midiMapPath.(~midiUserDir.(), map.name);
    var backup = ~midiBackupDir.() +/+ map.name.asString +/+ (Date.localtime.stamp ++ ".json");
    var n = map.bindings.size;
    ~midiWriteFile.(path, map.fileString, { |text|
        var r = LooperMidiMap.parse(text);
        case
        { r.isString } { r }
        { r[\bindings].size != n } { "it read back with " ++ r[\bindings].size ++ " bindings, not " ++ n }
        { nil }
    }, backup, { |ok, why|
        if(ok) {
            ~midiBackups.(map.name).drop(~midiBackupsKept).do { |p| File.delete(p) };
        };
        action.value(ok, why);
    });
};

// ---- Inputs ------------------------------------------------------------------------
// Whether megalooper listens to an input, by its device name (Live's "Remote"
// switch per port: docs/dev/midi-map.md 9). A new input listens. One that doesn't
// reaches no binding and goes nowhere near Live; the log still shows it,
// marked. ~midiSources is every input by uid, as [device, port]; a uid not in
// it (a test's, or an input plugged in since the last scan) listens.
~midiDeaf = IdentitySet.new;
~midiListens = { |src| ~midiDeaf.includes(src).not };
// MIDIClient's inputs and outputs as they are listed now (none before
// MIDIClient.init, as headless). The tests give their own.
~midiClientSources = { MIDIClient.sources ? [] };
~midiClientDestinations = { MIDIClient.destinations ? [] };
// The listening state from settings.json, onto the inputs there are now.
~midiListenFrom = { |settings|
    ~midiDeaf = IdentitySet.new;
    (~midiSources ? ()).keysValuesDo { |uid, names|
        if((settings[\listen][names[0]] ? true) == false) { ~midiDeaf.add(uid) };
    };
};

// ---- Learning ----------------------------------------------------------------------
// docs/dev/midi-map.md 6. A control is armed from the Rig tab's list (Learn, or
// Add mapping); LooperMidiLearn decides which message it learns. While a
// control is armed, and while a question about taking another control's
// message is open, every message is swallowed: no binding acts and nothing
// goes on to Live. The log still shows them, marked "learning". An arm ends
// after one binding, on Cancel, or 15 s after it began with nothing learned;
// the router checks that time itself on every message, so nothing can leave
// MIDI swallowed. A clock ticks it too, every 50 ms, so a single stomp is
// learned without waiting for the next message.
~midiNow = { Main.elapsedTime };   // the tests set their own time
~midiLastSeen = Dictionary.new;    // CC and bend: key -> [value, time]
~midiLearning = nil;               // (learner:, target:, add:, question:)
~midiLearnNote = nil;              // the last thing learning said, for the Rig tab

~midiLearnArm = { |targetId, add = false|
    var target = (~midiTargets ? ())[targetId];
    if(target.isNil) {
        ("megalooper: MIDI: there is no control " ++ targetId ++ " to learn.").warn;
        nil
    } {
        ~midiLearning = (learner: LooperMidiLearn(targetId, target[\kind], ~midiNow.()),
            target: targetId, add: add == true);
        ~midiLearnNote = if((target[\kind] == \trigger) or: { target[\kind] == \toggle }) {
            "Press it twice, or send a note or program change"
        } { "Move it" };
        ~midiLearnClock.();
        ~midiChanged.(\learn);
        ~midiLearning
    }
};

~midiLearnDisarm = { |note|
    ~midiLearning = nil;
    ~midiLearnNote = note;
    ~midiChanged.(\learn);
};

// The 50 ms tick, while a control is armed. Cleared by Cmd-period with every
// clock, which is why the router checks the time itself.
~midiLearnClock = {
    var gen = (~midiLearnGen ? 0) + 1;
    ~midiLearnGen = gen;
    SystemClock.sched(0.05, {
        if((gen == ~midiLearnGen) and: { ~midiLearning.notNil }) {
            try { ~midiLearnLive.(~midiNow.()) } { |err| ~midiLearnDisarm.(err.errorString) };
            0.05
        } { nil }
    });
};

// Is the learning still going, at `now`? Its time and its question's are
// checked, and what the learner has decided by now is carried out.
~midiLearnLive = { |now|
    var l = ~midiLearning, q, out;
    if(l.isNil) { false } {
        q = l[\question];
        case
        { q.notNil and: { now > q[\until] } } {
            // The question cancels itself: the old binding stays.
            ~midiLearnDisarm.("Nothing changed: the question timed out");
            false
        }
        { q.notNil } { true }
        {
            // What the learner has by now first, so a press in the last 30 ms
            // before the 15 s still counts; then its time.
            out = l[\learner].tick(now);
            case
            { out.notNil } { ~midiLearnResolve.(out, now) }
            { l[\learner].expired(now) } { ~midiLearnDisarm.("Nothing learned in 15 s") }
            { ~midiLearnRefusals.() };
            ~midiLearning.notNil
        }
    }
};

// What the learner refused, said once each.
~midiLearnRefusals = {
    var l = ~midiLearning;
    l !? {
        if(l[\learner].refusals.size > (l[\said] ? 0)) {
            l[\said] = l[\learner].refusals.size;
            ~midiLearnNote = ~midiCapital.(l[\learner].refusals.last);
            ~midiChanged.(\learn);
        };
    };
};

// A message learned: the binding it makes, taken at once, or after a question
// if another control has that message (6.4). It answers only the input it
// came from (decision 5), on its channel.
~midiLearnResolve = { |out, now|
    var l = ~midiLearning, binding, names, others;
    binding = (msg: out[\msg], chan: out[\chan], num: out[\num], target: l[\target]);
    names = (~midiSources ? ())[out[\src]];
    names !? {
        binding.put(\device, names[0]);
        // A port named as its device says nothing more.
        if(names[1] != names[0]) { binding.put(\port, names[1]) };
    };
    out[\switch] !? { |sw| binding.put(\switch, sw) };
    if(LooperMidiMap.bindingProblem(binding).notNil) {
        ~midiLearnDisarm.("Can't use that: " ++ LooperMidiMap.bindingProblem(binding));
    } {
        others = ~midiMap.conflicts(binding);
        if(others.notEmpty) {
            l[\question] = (binding: binding, others: others, until: now + 10, ask: out[\ask]);
            ~midiLearnNote = LooperMidiMap.describe(binding) ++ " is " ++ ~midiTargetLabel.(others[0][\target])
                ++ "'s: move it to " ++ ~midiTargetLabel.(l[\target]) ++ ", use it for both, or cancel";
            ~midiChanged.(\learn);
        } {
            ~midiLearnTake.(binding, \take, out[\ask]);
        };
    };
};

// The answer to the question, from the Rig tab: \move takes the message from
// the other control, \both lets it drive both, \cancel leaves things as they
// were. A stomp never answers it.
~midiLearnAnswer = { |answer|
    var q = ~midiLearning !? { |l| l[\question] };
    q !? {
        case
        { answer == \move } { ~midiLearnTake.(q[\binding], \move, q[\ask], q[\others]) }
        { answer == \both } { ~midiLearnTake.(q[\binding], \both, q[\ask]) }
        { ~midiLearnDisarm.("Nothing changed") };
    };
};

// Make the binding: the control's earlier bindings go unless it was added
// with Shift (Add), the other control's go with \move, and \both marks it
// as meant to share its message (layer).
~midiLearnTake = { |binding, how, ask, others|
    var l = ~midiLearning, map = ~midiMap, old;
    if(how == \move) { map = map.removing(others) };
    if(how == \both) { binding.put(\layer, true) };
    if(l.notNil and: { l[\add].not }) {
        old = map.bindingsFor(binding[\target]);
        // Learned again, a control keeps what its old binding most like the
        // new one said (of the same message, else a knob for a knob): its
        // range, and a CC its hysteresis and its controller's travel. The
        // pedal's flicker fix must not go with the message it was on.
        (old.detect { |o| o[\msg] == binding[\msg] }
            ?? { old.detect { |o| [\cc, \bend].includes(o[\msg]) and: { [\cc, \bend].includes(binding[\msg]) } } }
            ?? { old.first }) !? { |o|
            [\min, \max].do { |k| o[k] !? { |v| binding.put(k, v) } };
            if((o[\msg] == \cc) and: { binding[\msg] == \cc }) {
                o[\hysteresis] !? { |v| binding.put(\hysteresis, v) };
            };
            // A knob its travel, swept in the same units (CC to CC, pitch
            // bend to pitch bend), and its takeover, either way.
            if([\cc, \bend].includes(o[\msg]) and: { [\cc, \bend].includes(binding[\msg]) }) {
                if(o[\msg] == binding[\msg]) { [\inLo, \inHi].do { |k| o[k] !? { |v| binding.put(k, v) } } };
                o[\takeover] !? { |v| binding.put(\takeover, v) };
            };
        };
        map = map.removing(old);
    };
    map = map.adding(binding);
    ~midiMapEdit.(map);
    ~midiLearnDisarm.(LooperMidiMap.describe(binding) ++ " → " ++ ~midiTargetLabel.(binding[\target])
        ++ if(ask == true) { " (one message a press: say if it is another kind of switch)" } { "" });
};

~midiCapital = { |text| if(text.isEmpty) { text } { text[0].toUpper.asString ++ text.drop(1) } };

// What drives a control in the map now, in words ("PC 4", "PC 8, note 66"),
// or nil: for tooltips and labels, which say what the map says (8.6).
~midiBindingWords = { |id|
    var bs = (~midiMap !? { |m| m.bindingsFor(id) }) ? [];
    if(bs.isEmpty) { nil } { bs.collect { |b| LooperMidiMap.describe(b) }.join(", ") }
};
// The program that drives a control, or nil: the Effects tiles' number.
~midiProgramFor = { |id|
    (~midiMap !? { |m| m.bindingsFor(id).detect { |b| b[\msg] == \program } }) !? { |b| b[\num] }
};

~midiTargetLabel = { |id|
    (~midiTargets ? ())[id] !? { |t| ~midiTargetWords.(t) } ? id.asString
};
// A control in words. An effect's setting carries its device, "Delay 2 ›
// Dry/Wet": several effects have a Dry/Wet.
~midiTargetWords = { |t|
    if((t[\path] == "Effects") and: { t[\group].notNil } and: { t[\group] != t[\label] }) {
        t[\group] ++ " › " ++ t[\label] } { t[\label] }
};
// Why a binding's control does nothing now, in words, or nil: it is there.
// One of SA's effects that no chain holds is said as that, whether its
// controls were ever made here or not.
~midiTargetWhy = { |id|
    var t = (~midiTargets ? ())[id];
    case
    { t.notNil and: { (try { t[\available].value } { false }) != false } } { nil }
    { t.notNil } { (try { t[\why].value } { nil }) ? "not there now" }
    { id.asString.beginsWith("sa.fx") } { "its effect is not in the chains now" }
    { "not in this megalooper" }
};

// The controls made again once a kit is in force (gui-drums.scd): the trims
// are made for the pads of the kits loaded (setup-miditargets.scd), so the
// new kit's pads get theirs, under its names. A control the new build doesn't
// make, a pad only the old kit had, is kept as it was: not there now, so a
// binding on it is greyed, not lost. Swapped in with one assignment.
// Given \effects, only SA's effects' controls are made again: after a chain
// edit (gui-effects.scd), so a second Delay has its own before its switch is
// tagged, and a removed device's stay, greyed, for Undo to bring back.
~midiTargetsRefresh = { |family|
    var fresh = try { ~midiTargetsBuild.(family) } { |err|
        ("megalooper: the MIDI controls could not be made again (" ++ err.errorString
            ++ "); the ones there were stay.").warn;
        nil
    };
    fresh !? {
        (~midiTargets ? ()).keysValuesDo { |id, t| if(fresh[id].isNil) { fresh.put(id, t) } };
        ~midiTargets = fresh;
        // The Rig tab's list and picker are made again, with the new names,
        // although the map is the same.
        ~midiGui !? { |g| g[\shownMap] = nil; g[\pickStale] = true };
        ~midiChanged.(\map);
    };
};

// The same controls, but which of them are there changed (a chain edit on SA
// removed or brought back a device): the Rig tab's list greys its rows anew.
// Nothing is built again; the router asks each control's `available` as a
// message comes, so it needs nothing.
~midiTargetsRepaint = {
    ~midiGui !? { |g| g[\shownMap] = nil };
    ~midiChanged !? { |f| f.(\map) };
};

// ---- Editing -----------------------------------------------------------------------
// Every change makes a new map, swapped in with one assignment; Undo steps
// back through them. Nothing reaches the disk before Keep. A map swapped in
// takes what the router keeps of each knob from the one in force
// (LooperMidiMap.adopt): editing one mapping leaves every other knob as it
// was, and a map back from Undo brings no knob's old state with it.
~midiUndo = List.new;
~midiMapEdit = { |map|
    ~midiUndo.add(~midiMap);
    ~midiMap = map.adopt(~midiMap);
    ~midiChanged.(\map);
    map
};
~midiMapUndo = {
    var was = ~midiMap;
    if(~midiUndo.notEmpty) {
        ~midiMap = ~midiUndo.pop !? { |m| m.adopt(was) };
        ~midiChanged.(\map);
    };
    ~midiMap
};
// Are there changes since the map was loaded or kept?
// Asked four times a second while MIDI Map mode is on (its bar's Keep), and
// writing both maps out each time costs: a LooperMidiMap never changes once
// made (an edit makes a new one), so the answer is kept until either map is
// another one.
~midiMapDirtyFor = [nil, nil, false];
~midiMapDirty = {
    var m = ~midiMap, k = ~midiKept;
    if(m.isNil or: { k.isNil }) { false } {
        if((m !== ~midiMapDirtyFor[0]) or: { k !== ~midiMapDirtyFor[1] }) {
            ~midiMapDirtyFor = [m, k, m.fileString != k.fileString];
        };
        ~midiMapDirtyFor[2]
    }
};

~midiBindingRemove = { |binding|
    ~midiMapEdit.(~midiMap.removing([binding]))
};
// A binding with some fields changed (\remove takes one away; \none is a
// takeover's value). Refused, and said, if the result can't be used.
~midiBindingChange = { |binding, changes|
    var b = binding.copy, why;
    changes.keysValuesDo { |k, v| if(v == \remove) { b.removeAt(k) } { b.put(k, v) } };
    why = LooperMidiMap.bindingProblem(b);
    if(why.notNil) {
        ~midiLearnNote = "Not changed: " ++ why;
        ~midiChanged.(\learn);
        nil
    } {
        ~midiMapEdit.(~midiMap.replacing(binding, b));
        b
    }
};
// Set one end of a binding's range to where its control is now (7.3).
~midiBindingSetEnd = { |binding, end|
    var t = (~midiTargets ? ())[binding[\target]];
    var v = t !? { |x| x[\get].value };
    if(v.isNumber) { ~midiBindingChange.(binding, IdentityDictionary[end -> v]) };
};
// Turn a binding round: its two ends swap.
~midiBindingSwap = { |binding|
    var t = (~midiTargets ? ())[binding[\target]];
    var lo = binding[\min] ?? { t !? { |x| x[\fromPos] !? { |f| f.value(0) } } };
    var hi = binding[\max] ?? { t !? { |x| x[\fromPos] !? { |f| f.value(1) } } };
    if(lo.notNil and: { hi.notNil }) {
        ~midiBindingChange.(binding, (min: hi, max: lo));
    };
};

// A binding's input range, swept (docs/dev/midi-map.md 5.4): a pedal that stops
// short of 127, as the TSMega's stops at 126, never takes its control to the
// end. While a sweep runs, every value of the binding's message is noted, and
// at its end the lowest and the highest are its input range. The knob goes on
// driving its control meanwhile. It ends with Done on the Rig tab; one still
// running 20 s on ends itself and changes nothing.
~midiSweep = nil;    // (binding:, lo:, hi:, until:)
~midiSweepStart = { |binding|
    ~midiSweep = (binding: binding, until: ~midiNow.() + 20);
    ~midiLearnNote = "Move it from one end of its travel to the other, then Done";
    ~midiChanged.(\sweep);
};
// A message ~midiRoute carries to the bindings (not one learning takes, nor
// one from an input not listened to): one the swept binding answers is noted.
~midiSweepFeed = { |msg, chan, num, val, src|
    var sw = ~midiSweep, b = sw !? { |x| x[\binding] };
    if(b.notNil and: { b[\msg] == msg } and: { b[\num] == num } and: { b[\chan].isNil or: { b[\chan] == chan } }
        and: { LooperMidiMap.deviceMatches(b, ~midiSources !? { |s| s[src] }) }) {
        sw[\lo] = (sw[\lo] ? val).min(val);
        sw[\hi] = (sw[\hi] ? val).max(val);
    };
};
// The end: the range taken if the knob went far enough (a sixteenth of its
// travel), else nothing changed. `keep` false drops it, and says `note` if
// given: a sweep left to end itself is dropped, as one forgotten mid-song
// would otherwise change the pedal's whole response with no one asking.
~midiSweepEnd = { |keep = true, note|
    var sw = ~midiSweep, b, top, lo, hi;
    ~midiSweep = nil;
    if(keep.not and: { sw.notNil } and: { note.notNil }) { ~midiLearnNote = note };
    if(keep and: { sw.notNil }) {
        b = sw[\binding];
        top = LooperMidiMap.top(b[\msg]);
        lo = sw[\lo];
        hi = sw[\hi];
        case
        { ~midiMap.bindings.includes(b).not } {
            // Changed or taken away meanwhile: it is not the one swept.
            ~midiLearnNote = "Range not changed: the mapping changed while it swept";
        }
        { lo.isNil or: { (hi - lo) < (top / 16) } } {
            ~midiLearnNote = "Range not changed: move it from one end to the other while it sweeps";
        } {
            ~midiBindingChange.(b, (inLo: if(lo == 0) { \remove } { lo }, inHi: if(hi == top) { \remove } { hi }))
                !? { ~midiLearnNote = LooperMidiMap.describe(b) ++ " now covers " ++ lo ++ "–" ++ hi };
        };
    };
    ~midiChanged.(\sweep);
};

// The Rig tab's MIDI section repaints from this, once per burst of changes and
// never from the MIDI thread (5.5): it keeps the latest state and one pending
// AppClock task. ~midiGuiRefresh is gui-midimap.scd's, nil without a window.
~midiChanged = { |what|
    if(~midiGuiPending != true) {
        ~midiGuiPending = true;
        { ~midiGuiPending = false; ~midiGuiRefresh !? { |f| f.value } }.defer;
    };
};

// ---- The router ------------------------------------------------------------------
// Is a binding a knob or a pedal on a level, a count or a choice (pitch bend,
// or a CC that is not a switch), so its hysteresis, takeover and input range
// count? The Rig tab asks it too.
~midiIsKnob = { |b, kind|
    [\continuous, \step, \choice].includes(kind)
        and: { (b[\msg] == \bend) or: { (b[\msg] == \cc) and: { (b[\switch] ? \knob) == \knob } } }
};

// What the bindings a message would reach kept of its input and channel,
// forgotten where it is stale (LooperMidiMap.forget): the router didn't see
// where the knob went (learning took the message, or its input isn't
// listened to). What its controller shows isn't known either: it is sent
// again, if it is sent back to.
~midiForget = { |msg, chan, num, src|
    var bmsg = if((msg == \noteOn) or: { msg == \noteOff }) { \note } { msg };
    ~midiMap !? { |m| m.lookup(bmsg, chan, num).do { |slot|
        slot[\states][src ? 0] !? { |x| x.put(chan ? 0, LooperMidiMap.forget(x[chan ? 0],
            (~midiTargets ? ())[slot[\binding][\target]] !? { |t| t[\kind] })) };
        ~midiBackUnknown.(slot, src, chan);
    } };
};

// One message to the bindings it reaches. Each acts on its control at once and
// on this thread, as LooperMidiMap.decide says: the drums and the break take
// the moment of a press from it. A control that is not there now, or that this
// build does not know, does nothing. One that throws is said once and skipped,
// so the next binding still acts. `msg` is \noteOn, \noteOff, \cc, \program or
// \bend, `num` nil for bend; `sources` is the inputs by uid, as [device, port],
// for bindings that name one; `warned` the controls already said; `defaults`
// the knobs' hysteresis and takeover where a binding names none (~midiDefaults;
// missing, none of either). Answers the controls it acted on, for the log.
~midiRouteWith = { |map, targets, msg, chan, num, val, src, sources, warned, defaults|
    var bmsg = if((msg == \noteOn) or: { msg == \noteOff }) { \note } { msg };
    var acted = List.new, later = List.new;
    map.lookup(bmsg, chan, num).do { |slot|
        var b = slot[\binding];
        var target = targets[b[\target]];
        var byChan, out, knob, mode, v;
        try {
            if(target.notNil and: { LooperMidiMap.deviceMatches(b, sources !? { |s| s[src] }) }) {
                if(target[\available].value == false) {
                    // Not there now: what this binding kept of the knob would
                    // be stale by the time it is.
                    slot[\states][src ? 0] !? { |x| x.put(chan ? 0, LooperMidiMap.forget(x[chan ? 0], target[\kind])) };
                    ~midiBackUnknown.(slot, src, chan);
                } {
                    // What this binding remembers of each input and channel:
                    // the hysteresis, a knob's arm, its takeover.
                    byChan = slot[\states][src ? 0];
                    if(byChan.isNil) { byChan = Array.newClear(16); slot[\states].put(src ? 0, byChan) };
                    // A knob or a pedal on a level, a count or a choice: the
                    // defaults, and for a takeover where the control is now.
                    // One that can't be read has none, and jumps.
                    if(~midiIsKnob.(b, target[\kind])) {
                        knob = (hysteresis: defaults !? { |d| d[\hysteresis] }, takeover: defaults !? { |d| d[\takeover] });
                        mode = b[\takeover] ?? { knob[\takeover] } ? \none;
                        if((mode != \none) and: { target[\get].notNil }) {
                            v = try { target[\get].value } { nil };
                            if(v.isNumber) {
                                knob[\value] = v;
                                case
                                { target[\kind] == \choice } {
                                    knob[\current] = target[\toPos].value(v);
                                    // Its items counted only when pick-up asks:
                                    // a drum lane's are the kit's, and slow.
                                    knob[\same] = { |c|
                                        LooperMidiMap.choiceIndex(c, (target[\items].value ? []).size.max(1)) == v };
                                }
                                { target[\kind] == \step } {
                                    knob[\current] = LooperMidiMap.knobAt(v, target[\toPos], b[\min], b[\max]);
                                    knob[\same] = { |c| LooperMidiMap.valueAt(c, target[\fromPos], target[\toPos],
                                        b[\min], b[\max]).round == v.round };
                                }
                                { knob[\current] = LooperMidiMap.knobAt(v, target[\toPos], b[\min], b[\max]) };
                            };
                        };
                    };
                    out = LooperMidiMap.decide(target[\kind], b, msg, val, byChan[chan ? 0], knob);
                    byChan.put(chan ? 0, out[1]);
                    out[0] !? { |action|
                        ~midiApply.(target, action, b);
                        acted.add(b[\target]);
                        // The control as the model rounded it: if it is
                        // something else at the next message, something else
                        // moved it, and a pick-up knob has to catch it again
                        // (a scaling one starts again from it).
                        if(((mode == \pickup) or: { mode == \scale }) and: { out[1].isKindOf(Event) }) {
                            out[1][\readBack] = try { target[\get].value } { nil };
                        };
                    };
                    // What its controller shows now, if it is sent back to (5.7).
                    if((~midiBackSrcs !? { |s| s.includes(src) }) == true) {
                        ~midiBackHeard.(slot, target, msg, chan, val, src, out[0].notNil, later);
                    };
                };
            };
        } { |err|
            if(warned.notNil and: { warned.includes(b[\target]).not }) {
                warned.add(b[\target]);
                ("megalooper: MIDI " ++ LooperMidiMap.describe(b) ++ " -> " ++ b[\target]
                    ++ " threw (" ++ err.errorString ++ "). Said once; it is tried again each time.").warn;
            };
        };
    };
    // A light sent at once moved the controller under the message's other
    // bindings: told once each has acted on the message (~midiBackOthers).
    later.do { |x|
        try { ~midiBackOthers.(x[0], x[1], x[2]) } { |err|
            ~midiBackSaid.(x[0][\slot][\binding][\target], "telling the others of " ++ LooperMidiMap.describe(x[0][\slot][\binding])
                ++ " threw (" ++ err.errorString ++ "). Said once; it is tried again each time.");
        };
    };
    acted.asArray
};

// One message from a responder: dropped, if it is an echo of what was sent
// back (5.7); learned, if a control is learning; left alone, if its input
// isn't listened to; else carried to its bindings. Answers which, for the
// proxy and the log: \echo, \swallowed, \deaf, or the controls it acted on
// (an Array, empty when none).
~midiRoute = { |msg, chan, num, val, src|
    var key, was, sent, now, l, how;
    // Carried to the bindings, and noted first by an input range being swept.
    var go = {
        if(~midiSweep.notNil and: { key.notNil }) { ~midiSweepFeed.(msg, chan, num, val, src) };
        ~midiRouteWith.(~midiMap, ~midiTargets, msg, chan, num, val, src, ~midiSources, ~midiWarned, ~midiDefaults)
    };
    // An echo moves nothing and goes nowhere: not even into learning's 3
    // steps, nor what the router last saw.
    if(((~midiBackSrcs !? { |s| s.includes(src) }) == true) and: { ~midiBackIsEcho.(msg, chan, num, val, src) }) {
        \echo
    } {
        // What the router last saw of each CC and bend, for learning's 3 steps.
        if((msg == \cc) or: { msg == \bend }) {
            key = LooperMidiLearn.key(msg, chan, num, src);
            was = ~midiLastSeen[key];
            // A knob sent its place since its own last message: one that took
            // it is there now, one that didn't (a pedal, a fader with no motor)
            // is where it was, so learning counts 3 steps from both (5.7). One
            // not heard since the boot has no place: its first message says
            // where it is.
            sent = (~midiBackLastSent !? { |t| t[key] }) !? { |x|
                if((x[2] == \knob) and: { was.notNil } and: { x[1] > was[1] }) { x[0] }
            };
            now = ~midiNow.();
            ~midiLastSeen.put(key, [val, now]);
        };
        l = ~midiLearning;
        how = case
        // Counting a switch's presses: that switch is held back, nothing else is.
        { l.notNil and: { ~midiLearnLive.(now ?? { now = ~midiNow.() }) } and: { ~midiLearning.notNil }
            and: { ~midiLearning[\question].isNil } and: { ~midiLearning[\learner].counting }
            and: { ~midiLearning[\learner].chosenKey != LooperMidiLearn.key(msg, chan, num, src) } } {
            if(~midiListens.(src).not) { \deaf } { go.value }
        }
        { ~midiLearning.notNil and: { ~midiLearnLive.(now ?? { now = ~midiNow.() }) } } {
            if(~midiLearning[\question].isNil) {
                ~midiLearning[\learner].feed(msg, chan, num, val, src, was !? { |w| w[0] }, was !? { |w| w[1] }, now, sent)
                    !? { |out| ~midiLearnResolve.(out, now) };
            };
            \swallowed
        }
        { ~midiListens.(src).not } { \deaf }
        { go.value };
        // Held back, it reached no binding: what they kept of that knob is stale.
        if(how.isKindOf(Symbol)) { ~midiForget.(msg, chan, num, src) };
        how
    }
};

// The log's mark: a message the router held back, or what it did
// (docs/dev/midi-map.md 7.4: "program  prog=5 chan=0  → Clear").
~midiLogMark = { |how|
    case
    { how == \swallowed } { "  (learning)" }
    { how == \deaf } { "  (not listening)" }
    { how == \echo } { "  (echo of what was sent back)" }
    { how.isKindOf(Array) and: { how.notEmpty } } {
        "  → " ++ how.collect { |id| ~midiTargetLabel.(id) }.join(", ")
    }
    { "" }
};

// Is MIDI held back from this input now (learning, or not listened to)? For
// the messages no binding takes (aftertouch), which still go to Live.
~midiHeld = { |src|
    (~midiLearning.notNil and: { ~midiLearnLive.(~midiNow.()) } and: { ~midiLearning.notNil }
        and: { ~midiLearning[\question].notNil or: { ~midiLearning[\learner].counting.not } })
        or: { ~midiListens.(src).not }
};

// What the header should say about MIDI, if anything: [text, level], the
// level \error (red) or \note (amber). A map that could not be loaded first;
// then an input the map is for that isn't listened to, whose footswitches are
// all off; then one that isn't connected (only once MIDI lists inputs at all).
~midiAttention = {
    var devices = (~midiMap !? { |m| m.bindings.collect { |b| b[\device] } } ? []).reject(_.isNil).asSet.asArray.sort;
    var sources = ~midiSources ? ();
    var here = sources.values.collect { |n| n[0] };
    var deaf = sources.keys.asArray.select { |uid| ~midiDeaf.includes(uid) }.collect { |uid| sources[uid][0] };
    var off = devices.select { |d| deaf.includesEqual(d) };
    var missing = devices.reject { |d| here.includesEqual(d) };
    case
    { ~midiMapWarning.notNil } { [~midiMapWarning, ~midiMapWarningLevel ? \error] }
    { off.notEmpty } { [off.join(", ") ++ " is not listened to — its footswitches are off · Setup › MIDI map", \error] }
    { missing.notEmpty and: { here.notEmpty } } { [missing.join(", ") ++ " is not connected · Setup › MIDI map › Rescan", \note] }
    { nil }
};

// An action of LooperMidiMap.decide, carried out on a control.
~midiApply = { |target, action, binding|
    var verb = action[0], kind = target[\kind];
    var at = { |c| LooperMidiMap.valueAt(c, target[\fromPos], target[\toPos], binding[\min], binding[\max]) };
    var put = { |v| target[\set].value(if(kind == \step) { v.round.asInteger } { v }) };
    var lo, hi, cur, n;
    case
    { verb == \fire } { target[\fire].value }
    { verb == \flip } {
        case
        { kind == \toggle } {
            if(target[\flip].notNil) { target[\flip].value } { target[\set].value(target[\get].value != true) }
        }
        { kind == \choice } { ~midiApply.(target, [\next], binding) }
        {
            // A knob's two ends: to the one further from where it is.
            lo = at.(0);
            hi = at.(1);
            cur = target[\get].value;
            put.(if((cur - lo).abs > (cur - hi).abs) { lo } { hi });
        }
    }
    { verb == \set } {
        if(target[\set].notNil) { target[\set].value(action[1]) } {
            if((target[\get].value == true) != action[1]) { target[\flip].value };
        }
    }
    { verb == \position } {
        if(kind == \choice) {
            n = (target[\items].value ? []).size;
            if(n > 0) { target[\set].value(LooperMidiMap.choiceIndex(action[1], n)) };
        } { put.(at.(action[1])) };
    }
    { verb == \end } { put.(at.(if(action[1] == \max) { 1 } { 0 })) }
    { verb == \next } {
        n = (target[\items].value ? []).size;
        if(n > 0) { target[\set].value(((target[\get].value ? -1) + 1).mod(n)) };
    };
};

// ---- Sending back ----------------------------------------------------------------
// docs/dev/midi-map.md 5.7. A controller that takes MIDI back (the Faderfox UC4
// does) is sent, for each of its bindings, where the control is: an encoder
// then goes on from where the mouse, a preset or another controller put its
// control, and a button's light shows its switch. Off for every input until
// the Rig tab's Send back switches it on (settings.json's sendBack), and only
// for an input listened to that has an output of its own (~midiBackOutputFor).
// Never to an IAC bus, nor to ~midiOut: Live would take it for the controller.
//
// A knob is sent a value only once something other than its own messages
// moved its control, and not while it was touched in the last ~midiBackHold
// seconds: sent its own moves, rounded, it would fight the hand (a count's
// band holds several values, and hysteresis leaves a step out). Once sent, the
// router notes the place (LooperMidiMap.sentBack), and the knob's next message
// says whether it took it. A switch's light is sent at once after each message
// from it, as a controller may light or darken a button itself when it is
// pressed or let go, and at the next tick when something else changes it. A
// place two bindings share (layered) shows the first's whose control is
// there. A send moves the controller under every other binding of the
// message (~midiBackOthers): a CC knob on a toggle is told the place
// (LooperMidiMap.sentBack), the others forget their knob
// (LooperMidiMap.forget), and what the place shows of theirs isn't known.
//
// What was just sent coming back is an echo (a MIDI thru), dropped before
// learning, the bindings and Live (~midiBackIsEcho): a knob's, the value sent,
// within ~midiBackKnobEcho of when it left (each output's messages leave one
// after another: ~midiBackFree); a light's, a press, within
// ~midiBackLightEcho. A release is never one: it goes on, and a release so
// soon after a light off was sent has nothing sent again, so a thru can't
// keep it going.
//
// What was sent is kept with the router's states, under \back: an input's
// uid -> one record per channel, (wire:, value:, at:), what the controller
// shows, the control's value it shows, and when its light was sent. So an edit
// of the map sends nothing again (LooperMidiMap.adopt), and a boot, the rebuild
// after a Cmd-period, a Rescan or switching Send back on sends everything. A
// binding is sent to on its own input and channel if it names both (a learned
// one does), and on each input and channel its message came from. A clock
// ticks it, on SystemClock, apart from the window's repaints on AppClock
// (both share the interpreter).
~midiBackHold = 0.3;
~midiBackKnobEcho = 0.05;
~midiBackLightEcho = 0.02;
~midiBackRate = 0.05;
~midiBackFirst = 1;                           // the clock's first tick, after a boot's window is made
~midiBackMax = 40;                            // messages a tick: what a DIN wire carries in one, so none waits for the next
~midiBackGap = 0.001;                         // a message's time on a DIN wire: when each of a burst leaves
~midiBackFree = IdentityDictionary.new;       // an output's uid -> when its wire is free again
~midiDestinations = IdentityDictionary.new;   // uid -> [device, name]: the outputs, IAC buses and ~midiOut left out
~midiBackSrcs = IdentitySet.new;              // the inputs sent back to, by uid
~midiBackTo = IdentityDictionary.new;         // an input's uid -> its output's
~midiBackOuts = IdentityDictionary.new;       // an output's uid -> its MIDIOut, \dead once a send failed
~midiBackSent = Dictionary.new;               // for the echo: LooperMidiLearn.key -> what is on its way, [[value, time it left, match], ...]
~midiBackLastSent = Dictionary.new;           // LooperMidiLearn.key -> [value, when, \knob or \light] last sent: the hold, learning
// An output by uid, on port 0, which MIDIClient.init always makes: the
// destination is found by its uid at every send, so a controller plugged in
// after the boot can be sent to (newByName needs a port made for it at
// init). The tests give their own.
~midiBackOpen = { |uid| MIDIOut(0, uid).latency_(0) };
// Said once (the tests count what is said).
~midiBackWarn = { |text| text.warn };
~midiBackSaid = { |key, text|
    if(~midiWarned.isNil or: { ~midiWarned.includes(key).not }) {
        ~midiWarned !? { |w| w.add(key) };
        ~midiBackWarn.("megalooper: MIDI: " ++ text);
    };
};

// The outputs there are now (none before MIDIClient.init, as headless).
~midiBackOutputs = {
    var mine = ~midiOut !? { |o| try { o.uid } { nil } };
    ~midiDestinations = IdentityDictionary.new;
    ~midiClientDestinations.().do { |d|
        if(d.device.contains("IAC").not and: { mine.isNil or: { d.uid != mine } }) {
            ~midiDestinations.put(d.uid, [d.device, d.name]);
        };
    };
    ~midiDestinations
};

// An input's output, by its names [device, port]: the one output of the
// same names; else, for a device of one input and one output, that one. None
// where two outputs have the input's names (two controllers alike: which is
// whose isn't known), nor for an input of a device with several.
~midiBackOutputFor = { |names|
    var dests = ~midiDestinations ? (), uids = dests.keys.asArray.sort, exact, same, inputs;
    exact = uids.select { |u| dests[u] == names };
    case
    { exact.size == 1 } { exact[0] }
    { exact.size > 1 } { nil }
    {
        same = uids.select { |u| dests[u][0] == names[0] };
        inputs = (~midiSources ? ()).values.count { |n| n[0] == names[0] };
        if((same.size == 1) and: { inputs == 1 }) { same[0] }
    }
};
// Could this device be sent back to (one of its inputs has an output)?
~midiBackCan = { |device|
    (~midiSources ? ()).values.any { |n| (n[0] == device) and: { ~midiBackOutputFor.(n).notNil } }
};

// The inputs sent back to, from the settings: switched on, listened to, with
// an output; one output to one input (two on one are left out). The clock
// runs while there is one.
~midiBackFrom = { |settings|
    var on = (settings !? { |s| s[\sendBack] }) ? Dictionary.new, taken = IdentityDictionary.new;
    ~midiBackSrcs = IdentitySet.new;
    ~midiBackTo = IdentityDictionary.new;
    (~midiSources ? ()).keysValuesDo { |uid, names|
        var out;
        if((on[names[0]] == true) and: { ~midiListens.(uid) } and: { names[0].contains("IAC").not }) {
            out = ~midiBackOutputFor.(names);
            out !? { taken.put(out, (taken[out] ? []).add(uid)) };
        };
    };
    taken.keysValuesDo { |out, uids| if(uids.size == 1) { ~midiBackSrcs.add(uids[0]); ~midiBackTo.put(uids[0], out) } };
    ~midiBackStale = true;
    ~midiBackClock.();
};

// Send back switched on or off for a device, kept in settings.json. Switched
// on, it is sent everything: what it shows is not known.
~midiBackSwitch = { |device, on|
    var s = ~midiSettingsNow.();
    (s[\sendBack] ?? { s.put(\sendBack, Dictionary.new); s[\sendBack] }).put(device, on);
    if(on) { ~midiBackAgain.(device) };
    ~midiBackFrom.(s);
    ~midiSettingsSave.();
};

// What a controller shows is not known (Send back switched on, a Rescan): all
// of it is sent again. `device` limits it to that device's inputs; none is
// every one.
~midiBackAgain = { |device|
    var srcs = (~midiSources ? ()).keys.select { |uid| device.isNil or: { ~midiSources[uid][0] == device } };
    ~midiMap !? { |m| m.slots.do { |slot|
        slot[\states][\back] !? { |back| back.keysValuesDo { |src, byChan|
            if(device.isNil or: { srcs.includes(src) }) { byChan.do { |r| r !? { r[\wire] = nil; r[\value] = nil } } };
        } };
    } };
    if(device.isNil) { ~midiBackSent = Dictionary.new } {
        ~midiBackSent.keys.asArray.do { |k| if(srcs.any { |uid| k.endsWith("/" ++ uid) }) { ~midiBackSent.removeAt(k) } };
    };
};

// What a binding last sent to one input's channel, or heard from it: made
// when first asked for.
~midiBackRecord = { |slot, src, chan|
    var back = slot[\states][\back], byChan, r;
    if(back.isNil) { back = IdentityDictionary.new; slot[\states].put(\back, back) };
    byChan = back[src];
    if(byChan.isNil) { byChan = Array.newClear(16); back.put(src, byChan) };
    r = byChan[chan];
    if(r.isNil) { r = (); byChan.put(chan, r) };
    r
};
// What the controller shows there is not known: sent again (its messages
// went unseen: learning took them, or the control wasn't there).
~midiBackUnknown = { |slot, src, chan|
    slot[\states][\back] !? { |x| x[src ? 0] !? { |y| y[chan ? 0] !? { |r| r[\wire] = nil; r[\value] = nil } } };
};
// A send `w` to a place (an address) moved the controller under every other
// binding its message reaches (layered), sent back or not: what the router
// kept of their knob is stale (LooperMidiMap.forget: a pick-up catches again,
// a trigger is disarmed), a CC knob on a toggle is told the place, so its
// next message sets its side if the knob took it (LooperMidiMap.sentBack),
// and what the place shows of theirs isn't known, so whichever shows there
// next is sent its own.
~midiBackOthers = { |e, a, w|
    var b = e[\slot][\binding], names = (~midiSources ? ())[a[0]];
    (~midiMap !? { |m| m.lookup(b[\msg], a[1], b[\num]) } ? []).do { |slot|
        var x = slot[\binding], t = (~midiTargets ? ())[x[\target]], byChan;
        if((slot !== e[\slot]) and: { t.notNil } and: { LooperMidiMap.deviceMatches(x, names) }) {
            byChan = slot[\states][a[0]];
            if((t[\kind] == \toggle) and: { LooperMidiMap.backKind(x, \toggle) == \knob }) {
                // Also one not heard yet (a boot, a binding just learned):
                // its first message, near the place, mustn't switch it.
                if(byChan.isNil) { byChan = Array.newClear(16); slot[\states].put(a[0], byChan) };
                byChan.put(a[1], LooperMidiMap.sentBack(byChan[a[1]], x, \toggle, w));
            } {
                byChan !? { byChan.put(a[1], LooperMidiMap.forget(byChan[a[1]], t[\kind])) };
            };
            ~midiBackUnknown.(slot, a[0], a[1]);
        };
    };
};
// The router's state of a knob just sent `w`, its control at `v`: the place
// noted (LooperMidiMap.sentBack).
~midiBackSettle = { |slot, src, chan, b, kind, w, v|
    var byChan = slot[\states][src];
    if(byChan.isNil) { byChan = Array.newClear(16); slot[\states].put(src, byChan) };
    byChan.put(chan, LooperMidiMap.sentBack(byChan[chan], b, kind, w, v));
};

// A message the router carried to a binding, from an input sent back to:
// what its controller shows now. A knob is where its message is, and its
// control where the message put it (read back), or where it was if the
// message moved nothing (hysteresis, a pick-up not caught yet). A switch's
// light may have been lit or darkened by the controller itself: it is sent
// now, unless this is a release within ~midiBackLightEcho of a light off (that
// light's echo comes back as a release, and must not have it sent again for
// ever). The message's other bindings are told of a light sent once they too
// have acted on the message: `later` collects it for the router; with no
// `later`, they are told at once.
~midiBackHeard = { |slot, target, msg, chan, val, src, acted, later|
    var b = slot[\binding], how = LooperMidiMap.backKind(b, target[\kind]), fresh, r, now, e, key, w, a, at;
    if(how.notNil and: { chan.notNil }) {
        fresh = (slot[\states][\back] !? { |x| x[src] !? { |y| y[chan] } }).isNil;
        r = ~midiBackRecord.(slot, src, chan);
        // A place it hasn't been sent to yet: the list is made again.
        if(fresh) { ~midiBackStale = true };
        if(how == \light) {
            now = ~midiNow.();
            // A release so soon after a light off was sent may be its echo: a
            // light off shows as it should, and must not be sent for ever.
            if(((r[\wire] == 0) and: { ((r[\at] ? -1e9) + ~midiBackLightEcho) >= now }
                and: { (msg == \noteOff) or: { (msg == \cc) and: { val < 64 } } }).not) {
                r[\wire] = nil;
                key = ~midiBackKey.(src, chan, b);
                e = ~midiBackList.() !? { ~midiBackBySlot[slot] };
                a = e !? { e[\addrs].detect { |x| x[3] == key } };
                if(a.notNil and: { ~midiLearning.isNil } and: { ~midiBackOuts[a[2]] != \dead } and: { ~midiBackOwns.(e, a[4]) }) {
                    w = LooperMidiMap.backValue(b, target[\kind], try { target[\get].value } { nil }, target[\toPos]);
                    at = w !? { ~midiBackSend.(a[2], b, chan, w, src, \light, now) };
                    at !? {
                        r[\wire] = w; r[\at] = at;
                        if(later.notNil) { later.add([e, a, w]) } { ~midiBackOthers.(e, a, w) };
                    };
                };
            };
        } {
            r[\wire] = val;
            if(acted) { r[\value] = try { target[\get].value } { nil } };
        };
    };
};

// The bindings sent back to, and where: made again when the map, the
// controls, the inputs sent back to or the places heard from change. Each is
// (slot:, target:, how:, addrs: [[input, channel, output, place, owners],
// ...]). A place two bindings share (layered) is the first's in the map's
// order whose control is there now (~midiBackOwns, of the place's bindings
// in that order): an encoder can't show two values.
~midiBackList = {
    var f = ~midiBackFor;
    if((~midiBackStale != false) or: { f.isNil } or: { f[0] !== ~midiMap } or: { f[1] !== ~midiTargets }) {
        ~midiBackStale = false;
        f = [~midiMap, ~midiTargets, ~midiBackBuild.()];
        ~midiBackFor = f;
    };
    f[2]
};
~midiBackKey = { |src, chan, b| src.asString ++ "/" ++ chan ++ "/" ++ b[\msg] ++ "/" ++ b[\num] };
~midiBackBuild = {
    var list = List.new, owners = Dictionary.new, bySlot = IdentityDictionary.new;
    var srcs = ~midiBackSrcs.asArray.sort, names = ~midiSources ? ();
    (~midiMap !? { |m| m.slots } ? []).do { |slot|
        var b = slot[\binding], t = (~midiTargets ? ())[b[\target]], how, addrs = List.new, kept = List.new;
        var seen = Set.new, heard, e, ins;
        how = t !? { |x| LooperMidiMap.backKind(b, x[\kind]) };
        if(how.notNil) {
            // Its own input and channel, if it names both; one that names a
            // device of several inputs but no port, only where its message
            // came from (the device's other ports may go to another
            // instrument).
            if(b[\device].notNil and: { b[\chan].notNil }) {
                ins = srcs.select { |src| LooperMidiMap.deviceMatches(b, names[src]) };
                if(b[\port].notNil or: { ins.size == 1 }) { ins.do { |src| addrs.add([src, b[\chan]]) } };
            };
            heard = slot[\states][\back];
            heard !? { srcs.do { |src| heard[src] !? { |byChan| byChan.do { |r, ch| if(r.notNil) { addrs.add([src, ch]) } } } } };
            addrs.do { |a|
                var k = ~midiBackKey.(a[0], a[1], b);
                if(seen.includes(k).not) { seen.add(k); kept.add([a[0], a[1], ~midiBackTo[a[0]], k, nil]) };
            };
            if(kept.notEmpty) {
                e = (slot: slot, target: t, how: how, addrs: kept.asArray);
                list.add(e);
                bySlot.put(slot, e);
                kept.do { |a| owners.put(a[3], (owners[a[3]] ? []).add(e)) };
            };
        };
    };
    // Each place with its bindings, in the map's order.
    list.do { |e| e[\addrs].do { |a| a.put(4, owners[a[3]]) } };
    ~midiBackOwners = owners;
    ~midiBackBySlot = bySlot;
    list.asArray
};
// Is this binding the one its place shows: the first of the place's bindings
// (`owners`, in the map's order) whose control is there now? One whose
// control isn't there leaves it to the next.
~midiBackOwns = { |e, owners|
    (owners ? []).detect { |x| x[\target][\available].value != false } === e
};

// One tick: what changed is sent, ~midiBackMax messages at most.
// Nothing while a control is learning (an encoder that took it would be off
// from where learning counts from), nor to a binding whose input range is
// being swept (it keeps its place from a layered other), nor to an output
// that failed. A binding that throws is said once and skipped. Answers how
// many it sent.
~midiBackTick = { |now|
    var sent = 0;
    if(~midiMap.notNil and: { ~midiBackSrcs.notEmpty } and: { ~midiLearning.isNil }) {
        ~midiBackList.().do { |e|
            var t = e[\target], slot = e[\slot], b = slot[\binding], v, w, r, at, key;
            try {
                if((sent < ~midiBackMax) and: { t[\available].value != false }
                    and: { (~midiSweep !? { |sw| sw[\binding] === b }) != true }) {
                    v = try { t[\get].value } { nil };
                    v !? { e[\addrs].do { |a|
                        if((sent < ~midiBackMax) and: { ~midiBackOuts[a[2]] != \dead } and: { ~midiBackOwns.(e, a[4]) }) {
                            r = ~midiBackRecord.(slot, a[0], a[1]);
                            if(e[\how] == \light) {
                                w = LooperMidiMap.backValue(b, t[\kind], v, t[\toPos]);
                                if(w.notNil and: { r[\wire] != w }) {
                                    at = ~midiBackSend.(a[2], b, a[1], w, a[0], \light, now);
                                    at !? { r[\wire] = w; r[\at] = at; sent = sent + 1; ~midiBackOthers.(e, a, w) };
                                };
                            } {
                                if(r[\value] != v) {
                                    w = w ?? { LooperMidiMap.backValue(b, t[\kind], v, t[\toPos]) };
                                    case
                                    { w.isNil } { }
                                    { r[\wire] == w } { r[\value] = v }
                                    // Touched a moment ago, or just sent: later.
                                    { key = LooperMidiLearn.key(b[\msg], a[1], b[\num], a[0]);
                                        ((~midiLastSeen[key] !? { |x| (now - x[1]) < ~midiBackHold }) == true)
                                            or: { (~midiBackLastSent[key] !? { |x| (now - x[1]) < ~midiBackHold }) == true } } { }
                                    {
                                        at = ~midiBackSend.(a[2], b, a[1], w, a[0], \knob, now);
                                        at !? {
                                            r[\wire] = w; r[\value] = v; sent = sent + 1;
                                            ~midiBackSettle.(slot, a[0], a[1], b, t[\kind], w, v);
                                            ~midiBackOthers.(e, a, w);
                                        };
                                    };
                                };
                            };
                        };
                    } };
                };
            } { |err|
                ~midiBackSaid.(b[\target], "sending " ++ b[\target] ++ " back to " ++ LooperMidiMap.describe(b)
                    ++ " threw (" ++ err.errorString ++ "). Said once; it is tried again each time.");
            };
        };
    };
    sent
};

// One message to an output, kept for its echo, with when it leaves: after
// what went to that output before it, one after another as on a DIN wire. A
// failed send leaves that output alone until Rescan, said once. Answers when
// it left, or nil if it didn't go.
~midiBackSend = { |dest, b, chan, w, src, how, now|
    var out = ~midiBackOuts[dest], msg = b[\msg], num = b[\num], key, ok = false, at;
    if(out.isNil) {
        out = try { ~midiBackOpen.(dest) } { |err| ~midiBackFailed.(dest, err); \dead };
        ~midiBackOuts.put(dest, out);
    };
    if(out.isKindOf(Symbol).not) {
        ok = try {
            case
            { msg == \cc } { out.control(chan, num, w) }
            { msg == \bend } { out.bend(chan, w) }
            // A light off is a note off, as a release is.
            { msg == \note } { if(w > 0) { out.noteOn(chan, num, w) } { out.noteOff(chan, num, 0) } };
            true
        } { |err|
            ~midiBackOuts.put(dest, \dead);
            ~midiBackFailed.(dest, err);
            false
        };
        if(ok) {
            at = now.max(~midiBackFree[dest] ? now);
            ~midiBackFree.put(dest, at + ~midiBackGap);
            key = LooperMidiLearn.key(msg, chan, num, src);
            // How its echo would look (~midiBackIsEcho), beside those of the
            // sends before it still on their way (a light on, and the light off
            // its release sent at once).
            ~midiBackSent.put(key, (~midiBackSent[key] ? []).keep(-3) ++ [[w, at, case
                { how == \knob } { \exact }
                { (msg == \cc) and: { b[\switch] == \oneMessage } } { \any }
                { \press }]]);
            // For the hold, and for learning (~midiRoute); kept apart from
            // what the input itself sent: a pedal that didn't take it mustn't
            // be learned from its next flicker.
            ~midiBackLastSent.put(key, [w, at, how]);
        };
    };
    if(ok) { at }
};
~midiBackFailed = { |dest, err|
    var who = (~midiDestinations ? ())[dest] !? { |n| n[0] } ? dest.asString;
    ~midiBackWarn.("megalooper: MIDI: sending back to " ++ who ++ " failed (" ++ err.errorString
        ++ "); nothing more is sent to it until Rescan.");
    ~midiLearnNote = "Sending back to " ++ who ++ " failed: Rescan to try again";
    ~midiChanged.(\inputs);
};

// Is this message an echo of what was just sent back to its input? A knob's
// is the value sent (\exact), within ~midiBackKnobEcho: as it was left alone
// for ~midiBackHold before, the knob's own next message is a step off. A
// light's is a press, within ~midiBackLightEcho: on a one-message switch any
// message (\any: every one is a press, and one a thru changed would flip it),
// else a press for a light on (\press). A release is never an echo: it goes
// on to the bindings and Live, and a light off can't be undone by one. Each
// send is taken back once: by its echo, or once its time is up.
~midiBackIsEcho = { |msg, chan, num, val, src|
    var key = LooperMidiLearn.key(msg, chan, num, src), pending = ~midiBackSent[key], now, hit, left;
    if(pending.isNil) { false } {
        now = ~midiNow.();
        hit = pending.detect { |e|
            var age = now - e[1];
            case
            { e[2] == \exact } { (age <= ~midiBackKnobEcho) and: { e[0] == val } }
            { age > ~midiBackLightEcho } { false }
            { e[2] == \any } { true }
            { e[0] > 0 } { if(msg == \cc) { val >= 64 } { (msg == \noteOn) and: { val > 0 } } }
            { false }
        };
        left = pending.reject { |e| (e === hit) or: { (now - e[1]) > ~midiBackKnobEcho.max(~midiBackLightEcho) } };
        if(left.isEmpty) { ~midiBackSent.removeAt(key) } { ~midiBackSent.put(key, left) };
        hit.notNil
    }
};

// The clock, while an input is sent back to: generation-guarded, so a new one
// stops the old. Its first tick waits ~midiBackFirst, as a boot makes the
// window right after. Ticks that come late bunch up (the interpreter was
// busy): one at a time. Cleared by Cmd-period with every clock; the rebuild
// (~setupMidiBindings) starts it again.
~midiBackClockStep = { |gen|
    if(gen == ~midiBackGen) {
        if((Main.elapsedTime - (~midiBackTickAt ? -1e9)) >= (~midiBackRate * 0.5)) {
            ~midiBackTickAt = Main.elapsedTime;
            try { ~midiBackTick.(~midiNow.()) } { |err|
                ~midiBackSaid.(\sendBack, "sending back threw (" ++ err.errorString ++ "). Said once.");
            };
        };
        ~midiBackRate
    } { nil }
};
~midiBackSched = { |delay, fn| SystemClock.sched(delay, fn) };   // the tests count what is scheduled
~midiBackClock = {
    var gen = (~midiBackGen ? 0) + 1;
    ~midiBackGen = gen;
    if(~midiBackSrcs.notEmpty) { ~midiBackSched.(~midiBackFirst, { ~midiBackClockStep.(gen) }); true } { false }
};

// Rescan's part (gui-midimap.scd): the outputs listed again, each opened
// again when next sent to, and every controller sent everything, as one
// plugged in again may show anything.
~midiBackRescan = {
    ~midiBackOutputs.();
    ~midiBackOuts = IdentityDictionary.new;
    ~midiBackAgain.();
    ~midiBackFrom.(~midiSettingsNow.());
};

// ---- The proxy to Live -----------------------------------------------------------
// Every incoming message goes out again on ~midiOut (the IAC bus Live listens
// on), so the one controller drives both megalooper and Live; ~midiOut already
// carries SC's MIDI clock and transport, so Live gets clock and control on one
// port. Never what came from an IAC bus: that is our own output coming back,
// and forwarding it would loop forever. ~midiProxy = false in the IDE turns it
// off.
~midiProxyOk = { |src| ~midiProxy and: { ~midiOut.notNil } and: { ~iacSources.includes(src).not } };
~midiProxyNoteOn = { |vel, num, chan, src| if(~midiProxyOk.(src)) { ~midiOut.noteOn(chan, num, vel) } };
~midiProxyNoteOff = { |vel, num, chan, src| if(~midiProxyOk.(src)) { ~midiOut.noteOff(chan, num, vel) } };
~midiProxyCc = { |val, num, chan, src| if(~midiProxyOk.(src)) { ~midiOut.control(chan, num, val) } };
// Live's MIDI map can't learn a program change, so each one also goes out as a
// CC Live can map: number = the program's, on ~pcCcChannel. A "Device On" in
// Live is a toggle, so the value alternates per program (127, 0, 127...), and
// if Live drifts (switched by hand), two presses put it right. Never the
// break macro's own CC (~breakMacroCc): a program change of that number from
// any controller would flip the macro (docs/dev/midi-map.md, 5.6). The program
// change itself still goes.
~midiProxyProgram = { |num, chan, src|
    var on;
    if(~midiProxyOk.(src)) {
        ~midiOut.program(chan, num);   // raw PC too (Live ignores it; looper uses it)
        if(num != ~breakMacroCc) {
            on = (~pcCcState[num] ? false).not;
            ~pcCcState[num] = on;
            ~midiOut.control(~pcCcChannel, num, if(on) { 127 } { 0 });
        };
    };
};
~midiProxyBend = { |val, chan, src| if(~midiProxyOk.(src)) { ~midiOut.bend(chan, val) } };
~midiProxyTouch = { |val, chan, src| if(~midiProxyOk.(src)) { ~midiOut.touch(chan, val) } };
~midiProxyPolytouch = { |val, num, chan, src| if(~midiProxyOk.(src)) { ~midiOut.polyTouch(chan, num, val) } };

// ---- The responders ----------------------------------------------------------------
// One part of a responder, protected: a throw in the router, the proxy or the
// log can't skip the others, and each part says so once.
~midiPart = { |part, fn|
    try { fn.value } { |err|
        if(~midiWarned.isNil or: { ~midiWarned.includes(part).not }) {
            ~midiWarned !? { |w| w.add(part) };
            ("megalooper: MIDI " ++ part ++ " threw (" ++ err.errorString ++ "). Said once.").warn;
        };
        nil
    };
};

// The responders megalooper made before the router, by name. Re-running this
// file in an interpreter that ran the old one would leave them answering
// beside the new ones, so ~setupMidiBindings frees them.
~midiOldResponders = [
    \midiLogNoteOn, \midiLogNoteOff, \midiLogCc, \midiLogProgram,
    \proxyNoteOn, \proxyNoteOff, \proxyCc, \proxyProgram, \proxyBend, \proxyTouch, \proxyPolytouch,
    \looperGranularMorph, \looperGranularAmp, \looperFeedback, \looperOnsetThreshold,
    \looperIntensity, \looperBindings, \looperProgramBindings, \saFxBindings
];
~midiFreeOldResponders = {
    (~midiOldResponders ++ MIDIdef.all.keys.asArray.select { |k| k.asString.beginsWith("looperCc_") })
        .do { |k| MIDIdef.all[k] !? { |d| d.free } };
};

// What the map holds, in one line, and what is wrong with it, if anything.
~midiMapReport = { |map, targets, from|
    var unknown = map.bindings.reject { |b| targets.includesKey(b[\target]) };
    var devices = map.bindings.collect { |b| b[\device] }.reject(_.isNil).asSet.asArray.sort;
    var here = (~midiSources ? ()).values.collect { |n| n[0] };
    var missing = devices.reject { |d| here.includesEqual(d) };
    ("megalooper: MIDI map " ++ (map.name ?? { "(none)" })
        ++ (from !? { |f| " (" ++ (yours: "yours", backup: "your backup", shipped: "as shipped")[f] ++ ")" } ? "")
        ++ ": " ++ map.bindings.size ++ " bindings"
        ++ (if(devices.notEmpty) { ", for " ++ devices.join(", ") } { "" })
        ++ (if(missing.notEmpty and: { ~midiSources.notEmpty }) { "; not connected: " ++ missing.join(", ") } { "" })
        ++ ".").postln;
    map.problems.do { |p| ("megalooper: MIDI map: " ++ p).warn };
    unknown.do { |b|
        ("megalooper: MIDI map: " ++ LooperMidiMap.describe(b) ++ " names " ++ b[\target]
            ++ if(b[\target].asString.beginsWith("sa.fx")) { ", an effect the chains do not hold now; it does nothing until they do." } {
                ", which this megalooper does not have; it does nothing." }).warn;
    };
    if(~midiOut.notNil) {
        LooperMidiMap.proxyProblems(map.bindings, ~breakMacroCc).do { |p| ("megalooper: MIDI map: " ++ p).warn };
    };
    map
};

// Builds the controls, takes the rig's map and makes the responders. `given`,
// a LooperMidiMap, is used instead of the rig's (the tests give one). A
// rebuild mid-set keeps the map's changes not kept yet.
~setupMidiBindings = { |given|
    var targets, map, settings, loaded, rigName = ~routingProfile;
    // Did the router run until now? Not after a Cmd-period, nor in a boot,
    // whose ~setupMidiIO frees every responder first.
    var alive = MIDIdef.all[\midiInCc].notNil;
    ~midiFreeOldResponders.();
    // No sources before MIDIClient.init, as in the headless tests.
    ~iacSources = ~midiClientSources.().select { |s| s.device.contains("IAC") }.collect { |s| s.uid };
    ~midiSources = IdentityDictionary.new;
    ~midiClientSources.().do { |s| ~midiSources.put(s.uid, [s.device, s.name]) };
    ~midiProxy = ~midiProxy ? true;  // set false in the IDE to disable proxying
    ~pcCcState = IdentityDictionary.new;
    ~midiWarned = IdentitySet.new;
    ~midiLearning = nil;
    ~midiLastSeen = Dictionary.new;
    // Cmd-period ends a learning (6.5); it frees these responders too, as it
    // frees every one, and MIDI is then dead until the next boot, as before.
    // A repaint queued when Cmd-period cleared AppClock would otherwise leave
    // every later one waiting for it. What the router kept of each knob goes
    // (it sees nothing more), and a sweep ends: its poll was on AppClock.
    ~midiGuiPending = false;
    ~midiCmdPeriodHook !? { |f| CmdPeriod.remove(f) };
    ~midiCmdPeriodHook = {
        ~midiLearning = nil;
        ~midiGuiPending = false;
        ~midiMap !? { |m| m.forgetStates };
        ~midiSweep !? { ~midiSweepEnd.(false, "Range not changed: Cmd-period ended the sweep") };
        // Sending back's clock went with every clock; what was sent goes with
        // the states, and so do the places a binding's message came from: the
        // rebuild sends everything to where the bindings say.
        ~midiBackGen = (~midiBackGen ? 0) + 1;
        ~midiBackSent = Dictionary.new;
        ~midiBackStale = true;
    };
    CmdPeriod.add(~midiCmdPeriodHook);
    // The controls and the map are made before either is swapped in. If making
    // them throws, the footswitches keep the map they had (at boot: none), the
    // proxy and the log still run, the boot goes on, and the post window says
    // why.
    try {
        settings = ~midiSettingsNow.();
        ~midiListenFrom.(settings);
        ~midiDefaultsFrom.(settings);
        targets = ~midiTargetsBuild.();
        case
        { given.notNil } {
            map = given;
            ~midiKept = given;
            ~midiMapFrom = nil;
            ~midiMapWarning = nil;
            ~midiUndo = List.new;
        }
        { ~midiMap.notNil and: { ~midiMapRig == rigName } and: { ~midiMapDirty.() } } {
            map = ~midiMap;
            "megalooper: MIDI: the map's changes, not kept yet, stay.".postln;
        }
        {
            loaded = ~midiMapLoad.(~midiMapNameFor.(rigName, settings));
            // A map that could not be read keeps its name, so the Rig tab can
            // put the shipped one back (Reset) or Keep a new one under it.
            map = loaded[\map] ?? { LooperMidiMap([], loaded[\name]) };
            ~midiKept = map;
            ~midiMapFrom = loaded[\from];
            ~midiMapWarning = loaded[\warning];
            ~midiMapWarningLevel = loaded[\level] ? \error;
            ~midiUndo = List.new;
            (loaded[\problems] ? []).do { |p| ("megalooper: MIDI map: " ++ p).warn };
        };
        ~midiMapReport.(map, targets, ~midiMapFrom);
    } { |err|
        ("megalooper: the MIDI map could not be made (" ++ err.errorString ++ "). "
            ++ if(~midiMap.notNil) { "The footswitches keep the one they had." }
                { "The footswitches do nothing; Live still gets every message." }).warn;
        targets = ~midiTargets ? IdentityDictionary.new;
        map = ~midiMap ?? { LooperMidiMap([], nil) };
        ~midiKept = ~midiKept ? map;
    };
    ~midiTargets = targets;
    // What the router kept of each knob goes on in the new map if MIDI ran
    // until now. Else it saw nothing meanwhile, and every knob starts afresh.
    ~midiMap = if(alive) { map.adopt(~midiMap) } { map.forgetStates };
    ~midiMapRig = rigName;
    // Sending back (5.7): the outputs as MIDIClient lists them now, each
    // opened again when first sent to. After a boot or a Cmd-period the
    // states are new, so every controller sent back to is sent everything.
    try {
        ~midiBackOutputs.();
        ~midiBackOuts = IdentityDictionary.new;
        ~midiBackSent = Dictionary.new;
        ~midiBackLastSent = Dictionary.new;
        ~midiBackFree = IdentityDictionary.new;
        ~midiBackFrom.(settings ?? { ~midiSettingsNow.() });
    } { |err| ("megalooper: MIDI: sending back is off (" ++ err.errorString ++ ").").warn };
    // An input the map is for, switched off, is said at boot too.
    (~midiAttention.() !? { |a| if(~midiMapWarning.isNil) { a } }) !? { |a| ("megalooper: MIDI: " ++ a[0]).warn };

    // One responder per message type, on every number, channel and input:
    // the router, then the proxy, then the log, so printing never holds up an
    // action. A message is logged mapped or not; one the router held back
    // (learning, an input not listened to, an echo of what was sent back)
    // goes nowhere near Live.
    MIDIdef.noteOn(\midiInNoteOn, { |vel, num, chan, src|
        var how = ~midiPart.(\router, { ~midiRoute.(\noteOn, chan, num, vel, src) });
        if(how.isKindOf(Symbol).not) { ~midiPart.(\proxy, { ~midiProxyNoteOn.(vel, num, chan, src) }) };
        ~midiPart.(\log, { ~midiLogLine.("noteOn   num=" ++ num ++ " vel=" ++ vel ++ " chan=" ++ chan ++ ~midiLogMark.(how)) });
    });
    MIDIdef.noteOff(\midiInNoteOff, { |vel, num, chan, src|
        var how = ~midiPart.(\router, { ~midiRoute.(\noteOff, chan, num, vel, src) });
        if(how.isKindOf(Symbol).not) { ~midiPart.(\proxy, { ~midiProxyNoteOff.(vel, num, chan, src) }) };
        ~midiPart.(\log, { ~midiLogLine.("noteOff  num=" ++ num ++ " vel=" ++ vel ++ " chan=" ++ chan ++ ~midiLogMark.(how)) });
    });
    MIDIdef.cc(\midiInCc, { |val, num, chan, src|
        var how = ~midiPart.(\router, { ~midiRoute.(\cc, chan, num, val, src) });
        if(how.isKindOf(Symbol).not) { ~midiPart.(\proxy, { ~midiProxyCc.(val, num, chan, src) }) };
        ~midiPart.(\log, { ~midiLogLine.("cc       num=" ++ num ++ " val=" ++ val ++ " chan=" ++ chan ++ ~midiLogMark.(how)) });
    });
    MIDIdef.program(\midiInProgram, { |num, chan, src|
        var how = ~midiPart.(\router, { ~midiRoute.(\program, chan, num, nil, src) });
        if(how.isKindOf(Symbol).not) { ~midiPart.(\proxy, { ~midiProxyProgram.(num, chan, src) }) };
        ~midiPart.(\log, { ~midiLogLine.("program  prog=" ++ num ++ " chan=" ++ chan ++ ~midiLogMark.(how)) });
    });
    MIDIdef.bend(\midiInBend, { |val, chan, src|
        var how = ~midiPart.(\router, { ~midiRoute.(\bend, chan, nil, val, src) });
        if(how.isKindOf(Symbol).not) { ~midiPart.(\proxy, { ~midiProxyBend.(val, chan, src) }) };
    });
    MIDIdef.touch(\midiInTouch, { |val, chan, src|
        if((~midiPart.(\router, { ~midiHeld.(src) }) == true).not) {
            ~midiPart.(\proxy, { ~midiProxyTouch.(val, chan, src) });
        };
    });
    MIDIdef.polytouch(\midiInPolytouch, { |val, num, chan, src|
        if((~midiPart.(\router, { ~midiHeld.(src) }) == true).not) {
            ~midiPart.(\proxy, { ~midiProxyPolytouch.(val, num, chan, src) });
        };
    });
    ~midiChanged.(\map);
    ~midiMap
};
)
