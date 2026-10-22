// A sound: both chains as a document (docs/dev/device-chains.md, section 11).
// Which devices, in which order, each with its name, its switch and its own
// settings; a plugin with what it is and the file its state is in; and the
// number each type's ids go on from. It is data only: it reads from JSON
// text, writes back to it, and is made from MegaSA's chains (MegaSA.sound)
// or handed to MegaSA to build them from. Nothing here touches a server.
//
//   {"format": "megalooper sound", "version": 1,
//    "name": "kept", "savedAt": "261010_101500",
//    "nextIds": {"delay": 3, "plugin": 2},
//    "tracks": [
//     {"track": "guitar", "devices": [
//      {"id": "filter", "type": "filter", "name": "Auto Filter", "on": false, "settings": {"filterFreq": 311.09, …}},
//      {"id": "plugin1", "type": "plugin", "name": "BIAS FX 2", "on": true, "layout": [1, 1],
//       "plugin": {"key": …, "vendor": …, "format": "vst2", "uid": …, "version": …, "path": …},
//       "state": {"kind": "program", "file": "plugin1-261010_101500.fxp"}}]},
//     {"track": "loop", "devices": […]}]}
//
// What this build does not know goes back as it came: a field of the file, a
// field or a setting of a device, a device of a type it has not, a track it
// has not, each with the text it was written as. A file from a newer build
// is refused whole (MegaFiles.versionOf), so it is never written over.
//
// A device here is an Event:
//   id, type      Symbols
//   name          a String
//   on            a Boolean
//   settings      name -> number, every setting of its type (built-ins)
//   layout        [ins, outs] (a plugin)
//   plugin        what the plugin is: a Dictionary, or the text it had in
//                 the file (a plugin)
//   state         (kind: \program or \bank, file: a plain file name in the
//                 sound's own states folder), or nil
//   raw           the device's whole text, for a type this build has not
//   extras, settingsExtras, stateExtras
//                 [[name, text], …] of what this build does not know
MegaSASound {
    var <name, <savedAt, <nextIds, <tracks, <extras;
    // What a read corrected or left out, as sentences for the post window.
    var <problems;
    // The folder its plugins' state files are in: beside the file it was
    // read from or written to (statesDirFor), nil for one never on disk.
    var <>statesDir;

    *formatName { ^"megalooper sound" }
    *formatVersion { ^1 }
    *trackNames { ^[\guitar, \loop, \drums, \bass] }
    // The chains a sound has had since there were sounds. The drums' and the
    // bass's came later: a sound without one is no fault, and that chain is
    // empty.
    *firstTrackNames { ^[\guitar, \loop] }

    // tracks: [(track: a Symbol, devices: [device, …], extras: […]), …]; a
    // track this build has not is (track:, raw:).
    *new { |name, savedAt, nextIds, tracks, extras|
        ^super.newCopyArgs((name ? "sound").asString, savedAt, nextIds ?? { IdentityDictionary.new },
            tracks ? [], extras ? []).init
    }

    init { problems = List.new }

    // The states folder of the sound file at `path`: <name>.states beside it.
    *statesDirFor { |path| ^path.splitext[0] ++ ".states" }

    // ---- the default chains ------------------------------------------------
    // The chains as megalooper ships them: the guitar's four effects, then
    // the plugin if there is one (`pluginName`), and the loop's three, every
    // effect off at its own defaults, the plugin on.
    *default { |pluginName, name = "default"|
        var guitar = MegaSAFx.guitarKeys.collect { |k| this.deviceOfType(k, k) };
        var marks = IdentityDictionary.new;
        MegaSAFx.keys.do { |k| marks.put(k, 2) };
        marks.put(\plugin, if(pluginName.notNil) { 2 } { 1 });
        pluginName !? { |n| guitar = guitar ++ [(id: \plugin1, type: \plugin, name: n.asString, on: true, layout: [1, 1])] };
        ^this.new(name, nil, marks, [
            (track: \guitar, devices: guitar),
            (track: \loop, devices: MegaSAFx.loopKeys.collect { |k| this.deviceOfType(k, k) })
        ])
    }

    // A built-in device of `type` as `id`, off, at its type's defaults, with
    // `given` (name -> number) on top, each held to its range.
    *deviceOfType { |id, type, given|
        var settings = IdentityDictionary.new;
        MegaSAFx.paramsOf(type).do { |p|
            var v = given !? { |g| g[p[\name]] };
            settings.put(p[\name], if(v.isNumber and: { v == v }) { MegaSAFx.constrain(p[\name], v) } { p[\spec].default });
        };
        ^(id: id, type: type, name: MegaSAFx.title(type), on: false, settings: settings)
    }

    // The default chains with the settings of a preset from before the
    // chains (every effect setting by its name, as presets/sa/biasfx/
    // current.scd holds them): what the migration makes of one.
    *fromSettings { |settings, pluginName, name = "kept"|
        var sound = this.default(pluginName, name);
        sound.devices.do { |d|
            d[\settings] !? { |own|
                own.keys.asArray.do { |k|
                    var v = settings[k];
                    if(v.isNumber and: { v == v }) { own.put(k, MegaSAFx.constrain(k, v)) };
                }
            }
        };
        ^sound
    }

    // ---- reading -------------------------------------------------------------
    // The sound in the file at `path`, its statesDir set, or a String saying
    // why it was refused.
    *read { |path|
        var text = MegaFiles.readText(path), sound;
        if(text.isNil) { ^"it is missing or can't be read" };
        sound = this.parse(text);
        if(sound.isString.not) { sound.statesDir = this.statesDirFor(path) };
        ^sound
    }

    // The sound in `text`, or a String saying why it was refused. Fail-soft
    // by entry, reject by file: a device or a setting that makes no sense is
    // corrected or left out and said in `problems`; text that is no sound,
    // or one from a newer build, is refused whole.
    *parse { |text|
        var object = MegaFiles.parseObject(text), version, sound, tracks, extras = List.new, seen = IdentitySet.new;
        var known = ["format", "version", "name", "savedAt", "nextIds", "tracks"], notes = List.new, marks;
        if(object.isString) { ^object };
        version = MegaFiles.versionOf(object, this.formatName, this.formatVersion, "megalooper sound");
        if(version.isString) { ^version };
        if(object.at("tracks").isKindOf(Array).not) { ^"its tracks are not a list" };
        tracks = object.at("tracks").collect { |t, i| this.prTrack(t, i, seen, notes) }.reject(_.isNil);
        this.trackNames.do { |n|
            if(tracks.any { |t| t[\track] == n }.not) {
                if(this.firstTrackNames.includes(n)) { notes.add("it has no " ++ n ++ " chain: that chain is empty") };
                tracks = tracks ++ [(track: n, devices: [])];
            };
        };
        object.keysValuesDo { |k, v, raw| if(known.includesEqual(k).not) { extras.add([k, raw]) } };
        marks = this.prMarks(object.at("nextIds"), tracks);
        sound = this.new(if(object.at("name").isString) { object.at("name") } { "sound" },
            if(object.at("savedAt").isString) { object.at("savedAt") }, marks, tracks, extras.asArray);
        sound.problems.addAll(notes);
        ^sound
    }

    *prTrack { |t, index, seen, notes|
        var name, devices, extras = List.new;
        if(t.isKindOf(MegaJsonObject).not) { notes.add("track " ++ (index + 1) ++ " is left out: it is no object"); ^nil };
        name = t.at("track");
        if(name.isString.not) { notes.add("track " ++ (index + 1) ++ " is left out: it has no name"); ^nil };
        name = name.asSymbol;
        // A track this build has not: kept as it came.
        if(this.trackNames.includes(name).not) { ^(track: name, raw: t.raw) };
        if(seen.includes(name)) { notes.add("the " ++ name ++ " chain is written twice: the second is left out"); ^nil };
        seen.add(name);
        devices = (if(t.at("devices").isKindOf(Array)) { t.at("devices") } { [] }).collect { |d, i|
            this.prDevice(d, name, i, seen, notes)
        }.reject(_.isNil);
        t.keysValuesDo { |k, v, raw| if(["track", "devices"].includesEqual(k).not) { extras.add([k, raw]) } };
        ^(track: name, devices: devices, extras: extras.asArray)
    }

    *prDevice { |d, track, index, seen, notes|
        var where = "device " ++ (index + 1) ++ " of the " ++ track ++ " chain", id, type, spec, extras = List.new;
        var known = ["id", "type", "name", "on", "settings", "layout", "plugin", "state"];
        if(d.isKindOf(MegaJsonObject).not) { notes.add(where ++ " is left out: it is no object"); ^nil };
        id = d.at("id");
        type = d.at("type");
        if(id.isString.not or: { "^[a-zA-Z][a-zA-Z0-9]*$".matchRegexp(id).not }) {
            notes.add(where ++ " is left out: its id is none"); ^nil };
        if(type.isString.not or: { type.size == 0 }) { notes.add(where ++ " (" ++ id ++ ") is left out: it has no type"); ^nil };
        id = id.asSymbol;
        type = type.asSymbol;
        // Device ids are one family across both chains; a track's own name is
        // not among them (seen holds both).
        if(seen.includes(("device " ++ id).asSymbol)) { notes.add(where ++ " is left out: " ++ id ++ " is there already"); ^nil };
        seen.add(("device " ++ id).asSymbol);
        spec = (id: id, type: type,
            name: if(d.at("name").isString) { d.at("name") } { if(type == \plugin) { "plugin" } { MegaSAFx.title(type) } },
            on: d.at("on") == true);
        if(d.includesKey("on") and: { d.at("on").isKindOf(Boolean).not }) { notes.add(id ++ ": its switch is neither true nor false: off") };
        case
        { type == \plugin } {
            spec.put(\layout, this.prLayout(d.at("layout")));
            d.rawAt("plugin") !? { |raw| if(d.at("plugin").isKindOf(MegaJsonObject)) { spec.put(\plugin, raw) } };
            this.prState(d.at("state"), id, notes) !? { |pair|
                spec.put(\state, pair[0]);
                spec.put(\stateExtras, pair[1]);
            };
            // A plugin has no settings of megalooper's yet: one written here is kept.
            d.rawAt("settings") !? { |raw| extras.add(["settings", raw]) };
        }
        { MegaSAFx.type(type).isNil } {
            // A type this build has not: the whole device as it came.
            spec.put(\raw, d.raw);
            ^spec
        }
        {
            this.prSettings(d.at("settings"), spec, notes);
            [["layout", d.rawAt("layout")], ["plugin", d.rawAt("plugin")], ["state", d.rawAt("state")]].do { |pair|
                pair[1] !? { extras.add(pair) } };
        };
        d.keysValuesDo { |k, v, raw| if(known.includesEqual(k).not) { extras.add([k, raw]) } };
        spec.put(\extras, extras.asArray);
        ^spec
    }

    *prSettings { |object, spec, notes|
        var settings = IdentityDictionary.new, more = List.new, params = MegaSAFx.paramsOf(spec[\type]);
        params.do { |p| settings.put(p[\name], p[\spec].default) };
        if(object.isKindOf(MegaJsonObject)) {
            object.keysValuesDo { |k, v, raw|
                var key = k.asSymbol, held;
                case
                { settings.includesKey(key).not } { more.add([k, raw]) }
                { v.isNumber.not } { notes.add(spec[\id] ++ ": " ++ k ++ " is no number: its default") }
                {
                    held = MegaSAFx.constrain(key, v);
                    // A file holds 14 digits: a value read back is not corrected.
                    if((held - v).abs > (v.abs * 1e-9).max(1e-12)) { notes.add(spec[\id] ++ ": " ++ k ++ " " ++ v ++ " -> " ++ held ++ " (range)") };
                    settings.put(key, held);
                };
            };
        };
        spec.put(\settings, settings);
        spec.put(\settingsExtras, more.asArray);
    }

    *prLayout { |x|
        ^if(x.isKindOf(Array) and: { x.size == 2 } and: { x.every { |n| [1, 2].includes(n) } }) { x } { [1, 1] }
    }

    // [(kind:, file:), extras] of a device's state, or nil. Its file is a
    // plain name in the sound's own states folder, never a path: sounds are
    // shared, and a file must not name something elsewhere on the Mac.
    *prState { |object, id, notes|
        var kind, file, extras = List.new;
        if(object.isNil) { ^nil };
        if(object.isKindOf(MegaJsonObject).not) { notes.add(id ++ ": its state is no object: none"); ^nil };
        kind = object.at("kind");
        file = object.at("file");
        if(["program", "bank"].includesEqual(kind).not) { notes.add(id ++ ": its state is of no kind this build reads: none"); ^nil };
        if(file.isString.not or: { this.plainName(file).not }) {
            notes.add(id ++ ": its state names no plain file: none"); ^nil };
        object.keysValuesDo { |k, v, raw| if(["kind", "file"].includesEqual(k).not) { extras.add([k, raw]) } };
        ^[(kind: kind.asSymbol, file: file), extras.asArray]
    }

    *plainName { |file|
        ^(file.size > 0) and: { file.contains("/").not } and: { file.contains("\\").not } and: { file[0] != $. }
    }

    // Each type's next id number: the file's, never under what its devices
    // already use (a default device counts as 1), nor under megalooper's own
    // start (2 for a built-in, whose default device is there or was).
    *prMarks { |object, tracks|
        var marks = IdentityDictionary.new;
        MegaSAFx.keys.do { |k| marks.put(k, 2) };
        marks.put(\plugin, 1);
        if(object.isKindOf(MegaJsonObject)) {
            object.keysValuesDo { |k, v| if(v.isKindOf(Integer) and: { v > 0 }) { marks.put(k.asSymbol, max(marks[k.asSymbol] ? 1, v)) } };
        };
        tracks.do { |t| (t[\devices] ? []).do { |d|
            var digits = d[\id].asString.drop(d[\type].asString.size), n;
            if(d[\id].asString.beginsWith(d[\type].asString) and: { (digits.size == 0) or: { digits.every(_.isDecDigit) } }) {
                n = if(digits.size == 0) { 1 } { digits.asInteger };
                marks.put(d[\type], max(marks[d[\type]] ? 1, n + 1));
            };
        } };
        ^marks
    }

    // ---- asking ----------------------------------------------------------------
    track { |trackName| ^tracks.detect { |t| t[\track] == trackName } }

    // A chain's devices in order, or every device of all, the guitar's first.
    devices { |trackName|
        ^if(trackName.notNil) { (this.track(trackName) !? { |t| t[\devices] }) ? [] } {
            this.class.trackNames.collect { |n| this.devices(n) }.flatten(1)
        }
    }

    device { |id| ^this.devices.detect { |d| d[\id] == id } }

    // The state files it names.
    stateFiles { ^this.devices.collect { |d| d[\state] !? { |s| s[\file] } }.reject(_.isNil) }

    // Where a device's state file is, or nil (no state, or never on disk).
    statePath { |spec| ^(spec[\state] !? { |s| statesDir !? { |dir| dir +/+ s[\file] } }) }

    // The same sound under another name and stamp.
    named { |aName, aStamp|
        var copy = this.class.new(aName, aStamp, nextIds, tracks, extras);
        copy.statesDir = statesDir;
        ^copy
    }

    // ---- writing -----------------------------------------------------------------
    // A setting's value as text, the same whether the model holds it as an
    // Integer or a Float (a type's default 0 comes back from a file as 0.0):
    // a whole number with no fraction, so a sound read and written again is
    // the same text.
    *number { |x|
        ^if((x == x) and: { x.abs < 2147483647 } and: { x.frac == 0 }) { x.asInteger.asString } { MegaFiles.jsonNumber(x) }
    }

    // The tracks as a file has them: every one but a chain of a later build
    // (the drums', the bass's) that holds nothing. So a sound with no effect
    // on the drums or the bass is the file it was before they had a chain,
    // to this build and to an older one alike.
    prWrittenTracks {
        ^tracks.reject { |t|
            t[\raw].isNil and: { this.class.firstTrackNames.includes(t[\track]).not }
                and: { (t[\devices] ? []).isEmpty } and: { (t[\extras] ? []).isEmpty }
        }
    }

    fileString {
        var j = { |x| MegaFiles.jsonString(x) };
        var head = "{\"format\": " ++ j.(this.class.formatName) ++ ", \"version\": " ++ this.class.formatVersion ++ ",\n"
            ++ " \"name\": " ++ j.(name) ++ (savedAt !? { |s| ", \"savedAt\": " ++ j.(s) } ? "") ++ ",\n"
            ++ " \"nextIds\": {" ++ nextIds.keys.asArray.sort.collect { |k| j.(k) ++ ": " ++ nextIds[k] }.join(", ") ++ "},\n"
            ++ " \"tracks\": [\n";
        ^head ++ this.prWrittenTracks.collect { |t| this.prTrackString(t) }.join(",\n") ++ "]"
            ++ extras.collect { |pair| ",\n " ++ j.(pair[0]) ++ ": " ++ pair[1] }.join ++ "}\n"
    }

    prTrackString { |t|
        var j = { |x| MegaFiles.jsonString(x) };
        if(t[\raw].notNil) { ^"  " ++ t[\raw] };
        ^"  {\"track\": " ++ j.(t[\track]) ++ ", \"devices\": ["
            ++ t[\devices].collect { |d| "\n   " ++ this.prDeviceString(d) }.join(",") ++ "]"
            ++ (t[\extras] ? []).collect { |pair| ", " ++ j.(pair[0]) ++ ": " ++ pair[1] }.join ++ "}"
    }

    prDeviceString { |d|
        var j = { |x| MegaFiles.jsonString(x) }, parts, names;
        if(d[\raw].notNil) { ^d[\raw] };
        parts = List["\"id\": " ++ j.(d[\id]), "\"type\": " ++ j.(d[\type]), "\"name\": " ++ j.(d[\name]),
            "\"on\": " ++ (d[\on] == true)];
        d[\layout] !? { |l| parts.add("\"layout\": [" ++ l.join(", ") ++ "]") };
        d[\plugin] !? { |p| parts.add("\"plugin\": " ++ if(p.isString) { p } { MegaFiles.json(p) }) };
        d[\state] !? { |s|
            parts.add("\"state\": {\"kind\": " ++ j.(s[\kind]) ++ ", \"file\": " ++ j.(s[\file])
                ++ (d[\stateExtras] ? []).collect { |pair| ", " ++ j.(pair[0]) ++ ": " ++ pair[1] }.join ++ "}");
        };
        d[\settings] !? { |settings|
            // The type's own order, as its panel has them.
            names = MegaSAFx.paramsOf(d[\type]).collect { |p| p[\name] }.select { |n| settings.includesKey(n) };
            parts.add("\"settings\": {" ++ (names.collect { |n| j.(n) ++ ": " ++ this.class.number(settings[n]) }
                ++ (d[\settingsExtras] ? []).collect { |pair| j.(pair[0]) ++ ": " ++ pair[1] }).join(", ") ++ "}");
        };
        (d[\extras] ? []).do { |pair| parts.add(j.(pair[0]) ++ ": " ++ pair[1]) };
        ^"{" ++ parts.join(", ") ++ "}"
    }

    // What Keep's mark compares: the chains and their settings as text,
    // without the name, the stamp, the switches, the state files, what a
    // plugin says it is (known only once it has opened) and the ids' marks.
    // A footswitch pressed, a plugin's own knob turned, a plugin opening, or
    // a device inserted and taken back, is no unkept edit.
    contentString {
        ^this.prWrittenTracks.collect { |t|
            if(t[\raw].notNil) { t[\raw] } {
                t[\track].asString ++ ": " ++ t[\devices].collect { |d|
                    var e = d.copy;
                    e.put(\on, false);
                    e.removeAt(\state);
                    e.removeAt(\stateExtras);
                    e.removeAt(\plugin);
                    this.prDeviceString(e)
                }.join("; ")
            }
        }.join("\n")
    }

    // Whether `other` has the same devices in the same places: then a recall
    // moves no synth, and only settings and states go across.
    sameStructureAs { |other|
        ^this.class.trackNames.every { |n|
            this.devices(n).collect { |d| [d[\id], d[\type]] } == other.devices(n).collect { |d| [d[\id], d[\type]] }
        }
    }

    printOn { |stream| stream << "MegaSASound(" << name << ", " << this.devices.collect { |d| d[\id] } << ")" }
}
