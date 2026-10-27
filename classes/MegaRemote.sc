// megalooper as a tool for an AI app (docs/dev/ai-tool.md): a request names
// an id, its body is a JSON file in <userRoot>/remote/, and the answer is
// another one there, written whole. tools/megalooper-mcp.py asks; it is the
// bridge between an AI app speaking MCP and this.
//
// Who may ask: a message from 127.0.0.1 carrying the token of this boot, as
// the handshake file (<userRoot>/remote.json, mode 600) holds it beside the
// port sclang got. sclang's port listens on every interface, so a message
// from anywhere else is dropped unanswered, as is one with a wrong token.
//
// Reading: \ping, \context (what is playing and how it is set, where the
// playhead is, and the AI's own changes), \describe (what every setting
// means), \list_sets and \get_set (the sets recorded before: what was
// played, what the analyser heard and what the players changed;
// docs/dev/roadmap.md item 20, "the AI as the experimenter"). Writing: \set_drum_pattern (a
// pattern, the steps' kit), \set_synth (the note sequencer's pattern, the
// Wave synth's settings, the sequencer's switch), \set_chain (built-in
// effects in, out and moved, settings, switches), \set_grains (the granular
// layer's settings, its window, its switch), \set_cutter (the cutter's
// voices, its mode, its switch), \revert (the AI's own changes, newest
// first), \save_drum_preset, \save_synth_preset, \save_sound,
// \save_grains_preset and \save_cutter_preset. Every change is snapshotted
// before it lands, so it can be taken back. A plugin is never put in or
// taken out by the AI.
//
// Everything a request reads or changes comes from `source`, a function
// answering an Event (looper:, sa:, profile:, drumsPresetDir:,
// synthPresetDir:, soundDir:, grainsPresetDir:, cutterPresetDir:,
// grainParams:, say:, sessionDir:, playhead:), so a test hands it stubs; setup-remote.scd hands it
// the running ~looper and ~megaSA, the presets' folders, the Grains view's
// rows (grainParams: their labels, window ranges and tips) and the window's
// status line (say: a function of a String).
MegaRemote {
    var <source, <token, <port, responder, onShutDown, <started = false;
    // The AI's changes, oldest first: (part:, label:, data:), data the part as
    // it was just before the change: the drums' presetData, the synth's
    // (notes:, wave:, on:), the chains' (sound:, on: [[id, flag] ...]), the
    // grains' (preset:, on:) or the cutter's (preset:, on:), preset the
    // Looper's own preset data for them.
    var changes;

    *new { |source| ^super.newCopyArgs(source) }

    *formatName { ^"megalooper remote" }
    *version { ^1 }
    *oscPath { ^'/megalooper/remote' }
    *dir { ^MegaFiles.userRoot +/+ "remote" }
    *handshakePath { ^MegaFiles.userRoot +/+ "remote.json" }
    *requestPath { |id| ^this.dir +/+ id ++ ".request.json" }
    *replyPath { |id| ^this.dir +/+ id ++ ".reply.json" }

    // ---- starting and stopping ---------------------------------------------

    // Listens on `langPort` (sclang's own unless a test names another), with a
    // new token, and says so in the handshake file. Requests and replies left
    // from an earlier run are cleared: nobody waits for them any more.
    start { |langPort|
        var why;
        this.stop;
        port = langPort ? NetAddr.langPort;
        token = this.class.newToken;
        File.mkdir(this.class.dir);
        (this.class.dir +/+ "*.json").pathMatch.do { |p| File.delete(p) };
        responder = OSCdef(\megalooperRemote, { |msg, time, addr| this.receive(msg, addr) },
            this.class.oscPath).permanent_(true);
        why = MegaFiles.writeNow(this.class.handshakePath, this.handshakeText);
        if(why.notNil) {
            ("MegaRemote: the handshake was not written to " ++ this.class.handshakePath
                ++ " (" ++ why ++ "); no AI app can reach megalooper.").warn;
        } {
            ("chmod 600 " ++ this.class.handshakePath.shellQuote).systemCmd;
        };
        onShutDown = { this.stop };
        ShutDown.add(onShutDown);
        started = true;
    }

    // Stops listening and removes the handshake, if it is still this run's.
    stop {
        var text;
        responder !? { |r| r.free };
        responder = nil;
        onShutDown !? { |f| ShutDown.remove(f) };
        onShutDown = nil;
        if(started) {
            text = MegaFiles.readText(this.class.handshakePath);
            if(text.notNil and: { token.notNil } and: { text.contains(token) }) {
                File.delete(this.class.handshakePath)
            };
        };
        started = false;
    }

    free { this.stop }

    handshakeText {
        ^MegaFiles.json(this.class.obj([\format, this.class.formatName, \version, this.class.version,
            \port, port, \token, token, \pid, thisProcess.pid, \oscPath, this.class.oscPath.asString,
            \dir, this.class.dir])) ++ "\n"
    }

    // 32 hex digits from the system's random source, or from sclang's
    // generator where there is none.
    *newToken {
        var bytes = try {
            File.use("/dev/urandom", "rb", { |f| var a = Int8Array.newClear(16); f.read(a); a.asArray })
        };
        ^if(bytes.isKindOf(Array) and: { bytes.size == 16 }) {
            bytes.collect { |b| b.bitAnd(255).asHexString(2) }.join.toLower
        } { Array.fill(32, { 16.rand.asHexString(1) }).join.toLower }
    }

    // ---- receiving -----------------------------------------------------------

    *isLocal { |addr| ^addr.notNil and: { addr.ip == "127.0.0.1" } }

    // An id names two files, so it may hold nothing a path could misread.
    *idOk { |id|
        id = id.asString;
        ^(id.size >= 1) and: { id.size <= 64 } and: { id.every { |c| c.isAlphaNum or: { c == $- } } }
    }

    // [path, token, id] from `addr`: answered, or dropped without a word.
    receive { |msg, addr|
        var id = msg[2];
        if(this.class.isLocal(addr).not) { ^this };
        if(token.isNil or: { msg[1].asString != token }) { ^this };
        if(this.class.idOk(id).not) { ^this };
        this.answer(id.asString);
    }

    // The request file's answer, in the reply file (asynchronously: the move
    // into place is a shell's, so the clocks keep time). The request goes.
    answer { |id|
        var reqPath = this.class.requestPath(id);
        var text = MegaFiles.readText(reqPath);
        var reply;
        if(File.exists(reqPath)) { File.delete(reqPath) };
        reply = this.handle(text);
        MegaFiles.write(this.class.replyPath(id), MegaFiles.json(reply), nil, nil, { |ok, why|
            if(ok.not) { ("MegaRemote: a reply was not written (" ++ why ++ ").").warn } });
    }

    // A request's text answered: (ok: true, result:) or (ok: false, error:).
    handle { |text|
        var request = MegaFiles.parseObject(text), command, args;
        if(request.isString) { ^this.class.failure("the request " ++ request) };
        command = request.at("command");
        args = request.at("args");
        if(args.notNil and: { args.isKindOf(MegaJsonObject).not }) {
            ^this.class.failure("args must be an object")
        };
        ^try {
            case
            { command == "ping" } {
                this.class.success(this.class.obj([\format, this.class.formatName,
                    \version, this.class.version, \pid, thisProcess.pid]))
            }
            { command == "context" } {
                this.class.success(this.class.context(source.value).add("aiChanges", this.changeCount)
                    .add("aiChangeLabels", this.changeLabels))
            }
            { command == "list_sets" } { this.class.listSets(source.value, args) }
            { command == "get_set" } { this.class.getSet(source.value, args) }
            { command == "describe" } {
                this.class.describe(args !? { |a| a.at("topic") }, source.value) !? { |d| this.class.success(d) }
                    ?? { this.class.failure("no such topic; there are " ++ this.class.topics.join(", ")) }
            }
            { command == "set_drum_pattern" } { this.setDrumPattern(args) }
            { command == "revert" } { this.revert(args) }
            { command == "save_drum_preset" } { this.saveDrumPreset(args) }
            { command == "set_synth" } { this.setSynth(args) }
            { command == "save_synth_preset" } { this.saveSynthPreset(args) }
            { command == "set_chain" } { this.setChain(args) }
            { command == "save_sound" } { this.saveSound(args) }
            { command == "set_grains" } { this.setGrains(args) }
            { command == "set_cutter" } { this.setCutter(args) }
            { command == "save_grains_preset" } { this.saveGrainsPreset(args) }
            { command == "save_cutter_preset" } { this.saveCutterPreset(args) }
            { this.class.failure("no command " ++ command.asString.quote ++ "; there are "
                ++ this.class.commands.join(", ")) }
        } { |err| this.class.failure("megalooper failed to answer: " ++ err.errorString) }
    }

    *commands { ^#["ping", "context", "describe", "set_drum_pattern", "set_synth", "set_chain", "set_grains",
        "set_cutter", "revert", "save_drum_preset", "save_synth_preset", "save_sound", "save_grains_preset",
        "save_cutter_preset", "list_sets", "get_set"] }

    *success { |result| ^this.obj([\ok, true, \result, result]) }
    *failure { |why| ^this.obj([\ok, false, \error, why]) }

    // An object with its members in this order: [key, value, key, value ...].
    // A nil value stays, as null.
    *obj { |pairs|
        var o = MegaJsonObject.new;
        pairs.pairsDo { |k, v| o.add(k, v) };
        ^o
    }

    // ---- the AI's changes ----------------------------------------------------------

    *changesMax { ^32 }

    changeCount { ^(changes ? []).size }

    // MegaRemote says \aiChanges, count whenever the count moves: the
    // window's Revert follows it.

    // The labels of the changes revert can take back, oldest first.
    changeLabels { ^(changes ? []).collect { |c| c[\label] }.asArray }

    prDrums { |src| ^src !? { |s| s[\sa] } !? { |m| m.drums } }

    prNoDrums { ^this.class.failure("there are no drums: this megalooper runs without Megalooper SA") }

    prSnapshot { |part, label, data|
        changes = changes ?? { List.new };
        changes.add((part: part, label: label, data: data));
        while { changes.size > this.class.changesMax } { changes.removeAt(0) };
        this.changed(\aiChanges, this.changeCount);
    }

    // Said in the window's status line and the post window.
    prSay { |src, msg|
        ("MegaRemote: " ++ msg).postln;
        src !? { |s| s[\say] } !? { |f| { f.value(msg) }.defer };
    }

    // A pattern for `which` (main or break, main if not said) and/or the
    // steps' kit. The pattern is merged over the one playing (mergePattern):
    // what it leaves out, or gives as null, stays. Then it is cleaned as a
    // preset's is (MegaSASteps.cleanPattern), and every correction is said.
    setDrumPattern { |args|
        var src = source.value, drums = this.prDrums(src), which, given, kit, notes = List.new, label;
        if(drums.isNil) { ^this.prNoDrums };
        which = (args !? { |a| a.at("which") }) ? "main";
        if(#["main", "break"].includesEqual(which).not) { ^this.class.failure("which is main or break") };
        which = which.asSymbol;
        given = args !? { |a| a.at("pattern") };
        kit = args !? { |a| a.at("kit") };
        if(given.isNil and: { kit.isNil }) { ^this.class.failure("nothing to change: give a pattern, a kit, or both") };
        if(given.notNil and: { given.isKindOf(MegaJsonObject).not }) { ^this.class.failure("pattern must be an object") };
        if(kit.notNil and: { drums.kitKeys.includes(kit.asString.asSymbol).not }) {
            ^this.class.failure("there is no kit " ++ kit.asString.quote ++ "; there are "
                ++ drums.kitKeys.collect(_.asString).join(", "))
        };
        label = "drums' " ++ [given !? { which.asString ++ " pattern" }, kit !? { "kit" }].reject(_.isNil).join(" and ");
        this.prSnapshot(\drums, label, drums.presetData("before the AI's change"));
        kit !? { |k| if(k.asString.asSymbol != drums.kit(\steps)) { drums.setKit(\steps, k.asString.asSymbol) } };
        given !? { |g| drums.setPattern(which, this.class.mergePattern(drums.patterns[which], this.class.plain(g)), notes) };
        this.prSay(src, "The AI changed the " ++ label ++ " (it can revert it)");
        ^this.class.success(this.class.obj([
            \which, which, \kit, drums.kit(\steps), \corrections, notes.asArray,
            \pattern, drums.patterns[which], \aiChanges, this.changeCount
        ]))
    }

    // Everything as it was before the newest `count` changes (1 if not said;
    // all there are, if more): each part they touched as it was before the
    // earliest of them.
    revert { |args|
        var src = source.value, drums = this.prDrums(src), count, taken, parts, notes = List.new, why, undone;
        if(drums.isNil and: { this.prLooper(src).isNil }) { ^this.prNoDrums };
        count = (args !? { |a| a.at("count") }) ? 1;
        if(count.isInteger.not or: { count < 1 }) { ^this.class.failure("count is a whole number, 1 or more") };
        if(this.changeCount == 0) { ^this.class.failure("nothing to revert: the AI has changed nothing since megalooper started") };
        count = count.min(this.changeCount);
        taken = changes.asArray.drop(changes.size - count);
        parts = [\drums, \synth, \chains, \grains, \cutter].select { |part| taken.any { |c| c[\part] == part } };
        parts.do { |part|
            why = why ?? { this.prRestore(src, part, taken.detect { |c| c[\part] == part }[\data], notes) };
        };
        if(why.notNil) { ^this.class.failure(why) };
        count.do { changes.pop };
        this.changed(\aiChanges, this.changeCount);
        undone = taken.collect { |c| c[\label] }.reverse;
        this.prSay(src, "The AI reverted the " ++ undone.join(", "));
        ^this.class.success(this.class.obj([\reverted, undone, \aiChanges, this.changeCount]))
    }

    // A part put back as a snapshot holds it: nil when done, else why not.
    prRestore { |src, part, data, notes|
        var drums = this.prDrums(src), sa = src !? { |s| s[\sa] }, wave = sa !? { |m| m.wave }, looper = this.prLooper(src);
        if(part == \grains) {
            if(looper.applyGranularPreset(data[\preset]).not) { ^"the grains could not be put back" };
            if(looper.granularOn != data[\on]) { looper.toggleGranular };
            ^nil
        };
        if(part == \cutter) {
            if(looper.applyBBCutPreset(data[\preset]).not) { ^"the cutter could not be put back" };
            if(looper.bbcut != data[\on]) { looper.bbcut = data[\on] };
            ^nil
        };
        if(part == \chains) {
            // A recall (applySound) without the plugins' own sounds: the
            // structure on the cross-fade, the settings and the names. It
            // flips no switch of a device that stays, so the switches go back
            // here.
            if(sa.applySound(data[\sound], nil, false).not) { ^"the chains could not be put back: a chain is not built yet" };
            data[\on].do { |pair| sa.device(pair[0]) !? { |d| if(d.on != pair[1]) { sa.setFx(pair[0], pair[1]) } } };
            ^nil
        };
        if(part == \drums) {
            ^if(drums.applyPresetData(data, notes)) { nil } { "the drums could not be put back: " ++ notes.join("; ") }
        };
        if(wave.isNil) { ^"there is no synth to put back" };
        drums.setNotes(data[\notes]);
        wave.setAll(data[\wave]);
        if(drums.notesOn != data[\on]) { drums.setNotesOn(data[\on]) };
        ^nil
    }

    // ---- the synth ---------------------------------------------------------------------

    prNoSynth { ^this.class.failure("there is no synth: this megalooper runs without Megalooper SA") }

    // The note sequencer's pattern (notes) and/or the Wave synth's settings
    // (wave), merged over what plays as the drums' are, then checked as a
    // synth preset file is (MegaSASynthFile.fromObject); and/or the
    // sequencer on or off (on). What was held to a range, or is no setting,
    // is said in the answer's corrections. An instrument plugin's own sound
    // is not touched: the AI cannot see it.
    setSynth { |args|
        var src = source.value, drums = this.prDrums(src), wave = src !? { |s| s[\sa] } !? { |m| m.wave };
        var given, waveGiven, on, label, obj, data, notes = List.new;
        if(drums.isNil or: { wave.isNil }) { ^this.prNoSynth };
        given = args !? { |a| a.at("notes") };
        waveGiven = args !? { |a| a.at("wave") };
        on = args !? { |a| a.at("on") };
        if(given.isNil and: { waveGiven.isNil } and: { on.isNil }) {
            ^this.class.failure("nothing to change: give notes, wave, on, or several")
        };
        if(given.notNil and: { given.isKindOf(MegaJsonObject).not }) { ^this.class.failure("notes must be an object") };
        if(waveGiven.notNil and: { waveGiven.isKindOf(MegaJsonObject).not }) { ^this.class.failure("wave must be an object") };
        if(on.notNil and: { on.isKindOf(Boolean).not }) { ^this.class.failure("on is true or false") };
        given = this.class.plain(given);
        waveGiven = this.class.plain(waveGiven);
        if(given.notNil or: { waveGiven.notNil }) {
            obj = MegaFiles.parseObject(MegaSASynthFile.text("ai",
                this.class.mergePattern(drums.notes, given), this.class.mergePattern(wave.settings, waveGiven)));
            if(obj.isString) { ^this.class.failure("the synth did not read back: " ++ obj) };
            data = MegaSASynthFile.fromObject(obj, notes);
            this.class.corrections(given, data[\notes], "notes", notes);
            this.class.corrections(waveGiven, data[\wave], "wave", notes);
        };
        label = "synth's " ++ [given !? { "note pattern" }, waveGiven !? { "Wave settings" },
            on !? { "sequencer switch" }].reject(_.isNil).join(" and ");
        this.prSnapshot(\synth, label, (notes: MegaSANoteSeq.copyPattern(drums.notes), wave: wave.settings.copy,
            on: drums.notesOn));
        given !? { drums.setNotes(data[\notes]) };
        waveGiven !? { wave.setAll(data[\wave]) };
        on !? { |flag| if(flag != drums.notesOn) { drums.setNotesOn(flag) } };
        this.prSay(src, "The AI changed the " ++ label ++ " (it can revert it)");
        ^this.class.success(this.class.obj([
            \on, drums.notesOn, \corrections, notes.asArray, \notes, drums.notes, \wave, wave.settings,
            \aiChanges, this.changeCount
        ]))
    }

    // The synth as it stands (the note pattern, the Wave synth, the
    // instrument), as a preset in the Synth view's menu. A name taken is
    // refused unless `overwrite` is true.
    saveSynthPreset { |args|
        var src = source.value, sa = src !? { |s| s[\sa] }, dir = src !? { |s| s[\synthPresetDir] }, name, slug, path;
        if(sa.isNil or: { sa.drums.isNil }) { ^this.prNoSynth };
        name = args !? { |a| a.at("name") };
        if(name.isKindOf(String).not or: { name.stripWhiteSpace.isEmpty }) { ^this.class.failure("name the preset") };
        if(dir.isNil) { ^this.class.failure("there is no folder for synth presets") };
        path = dir +/+ sa.synthPresetSlug(name) ++ ".json";
        if(File.exists(path) and: { (args.at("overwrite") == true).not }) {
            ^this.class.failure("there is a synth preset " ++ sa.synthPresetSlug(name).quote
                ++ " already; overwrite: true replaces it")
        };
        slug = sa.saveSynthPreset(dir, name);
        if(slug.isNil) { ^this.class.failure("the preset was not written (the post window says why)") };
        this.prSay(src, "The AI saved the synth as " ++ slug.quote);
        ^this.class.success(this.class.obj([\saved, slug, \path, path]))
    }

    // ---- the chains --------------------------------------------------------------------

    prNoChains { ^this.class.failure("there are no chains: this megalooper runs without Megalooper SA") }

    // Built-in effects taken out (remove: [id ...]), put in (insert: [(track:,
    // type:, index:, on:, settings:) ...]), moved (move: [(id:, track:,
    // index:) ...]), set (settings: (id: (name: value))) and switched (on:
    // (id: flag)), in that order, as the Effects view's own edits are: on
    // the cross-fade, while a loop plays. Everything is checked first; one
    // thing wrong refuses it all, changing nothing. An edit MegaSA refuses
    // then (no room, the CPU busy, a chain not built yet) is said in the
    // answer, as is a value held to its range. A plugin may be moved and
    // switched, never put in or taken out, and its own settings are its own.
    setChain { |args|
        var src = source.value, sa = src !? { |s| s[\sa] }, why, label, notes = List.new, inserted = List.new;
        var removes, inserts, moves, settings, switches, heard, listener;
        if(sa.isNil) { ^this.prNoChains };
        removes = args !? { |a| a.at("remove") };
        inserts = args !? { |a| a.at("insert") };
        moves = args !? { |a| a.at("move") };
        settings = args !? { |a| a.at("settings") };
        switches = args !? { |a| a.at("on") };
        if([removes, inserts, moves, settings, switches].every(_.isNil)) {
            ^this.class.failure("nothing to change: give remove, insert, move, settings, on, or several")
        };
        why = this.class.chainWhy(sa, removes, inserts, moves, settings, switches);
        if(why.notNil) { ^this.class.failure(why) };
        label = "chains (" ++ [removes !? { "removed" }, inserts !? { "inserted" }, moves !? { "moved" },
            settings !? { "settings" }, switches !? { "switches" }].reject(_.isNil).join(", ") ++ ")";
        this.prSnapshot(\chains, label, (sound: sa.sound("before the AI's change"),
            on: sa.devices.collect { |d| [d.id, d.on] }));
        heard = List.new;
        listener = { |obj, what, op, reason| if(what == \refused) { heard.add(op.asString ++ " refused: " ++ reason) } };
        sa.addDependant(listener);
        protect {
            (removes ? []).do { |id| sa.removeDevice(id.asSymbol) };
            (inserts ? []).do { |x| this.prInsert(sa, x, inserted, notes) };
            (moves ? []).do { |x| sa.moveDevice(x.at("id").asSymbol, x.at("track") !? { |t| t.asSymbol }, x.at("index")) };
            settings !? { |set| set.keysValuesDo { |id, values|
                values.keysValuesDo { |k, v|
                    sa.setParam(id.asSymbol, k.asSymbol, v);
                    this.class.corrections(v, sa.param(id.asSymbol, k.asSymbol), id ++ "." ++ k, notes);
                };
            } };
            switches !? { |set| set.keysValuesDo { |id, flag| sa.setFx(id.asSymbol, flag) } };
        } { sa.removeDependant(listener) };
        notes = heard ++ notes;
        this.prSay(src, "The AI changed the " ++ label ++ " (it can revert it)");
        ^this.class.success(this.class.obj([
            \inserted, inserted.asArray, \corrections, notes.asArray, \chains, sa.sessionInfo[\chains],
            \aiChanges, this.changeCount
        ]))
    }

    // One insert of set_chain's: the new device's id and place to `inserted`,
    // its settings held to their ranges to `notes`.
    prInsert { |sa, x, inserted, notes|
        var given = x.at("settings") !? { |set| this.class.settingsOf(set) };
        var d = sa.insertDevice(x.at("track").asSymbol, x.at("index"), x.at("type").asSymbol, given, x.at("on") != false);
        if(d.isNil) { ^this };
        inserted.add(this.class.obj([\id, d.id, \track, x.at("track"), \index, sa.chainOf(d).indexOf(d)]));
        given !? { |g| g.keysValuesDo { |k, v| this.class.corrections(v, d.param(k), d.id ++ "." ++ k, notes) } };
    }

    // A JSON object of settings as a device takes them: name -> number.
    *settingsOf { |set|
        var out = IdentityDictionary.new;
        set.keysValuesDo { |k, v| out.put(k.asSymbol, v) };
        ^out
    }

    // Why the settings `set` (a JSON object) can't go on a device of `type`
    // (`who` in the words), or nil.
    *settingsWhy { |type, set, who|
        var names = MegaSAFx.paramsOf(type).collect { |p| p[\name].asString }, found;
        if(set.isKindOf(MegaJsonObject).not) { ^who ++ ": settings must be an object" };
        set.keysValuesDo { |k, v|
            if(found.isNil) {
                if(names.includesEqual(k).not) {
                    found = who ++ " (" ++ type ++ ") has no setting " ++ k ++ "; it has " ++ names.join(", ")
                } {
                    if(v.isNumber.not) { found = who ++ "." ++ k ++ " must be a number" };
                };
            };
        };
        ^found
    }

    // Why the device named `id` can't be edited, or nil: `removed` are those
    // this same request takes out.
    *deviceWhy { |sa, id, removed|
        var ids = sa.devices.collect { |d| d.id.asString };
        if(id.isString.not) { ^"a device is named by its id, a string" };
        if(ids.includesEqual(id).not) { ^"there is no device " ++ id ++ "; there are " ++ ids.join(", ") };
        if(removed.includesEqual(id)) { ^id ++ " is removed in this same change" };
        ^nil
    }

    // Why a set_chain request can't be done as it stands, or nil.
    *chainWhy { |sa, removes, inserts, moves, settings, switches|
        var removed = List.new, tracks = sa.chains.collect { |c| c.track.asString };
        var types = MegaSAFx.types.collect { |t| t[\key].asString };
        var index = { |x| x.isNil or: { x.isInteger and: { x >= 0 } } };
        var w;
        if(removes.notNil) {
            if(removes.isKindOf(Array).not) { ^"remove must be a list of device ids" };
            removes.do { |id|
                w = this.deviceWhy(sa, id, removed);
                if(w.notNil) { ^"remove: " ++ w };
                if(sa.device(id.asSymbol).isPlugin) { ^id ++ " is a plugin: the player takes plugins out, not the AI" };
                removed.add(id);
            };
        };
        if(inserts.notNil) {
            if(inserts.isKindOf(Array).not) { ^"insert must be a list of objects" };
            inserts.do { |x|
                if(x.isKindOf(MegaJsonObject).not) { ^"each insert is an object (track, type, index, on, settings)" };
                if(tracks.includesEqual(x.at("track")).not) {
                    ^"insert: there is no track " ++ x.at("track").asString ++ "; there are " ++ tracks.join(", ") };
                if(types.includesEqual(x.at("type")).not) {
                    ^"insert: there is no effect type " ++ x.at("type").asString ++ "; there are " ++ types.join(", ") };
                if(index.(x.at("index")).not) { ^"insert: index is a whole number from 0" };
                if(x.at("on").notNil and: { x.at("on").isKindOf(Boolean).not }) { ^"insert: on is true or false" };
                x.at("settings") !? { |set|
                    w = this.settingsWhy(x.at("type").asSymbol, set, "insert " ++ x.at("type"));
                    if(w.notNil) { ^w };
                };
            };
        };
        if(moves.notNil) {
            if(moves.isKindOf(Array).not) { ^"move must be a list of objects" };
            moves.do { |x|
                if(x.isKindOf(MegaJsonObject).not) { ^"each move is an object (id, track, index)" };
                w = this.deviceWhy(sa, x.at("id"), removed);
                if(w.notNil) { ^"move: " ++ w };
                if(x.at("track").notNil and: { tracks.includesEqual(x.at("track")).not }) {
                    ^"move: there is no track " ++ x.at("track").asString };
                if(index.(x.at("index")).not) { ^"move: index is a whole number from 0" };
            };
        };
        if(settings.notNil) {
            if(settings.isKindOf(MegaJsonObject).not) { ^"settings must be an object: device id -> (setting -> value)" };
            settings.keysValuesDo { |id, set|
                if(w.isNil) {
                    w = this.deviceWhy(sa, id, removed) !? { |x| "settings: " ++ x };
                    if(w.isNil and: { sa.device(id.asSymbol).isPlugin }) {
                        w = id ++ " is a plugin: its own settings are in its window, not here" };
                    if(w.isNil) { w = this.settingsWhy(sa.device(id.asSymbol).type, set, id) };
                };
            };
            if(w.notNil) { ^w };
        };
        if(switches.notNil) {
            if(switches.isKindOf(MegaJsonObject).not) { ^"on must be an object: device id -> true or false" };
            switches.keysValuesDo { |id, flag|
                if(w.isNil) {
                    w = this.deviceWhy(sa, id, removed) !? { |x| "on: " ++ x };
                    if(w.isNil and: { flag.isKindOf(Boolean).not }) { w = "on: " ++ id ++ " is true or false" };
                };
            };
            if(w.notNil) { ^w };
        };
        ^nil
    }

    // The chains as they stand, as a sound in the Effects view's menu (the
    // plugin's own sound with it). A name taken is refused unless
    // `overwrite` is true.
    saveSound { |args|
        var src = source.value, sa = src !? { |s| s[\sa] }, dir = src !? { |s| s[\soundDir] }, name, slug, path;
        if(sa.isNil) { ^this.prNoChains };
        name = args !? { |a| a.at("name") };
        if(name.isKindOf(String).not or: { name.stripWhiteSpace.isEmpty }) { ^this.class.failure("name the sound") };
        if(dir.isNil) { ^this.class.failure("there is no folder for sounds") };
        path = sa.soundPath(dir, name);
        if(File.exists(path) and: { (args.at("overwrite") == true).not }) {
            ^this.class.failure("there is a sound " ++ sa.fxPresetSlug(name).quote ++ " already; overwrite: true replaces it")
        };
        slug = sa.saveSound(dir, name);
        if(slug.isNil) { ^this.class.failure("the sound was not written (the post window says why)") };
        this.prSay(src, "The AI saved the chains as the sound " ++ slug.quote);
        ^this.class.success(this.class.obj([\saved, slug, \path, path]))
    }

    // What `given` asked for that `result` does not hold, added to `out` (a
    // List) as words: a value held to a range or refused ("notes.swing 50 ->
    // 1.0"), a member that is no setting, an item past a list's end. A given
    // string and a result's Symbol of the same name agree.
    *corrections { |given, result, path, out|
        out = out ?? { List.new };
        case
        { given.isNil } { }
        { given.isKindOf(Dictionary) } {
            given.keysValuesDo { |k, v|
                if(result.isKindOf(Dictionary) and: { result.includesKey(k) }) {
                    this.corrections(v, result[k], path ++ "." ++ k, out)
                } { out.add(path ++ "." ++ k ++ " is no setting (ignored)") };
            };
        }
        { given.isKindOf(Array) } {
            given.do { |v, i|
                if(result.isKindOf(Array) and: { i < result.size }) {
                    this.corrections(v, result[i], path ++ "[" ++ i ++ "]", out)
                } { if(v.notNil) { out.add(path ++ "[" ++ i ++ "] is past the list's end (ignored)") } };
            };
        }
        { (given == result) or: { given.isString and: { result.isKindOf(Symbol) } and: { given.asSymbol == result } } } { }
        { out.add(path ++ " " ++ MegaFiles.json(given) ++ " -> " ++ MegaFiles.json(result)) };
        ^out
    }

    // The drums as they stand, as a preset in the Drums view's menu. A name
    // taken is refused unless `overwrite` is true.
    saveDrumPreset { |args|
        var src = source.value, drums = this.prDrums(src), dir = src !? { |s| s[\drumsPresetDir] }, name, slug;
        if(drums.isNil) { ^this.prNoDrums };
        name = args !? { |a| a.at("name") };
        if(name.isKindOf(String).not or: { name.stripWhiteSpace.isEmpty }) { ^this.class.failure("name the preset") };
        if(dir.isNil) { ^this.class.failure("there is no folder for drum presets") };
        if(File.exists(drums.presetPath(dir, name)) and: { (args.at("overwrite") == true).not }) {
            ^this.class.failure("there is a drum preset " ++ drums.presetSlug(name).quote
                ++ " already; overwrite: true replaces it")
        };
        slug = drums.savePreset(dir, name);
        if(slug.isNil) { ^this.class.failure("the preset was not written (the post window says why)") };
        this.prSay(src, "The AI saved the drums as " ++ slug.quote);
        ^this.class.success(this.class.obj([\saved, slug, \path, drums.presetPath(dir, name)]))
    }

    // JSON values as sclang's patterns hold them: an object an Event with
    // Symbol keys (a null member left out), a list an Array.
    *plain { |v|
        var e;
        if(v.isKindOf(MegaJsonObject)) {
            e = ();
            v.keysValuesDo { |k, x| e.put(k.asSymbol, this.plain(x)) };
            ^e
        };
        if(v.isKindOf(Array)) { ^v.collect { |x| this.plain(x) } };
        ^v
    }

    // `given` over `current`, at every depth: a member or an item given
    // replaces, one left out or null keeps what is there, and a list shorter
    // than the one there changes only its first items ("steps": {"chance":
    // [null, [6, 0, 3]]} sets the first three chance steps of lane 1). Neither
    // is touched; the answer is new.
    *mergePattern { |current, given|
        var out;
        if(given.isNil) { ^current.deepCopy };
        if(given.isKindOf(Dictionary) and: { current.isKindOf(Dictionary) }) {
            out = current.deepCopy;
            given.keysValuesDo { |k, v| out.put(k, this.mergePattern(current[k], v)) };
            ^out
        };
        if(given.isKindOf(Array) and: { current.isKindOf(Array) }) {
            ^current.collect { |c, i| this.mergePattern(c, given[i]) } ++ given.drop(current.size)
        };
        ^given.deepCopy
    }

    // ---- the grains and the cutter -------------------------------------------------
    // Both are the Looper's, not Megalooper SA's: they work on the loop
    // whatever else runs, and both are changed as their own presets are
    // recalled (applyGranularPreset, applyBBCutPreset), so the AI's values
    // meet the checks a preset file meets.

    prLooper { |src| ^src !? { |s| s[\looper] } }

    prNoLooper { ^this.class.failure("there is no looper running") }

    // What `model` refuses (\refused, what, why) while `func` runs, as words.
    prHeard { |model, func|
        var heard = List.new, listener = { |obj, what, op, reason|
            if(what == \refused) { heard.add(op.asString ++ " refused: " ++ reason) } };
        model.addDependant(listener);
        protect { func.value } { model.removeDependant(listener) };
        ^heard
    }

    // The granular layer's settings by name (settings: (name: number), the
    // names the context's grains.settings has), its grain window by name
    // (window), and/or the layer on or off (on). Settings are merged over
    // what plays; a value held to its range is said in the corrections.
    setGrains { |args|
        var src = source.value, looper = this.prLooper(src), settings, window, on, names, data, label, notes, w;
        if(looper.isNil) { ^this.prNoLooper };
        settings = args !? { |a| a.at("settings") };
        window = args !? { |a| a.at("window") };
        on = args !? { |a| a.at("on") };
        if(settings.isNil and: { window.isNil } and: { on.isNil }) {
            ^this.class.failure("nothing to change: give settings, window, on, or several")
        };
        names = Looper.granularPresetFields.collect { |f| f[0].asString };
        if(settings.notNil) {
            if(settings.isKindOf(MegaJsonObject).not) { ^this.class.failure("settings must be an object: name -> number") };
            settings.keysValuesDo { |k, v|
                if(w.isNil) {
                    if(names.includesEqual(k).not) { w = "the grains have no setting " ++ k ++ "; they have " ++ names.join(", ") } {
                        if(v.isNumber.not) { w = "grains." ++ k ++ " must be a number" } };
                };
            };
            if(w.notNil) { ^this.class.failure(w) };
        };
        if(window.notNil and: { this.class.grainWindowIndex(window).isNil }) {
            ^this.class.failure("there is no grain window " ++ window.asString.quote ++ "; there are "
                ++ Looper.granularEnvNames.join(", "))
        };
        if(on.notNil and: { on.isKindOf(Boolean).not }) { ^this.class.failure("on is true or false") };
        label = "grains' " ++ [settings !? { "settings" }, window !? { "window" }, on !? { "switch" }]
            .reject(_.isNil).join(" and ");
        this.prSnapshot(\grains, label, (preset: looper.granularPresetData("before the AI's change"),
            on: looper.granularOn));
        notes = this.prHeard(looper, {
            if(settings.notNil or: { window.notNil }) {
                data = looper.granularPresetData("ai");
                settings !? { |set| set.keysValuesDo { |k, v| data[k.asSymbol] = v } };
                window !? { data[\env] = Looper.granularEnvNames[this.class.grainWindowIndex(window)] };
                looper.applyGranularPreset(data);
            };
            on !? { |flag| if(flag != looper.granularOn) { looper.toggleGranular } };
        });
        settings !? { |set| set.keysValuesDo { |k, v|
            this.class.corrections(v, looper.perform(Looper.granularPresetFields.detect { |f| f[0].asString == k }[1]),
                "grains." ++ k, notes) } };
        this.prSay(src, "The AI changed the " ++ label ++ " (it can revert it)");
        ^this.class.success(this.class.grainsOf(looper).add("corrections", notes.asArray).add("aiChanges", this.changeCount))
    }

    // A grain window's index in Looper.granularEnvNames from its name, the
    // case not minded, or nil.
    *grainWindowIndex { |name|
        ^if(name.isString.not) { nil } {
            Looper.granularEnvNames.detectIndex { |n| n.asString.toLower == name.toLower }
        }
    }

    // The cutter's voices (voices: a list merged by place over the voices
    // there: an item null keeps that voice, a member left out keeps its
    // value; a procedure changed starts from that procedure's defaults, and
    // fx given replaces the list), how many voices there are (voiceCount,
    // 1..4: voices past it go, new ones start as a new voice does), the mode
    // (mix, insert or gate) and/or the cutter on or off (on). Everything is
    // checked first; one thing wrong refuses it all. Values held to a range
    // are said in the corrections.
    setCutter { |args|
        var src = source.value, looper = this.prLooper(src), voices, count, mode, on, why, current, data, label, notes;
        if(looper.isNil) { ^this.prNoLooper };
        voices = args !? { |a| a.at("voices") };
        count = args !? { |a| a.at("voiceCount") };
        mode = args !? { |a| a.at("mode") };
        on = args !? { |a| a.at("on") };
        if([voices, count, mode, on].every(_.isNil)) {
            ^this.class.failure("nothing to change: give voices, voiceCount, mode, on, or several")
        };
        current = looper.bbcutPresetData("before the AI's change");
        why = this.class.cutterWhy(looper, current, voices, count, mode, on);
        if(why.notNil) { ^this.class.failure(why) };
        voices = this.class.plain(voices) ? [];
        count = count ?? { current[\voices].size.max(voices.size) };
        label = "cutter's " ++ [if(voices.notEmpty or: { args.at("voiceCount").notNil }) { "voices" },
            mode !? { "mode" }, on !? { "switch" }].reject(_.isNil).join(" and ");
        this.prSnapshot(\cutter, label, (preset: current, on: looper.bbcut));
        data = (version: looper.bbcutPresetVersion, name: "ai", mode: (mode ? current[\mode]).asSymbol,
            voices: Array.fill(count, { |i| this.class.cutterVoice(looper, current[\voices][i], voices[i]) }));
        notes = this.prHeard(looper, {
            looper.applyBBCutPreset(data);
            on !? { |flag| looper.bbcut = flag };
        });
        this.class.corrections(voices, looper.bbcutPresetData[\voices], "voices", notes);
        if(on == true and: { looper.bbcut.not } and: { notes.isEmpty }) {
            notes.add("the cutter comes in at the loop's next downbeat")
        };
        this.prSay(src, "The AI changed the " ++ label ++ " (it can revert it)");
        ^this.class.success(this.class.cutterOf(looper).add("corrections", notes.asArray).add("aiChanges", this.changeCount))
    }

    // Voice `given` (an Event, or nil to keep it) over `base` (a voice as
    // bbcutPresetData has it, or nil for a new one), as a preset holds it.
    *cutterVoice { |looper, base, given|
        var out = (base ?? { looper.bbcutVoiceData(looper.defaultBBCutVoice) }).deepCopy, proc;
        if(given.isNil) { ^out };
        proc = (given[\proc] ? out[\proc]).asSymbol;
        if(proc != out[\proc]) { out[\params] = looper.defaultParamsFor(proc) };
        out = this.mergePattern(out, given.copy.put(\fx, nil));
        out[\proc] = proc;
        given[\fx] !? { |fx| out[\fx] = fx.collect(_.asSymbol) };
        ^out
    }

    // Why a set_cutter request can't be done as it stands, or nil.
    *cutterWhy { |looper, current, voices, count, mode, on|
        var procs = looper.bbcutProcOrder.collect(_.asString), synths = looper.bbcutSynthKeys.collect(_.asString);
        var fxs = looper.bbcutFxOrder.collect(_.asString), keys = #["enabled", "proc", "synth", "fx", "ratio", "amp", "pan", "params"];
        var w, proc, params, tag;
        if(mode.notNil and: { #["mix", "insert", "gate"].includesEqual(mode).not }) { ^"mode is mix, insert or gate" };
        if(on.notNil and: { on.isKindOf(Boolean).not }) { ^"on is true or false" };
        if(count.notNil and: { count.isInteger.not or: { count < 1 } or: { count > 4 } }) { ^"voiceCount is 1, 2, 3 or 4" };
        if(voices.isNil) { ^nil };
        if(voices.isKindOf(Array).not) { ^"voices must be a list of objects (or null to keep a voice)" };
        if(voices.size > (count ? 4)) { ^"there are " ++ voices.size ++ " voices given, more than " ++ (count ? 4) };
        voices.do { |x, i|
            tag = "voice " ++ (i + 1);
            if(w.isNil and: { x.notNil }) {
                if(x.isKindOf(MegaJsonObject).not) { w = tag ++ " is an object (or null to keep it)" } {
                    x.keysValuesDo { |k, v|
                        if(w.isNil and: { keys.includesEqual(k).not }) {
                            w = tag ++ " has no " ++ k ++ "; a voice has " ++ keys.join(", ") }
                    };
                    proc = x.at("proc") ?? { (current[\voices][i] !? { |vd| vd[\proc] } ? looper.defaultBBCutProc).asString };
                    case
                    { w.notNil } { }
                    { procs.includesEqual(proc).not } { w = tag ++ ": there is no procedure " ++ proc.asString ++ "; there are " ++ procs.join(", ") }
                    { x.at("synth").notNil and: { synths.includesEqual(x.at("synth")).not } } {
                        w = tag ++ ": there is no cut synth " ++ x.at("synth").asString ++ "; there are " ++ synths.join(", ") }
                    { x.at("fx").notNil and: { x.at("fx").isKindOf(Array).not
                        or: { x.at("fx").any { |f| fxs.includesEqual(f).not } } } } {
                        w = tag ++ ": fx is a list of " ++ fxs.join(", ") }
                    { x.at("enabled").notNil and: { x.at("enabled").isKindOf(Boolean).not } } { w = tag ++ ": enabled is true or false" }
                    { #["ratio", "amp", "pan"].any { |k| x.at(k).notNil and: { x.at(k).isNumber.not } } } {
                        w = tag ++ ": ratio, amp and pan are numbers" }
                    { x.at("params").notNil and: { x.at("params").isKindOf(MegaJsonObject).not } } {
                        w = tag ++ ": params must be an object: name -> number" }
                    { x.at("params").notNil } {
                        params = looper.bbcutProcSpecs[proc.asSymbol][\params].collect { |e| e[\key].asString };
                        x.at("params").keysValuesDo { |k, v|
                            if(w.isNil) {
                                if(params.includesEqual(k).not) {
                                    w = tag ++ ": " ++ proc ++ " has no parameter " ++ k ++ "; it has " ++ params.join(", ") } {
                                    if(v.isNumber.not) { w = tag ++ ": " ++ k ++ " must be a number" } };
                            };
                        };
                    };
                };
            };
        };
        ^w
    }

    // The granular layer as it stands, as a preset in the Grains view's
    // menu. A name taken is refused unless `overwrite` is true.
    saveGrainsPreset { |args|
        ^this.prSaveLooperPreset(args, \grainsPresetDir, "grains", \granularPresetPath, \granularPresetSlug,
            \saveGranularPreset)
    }

    // The cutter as it stands (every voice and the mode), as a preset in the
    // Cutter view's menu. A name taken is refused unless `overwrite` is true.
    saveCutterPreset { |args|
        ^this.prSaveLooperPreset(args, \cutterPresetDir, "cutter", \bbcutPresetPath, \bbcutPresetSlug,
            \saveBBCutPreset)
    }

    prSaveLooperPreset { |args, dirKey, what, pathSel, slugSel, saveSel|
        var src = source.value, looper = this.prLooper(src), dir = src !? { |s| s[dirKey] }, name, slug, path;
        if(looper.isNil) { ^this.prNoLooper };
        name = args !? { |a| a.at("name") };
        if(name.isKindOf(String).not or: { name.stripWhiteSpace.isEmpty }) { ^this.class.failure("name the preset") };
        if(dir.isNil) { ^this.class.failure("there is no folder for " ++ what ++ " presets") };
        path = looper.perform(pathSel, dir, name);
        if(File.exists(path) and: { (args.at("overwrite") == true).not }) {
            ^this.class.failure("there is a " ++ what ++ " preset " ++ looper.perform(slugSel, name).quote
                ++ " already; overwrite: true replaces it")
        };
        slug = looper.perform(saveSel, dir, name);
        if(slug.isNil) { ^this.class.failure("the preset was not written (the post window says why)") };
        this.prSay(src, "The AI saved the " ++ what ++ " as " ++ slug.quote);
        ^this.class.success(this.class.obj([\saved, slug, \path, path]))
    }

    // ---- the context -----------------------------------------------------------

    // What is playing and how it is set, from `src` (looper:, sa:, profile:).
    *context { |src|
        var looper = src !? { |s| s[\looper] }, sa = src !? { |s| s[\sa] };
        var drums = sa !? { |m| m.drums };
        ^this.obj([
            \format, "megalooper context", \version, this.version,
            \profile, src !? { |s| s[\profile] !? { |p| p.asString } },
            \standalone, sa.notNil,
            \loop, this.loopOf(looper),
            \now, looper !? { |l| this.nowOf(l, src !? { |x| x[\playhead] }) },
            \tempo, sa !? { |m| m.tempo },
            \drums, drums !? { |d| this.drumsOf(d) },
            \synth, sa !? { |m| this.synthOf(m) },
            \chains, sa !? { |m| m.sessionInfo[\chains] },
            \grains, looper !? { |l| this.grainsOf(l) },
            \cutter, looper !? { |l| this.cutterOf(l) }
        ])
    }

    // The granular layer: on or off, its settings by name, its grain window,
    // and the arc's intensity, which scales its level.
    *grainsOf { |looper|
        var data = looper.granularPresetData;
        ^this.obj([
            \on, looper.granularOn,
            \settings, this.obj(Looper.granularPresetFields.collect { |f| [f[0], data[f[0]]] }.flatten(1)),
            \window, data[\env],
            \intensity, looper.intensity
        ])
    }

    // The cutter: on or off, its mode, the arc's intensity, which scales each
    // procedure's pedal parameter, and its voices as a cutter preset holds
    // them, their parameters in the window's order, whole or not as a preset
    // recall makes them (a new voice holds a default 0 that a recall makes
    // 0.0).
    *cutterOf { |looper|
        var data = looper.bbcutPresetData;
        ^this.obj([
            \on, looper.bbcut,
            \mode, data[\mode],
            \intensity, looper.intensity,
            \voices, data[\voices].collect { |vd|
                var spec = looper.bbcutProcSpecs[vd[\proc]];
                this.obj([\enabled, vd[\enabled], \proc, vd[\proc], \synth, vd[\synth], \fx, vd[\fx],
                    \ratio, vd[\ratio], \amp, vd[\amp], \pan, vd[\pan],
                    \params, this.obj(spec[\params].collect { |e|
                        [e[\key], vd[\params][e[\key]] !? { |v| if(e[\int] == true) { v.round.asInteger } { v.asFloat } }]
                    }.flatten(1))])
            }
        ])
    }

    // The loop's state and the reading in force: its signature as the window
    // shows it ("7/8", "7+7+7+8/8"), its bars (each in units of 1 /
    // denominator), its tempo in quarter notes a minute and its length.
    *loopOf { |looper|
        var r;
        if(looper.isNil) { ^nil };
        r = looper.lastResult;
        ^this.obj([
            \state, looper.state !? { |s| s.asString },
            \reading, if(r.isNil or: { r[\denominator].isNil }) { nil } {
                this.obj([
                    \signature, MeterAnalyzer.sigString(r),
                    \numerator, r[\numerator], \denominator, r[\denominator],
                    \bars, (r[\bars] ?? { Array.fill(r[\k] ? 1, r[\numerator]) }).asArray,
                    // How each bar is felt: its beat groups in units of 1 /
                    // denominator (2+2+3 for a bar of 7/8), as the count
                    // on Perform shows them.
                    \groups, (r[\bars] ?? { Array.fill(r[\k] ? 1, r[\numerator]) }).asArray.collect { |b|
                        MeterAnalyzer.beatGrouping(b, r[\denominator]) },
                    \barCount, r[\k],
                    \bpm, r[\bpm], \loopSeconds, r[\loopDur],
                    \byHand, r[\from] == \hand
                ] ++ this.accentOf(r))
            },
            \take, this.takeOf(looper)
        ])
    }

    // How the take's loudness fits a reading, as the analyser scored it: for
    // a meter, accentFit, how well its loud hits fall on the meter's strong
    // beats (the downbeat, then each beat group's first: MeterAnalyzer's
    // accent template), 0 not at all to 1 exactly; for uneven bars,
    // barLineAccent, how loud its bar lines are against its mean hit (1: as
    // loud as an average hit). Neither for a reading given by hand or a
    // fallback, which no loudness decided.
    *accentOf { |r|
        var a = r[\accent];
        // A set's log holds the reading as JSON: its `from` is a String.
        if(a.isNil or: { r[\error].notNil } or: { (r[\from] !? { |f| f.asString }) == "hand" }) { ^[] };
        ^if(MeterAnalyzer.isUneven(r)) { [\barLineAccent, a.round(0.01)] } { [\accentFit, a.round(0.001)] }
    }

    // Where the loop is now and what is coming: the bar, the beat and its
    // group as the count on Perform shows them (Looper.beatCountAt), from the
    // window's prediction of the playhead (`playhead`, a function answering
    // seconds into the loop) or, without one, from where the passes began;
    // half-time, reverse, a break, a dissolve, the arc's intensity, and the
    // events on their way (Looper.upcoming) in seconds from now.
    *nowOf { |looper, playhead|
        var r = looper.countResult, dur = looper.loopDuration, now = SystemClock.seconds, pos, c, moving;
        moving = #[\playing, \overdubbing].includes(looper.state) and: { dur > 0 };
        pos = if(moving) {
            (playhead !? { |f| f.value }) ?? {
                looper.passStart !? { |t0| (((now - t0) * looper.speed) * if(looper.reverseFlag) { -1 } { 1 }).mod(dur) } }
        };
        c = pos !? { |p| Looper.beatCountAt(p, r, dur, nil, looper.reverseFlag) };
        ^this.obj([
            \about, "Where the loop is as you read this (to about a beat) and what is on its way. bar and beat "
                "count from 1; group is the beat group of the bar it is in (the bar's groups are in "
                "loop.reading.groups), groupBeat the beat within it. halfTime: off, armed, on or releasing "
                "(the loop at half speed, an octave down, under drums that keep their tempo). coming: "
                "what lands on a coming loop boundary, in seconds.",
            \playing, moving,
            \bar, c !? { |x| x[\bar] }, \barCount, c !? { |x| x[\barCount] },
            \beat, c !? { |x| x[\beat] }, \beatsPerBar, c !? { |x| x[\beatsPerBar] },
            \group, c !? { |x| x[\group] }, \groupBeat, c !? { |x| x[\groupBeat] },
            \halfTime, looper.halfTime.asString, \speed, looper.speed,
            \reversed, looper.reverseFlag,
            \onBreak, looper.onBreak,
            \dissolving, looper.dissolving, \dissolve, looper.dissolvePos.round(0.01),
            \intensity, looper.intensity,
            \breakLoops, looper.breakLoops, \dissolveLoops, looper.dissolveLoops,
            \coming, if(moving) { looper.upcoming(now).collect { |e|
                this.obj([\what, e[\what].asString, \inSeconds, (e[\at] - now).max(0).round(0.01)]) } } { [] }
        ])
    }

    // What the take was heard to play, on the reading's bar grid, in
    // sixteenths from the record press (the transport's beat one; an
    // overdub's reading counts from its downbeatPhase): per bar a grid, "X"
    // a strong hit (two thirds of the loudest or more), "x" a hit, "." none,
    // and the hits with their strength (0..1 of the loudest) and their pitch
    // where the pitch tracker heard one; and the chords it heard, where they
    // start. nil without a reading, or before a take with onsets, or when a
    // sixteenth is no whole share of the denominator's unit (x/32).
    *takeOf { |looper|
        ^looper !? { |l| this.gridOf(l.lastResult, l.takeOnsets, l.takePitches,
            "What the first take played, on the bar grid in sixteenths from the downbeat: "
                "X a strong hit, x a hit, . nothing. at counts sixteenths from the bar's start (0). "
                "note is the pitch heard at a hit, where one was. Overdubs are not in it.") }
    }

    // A take's hits on reading `r`'s bar grid (takeOf, and a past set's takes
    // in get_set): `onsets` [seconds from the record press, strength] pairs,
    // `pitches` the pitch tracker's readings (none for a past set's).
    *gridOf { |r, onsets, pitches, about|
        var den, beatDur, six, units, cycles, barSix, starts;
        var rows, loudest, total, bar, at, q, strength, chords;
        onsets = onsets ? [];
        if(r.isNil or: { r[\error].notNil } or: { r[\denominator].isNil } or: { r[\tau].isNil }
            or: { r[\loopDur].isNil } or: { onsets.isEmpty }) { ^nil };
        den = r[\denominator].asInteger;
        if((den < 1) or: { (16 % den) != 0 }) { ^nil };
        beatDur = r[\tau] * (r[\sub] ? 1);
        six = beatDur * den / 16;
        units = MeterAnalyzer.barsOf(r);
        cycles = (((r[\loopDur] / beatDur).round / units.sum).round.asInteger).max(1);
        barSix = (units ! cycles).flatten.collect { |b| (b * 16 / den).round.asInteger };
        total = barSix.sum;
        starts = [0] ++ barSix.integrate.drop(-1);
        rows = barSix.collect { |n| (grid: String.fill(n, $.), hits: List.new) };
        loudest = onsets.collect { |o| o[1] ? 0 }.maxItem.max(1e-9);
        onsets.do { |o|
            q = (((o[0] - (r[\downbeatPhase] ? 0)) / six).round.asInteger).mod(total);
            bar = starts.lastIndexForWhich { |s0| s0 <= q } ? 0;
            at = q - starts[bar];
            strength = ((o[1] ? 0) / loudest).clip(0, 1);
            if(strength >= (2/3)) { rows[bar][\grid][at] = $X } {
                if(rows[bar][\grid][at] != $X) { rows[bar][\grid][at] = $x } };
            rows[bar][\hits].add(this.obj([\at, at, \strength, strength.round(0.01),
                \note, this.noteName(this.pitchAt(pitches, o[0]))]));
        };
        chords = (r[\chordSegments] ? []).collect { |c|
            q = (((c[\start] - (r[\downbeatPhase] ? 0)) / six).round.asInteger).mod(total);
            bar = starts.lastIndexForWhich { |s0| s0 <= q } ? 0;
            this.obj([\bar, bar + 1, \at, q - starts[bar],
                \chord, [c[\rootName], c[\scaleName]].reject(_.isNil).join(" ")])
        };
        ^this.obj((if(about.notNil) { [\about, about] } { [] }) ++ [
            \sixteenthsPerBar, barSix,
            \bars, rows.collect { |row, i| this.obj([\bar, i + 1, \grid, row[\grid], \hits, row[\hits].asArray]) },
            \chords, chords
        ])
    }

    // ---- the sets recorded before ---------------------------------------------------
    // The set recorder's logs (LooperSessionRecorder: <sessionDir>/<stamp>…
    // -events.jsonl, a JSON object a line), read for the AI: which sets there
    // are, and one set's story, so between rehearsals it can do what the
    // roadmap's rounds did by hand ("what did the analyser get wrong on
    // Thursday, and what did we play there?"). Read only. The drums' hits,
    // thousands a set, are counted, not listed.

    *setsMax { ^20 }

    // Every set's log in `dir`, newest first.
    *setFiles { |dir|
        if(dir.isNil or: { File.exists(dir).not }) { ^[] };
        ^(LooperSessionRecorder.globQuote(dir) +/+ "*-events.jsonl").pathMatch.sort.reverse
    }

    // A set's id: its log's name without "-events.jsonl" (its stamp, and the
    // tempo and meter the recorder named it by).
    *setIdOf { |path| ^path.basename.drop("-events.jsonl".size.neg) }

    // A log read: (header:, events: the records but the hits, as Events,
    // hits: (total:, main:, break:, onset:)).
    *readSet { |path|
        var header, events = List.new, hits = (total: 0, main: 0, break: 0, onset: 0), o;
        (File.readAllString(path) ? "").split($\n).do { |line|
            case
            { line.contains("\"ev\": \"hit\"") } {
                hits[\total] = hits[\total] + 1;
                case
                { line.contains("\"slot\": \"onset\"") } { hits[\onset] = hits[\onset] + 1 }
                { line.contains("\"which\": \"break\"") } { hits[\break] = hits[\break] + 1 }
                { hits[\main] = hits[\main] + 1 };
            }
            { line.size > 2 } {
                o = MegaFiles.parseObject(line);
                if(o.isKindOf(MegaJsonObject)) {
                    o = this.plain(o);
                    if(o[\ev] == "session") { header = o } { events.add(o) };
                };
            };
        };
        ^(header: header, events: events, hits: hits)
    }

    // The wall clock `t` seconds into a set that began at `date` (the log's
    // "Mon Oct 26 19:11:12 2026"), "19:13:05"; its day, "Mon Oct 26".
    *clockAt { |date, t|
        var parts = date !? { |d| d.split($ ).reject(_.isEmpty) }, hms, secs;
        if(parts.isNil or: { parts.size < 4 } or: { t.isNumber.not }) { ^nil };
        hms = parts[3].split($:).collect(_.asInteger);
        if(hms.size != 3) { ^nil };
        secs = ((hms[0] * 3600) + (hms[1] * 60) + hms[2] + t.floor).asInteger.mod(86400);
        ^[secs div: 3600, (secs div: 60) % 60, secs % 60].collect { |n| n.asString.padLeft(2, "0") }.join(":")
    }
    *dayOf { |date| ^date !? { |d| d.split($ ).reject(_.isEmpty).keep(3).join(" ") } }

    // A reading as the window says it: signature, tempo, bars, the
    // analyser's score where it had one.
    *readingWords { |r|
        if(r.isNil or: { r[\denominator].isNil }) { ^nil };
        ^this.obj([\signature, MeterAnalyzer.sigString(r), \bpm, r[\bpm] !? { |b| b.round(0.1) },
            \bars, MeterAnalyzer.barsOf(r).asArray, \score, r[\score] !? { |x| x.round(0.001) },
            \byHand, r[\from] == "hand"] ++ this.accentOf(r))
    }

    // `limit` sets (setsMax), newest first, each in a line or two.
    *listSets { |src, args|
        var files = this.setFiles(src !? { |s| s[\sessionDir] }), limit;
        limit = (args !? { |a| a.at("limit") }) ? this.setsMax;
        if(limit.isInteger.not or: { limit < 1 }) { ^this.failure("limit is a whole number, 1 or more") };
        ^this.success(this.obj([
            \about, "The sets megalooper recorded (Record set), newest first. takes: each take's time and "
                "the meter reading the analyser applied; readingsArmed: presses of Next reading (or bars "
                "given by hand, byHand) and readingsLanded/readingsCancelled what became of them: a take "
                "whose reading was changed is one the analyser got wrong. get_set with an id tells a set "
                "in full: every take with what was played on its bar grid, every change the players made.",
            \sets, files.keep(limit).collect { |p| this.setSummary(p) },
            \more, (files.size - limit).max(0)
        ]))
    }

    *setSummary { |path|
        var set = this.readSet(path), h = set[\header], ev = set[\events], date = h !? { |x| x[\date] };
        var stop = ev.detect { |e| e[\ev] == "sessionStop" };
        var count = { |name| ev.count { |e| e[\ev] == name } };
        ^this.obj([
            \id, this.setIdOf(path),
            \day, this.dayOf(date), \started, this.clockAt(date, 0),
            \minutes, stop !? { |e| ((e[\elapsed] ? e[\t] ? 0) / 60).round(0.1) },
            \readingAtStart, h !? { |x| this.readingWords(x[\loop]) },
            \takeAtStart, (h !? { |x| x[\take] }).notNil,
            \takes, ev.select { |e| e[\ev] == "take" }.collect { |e|
                this.obj([\at, this.clockAt(date, e[\t]), \reading, this.readingWords(e[\result])]) },
            \readingsArmed, count.("readingArmed"),
            \byHand, ev.count { |e| (e[\ev] == "readingArmed") and: { e[\via] == "hand" } },
            \readingsLanded, count.("readingLanded"), \readingsCancelled, count.("readingCancelled"),
            \thresholdChanges, count.("threshold"), \overdubs, count.("overdubStart"),
            \breaks, count.("breakStart"), \clears, count.("clear"), \halfTime, count.("halfTime"),
            \drumHits, set[\hits][\total]
        ])
    }

    // One set in full (`id` from list_sets, or its stamp): the reading it
    // began with, and every record but the hits, in time, as the AI can use
    // them; a take with what it played on the bar grid of the reading the
    // analyser applied (`grids` false leaves the grids out).
    *getSet { |src, args|
        var id = args !? { |a| a.at("id") }, path, set, h, date, grids;
        if(id.isNil) { ^this.failure("id is needed: list_sets gives the sets' ids") };
        id = id.asString;
        if(id.isEmpty or: { id.any { |c| (c.isAlphaNum or: { "-_.".includes(c) }).not } }) {
            ^this.failure("no set " ++ id.quote) };
        path = this.setFiles(src !? { |s| s[\sessionDir] }).detect { |p|
            var i = this.setIdOf(p); (i == id) or: { i.beginsWith(id ++ "-") } };
        if(path.isNil) { ^this.failure("no set " ++ id.quote ++ "; list_sets gives the ids") };
        grids = (args.at("grids") ? true) != false;
        set = this.readSet(path);
        h = set[\header];
        date = h !? { |x| x[\date] };
        ^this.success(this.obj([
            \about, "A recorded set, in time: at is the clock, seconds the time into the set. takeAtStart: "
                "the take a set begun with a loop playing was made of, played on the reading at its start. A take: the "
                "reading the analyser applied, its runners-up (alternatives), and played, the take's hits "
                "on that reading's bar grid in sixteenths (X strong, x a hit, . none). readingArmed: the "
                "players asked for another reading (via next, or hand: bars they gave), landing at lands; "
                "readingLanded: it came in; readingCancelled: it did not. threshold: the onset "
                "threshold moved (higher hears fewer hits).",
            \id, this.setIdOf(path), \day, this.dayOf(date), \started, this.clockAt(date, 0),
            \build, h !? { |x| x[\build] }, \fallback, h !? { |x| x[\fallback] },
            \readingAtStart, h !? { |x| this.readingWords(x[\loop]) },
            // A set begun with a loop playing: the take it was made of, what
            // it played on the reading in force, with the pitches heard.
            \takeAtStart, (h !? { |x| x[\take] }) !? { |t|
                this.obj([\reading, this.readingWords(t[\result]),
                    \alternatives, (t[\candidates] ? []).drop(1).keep(3).collect { |c| this.readingWords(c) },
                    \played, if(grids) { this.gridOf(h[\loop] ? t[\result], t[\onsets], t[\pitches], nil) }]) },
            \events, set[\events].collect { |e| this.eventOf(e, date, grids) }.reject(_.isNil),
            \drumHits, this.obj([\total, set[\hits][\total], \main, set[\hits][\main],
                \break, set[\hits][\break], \onsetKit, set[\hits][\onset]])
        ]))
    }

    // One record of a set as get_set gives it, or nil for one that says
    // nothing to the AI (the recorder's own: audio, files).
    *eventOf { |e, date, grids|
        var base = [\at, this.clockAt(date, e[\t]), \seconds, (e[\t] ? 0).round(0.1), \event, e[\ev]];
        var scalars = { e.keys.asArray.sort.reject { |k| #[\t, \ev].includes(k) }.select { |k|
            e[k].isNumber or: { e[k].isString } or: { e[k].isKindOf(Boolean) } }.collect { |k|
            [k, if(e[k].isFloat) { e[k].round(0.001) } { e[k] }] }.flatten(1) };
        ^switch(e[\ev],
            "audio", { nil },
            "files", { nil },
            "take", { this.obj(base ++ [\reading, this.readingWords(e[\result]),
                \alternatives, (e[\candidates] ? []).drop(1).keep(3).collect { |c| this.readingWords(c) },
                \onsets, (e[\onsets] ? []).size, \threshold, e[\threshold] !? { |x| x.round(0.001) },
                \played, if(grids) { e[\result] !? { |r| this.gridOf(r, e[\onsets], nil, nil) } }]) },
            "readingArmed", { this.obj(base ++ [\index, e[\index], \of, e[\of], \via, e[\via],
                \lands, this.clockAt(date, e[\landsAt]), \reading, this.readingWords(e[\reading])]) },
            "readingLanded", { this.obj(base ++ [\index, e[\index], \reading, this.readingWords(e[\reading])]) },
            { this.obj(base ++ scalars.value) }
        )
    }

    // The pitch heard at a hit at `t` (seconds from the press): the median of
    // the pitch readings in the 100 ms after it, as a MIDI note, or nil.
    *pitchAt { |pitches, t|
        var hz = (pitches ? []).select { |p| (p[0] >= t) and: { p[0] <= (t + 0.1) }
            and: { (p[2] ? 0) > 0 } and: { p[1].notNil } and: { p[1] > 30 } and: { p[1] < 2000 } }
            .collect { |p| p[1] }.sort;
        ^if(hz.isEmpty) { nil } { hz[hz.size div: 2].cpsmidi.round.asInteger }
    }

    // "E2" for MIDI 40, nil for nil.
    *noteName { |midi| ^midi !? { |m| MegaSANoteSeq.rootNames[m % 12] ++ ((m div: 12) - 1) } }

    // Both step patterns, which is in force, the kits and their pads.
    *drumsOf { |d|
        var pads = { |slot|
            var o = MegaJsonObject.new;
            d.pads(slot).asArray.sort.do { |n| o.add(n.asString, d.padName(slot, n)) };
            o
        };
        ^this.obj([
            \on, d.on, \playing, d.playing, \breakActive, d.breakActive,
            \stepsKit, d.kit(\steps) !? { |k| k.asString },
            \onsetKit, d.kit(\onset) !? { |k| k.asString },
            \kits, d.kitKeys.collect(_.asString),
            \pads, this.obj([\steps, pads.(\steps), \onset, pads.(\onset)]),
            \repeats, d.repeats, \reverbMix, d.reverbMix, \offsetMs, d.offsetMs,
            \patterns, this.obj([\main, d.patterns[\main], \break, d.patterns[\break]])
        ])
    }

    // The note sequencer's pattern and what plays it.
    *synthOf { |sa|
        var d = sa.drums, w = sa.wave;
        ^this.obj([
            \notesOn, d !? { |x| x.notesOn },
            \notes, d !? { |x| x.notes },
            \instrument, sa.instrumentKey !? { |k| k.asString } ? "wave",
            \wave, w !? { |x| x.settings },
            \waveTable, w !? { |x| x.tableName }
        ])
    }

    // ---- describe --------------------------------------------------------------

    *topics { ^#["drums", "synth", "effects", "grains", "cutter"] }

    // What every setting of `topic` means, or nil for a topic there is not.
    // With no topic: the list of them. `src` is the source's Event, for the
    // Grains view's rows and the running Looper's cutter tables.
    *describe { |topic, src|
        ^case
        { topic.isNil } { this.obj([\topics, this.topics]) }
        { topic == "drums" } { this.describeDrums(src !? { |s| s[\sa] } !? { |m| m.drums }) }
        { topic == "synth" } { this.describeSynth }
        { topic == "effects" } { this.describeEffects }
        { topic == "grains" } { this.describeGrains(src !? { |s| s[\grainParams] }) }
        { topic == "cutter" } { this.describeCutter(src !? { |s| s[\looper] }) }
        { nil }
    }

    // A settings row as JSON has it: its range from the ControlSpec, choices
    // as [value, label], `displayScale` when the window shows it multiplied
    // (a 0..0.25 shown as 0..25 %). A switch (true or false) has no range.
    *rowOf { |row|
        var spec = if(row[\bool] == true) { nil } { row[\spec] };
        ^this.obj([
            \name, row[\name], \label, row[\label],
            \min, spec !? { |s| s.minval }, \max, spec !? { |s| s.maxval },
            \step, spec !? { |s| s.step }, \default, spec !? { |s| s.default },
            \warp, spec !? { |s| s.warp.asSpecifier.asString },
            \units, row[\units] !? { |u| u.stripWhiteSpace },
            \displayScale, row[\scale],
            \choices, row[\choices],
            \switch, row[\bool] == true,
            \bipolar, row[\centered] == true,
            \tip, row[\tip] !? { |t| t.replace("\n", " ") }
        ])
    }

    // `drums` the running ones, for how their lanes meet a bar line
    // (MegaSADrums.retrigAt: \barLine restarts them on every one, the
    // default; \live lets them run on).
    *describeDrums { |drums|
        var retrig = (drums !? { |d| d.retrigAt }) ? \barLine;
        ^this.obj([
            \about, "The drums are a step sequencer of four lanes, each playing one drum pad (note) "
                "or its alternative pad (altNote). There are two patterns: main, and break (in force "
                "while a break is open). A step is a 16th at clockSpeed 3. A pattern holds, per lane, "
                "five pages of 16 step values each 0..6: chance (the step plays with probability "
                "value/6: 0 never, 6 always), velo (an index into velocities), alt (the probability, "
                "/6, that the step plays altNote instead of note), roll (that many extra hits within "
                "the step at rollRate), slide (stored, not heard). Each page of each lane has its own "
                "length (lengths[page][lane], 2..16): it wraps on its own, so lanes of different "
                "lengths drift against each other; lock[lane] plays globalLength[lane] on every page "
                "instead. "
                ++ (if(retrig == \barLine) {
                    "The lanes restart at every bar line of the loop's reading (uneven bars too: Retrig "
                    "is on, as it is by default), so a lane of 7 steps fits a bar of 7/16 and a lane of 14 "
                    "a bar of 7/8. "
                } {
                    "Retrig is off: the lanes run on across bar lines, each at its own length, and meet "
                    "the bar only where their lengths divide it. "
                })
                ++ "mute[lane] silences a lane, delay[lane] moves it later in ms. Shuffle: shuffle[0..7] "
                "per step of a shuffleLength cycle, scaled by globalShuffle. Lane 0 is the hats in "
                "the shipped pattern. The pads a kit has are in the context's drums.pads.steps.",
            \velocities, MegaSASteps.velocities,
            \pages, MegaSASteps.subs,
            \stepValues, this.obj([\min, 0, \max, 6]),
            \stepsPerPage, 16,
            \clockSpeeds, MegaSASteps.clockSpeedLabels.collect { |l, i| [i, l] },
            \rollRates, MegaSASteps.rollRateLabels.collect { |l, i| [i, l] },
            \settings, MegaSASteps.paramSpecs.collect { |r| this.rowOf(r) },
            \laneSettings, MegaSASteps.laneParamSpecs.collect { |r| this.rowOf(r) }
        ])
    }

    *describeSynth {
        var specs = MegaSANoteSeq.laneSpecs;
        ^this.obj([
            \about, "The note sequencer plays one note per step (stepCount 8 or 16, steps[i] on or "
                "off) on the synth: the built-in Wave synth, or an instrument plugin. Seven lanes "
                "hold 16 values each, one per step: pitch (semitones), octave, velocity (0 is "
                "silent), length (% of the step), shift (late, % of the step), ratchet (the step "
                "plays ratchet + 1 times), condition (0 or 1 always; +k once every k passes of the "
                "lane; -k all but that one; -1 never). A lane follows the sequence unless own is "
                "true: then it steps on its own between first and last in its own direction, so "
                "lanes drift. The note: 60 + root + pitch, moved down to the nearest note of the "
                "scale when scaleOn, plus 12 * (the octave lane + the pattern's octave); root 0 is "
                "C. The sequence plays steps first..last of stepCount in its direction. division "
                "indexes divisions (1/1 .. 1/64), with triplet or dotted; swing 0..1 delays every "
                "second step (1 puts it at three quarters of the pair). restart: bar (from every "
                "bar line of the loop's reading, uneven bars too), loop or off. on (the context's "
                "synth.notesOn) is whether the sequencer plays at all.",
            \lanes, MegaSANoteSeq.laneNames.collect { |n|
                this.obj([\name, n, \min, specs[n][0], \max, specs[n][1], \default, specs[n][2]]) },
            \settings, MegaSANoteSeq.settingNames,
            \laneSettings, MegaSANoteSeq.laneSettingNames,
            \directions, MegaSANoteSeq.directions,
            \divisions, MegaSANoteSeq.divisionNames.collect { |l, i| [i, l] },
            \restarts, MegaSANoteSeq.restarts,
            \roots, MegaSANoteSeq.rootNames.collect { |l, i| [i, l] },
            \scales, MegaSANoteSeq.scales.collect { |s, i| [i, s[0], s[1]] },
            \wave, MegaSAWave.params.collect { |r| this.rowOf(r) }
        ])
    }

    // Every built-in effect: its key, the chain it is made for, what it does,
    // and its settings.
    *describeEffects {
        ^this.obj([
            \about, "Effects sit in chains as devices, in order: guitar (the instrument input, whatever is plugged in, before "
                "the looper records it), loop (what the loop plays back), drums, bass and synth (each "
                "after its source). A device has an id, a type (one of these keys), a name, an on "
                "switch and settings by name. Any type may go in any chain; track says what it was "
                "made for (any: none in particular). A type in no chain to begin with gets its key as "
                "its first device's id (eq); a further device of a type gets the next id (delay2). Plugins (VST, e.g. "
                "an amp) are devices too: they may be moved and switched, their own settings are in "
                "their window, and only the player puts them in or takes them out.",
            \effects, MegaSAFx.types.collect { |t|
                this.obj([\key, t[\key], \track, t[\track], \about, t[\blurb],
                    \settings, MegaSAFx.paramsOf(t[\key]).collect { |r| this.rowOf(r) }])
            }
        ])
    }

    // The granular layer's settings: the ranges the Looper holds them to,
    // and from the Grains view's rows (`rows`, ~granularParams, when the
    // window has them) the label, the range its slider covers and the tip.
    *describeGrains { |rows|
        ^this.obj([
            \about, "The grains are a granular layer (SuperCollider's Warp1) reading the recorded loop, "
                "played over it. It needs a recorded loop to switch on. morph is the meta-control: 0 a "
                "frozen drone (long overlapped grains, a still read point), 1 a pulsed scan (a grain per "
                "beat of the reading, moving through the loop in time, so its rhythm is what was played); "
                "size, density and scan bend what morph asks for (size and density multiply it, 1 leaves "
                "it), position is where the grains read (0..1 of the loop; at the drone end the freeze "
                "point), pitch transposes without changing the read speed, detune and spray randomise "
                "each grain. amp is the level at full intensity: the arc pedal (the context's intensity, "
                "0..1) scales it, and the Dissolve takes it out last. window is the grain's shape. "
                "Density is the CPU's bill: the result is held to 16 overlaps.",
            \settings, Looper.granularPresetFields.collect { |f|
                var row = (rows ? []).detect { |r| r[\key] == f[1] }, spec = row !? { |r| r[\spec] };
                this.obj([\name, f[0], \label, row !? { |r| r[\label] }, \min, f[2], \max, f[3], \default, f[4],
                    \windowMin, spec !? { |x| x.minval }, \windowMax, spec !? { |x| x.maxval },
                    \units, row !? { |r| r[\unit] !? { |u| u.stripWhiteSpace } },
                    \tip, row !? { |r| r[\tip] !? { |t| t.replace("\n", " ") } }])
            },
            \windows, Looper.granularEnvNames.collect { |n, i| this.obj([\name, n, \about, Looper.granularEnvHints[i]]) }
        ])
    }

    // The cutter's procedures, cut synths, effects and modes, from the
    // running Looper's tables (a fresh one's when there is none: they are the
    // same in every Looper).
    *describeCutter { |looper|
        looper = looper ?? { Looper.newCopyArgs.initBBCut };
        ^this.obj([
            \about, "The cutter (Nick Collins's BBCut) re-splices the loop in tempo. Switched on, it takes a "
                "snapshot of the loop (overdubs after it are not in it until it is switched off and on) and "
                "comes in at the loop's next downbeat; it needs an analysed take. It has one to four voices, "
                "each its own cutter over the same snapshot: a procedure (how it cuts) with its parameters, a "
                "cut synth, effects on its cuts, a ratio (its clock against the loop's beat: voices at "
                "different ratios stay locked to the same downbeat, so 1.5 against 1 is three cuts against "
                "two; the window offers 1, 3/2, 2/3, 4/3, 3/4, 1/2, 2; 0.01..8 is taken), amp (0..1) and pan "
                "(-1..1); enabled false silences a voice. Lengths in beats count the reading's pulses (a 7/8 "
                "loop is 7 beats); phrase lengths round to whole loop passes. A procedure's pedal parameter is "
                "how much it chops at full intensity: the arc pedal (the context's intensity, 0..1) scales it "
                "from the parameter's minimum up, so heel barely chops and toe is what is set. A parameter "
                "that is not live rebuilds the voice at the next beat. A procedure changed starts from its "
                "defaults. mode: how the cutter sits against the dry loop.",
            \modes, [["mix", "the dry loop with the repeats on top"],
                ["insert", "the dry loop ducks only while a repeat plays (the default)"],
                ["gate", "the dry loop muted: the cutter alone"]],
            \procedures, looper.bbcutProcOrder.collect { |k|
                var spec = looper.bbcutProcSpecs[k];
                this.obj([\key, k, \name, spec[\name], \about, spec[\desc], \pedal, spec[\intensityKey],
                    \params, spec[\params].collect { |e|
                        this.obj([\name, e[\key], \label, e[\label], \min, e[\lo], \max, e[\hi], \default, e[\default],
                            \whole, e[\int] == true, \live, (spec[\live] ? []).includes(e[\key]), \tip, e[\hint]])
                    }])
            },
            \synths, [["cutbuf1", "one PlayBuf per cut: the cheapest, no envelope, it may click"],
                ["cutbuf2", "a fresh enveloped grain per cut (the default)"],
                ["cutbuf3", "event-aware playback: keeps the original pitch at any tempo"]],
            \effects, looper.bbcutFxOrder.collect { |k|
                this.obj([\key, k, \name, looper.bbcutFxSpecs[k][\name], \about, looper.bbcutFxSpecs[k][\desc]]) }
        ])
    }
}
