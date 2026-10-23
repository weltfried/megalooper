// A synth file (docs/dev/synth.md, Phase 3): the note sequencer's pattern
// (MegaSANoteSeq) and the Wave synth's settings (MegaSAWave), together, as
// JSON. What the Synth view's presets are (sa/synth-presets/<slug>.json in
// your megalooper folder) and what Keep writes for the next boot
// (sa/kept-synth/synth.json). MegaSA reads and writes them.
//
//   {"format": "megalooper synth", "version": 1, "name": "…",
//    "notes": {"stepCount": 16, "first": 1, …, "steps": [true, …],
//              "lanes": {"pitch": {"values": [0, …], "own": false, …}, …}},
//    "wave": {"waveASet": 0, …}, "waveTable": "my-table.wav" or null}
//
// waveTable names your table (MegaSAWave.loadTable) in your wavetables folder
// (MegaSAWave.tableDir), or null for none. instrument is the catalog key of
// the instrument plugin that plays the notes (MegaSA.setInstrument), or null
// for the Wave synth; instrumentState its sound, a file beside this one.
//
// Read fail-soft, field by field: a value out of its range is held to it, one
// that is no value of its field (or a field this build has not) is left out
// and said in `warnings`, and what is missing stays at its default. A file
// that is not a synth file, or is from a newer megalooper, is refused whole.
MegaSASynthFile {

    *formatName { ^"megalooper synth" }
    *formatVersion { ^1 }

    // The file's text for a pattern and settings (name -> value).
    *text { |name, notes, wave, table, instrument, instrumentState|
        var j = { |x| MegaFiles.json(x) };
        var settings = MegaSANoteSeq.settingNames.collect { |k| j.(k.asString) ++ ": " ++ j.(notes[k]) };
        var lanes = MegaSANoteSeq.laneNames.collect { |k|
            var l = notes[\lanes][k];
            "    " ++ j.(k.asString) ++ ": {" ++ MegaSANoteSeq.laneSettingNames.collect { |s|
                j.(s.asString) ++ ": " ++ j.(l[s]) }.join(", ") ++ ", \"values\": " ++ j.(l[\values]) ++ "}"
        };
        ^"{\"format\": " ++ j.(this.formatName) ++ ", \"version\": " ++ this.formatVersion ++ ",\n"
            ++ " \"name\": " ++ j.((name ? "synth").asString) ++ ",\n"
            ++ " \"notes\": {" ++ settings.join(", ") ++ ",\n  \"steps\": " ++ j.(notes[\steps]) ++ ",\n"
            ++ "  \"lanes\": {\n" ++ lanes.join(",\n") ++ "}},\n"
            ++ " \"wave\": {" ++ MegaSAWave.params.collect { |p| j.(p[\name].asString) ++ ": " ++ j.(wave[p[\name]]) }.join(", ")
            ++ "},\n \"waveTable\": " ++ j.(table) ++ ",\n \"instrument\": " ++ j.(instrument)
            ++ ", \"instrumentState\": " ++ j.(instrumentState) ++ "}\n"
    }

    // (name:, notes:, wave:) from a file, or nil (said in `warnings`, a List,
    // or posted when there is none).
    *read { |path, warnings|
        var text = MegaFiles.readText(path), obj, why;
        var say = { |msg| if(warnings.notNil) { warnings.add(msg) } { ("MegaSA synth: " ++ msg).warn } };
        if(text.isNil) { say.((path ? "nil").asString.basename ++ " is not there or can't be read"); ^nil };
        obj = MegaFiles.parseObject(text);
        if(obj.isString) { say.(path.basename ++ ": " ++ obj); ^nil };
        why = MegaFiles.versionOf(obj, this.formatName, this.formatVersion, "megalooper synth file");
        if(why.isString) { say.(path.basename ++ ": " ++ why); ^nil };
        ^this.fromObject(obj, warnings ?? { List.new })
    }

    // From a parsed file (MegaFiles.parseObject). A Symbol's field is read
    // from its string.
    *fromObject { |obj, warnings|
        var notes = MegaSANoteSeq.defaultPattern, wave = IdentityDictionary.new;
        var n = obj.at("notes"), w = obj.at("wave"), lanes, steps;
        var symbolic = #[\direction, \restart];
        var put = { |where, name, v, setter|
            var x = if(symbolic.includes(name) and: { v.isString }) { v.asSymbol } { v };
            if(v.notNil and: { setter.value(x).isNil }) {
                warnings.add(where ++ " " ++ name ++ ": " ++ MegaFiles.json(v) ++ " is not one of its values; left at "
                    ++ MegaFiles.json(notes[name]))
            };
        };
        if(n.isKindOf(MegaJsonObject)) {
            // stepCount first: it limits the ranges the others go into.
            ([\stepCount] ++ MegaSANoteSeq.settingNames.reject { |k| k == \stepCount }).do { |k|
                put.("notes", k, n.at(k.asString), { |x| MegaSANoteSeq.putSetting(notes, k, x) });
            };
            steps = n.at("steps");
            if(steps.isArray) {
                steps.keep(16).do { |v, i| if(v.isKindOf(Boolean)) { notes[\steps][i] = v } };
            };
            lanes = n.at("lanes");
            if(lanes.isKindOf(MegaJsonObject)) {
                MegaSANoteSeq.laneNames.do { |lane|
                    var l = lanes.at(lane.asString);
                    if(l.isKindOf(MegaJsonObject)) {
                        MegaSANoteSeq.laneSettingNames.do { |k|
                            put.(lane.asString, k, l.at(k.asString), { |x| MegaSANoteSeq.putLaneSetting(notes, lane, k, x) });
                        };
                        if(l.at("values").isArray) {
                            l.at("values").keep(16).do { |v, i| if(v.isNumber) { MegaSANoteSeq.putValue(notes, lane, i, v) } };
                        };
                    };
                };
            };
        } {
            if(n.notNil) { warnings.add("notes is not an object; the pattern is the default") };
        };
        MegaSAWave.params.do { |p| wave.put(p[\name], p[\spec].default) };
        if(w.isKindOf(MegaJsonObject)) {
            w.keys.do { |k, i|
                var v = w.values[i], c = MegaSAWave.constrain(k.asSymbol, v);
                if(c.isNil) { warnings.add("wave " ++ k ++ ": " ++ MegaFiles.json(v) ++ " is no setting of this build's") }
                    { wave.put(k.asSymbol, c) };
            };
        };
        MegaSANoteSeq.keepRange(notes);
        ^(name: obj.at("name") !? { |x| x.asString }, notes: notes, wave: wave,
            table: obj.at("waveTable") !? { |x| if(x.isString) { x } },
            instrument: obj.at("instrument") !? { |x| if(x.isString) { x } },
            instrumentState: obj.at("instrumentState") !? { |x| if(x.isString) { x } })
    }
}
