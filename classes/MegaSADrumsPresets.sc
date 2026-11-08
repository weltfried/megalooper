// megalooper — the drums' presets as files: what a preset holds (both
// patterns whole, the two kits by key, every pad and group trim, Beat Repeat
// and its grid, the reverb, the offset and the dice), its JSON text, a file
// read and checked field by field (fail soft by field, reject by file) and
// applied, and the old SC-literal presets carried over once.
//
// A part of MegaSADrums (docs/dev/architecture.md 5, step 9; the drums' own
// until 2026-11-08): it reads the drums' state through their getters and
// applies a preset through their setters, as the Drums tab does. Saving,
// loading, the recall on the next bar line, Keep and the preset armed or
// loaded stay the drums' (their scheduler lands a recall), and ask it.
MegaSADrumsPresets {
    var drums;

    *new { |drums| ^super.newCopyArgs(drums) }

    // A folder's old presets (SC literals, <slug>.scd) carried over to JSON,
    // once (MegaFiles.migrateFolder: the .scd files stay where they are, and
    // a marker says the folder is done). One that does not read as a preset
    // is said. Answers the slugs carried over.
    migrate { |dir|
        ^MegaFiles.migrateFolder(dir, { |old, json| this.migrateFile(old, json) })
    }

    migrateFile { |old, json|
        ^MegaFiles.migrateFile(old, json, MegaSADrums.presetFormat, MegaSADrumsPresets.fieldOrder, { |why|
            ("MegaSADrums: " ++ old.basename ++ " was not carried over to JSON (" ++ why
                ++ "); it stays as it was, and is not read.").warn })
    }

    // What a preset holds, as an Event: kits as Strings (keys may have
    // dashes; "none" for a slot left without a kit, which an Event literal
    // could not hold as nil), trims as [kit, note or group, dB] rows.
    data { |name|
        var kitOf = { |slot| (drums.kit(slot) !? { |k| k.asString }) ? MegaSADrums.noKit };
        var rows = { |tables|
            var out = List.new;
            tables.keys.asArray.sort.do { |kit|
                tables[kit].keys.asArray.sort.do { |k|
                    out.add([kit.asString, if(k.isKindOf(Symbol)) { k.asString } { k }, tables[kit][k].asFloat]);
                };
            };
            out.asArray
        };
        ^(version: MegaSADrums.presetVersion, name: (name ? "").asString, savedAt: Date.getDate.stamp,
            stepsKit: kitOf.(\steps), onsetKit: kitOf.(\onset),
            repeats: drums.repeats, reverbMix: drums.reverbMix.asFloat, offsetMs: drums.offsetMs.asFloat,
            dice: drums.keptDice ? false, repeatGrid: drums.repeatGrid.asString,
            padTrims: rows.(drums.padTrims), groupTrims: rows.(drums.groupTrims),
            main: drums.patterns[\main].deepCopy, break: drums.patterns[\break].deepCopy)
    }

    // The file: JSON, one field a line, a lane of steps a line, so it reads
    // and hand-edits as the SC literal did (MegaFiles.jsonText). `data` as
    // presetData answers it, or an old preset's as it was read: every field
    // it holds is written.
    text { |data|
        ^MegaFiles.eventText(data, MegaSADrums.presetFormat, MegaSADrumsPresets.fieldOrder)
    }

    // A preset file read as an Event of its fields, or nil (why, in `notes`):
    // JSON only, nothing run. One that is not a drums preset, or is from a
    // newer megalooper, is refused whole.
    dataAt { |path, notes|
        ^MegaFiles.readEvent(path, MegaSADrums.presetFormat, MegaSADrums.presetVersion,
            "megalooper drums preset", { |why| notes.add(why) })
    }

    // Whole or not at all (MegaFiles.write): beside it, read back, moved over.
    write { |path, name|
        var why = MegaFiles.writeEvent(path, this.data(name), MegaSADrums.presetFormat, MegaSADrumsPresets.fieldOrder);
        if(why.notNil) { ("MegaSADrums preset: could not write " ++ path ++ " (" ++ why ++ ")").warn; ^false };
        ^true
    }

    read { |path, warnings, loud = true|
        var notes = List.new, data, clean;
        if(File.exists(path).not) {
            if(loud) { ("MegaSADrums preset: no such preset " ++ path.basename).warn };
            ^false
        };
        data = this.dataAt(path, notes);
        clean = data !? { this.validate(data, notes) };
        if(clean.isNil) {
            this.report(path, warnings, "rejected — ", notes);
            ^false
        };
        this.apply(clean);
        if(notes.notEmpty) { this.report(path, warnings, notes.size.asString ++ " correction(s) — ", notes) };
        ^true
    }

    report { |path, warnings, head, notes|
        if(warnings.notNil) { warnings.addAll(notes) } {
            ("MegaSADrums preset " ++ path.basename ++ ": " ++ head ++ notes.join("; ")).warn;
        };
    }

    // The whole check, before anything is touched: an Event of what to apply
    // (a field left out keeps what is playing), or nil to refuse the file.
    validate { |data, notes|
        var clean, version, known;
        var number = { |key, lo, hi|
            var v = data[key];
            case
            { v.isNil } { nil }
            { v.isNumber.not or: { v.isNaN } or: { v.abs == inf } } {
                notes.add(key.asString ++ " " ++ v.asCompileString ++ " is not a number (kept)");
                nil
            }
            { (v < lo) or: { v > hi } } {
                notes.add(key.asString ++ " " ++ v ++ " -> " ++ v.clip(lo, hi) ++ " (range)");
                v.clip(lo, hi)
            }
            { v }
        };
        // A kit's key, \none for "none" (or false: the slot emptied on
        // purpose), or nil to keep the kit playing.
        var kitKey = { |key, slot|
            var v = data[key];
            case
            { v.isNil } { nil }
            { (v == false) or: { (v.isKindOf(String) or: { v.isKindOf(Symbol) }) and: { v.asString == MegaSADrums.noKit } } } {
                \none
            }
            { (v.isKindOf(String) or: { v.isKindOf(Symbol) }).not or: { v.asString.isEmpty } } {
                notes.add(key.asString ++ " " ++ v.asCompileString ++ " is not a kit's key (kept)");
                nil
            }
            { drums.kitKeys.includes(v.asSymbol).not } {
                notes.add(key.asString ++ ": no kit " ++ v ++ " in " ++ drums.kitDir ++ " (the " ++ slot ++ " kit stays)");
                nil
            }
            { v.asSymbol }
        };
        if(data.isKindOf(Dictionary).not) { notes.add("not a preset (expected an Event)"); ^nil };
        version = data[\version] ? 1;
        if(version.isNumber.not) { notes.add("its version " ++ version.asCompileString ++ " is not a number"); ^nil };
        if(version.asInteger > MegaSADrums.presetVersion) {
            notes.add("version " ++ version ++ " is newer than this build (" ++ MegaSADrums.presetVersion ++ ")");
            ^nil
        };
        clean = (name: (data[\name] ? "").asString);
        [\main, \break].do { |which|
            var said = List.new;
            if(data[which].isNil) {
                notes.add("no " ++ which ++ " pattern -> the default");
                clean.put(which, MegaSASteps.livePattern(which));
            } {
                clean.put(which, MegaSASteps.cleanPattern(data[which], which, said));
                said.do { |s| notes.add(which.asString ++ ": " ++ s) };
            };
        };
        clean.put(\stepsKit, kitKey.(\stepsKit, \steps));
        clean.put(\onsetKit, kitKey.(\onsetKit, \onset));
        clean.put(\padTrims, this.cleanTrims(data[\padTrims], \padTrims, notes, { |k|
            if(k.isNumber and: { (k - k.round).abs < 1e-9 } and: { k >= 0 } and: { k <= 127 }) { k.round.asInteger }
        }));
        clean.put(\groupTrims, this.cleanTrims(data[\groupTrims], \groupTrims, notes, { |k|
            if((k.isKindOf(String) or: { k.isKindOf(Symbol) }) and: { k.asString.notEmpty }) { k.asSymbol }
        }));
        case
        { data[\repeats].isNil } { }
        { (data[\repeats] == true) or: { data[\repeats] == false } } { clean.put(\repeats, data[\repeats]) }
        { notes.add("drums.repeats " ++ data[\repeats].asCompileString ++ " is not true or false (kept)") };
        clean.put(\reverbMix, number.(\reverbMix, 0, 1));
        clean.put(\offsetMs, number.(\offsetMs, -15, 50));
        case
        { data[\dice].isNil } { }
        { data[\dice] == false } { clean.put(\dice, false) }
        { data[\dice].isInteger and: { data[\dice] >= 0 } } { clean.put(\dice, data[\dice]) }
        { notes.add("dice " ++ data[\dice].asCompileString ++ " is not a seed (0 or more) or false (kept)") };
        case
        { data[\repeatGrid].isNil } { }
        { #["bars", "live"].includesEqual(data[\repeatGrid].asString) } { clean.put(\repeatGrid, data[\repeatGrid].asSymbol) }
        { notes.add("drums.repeatGrid " ++ data[\repeatGrid].asCompileString ++ " is not \"bars\" or \"live\" (kept)") };
        known = #[\version, \name, \savedAt, \main, \break, \stepsKit, \onsetKit, \padTrims, \groupTrims,
            \repeats, \repeatGrid, \reverbMix, \offsetMs, \dice];
        data.keys.do { |k| if(known.includes(k).not) { notes.add(k.asString ++ " is no drums field (ignored)") } };
        ^clean
    }

    // Trim rows [kit, key, dB] as the tables keep them (kit -> key -> dB), or
    // nil for no field (the trims in force stay). A row that is not usable is
    // dropped, a level out of -24..+12 held to it.
    cleanTrims { |rows, label, notes, keyOf|
        var out;
        if(rows.isNil) { ^nil };
        if(rows.isKindOf(SequenceableCollection).not or: { rows.isString }) {
            notes.add(label.asString ++ " is not a list of [kit, key, dB] (the trims stay)");
            ^nil
        };
        out = IdentityDictionary.new;
        rows.do { |row|
            var kit, key, db;
            if(row.isKindOf(SequenceableCollection) and: { row.isString.not } and: { row.size == 3 }) {
                kit = row[0];
                key = keyOf.(row[1]);
                db = row[2];
            };
            if(((kit.isKindOf(String) or: { kit.isKindOf(Symbol) }) and: { kit.asString.notEmpty }).not
                or: { key.isNil } or: { db.isNumber.not } or: { db.isNaN } or: { db.abs == inf }) {
                notes.add(label.asString ++ " " ++ row.asCompileString ++ " is not [kit, key, dB] (dropped)");
            } {
                if((db < -24) or: { db > 12 }) {
                    notes.add(label.asString ++ " " ++ row.asCompileString ++ " -> " ++ db.clip(-24, 12) ++ " dB (range)");
                };
                if(out[kit.asSymbol].isNil) { out.put(kit.asSymbol, IdentityDictionary.new) };
                out[kit.asSymbol].put(key, db.clip(-24, 12).asFloat);
            };
        };
        ^out
    }

    // What presetData answered, applied as a preset file is: checked whole
    // first, and refused (false, nothing changed) if it does not hold.
    // `warnings`, a List, gets the corrections. An AI app's revert
    // (MegaRemote) puts the drums back so.
    applyData { |data, warnings|
        var notes = List.new, clean = this.validate(data, notes);
        warnings !? { |w| w.addAll(notes) };
        if(clean.isNil) { ^false };
        this.apply(clean);
        ^true
    }

    // Apply a checked preset through the setters, so every change reaches
    // the server and its notification: the kits first (setKit, if it names
    // others), the trims (each one that moved for the kits in the slots
    // notified), the drums.patterns, Beat Repeat and its grid, the reverb, the
    // offset and the dice.
    apply { |clean|
        var oldPads = drums.padTrims, oldGroups = drums.groupTrims;
        [[\stepsKit, \steps], [\onsetKit, \onset]].do { |pair|
            var key = clean[pair[0]];
            case
            { key == \none } { if(drums.kitEmptied(pair[1]).not) { drums.setKit(pair[1], nil) } }
            { key.notNil and: { key != drums.kit(pair[1]) } } { drums.setKit(pair[1], key) };
        };
        drums.prPutTrims(clean[\padTrims], clean[\groupTrims]);
        [\steps, \onset].do { |slot|
            var key = drums.kit(slot);
            key !? {
                this.trimsMoved(oldPads[key], drums.padTrims[key]).do { |note|
                    drums.prNotify(\padTrim, slot, note, drums.padTrim(slot, note));
                };
                this.trimsMoved(oldGroups[key], drums.groupTrims[key]).do { |group|
                    drums.prNotify(\groupTrim, slot, group, drums.groupTrim(slot, group));
                };
            };
        };
        [\main, \break].do { |which| drums.prReplacePattern(which, clean[which]) };
        clean[\repeats] !? { |flag| if(flag != drums.repeats) { drums.setRepeats(flag) } };
        clean[\repeatGrid] !? { |mode| drums.setRepeatGrid(mode) };
        clean[\reverbMix] !? { |v| drums.setReverbMix(v) };
        clean[\offsetMs] !? { |v| drums.setOffsetMs(v) };
        clean[\dice] !? { |v| drums.setDice(v) };
    }

    // The keys whose trims differ between two tables (key -> dB, either nil).
    trimsMoved { |a, b|
        var keys = IdentitySet.new;
        a !? { a.keys.do { |k| keys.add(k) } };
        b !? { b.keys.do { |k| keys.add(k) } };
        ^keys.asArray.select { |k| ((a !? { |t| t[k] }) ? 0) != ((b !? { |t| t[k] }) ? 0) }
    }

    // For the post window: what a save holds, in a few words.
    summary {
        var said = [\main, \break].collect { |w| w.asString ++ (if(drums.edited(w)) { " edited" } { " as shipped" }) };
        ^said.join(", ") ++ "; kits " ++ (drums.kit(\steps) ? "none") ++ " and " ++ (drums.kit(\onset) ? "none")
    }

    // The fields in the file's order: the header, the kits and the mix, the
    // trims, the drums.patterns, and a pattern's own; any others after, sorted.
    *fieldOrder {
        ^#[\version, \name, \savedAt, \stepsKit, \onsetKit, \repeats, \repeatGrid,
            \reverbMix, \offsetMs, \dice, \padTrims, \groupTrims, \main, \break, \steps, \lengths,
            \globalLength, \lock, \note, \altNote, \delay, \mute, \clockSpeed, \rollRate, \shuffle,
            \shuffleLength, \globalShuffle, \autoRetrigger, \autoTriggerRate] ++ MegaSASteps.subs
    }
}
