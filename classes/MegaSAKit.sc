// One drum kit for Megalooper SA's drums (docs/dev/megalooper-sa.md, Phase 4):
// the pads a kit file describes, checked; the arithmetic that turns one hit
// into each sounding layer's amplitude, rate and length; and the kit's samples
// read into buffers on a server. MegaSADrums holds two of these, the steps' kit
// and the onset kit, and plays the voices; nothing here schedules or sounds.
//
// A kit is presets/sa/drums/kits/<key>.json (tools/export-live-set.py kits),
// version 1, its audio beside it in git-ignored folders:
//
//   { "version": 1, "key": "carbon-layer", "name": "Kit-Carbon + layer",
//     "description": "one line", "source": "where it came from",
//     "notes": ["how it was made", ...],
//     "groups": { "carbon": "Kit-Carbon", "layer": "KJ Sawka 9 stand-in" },
//     "pads": { "42": { "name": "HiHat Closed Carbon", "choke": 1, "retrigger": false,
//                       "pan": 0.0, "gainDb": 0.0, "fit": { "db": -10.1, "r2": 0.996 },
//                       "beatRepeat": true, "repeatFilter": false,
//                       "layers": [ { "group": "carbon", "file": "carbon/HiHat Closed Carbon.ogg",
//                                     "gainDb": -10.1, "transpose": 0.0, "velLo": 1, "velHi": 127,
//                                     "startFrames": 0, "lenSecs": 0, "drive": 0.0,
//                                     "vel": { "law": "operator", "amount": 0.62 } } ] } } }
//
// sclang's parseJSON answers every number and boolean as a String, and a
// String that is no number reads as 0.0 through asFloat, so nothing is taken on
// trust: a number must look like one (the regexp in prNum), a switch must be
// true or false, and a field that is present but not usable takes its default
// with a warning; a pad that keeps no playable layer is dropped with one. A
// missing optional field takes its default silently. The defaults: a pad's
// name "Pad <note>", choke 0 (none; 1..16 are groups that choke each other),
// retrigger false (true: the pad chokes itself), pan 0, gainDb 0, beatRepeat
// and repeatFilter false, fit nil; a layer's group the kit's only group (or
// \main), gainDb 0, transpose 0 st, velLo 1, velHi 127, startFrames 0, lenSecs 0
// (to the end), drive 0 dB (off), vel (law: \none, amount: 0, curve: 1; a
// curve 0.25..6 bends the law's response about velocity 88, velFactor). Ranges
// are held with a warning. `file` is relative to the kits folder; one starting
// with / or ~ is used as it stands.
//
// Accessors answer what was read: key (a Symbol, the file's name when read from
// a file), name, description, source, remarks (the file's "notes", the
// exporter's account of how the kit was made: an Array of Strings, as in
// rhythmic-steps.json; `notes` answers the pads' notes), version, groups (IdentityDictionary
// group -> display name), pads (IdentityDictionary note -> pad Event, as above
// with Symbols for keys, law a Symbol, and `note:` added), warnings (every
// correction made, an Array). The voices' arithmetic is in class methods taking
// every input (velDb, velAmp, velFactor, ampFor, rateFor, durFor), with
// instance forwards.
//
// Loading (load, below) checks every distinct file with SoundFile first, reads
// the rest into Buffers through a reader the caller may replace (tests do),
// and settles one state: \ready (every file in), \partial (some), \missing
// (none could be found or read: Ableton's own pack samples are encrypted), or
// \failed (the server would not read them). Buffers live in a cache the caller
// owns, so kits sharing a file share its buffer, and only the caller frees
// them. Per file the channel count, rate and length are kept (infoFor), for
// the mono or stereo voice and for how long a voice can ring (soundingDur).
//
// Its buffers outlive Cmd-period (they are not nodes) but not a server
// reboot, after which nothing reads them again: re-run boot.scd, as for MegaSA.
MegaSAKit {
    var <key, <name, <description, <source, <remarks, <version, <groups, <pads, <warnings;
    // \unloaded until load; then \loading, \ready, \partial, \missing, \failed.
    var <state = \unloaded;
    // From the last load: the folder `file`s are relative to, path Symbol ->
    // Buffer and -> (numChannels:, sampleRate:, numFrames:), and the absolute
    // paths that could not be found or read (missing) or that the server did
    // not read (failed).
    var <root, <buffers, <fileInfo, <missing, <failed;
    var loadSerial = 0, syncRoutine;

    // The kit file format this build reads.
    *kitVersion { ^1 }

    // ---- Reading a kit ----------------------------------------------------

    // A kit from its JSON file, or nil if the file is missing, is not JSON, or
    // holds no playable pad. `warnings`, a List, collects every correction and
    // reason; with none given they are posted instead, one line per kit.
    *read { |path, warnings|
        var notes = List.new;
        var full = path !? { |p| p.standardizePath };
        var data, kit;
        if(full.isNil or: { File.exists(full).not }) {
            notes.add("no kit file " ++ path);
            ^this.prReport(nil, notes, warnings, path)
        };
        data = try { File.readAllString(full).parseJSON } { |err|
            notes.add("not JSON — " ++ err.errorString);
            nil
        };
        if(data.isNil and: { notes.isEmpty }) { notes.add("empty, or not JSON") };
        kit = data !? { |d| this.prBuild(d, notes, full) };
        ^this.prReport(kit, notes, warnings, path)
    }

    // The same from data already in hand: what parseJSON answers (String keys,
    // String values), or an Event with Symbol keys and real numbers and
    // Booleans (the tests' way). `path`, if given, names the kit's key.
    *fromData { |data, warnings, path|
        var notes = List.new;
        ^this.prReport(this.prBuild(data, notes, path), notes, warnings, path)
    }

    // The kit files in a folder, by key (their file names), sorted; and where a
    // key's file is.
    *keysIn { |dir|
        if(dir.isNil or: { File.exists(dir.standardizePath).not }) { ^[] };
        ^(dir.standardizePath +/+ "*.json").pathMatch
            .collect { |p| PathName(p).fileNameWithoutExtension.asSymbol }.sort
    }

    *fileFor { |dir, key| ^dir.standardizePath +/+ key.asString ++ ".json" }

    // A file as the voices read it: relative to rootDir unless it starts with
    // / or ~.
    *absolutePath { |rootDir, file|
        ^case
            { file.isNil or: { file.isEmpty } } { nil }
            { (file[0] == $/) or: { file[0] == $~ } } { file.standardizePath }
            { rootDir.isNil } { file }
            { (rootDir.standardizePath +/+ file).standardizePath }
    }

    *prReport { |kit, notes, warnings, path|
        var label = (kit !? { |k| k.key }) ?? { path !? { |p| PathName(p).fileName } } ? "kit";
        kit !? { |k| k.instVarPut(\warnings, notes.asArray) };
        if(warnings.notNil) { warnings.addAll(notes) } {
            if(notes.notEmpty) {
                ("MegaSAKit " ++ label ++ ": "
                    ++ if(kit.isNil) { "not loaded — " } { notes.size.asString ++ " correction(s) — " }
                    ++ notes.keep(8).join("; ")
                    ++ if(notes.size > 8) { "; and " ++ (notes.size - 8) ++ " more" } { "" }).warn;
            };
        };
        ^kit
    }

    // A value as a field of `dict`, whichever kind of key it has.
    *prGet { |dict, key| ^dict[key.asString] ?? { dict[key.asSymbol] } }

    // A finite number, from a number or a String that looks like one; else nil.
    *prNum { |v|
        var x;
        x = case
            { v.isNumber } { v }
            { v.isKindOf(String) and: { "^-?[0-9]+(\\.[0-9]+)?([eE][-+]?[0-9]+)?$".matchRegexp(v) } }
                { v.asFloat }
            { nil };
        ^if(x.notNil and: { x.isNaN.not } and: { x.abs != inf }) { x } { nil }
    }

    // A whole number, as an Integer; else nil.
    *prInt { |v|
        var x = this.prNum(v);
        ^if(x.notNil and: { (x - x.round).abs < 1e-9 }) { x.round.asInteger } { nil }
    }

    *prBool { |v|
        ^case
            { (v == true) or: { v == "true" } } { true }
            { (v == false) or: { v == "false" } } { false }
            { nil }
    }

    *prStr { |v|
        ^case
            { v.isKindOf(String) } { v }
            { v.isKindOf(Symbol) } { v.asString }
            { nil }
    }

    *prLaw { |v|
        var s = this.prStr(v);
        ^s !? { |x| #[\simpler, \operator, \none].detect { |l| l.asString == x } }
    }

    // The whole check. Pure: it builds a new kit or answers nil, and only adds
    // to `notes`.
    *prBuild { |data, notes, path|
        var fileKey = path !? { |p| PathName(p).fileNameWithoutExtension };
        var unknown = List.new;
        var numConv = { |r| this.prNum(r) };
        var intConv = { |r| this.prInt(r) };
        var boolConv = { |r| this.prBool(r) };
        var strConv = { |r| this.prStr(r) };
        var lawConv = { |r| this.prLaw(r) };
        var take, checkKeys, parseVel, parseFit, parseLayer, parsePad, groupOf;
        var ver, kitKey, kitName, groups, pads, rawGroups, rawPads, rawRemarks, remarks;

        // One field: absent -> the default, silently; present and usable ->
        // the value (held to lo..hi with a warning); present and not usable ->
        // the default, with a warning.
        take = { |dict, field, conv, default, where, lo, hi|
            var raw = this.prGet(dict, field), v;
            if(raw.isNil) { default } {
                v = conv.(raw);
                if(v.isNil) {
                    notes.add(where ++ field ++ " " ++ raw.asCompileString ++ " is not usable -> "
                        ++ default.asCompileString);
                    default
                } {
                    if(lo.notNil and: { (v < lo) or: { v > hi } }) {
                        notes.add(where ++ field ++ " " ++ v ++ " is outside " ++ lo ++ ".." ++ hi
                            ++ " -> " ++ v.clip(lo, hi));
                        v.clip(lo, hi)
                    } { v }
                }
            }
        };
        checkKeys = { |dict, known, where|
            dict.keys.do { |k| if(known.includes(k.asSymbol).not) { unknown.add(where ++ k) } };
        };
        parseVel = { |raw, where|
            if(raw.isNil) { (law: \none, amount: 0.0, curve: 1.0) } {
                if(raw.isKindOf(Dictionary).not) {
                    notes.add(where ++ "vel " ++ raw.asCompileString ++ " is not an object -> none");
                    (law: \none, amount: 0.0, curve: 1.0)
                } {
                    checkKeys.(raw, #[\law, \amount, \curve], where ++ "vel.");
                    (law: take.(raw, \law, lawConv, \none, where ++ "vel "),
                        amount: take.(raw, \amount, numConv, 0.0, where ++ "vel ", 0, 1),
                        curve: take.(raw, \curve, numConv, 1.0, where ++ "vel ", 0.25, 6))
                }
            }
        };
        parseFit = { |raw, where|
            var db, r2;
            if(raw.isNil) { nil } {
                if(raw.isKindOf(Dictionary).not) {
                    notes.add(where ++ "fit " ++ raw.asCompileString ++ " is not an object (dropped)");
                    nil
                } {
                    checkKeys.(raw, #[\db, \r2], where ++ "fit.");
                    db = this.prNum(this.prGet(raw, \db));
                    r2 = this.prNum(this.prGet(raw, \r2));
                    if(db.isNil) { notes.add(where ++ "fit has no db (dropped)"); nil } { (db: db, r2: r2) }
                }
            }
        };
        groupOf = { |raw, where|
            var given = this.prGet(raw, \group), g = this.prStr(given), sym;
            if(given.notNil and: { g.isNil }) {
                notes.add(where ++ "group " ++ given.asCompileString ++ " is not a name -> the default");
            };
            if(g.isNil) {
                sym = if(groups.size == 1) { groups.keys.asArray.first } { \main };
            } {
                sym = g.asSymbol;
            };
            if(groups.includesKey(sym).not) {
                if(g.notNil) { notes.add(where ++ "group " ++ g ++ " is not in groups (added)") };
                groups.put(sym, sym.asString);
            };
            sym
        };
        parseLayer = { |raw, where|
            var file, layer, lo;
            if(raw.isKindOf(Dictionary).not) {
                notes.add(where ++ "not an object (dropped)");
                nil
            } {
                file = this.prStr(this.prGet(raw, \file));
                if(file.isNil or: { file.isEmpty }) {
                    notes.add(where ++ "no file (dropped)");
                    nil
                } {
                    checkKeys.(raw, #[\group, \file, \gainDb, \transpose, \velLo, \velHi, \startFrames,
                        \lenSecs, \drive, \vel], where);
                    layer = (
                        group: groupOf.(raw, where),
                        file: file,
                        gainDb: take.(raw, \gainDb, numConv, 0.0, where, -120, 24),
                        transpose: take.(raw, \transpose, numConv, 0.0, where, -48, 48),
                        velLo: take.(raw, \velLo, intConv, 1, where, 1, 127),
                        velHi: take.(raw, \velHi, intConv, 127, where, 1, 127),
                        startFrames: take.(raw, \startFrames, intConv, 0, where, 0, 2147483647),
                        lenSecs: take.(raw, \lenSecs, numConv, 0.0, where, 0, 3600),
                        drive: take.(raw, \drive, numConv, 0.0, where, 0, 48),
                        vel: parseVel.(this.prGet(raw, \vel), where)
                    );
                    if(layer[\velLo] > layer[\velHi]) {
                        notes.add(where ++ "velLo " ++ layer[\velLo] ++ " is above velHi "
                            ++ layer[\velHi] ++ " (swapped)");
                        lo = layer[\velHi];
                        layer.put(\velHi, layer[\velLo]);
                        layer.put(\velLo, lo);
                    };
                    layer
                }
            }
        };
        parsePad = { |note, raw|
            var where = "pad " ++ note ++ ": ";
            var pad, rawLayers, layers;
            if(raw.isKindOf(Dictionary).not) {
                notes.add(where ++ "not an object (dropped)");
                nil
            } {
                checkKeys.(raw, #[\name, \choke, \retrigger, \pan, \gainDb, \fit, \beatRepeat,
                    \repeatFilter, \layers], where);
                pad = (
                    note: note,
                    name: take.(raw, \name, strConv, "Pad " ++ note, where),
                    choke: take.(raw, \choke, intConv, 0, where, 0, 16),
                    retrigger: take.(raw, \retrigger, boolConv, false, where),
                    pan: take.(raw, \pan, numConv, 0.0, where, -1, 1),
                    gainDb: take.(raw, \gainDb, numConv, 0.0, where, -120, 24),
                    fit: parseFit.(this.prGet(raw, \fit), where),
                    beatRepeat: take.(raw, \beatRepeat, boolConv, false, where),
                    repeatFilter: take.(raw, \repeatFilter, boolConv, false, where)
                );
                rawLayers = this.prGet(raw, \layers);
                layers = if(rawLayers.isKindOf(Array)) {
                    rawLayers.collect { |l, i| parseLayer.(l, where ++ "layer " ++ i ++ ": ") }.reject(_.isNil)
                } { [] };
                if(layers.isEmpty) {
                    notes.add(where ++ "no playable layer (dropped)");
                    nil
                } {
                    pad.put(\layers, layers);
                    pad
                }
            }
        };

        if(data.isKindOf(Dictionary).not) {
            notes.add("not a kit (expected a JSON object)");
            ^nil
        };
        checkKeys.(data, #[\version, \key, \name, \description, \source, \notes, \groups, \pads], "");
        ver = this.prGet(data, \version);
        if(ver.isNil) {
            notes.add("no version (read as 1)");
            ver = 1;
        } {
            ver = this.prInt(ver);
            if(ver.isNil) { notes.add("version is not a number"); ^nil };
            if(ver > this.kitVersion) {
                notes.add("version " ++ ver ++ " is newer than this build (" ++ this.kitVersion ++ ")");
                ^nil
            };
        };
        kitKey = this.prStr(this.prGet(data, \key));
        if(fileKey.notNil and: { kitKey != fileKey }) {
            if(kitKey.notNil) {
                notes.add("key " ++ kitKey ++ " is not its file's name " ++ fileKey
                    ++ " (the file's wins: kits are found by file)");
            };
            kitKey = fileKey;
        };
        if(kitKey.isNil or: { kitKey.isEmpty }) { notes.add("no key"); ^nil };
        kitName = take.(data, \name, strConv, kitKey, "");
        rawRemarks = this.prGet(data, \notes);
        remarks = case
            { rawRemarks.isNil } { [] }
            { rawRemarks.isKindOf(String) } { [rawRemarks] }
            { rawRemarks.isKindOf(Array) } {
                if(rawRemarks.every { |r| r.isKindOf(String) }.not) {
                    notes.add("notes: only its text is kept");
                };
                rawRemarks.select { |r| r.isKindOf(String) }
            }
            { notes.add("notes is not text (ignored)"); [] };

        groups = IdentityDictionary.new;
        rawGroups = this.prGet(data, \groups);
        if(rawGroups.notNil) {
            if(rawGroups.isKindOf(Dictionary)) {
                rawGroups.keysValuesDo { |g, gName|
                    groups.put(g.asSymbol, this.prStr(gName) ?? {
                        notes.add("group " ++ g ++ ": its name is not a name -> " ++ g);
                        g.asString
                    });
                };
            } { notes.add("groups is not an object (ignored)") };
        };

        pads = IdentityDictionary.new;
        rawPads = this.prGet(data, \pads);
        if(rawPads.isKindOf(Dictionary).not) { notes.add("no pads"); ^nil };
        // In note order, so the warnings and the groups' order read the same way
        // every time.
        rawPads.keys.asArray.sort { |a, b| (this.prInt(a.asString) ? 999) < (this.prInt(b.asString) ? 999) }
            .do { |k|
                var note = this.prInt(k.asString), pad;
                if(note.isNil or: { note < 0 } or: { note > 127 }) {
                    notes.add("pad " ++ k ++ " is not a note 0..127 (dropped)");
                } {
                    pad = parsePad.(note, rawPads[k]);
                    pad !? { |p| pads.put(note, p) };
                };
            };
        if(pads.isEmpty) { notes.add("no playable pad"); ^nil };
        if(unknown.notEmpty) {
            notes.add("ignored: " ++ unknown.keep(6).join(", ")
                ++ if(unknown.size > 6) { " and " ++ (unknown.size - 6) ++ " more" } { "" });
        };
        ^this.newCopyArgs(kitKey.asSymbol, kitName,
            take.(data, \description, strConv, "", ""), take.(data, \source, strConv, "", ""),
            remarks, ver, groups, pads, [])
    }

    // ---- What the kit holds -----------------------------------------------

    // The pads' notes, ascending.
    notes { ^pads.keys.asArray.sort }

    pad { |note| ^note !? { |n| pads[n.asInteger] } }

    padName { |note| ^this.pad(note) !? { |p| p[\name] } }

    groupKeys { ^groups.keys.asArray.sort }

    groupName { |group| ^groups[group] }

    // Any pad with Beat Repeat (the Kit-Carbon layer's own, emulated by
    // MegaSADrums).
    hasRepeats { ^pads.any { |p| p[\beatRepeat] == true } }

    // Every layer that sounds for this note at this velocity: all whose range
    // holds it (layering, as a rack with overlapping zones does). [] for a
    // note the kit has no pad on.
    layersFor { |note, vel|
        var pad = this.pad(note);
        ^if(pad.isNil or: { vel.isNil }) { [] } {
            pad[\layers].select { |l| (l[\velLo] <= vel) and: { vel <= l[\velHi] } }
        }
    }

    // The distinct files, in note order: as written (relative) with no root,
    // absolute with one.
    files { |rootDir|
        var seen = Set.new, out = List.new;
        this.notes.do { |n|
            pads[n][\layers].do { |l|
                var p = if(rootDir.isNil) { l[\file] } { this.class.absolutePath(rootDir, l[\file]) };
                if(seen.includes(p).not) { seen.add(p); out.add(p) };
            };
        };
        ^out.asArray
    }

    // A layer's file as loaded (rootDir defaults to the last load's).
    pathFor { |layer, rootDir| ^this.class.absolutePath(rootDir ? root, layer[\file]) }

    bufferFor { |layer|
        ^buffers !? { |b| this.pathFor(layer) !? { |p| b[p.asSymbol] } }
    }

    // (numChannels:, sampleRate:, numFrames:) of a layer's file, once loaded.
    infoFor { |layer|
        ^fileInfo !? { |fi| this.pathFor(layer) !? { |p| fi[p.asSymbol] } }
    }

    // Which voice plays it: 1 (mono) or 2 (stereo). nil before a load.
    channelsFor { |layer| ^this.infoFor(layer) !? { |i| i[\numChannels] } }

    // How long a voice of this layer can sound, in seconds: lenSecs (or the
    // file from startFrames to its end) at the layer's rate. nil when the file
    // was never read and lenSecs is 0. Before its release and any choke.
    soundingDur { |layer|
        var rate = this.class.rateFor(layer);
        var info = this.infoFor(layer);
        var len = layer[\lenSecs] ? 0;
        var rest = info !? { |i|
            ((i[\numFrames] - (layer[\startFrames] ? 0)).max(0)) / i[\sampleRate]
        };
        ^case
            { len > 0 } { (if(rest.isNil) { len } { len.min(rest) }) / rate }
            { rest.isNil } { nil }
            { rest / rate }
    }

    isPlayable { ^#[\ready, \partial].includes(state) }

    // ---- What a hit plays -------------------------------------------------

    // Velocity v (1..127) on a layer, in dB and as a factor: amp = (layer.gainDb
    // + pad.gainDb + groupTrimDb + padTrimDb).dbamp * velFactor, the law's
    // response a(v) = velDb.dbamp * velAmp bent by the layer's curve p:
    //   \simpler  Simpler and Sampler's Vel > Vol: +22.8 dB times the amount at
    //             127, linear in v around 64 (fitted to users' measurements at
    //             127; the pivot is assumed). The set's pad volumes are then the
    //             levels at about velocity 64.
    //   \operator Operator's carrier Vel: the law is unknown, so a linear
    //             amplitude placeholder, 1 at 127 and 1 - amount at 0.
    //   \none     no velocity response.
    //   curve p   (the kit's "vel": { ..., "curve": p }, 0.25..6, default 1)
    //             a(v) ** p * a(88) ** (1 - p): anchored at velocity 88, the
    //             Live patterns' commonest, so p changes the slope around it
    //             and not the level there (p = 2.4 is the steeper hat response
    //             Live's recordings show).
    *velDb { |law, amount, v|
        ^if((law ? \none).asSymbol == \simpler) { (22.8 * (amount ? 0)) * (((v ? 64) - 64) / 63) } { 0 }
    }

    *velAmp { |law, amount, v|
        var a = amount ? 0;
        ^if((law ? \none).asSymbol == \operator) { (1 - a) + (a * ((v ? 127) / 127)) } { 1 }
    }

    // The velocity factor a layer's law and curve give velocity v.
    *velFactor { |law, amount, curve, v|
        var p = curve ? 1;
        var a = { |x| this.velDb(law, amount, x).dbamp * this.velAmp(law, amount, x) };
        ^if(p == 1) { a.(v) } { (a.(v) ** p) * (a.(this.velAnchor) ** (1 - p)) }
    }

    // The velocity a curve turns about.
    *velAnchor { ^88 }

    *ampFor { |layer, pad, vel, groupTrimDb, padTrimDb|
        var law = layer[\vel] !? { |v| v[\law] };
        var amount = layer[\vel] !? { |v| v[\amount] };
        var curve = layer[\vel] !? { |v| v[\curve] };
        var db = (((layer[\gainDb] ? 0) + ((pad !? { |p| p[\gainDb] }) ? 0)) + (groupTrimDb ? 0))
            + (padTrimDb ? 0);
        ^db.dbamp * this.velFactor(law, amount, curve, vel)
    }

    // The playback rate for the voice: the transpose alone. The voice
    // multiplies by BufRateScale itself (a 44.1 kHz sample on a 48 kHz server);
    // passing it in here as well would play it about 3 semitones flat.
    *rateFor { |layer| ^2 ** ((layer[\transpose] ? 0) / 12) }

    // The voice's duration: lenSecs counts source seconds, so a layer
    // transposed up is over sooner. 0: play to the end of the file.
    *durFor { |layer|
        var len = layer[\lenSecs] ? 0;
        ^if(len > 0) { len / this.rateFor(layer) } { 0 }
    }

    ampFor { |layer, pad, vel, groupTrimDb, padTrimDb|
        ^this.class.ampFor(layer, pad, vel, groupTrimDb, padTrimDb)
    }
    rateFor { |layer| ^this.class.rateFor(layer) }
    durFor { |layer| ^this.class.durFor(layer) }

    // ---- Loading ----------------------------------------------------------

    // A file's header, (numChannels:, sampleRate:, numFrames:), or nil if it
    // cannot be found or opened (Ableton's encrypted AIFCs cannot), or has more
    // than two channels: the voices play one or two.
    *probeFile { |path|
        var sf, info;
        if(path.isNil or: { File.exists(path).not }) { ^nil };
        sf = try { SoundFile.openRead(path) } { nil };
        if(sf.isNil) { ^nil };
        info = (numChannels: sf.numChannels, sampleRate: sf.sampleRate, numFrames: sf.numFrames);
        sf.close;
        if((info[\numChannels] < 1) or: { info[\numChannels] > 2 } or: { info[\numFrames] < 1 }
            or: { info[\sampleRate].isNil } or: { info[\sampleRate] <= 0 }) { ^nil };
        ^info
    }

    // The state a load settles in, from its counts of files: all in \ready,
    // some \partial, none because the server would not \failed, none because
    // they could not be found or read \missing.
    *loadState { |total, missingCount, failedCount|
        var loaded = (total - missingCount) - failedCount;
        ^case
            { total <= 0 } { \missing }
            { loaded >= total } { \ready }
            { loaded > 0 } { \partial }
            { failedCount > 0 } { \failed }
            { \missing }
    }

    // Read the kit's samples on `server`. rootDir: the kits folder its files
    // are relative to. cache: path Symbol -> Buffer, the caller's (nil: a
    // private one); a file already in it is not read again, and every buffer
    // read here goes into it (should a file arrive twice, the second buffer is
    // freed and the cached one used). action.(kit, state) is called with
    // \loading as the reads go out and once more with the final state, which
    // \state notifications announce as well. reader.(server, path, done) must
    // call done.(buffer) once per file, or done.(nil) for one it could not
    // read; by default Buffer.read. The server answers a read it cannot do
    // with /fail and never with the /b_info Buffer.read waits for, so after the
    // reads one sync settles it: a file that has not answered by then failed.
    // inFlight: path Symbol -> the loads waiting for a read on its way, shared
    // by the caller's loads (nil: none). A load that needs a file another has
    // asked for waits for that read instead of reading it again (two menu
    // picks in a row, or kits sharing files in both slots); a read that has
    // not answered by its load's sync is let go of, and its waiters hear nil.
    // With a reader that answers at once (a test's), the whole load happens
    // inside this call. A load started over one in progress supersedes it: the
    // earlier one's action hears no final state.
    load { |server, rootDir, cache, action, reader, inFlight|
        var serial, paths, toRead, pending, answered, finished = false, finish, started;
        loadSerial = loadSerial + 1;
        serial = loadSerial;
        root = rootDir;
        cache = cache ?? { IdentityDictionary.new };
        reader = reader ?? { { |srv, path, done| Buffer.read(srv, path, action: done) } };
        buffers = IdentityDictionary.new;
        fileInfo = IdentityDictionary.new;
        missing = List.new;
        failed = List.new;
        syncRoutine = nil;
        this.prSetState(\loading);
        action.value(this, \loading);
        paths = this.files(rootDir);
        toRead = List.new;
        paths.do { |p|
            var sym = p.asSymbol, info = this.class.probeFile(p), have = cache[sym];
            info !? { |i| fileInfo.put(sym, i) };
            case
            { have.notNil } {
                buffers.put(sym, have);
                if(info.isNil) {
                    fileInfo.put(sym, (numChannels: have.numChannels, sampleRate: have.sampleRate,
                        numFrames: have.numFrames));
                };
            }
            { info.isNil } { missing.add(p) }
            { toRead.add(p) };
        };
        started = List.new;
        finish = {
            var newState;
            if(finished.not) {
                finished = true;
                // A read sent here that has not answered never will: let go of
                // it, and of every load waiting for it (this one's own answer
                // among them, which changes nothing now).
                inFlight !? { |f|
                    started.do { |p| f.removeAt(p.asSymbol) !? { |waiting| waiting.do { |w| w.value(nil) } } };
                };
                if(serial == loadSerial) {
                    toRead.do { |p| if(buffers[p.asSymbol].isNil) { failed.add(p) } };
                    newState = this.class.loadState(paths.size, missing.size, failed.size);
                    if(missing.notEmpty or: { failed.notEmpty }) {
                        ("MegaSAKit " ++ key ++ ": " ++ newState ++ " — "
                            ++ (missing.size.asString ++ " of " ++ paths.size ++ " files missing or unreadable"
                                ++ if(failed.notEmpty) { ", " ++ failed.size ++ " not read by the server" } { "" })
                            ++ ": " ++ (missing ++ failed).keep(4).collect { |p| PathName(p).fileName }.join(", ")
                            ++ if((missing.size + failed.size) > 4) { ", ..." } { "" }).warn;
                    };
                    this.prSetState(newState);
                    action.value(this, newState);
                };
            };
        };
        pending = toRead.size;
        answered = Set.new;
        toRead.do { |p|
            var sym = p.asSymbol;
            // This load's answer for p: the buffer into the cache (a second one
            // for a file already there is freed, the first kept) and the kit.
            var done = { |buf|
                var have;
                if(buf.notNil) {
                    have = cache[sym];
                    if(have.notNil and: { have !== buf } and: { have.bufnum.notNil }) {
                        buf.free;
                        buf = have;
                    } { cache.put(sym, buf) };
                };
                if(answered.includes(p).not) {
                    answered.add(p);
                    if(buf.notNil and: { serial == loadSerial }) { buffers.put(sym, buf) };
                    pending = pending - 1;
                    if(pending <= 0) { finish.value };
                };
            };
            if(inFlight.notNil and: { inFlight[sym].notNil }) {
                // Another load is reading it: its answer is this one's too.
                inFlight[sym].add(done);
            } {
                inFlight !? { |f| f.put(sym, List[done]) };
                started.add(p);
                reader.value(server, p, { |buf|
                    ((inFlight !? { |f| f.removeAt(sym) }) ?? { [done] }).do { |w| w.value(buf) };
                });
            };
        };
        if(pending <= 0) { finish.value } {
            syncRoutine = Routine { server.sync; finish.value }.play(SystemClock);
        };
    }

    prSetState { |new|
        state = new;
        this.changed(\state, state);
    }
}
