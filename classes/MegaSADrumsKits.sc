// megalooper — the drums' kits: the kits folder's index, the kit in each
// slot (\steps, Rhythmic Steps' kit; \onset, the onset notes'), its load and
// its level, the trims per kit key, and the sample buffers the kits share,
// freed a second after their last voice can have ended.
//
// A part of MegaSADrums (docs/dev/architecture.md 5, step 10; the drums' own
// until 2026-11-09): it holds the drums, reads their folder, server and wall
// clock, and says its changes as theirs (drums.prNotify: \kit, \kitState,
// \kitLevel, \padTrim, \groupTrim). The drums' old methods are its facade;
// the scheduler asks it for the kit in force (kitFor) and tells it which
// buffers a hit plays (noteBufferUse).
MegaSADrumsKits {
    var drums;
    // The index (MegaSADrums.scanKits), per slot the kit in force, the key
    // asked for, its state and the request serial, and the kit loading; the
    // buffers, shared by path, with the last time a voice of each can end and
    // when it is due to go, and the reads still on their way (MegaSAKit.load:
    // a load that needs a file another is reading waits for that read).
    var kitIndex, kitObjects, kitRequested, kitStates, kitSerials, loadingKits;
    var <bufferCache, bufferEnds, bufferFreeAt, readsInFlight;
    // Per kit key: note -> dB, and group -> dB (the layer trim).
    var <padTrims, <groupTrims;
    // reader.(server, path, done) for MegaSAKit.load; nil: Buffer.read.
    var <>kitReader;
    // Whether a kit is levelled as it loads: measured from its samples
    // (MegaSAKit.measureLevel) and its levelDb set to bring it to its slot's
    // reference (MegaSADrums.levelReference). On for a real server; on a
    // stub (the tests, the renders) the kits play their files' own levels
    // unless it is switched on (levelKits_).
    var <levelKits;

    *new { |drums| ^super.newCopyArgs(drums).init }

    init {
        kitObjects = (steps: nil, onset: nil);
        kitRequested = (steps: nil, onset: nil);
        kitStates = (steps: \unset, onset: \unset);
        kitSerials = (steps: 0, onset: 0);
        loadingKits = (steps: nil, onset: nil);
        bufferCache = IdentityDictionary.new;
        bufferEnds = IdentityDictionary.new;
        bufferFreeAt = IdentityDictionary.new;
        readsInFlight = IdentityDictionary.new;
        padTrims = IdentityDictionary.new;
        groupTrims = IdentityDictionary.new;
        levelKits = drums.server.isKindOf(Server);
    }

    // The folder moved: read its index again when next asked.
    forgetIndex { kitIndex = nil }

    // The drums freed: every buffer goes, and a load still on its way frees
    // what it brings (loaded).
    free {
        bufferCache.do { |b| b.free };
        bufferCache = IdentityDictionary.new;
        bufferFreeAt = IdentityDictionary.new;
        readsInFlight = IdentityDictionary.new;
        kitObjects = (steps: nil, onset: nil);
    }

    keys { ^this.index.keys.asArray.sort }

    info { |key| ^key !? { |k| this.index[k.asSymbol] } }

    // The kits that can sound on this Mac: those with a sample of theirs in
    // the kits folder. megalooper ships every kit's map, and the audio of two,
    // the Analog Kit and the Bolt Kit; the kits it was built on play
    // Ableton's. Only these are offered (the kit menus, the AI tool): a map
    // alone plays nothing. With none (a clone with the kits' folders gone),
    // the Drums pane says so and shows nothing else.
    withAudio { ^this.keys.select { |k| this.info(k)[\audio] == true } }

    // Read the folder again (a kit added while running).
    rescan { kitIndex = nil; ^this.index }

    index { ^kitIndex ?? { kitIndex = MegaSADrums.scanKits(drums.kitDir) } }

    // The key asked for last (the menu's), or nil.
    kit { |slot| ^if(drums.prSlotOk(slot, false)) { kitRequested[slot] } }

    // The MegaSAKit playing in the slot, or nil.
    kitFor { |slot| ^if(drums.prSlotOk(slot, false)) { kitObjects[slot] } }

    // Is the slot empty because it was asked to be (setKit(slot, nil): the
    // Drums tab's "— none —", a preset's or the kept drums' "none"), rather
    // than never given a kit? A boot fills only the slots never given one.
    emptied { |slot|
        ^drums.prSlotOk(slot, false) and: { kitRequested[slot].isNil } and: { kitSerials[slot] > 0 }
    }

    state { |slot| ^if(drums.prSlotOk(slot, false)) { kitStates[slot] } }

    levelKits_ { |on|
        levelKits = on == true;
        [\steps, \onset].do { |slot|
            [loadingKits[slot], kitObjects[slot]].do { |k| k !? { k.levelDb = this.levelFor(slot, k) } };
            kitObjects[slot] !? { |k| drums.prNotify(\kitLevel, slot, k.levelDb) };
        };
    }

    // The correction the slot's kit plays with, in dB (MegaSAKit.levelDb): 0
    // with levelKits off, or for a kit whose samples could not be measured;
    // nil with no kit in the slot.
    level { |slot| ^this.kitFor(slot) !? { |k| k.levelDb } }

    levelFor { |slot, kit|
        ^if(levelKits) { MegaSAKit.levelCorrection(kit.measureLevel(drums.kitDir), MegaSADrums.levelReference[slot]) } { 0 }
    }

    // Load a kit by key and swap it in when its buffers are in: notifies \kit,
    // slot, key at once, \kitLevel, slot, dB once it is measured (with
    // levelKits on), and \kitState, slot, state as it goes (\loading, then
    // \ready \partial \missing or \failed). action.(drums, state) hears the
    // final state. Each request has a serial: one overtaken by a later request
    // is dropped when it completes, its buffers freed if nothing else uses
    // them. The swap happens between two pumps, so no step plays half one kit.
    setKit { |slot, key, action|
        var serial, kit, path;
        if(drums.alive.not or: { drums.prSlotOk(slot, true).not }) { ^this };
        kitSerials[slot] = kitSerials[slot] + 1;
        serial = kitSerials[slot];
        if(key.isNil) {
            kitRequested[slot] = nil;
            kitObjects[slot] = nil;
            drums.prNotify(\kit, slot, nil);
            this.setState(slot, \unset);
            this.releaseBuffers;
            action.value(drums, \unset);
            ^this
        };
        key = key.asSymbol;
        kitRequested[slot] = key;
        drums.prNotify(\kit, slot, key);
        path = drums.kitDir !? { |d| MegaSAKit.fileFor(d, key) };
        kit = path !? { |p| MegaSAKit.read(p) };
        if(kit.isNil) {
            ("MegaSADrums: no kit " ++ key ++ " to read in " ++ drums.kitDir ++ "; the " ++ slot
                ++ " kit is silent.").warn;
            kitObjects[slot] = nil;
            this.setState(slot, \missing);
            this.releaseBuffers;
            action.value(drums, \missing);
            ^this
        };
        if(levelKits) {
            kit.levelDb = this.levelFor(slot, kit);
            drums.prNotify(\kitLevel, slot, kit.levelDb);
        };
        loadingKits[slot] = kit;
        this.setState(slot, \loading);
        kit.load(drums.server, drums.kitDir, bufferCache, { |k, state|
            if(state != \loading) { this.loaded(slot, serial, k, state, action) };
        }, kitReader, readsInFlight);
    }

    loaded { |slot, serial, kit, state, action|
        if(drums.alive.not) {
            // Kits sharing a file share its buffer, and free freed the cache:
            // only what is still allocated.
            kit.buffers.do { |b| if(b.bufnum.notNil) { b.free } };
            ^this
        };
        if(loadingKits[slot] === kit) { loadingKits[slot] = nil };
        if(serial != kitSerials[slot]) {
            this.releaseBuffers;
            ^this
        };
        kitObjects[slot] = kit;
        this.setState(slot, state);
        this.releaseBuffers;
        action.value(drums, state);
    }

    setState { |slot, state|
        kitStates[slot] = state;
        drums.prNotify(\kitState, slot, state);
    }

    // The pads of the slot's kit, by note.
    pads { |slot| ^((this.kitFor(slot) !? { |k| k.notes }) ? []) }

    padName { |slot, note| ^this.kitFor(slot) !? { |k| k.padName(note) } }

    // A pad's trim in dB, -24..+12, kept per kit key. Notifies \padTrim, slot,
    // note, db.
    padTrim { |slot, note| ^((this.trimTable(padTrims, slot) !? { |t| t[note] }) ? 0) }

    setPadTrim { |slot, note, db|
        var table;
        if(drums.prSlotOk(slot, true).not) { ^this };
        if(note.isNumber.not or: { db.isNumber.not } or: { db.isNaN }) {
            ("MegaSADrums: a pad trim is a note and dB, not " ++ [note, db].asCompileString).warn;
            ^this
        };
        table = this.trimTable(padTrims, slot, true);
        if(table.isNil) { ("MegaSADrums: no " ++ slot ++ " kit to trim.").warn; ^this };
        table.put(note.asInteger, db.clip(-24, 12));
        drums.prNotify(\padTrim, slot, note.asInteger, table[note.asInteger]);
    }

    // A group's trim in dB, -24..+12, per kit key: the layer trim of a kit
    // with two (the KJ stand-ins under Kit-Carbon). Notifies \groupTrim, slot,
    // group, db.
    groupTrim { |slot, group| ^((this.trimTable(groupTrims, slot) !? { |t| t[group ? \none] }) ? 0) }

    setGroupTrim { |slot, group, db|
        var table;
        if(drums.prSlotOk(slot, true).not) { ^this };
        if(group.isNil or: { db.isNumber.not } or: { db.isNaN }) {
            ("MegaSADrums: a group trim is a group and dB, not " ++ [group, db].asCompileString).warn;
            ^this
        };
        table = this.trimTable(groupTrims, slot, true);
        if(table.isNil) { ("MegaSADrums: no " ++ slot ++ " kit to trim.").warn; ^this };
        table.put(group.asSymbol, db.clip(-24, 12));
        drums.prNotify(\groupTrim, slot, group.asSymbol, table[group.asSymbol]);
    }

    trimTable { |tables, slot, create = false|
        var key = this.kit(slot);
        if(key.isNil) { ^nil };
        if(create and: { tables[key].isNil }) { tables.put(key, IdentityDictionary.new) };
        ^tables[key]
    }

    // Every cached buffer no kit in use (or being loaded) plays is freed a
    // second after its last voice can have ended.
    releaseBuffers {
        var wall = drums.wallClock.value, used = this.pathsInUse;
        bufferCache.keys.do { |path|
            if(used.includes(path)) { bufferFreeAt.removeAt(path) } {
                if(bufferFreeAt[path].isNil) {
                    bufferFreeAt.put(path, (wall + 1).max((bufferEnds[path] ? 0) + 1));
                };
            };
        };
    }

    // Each kit's files resolved against the folder it was loaded from, as its
    // buffers are cached: the folder may have moved since.
    pathsInUse {
        var used = IdentitySet.new;
        (kitObjects.values ++ loadingKits.values).do { |k|
            k !? { k.files(k.root).do { |p| used.add(p.asSymbol) } };
        };
        ^used
    }

    freeBuffers { |wall|
        var due, used;
        if(bufferFreeAt.isEmpty) { ^this };
        due = bufferFreeAt.keys.select { |path| bufferFreeAt[path] <= wall };
        if(due.isEmpty) { ^this };
        used = this.pathsInUse;
        due.do { |path|
            bufferFreeAt.removeAt(path);
            if(used.includes(path).not) {
                bufferEnds.removeAt(path);
                bufferCache.removeAt(path) !? { |b| b.free };
            };
        };
    }

    // When the last voice of each buffer a hit plays can end.
    noteBufferUse { |kit, layers, stamp|
        layers.do { |layer|
            var path = kit.pathFor(layer).asSymbol;
            var end = stamp + ((kit.soundingDur(layer) ? 10) + 0.005);
            if((bufferEnds[path] ? inf.neg) < end) { bufferEnds.put(path, end) };
        };
    }

    // A preset's trim tables in whole (per kit key), as it was saved: the
    // presets' part applies them here (nil: those left as they are).
    putTrims { |pads, groups|
        pads !? { padTrims = pads };
        groups !? { groupTrims = groups };
    }
}
