// The mixer's levels kept per rig (scripts/setup-sa.scd, Start with this under
// Levels on Perform): kept for the rig megalooper runs on, beside the other
// rigs', in at the next start there, never the mutes, Reset to megalooper's
// own, and Start with this's mark. On a stub mixer; the user folder is a
// scratch one.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-megasa-levels");

{
var scripts = thisProcess.nowExecutingPath.dirname.dirname;
var root = ~tTempPath.("megasa-levels");
var was = (root: ~midiUserRootOverride, megaSA: ~megaSA, rp: ~rp, profile: ~routingProfile, start: ~saLevelsStart);
var mixer, keep, db, rigs, text, path, r;

if(~saKeepLevels.isNil) { (scripts +/+ "setup-sa.scd").load };
~midiUserRootOverride = root +/+ "user";
path = ~saKeptLevelsPath.();
// A mixer as MegaSA's: a level per strip, megalooper's own to start; the
// bass's strip only with an input for it.
mixer = { |bass = false|
    var levels = MegaSA.defaultLevels;
    if(bass.not) { levels.removeAt(\bass) };
    (levels: levels, mutes: (guitar: false, loop: false),
        level: { |self, k| self[\levels][k] },
        setLevel: { |self, k, amp| self[\levels].put(k, amp) },
        mute: { |self, k| self[\mutes][k] })
};
// Start with this, written at once here; answers [ok, why].
keep = { var res; ~saKeepLevels.({ |ok, why| res = [ok, why] }); res };
db = { |k| ~saLevelDb.(~megaSA.level(k)) };
rigs = { ~saReadKeptLevels.()[\rigs] };
// A start on a rig: its levels key (the audio settings' devices) or a rig
// of yours by its name, a fresh mixer, and what a boot does.
r = { |key, profile = \saSystem, inherit, bass = false|
    ~rp = (sa: true, levelsKey: key, inheritRig: inherit);
    ~routingProfile = profile;
    ~megaSA = mixer.(bass);
    ~saLevelsStart = nil;
    ~saLoadKeptLevels.()
};

~tAssert.("this test's files are under a scratch folder", path.beginsWith(PathName.tmp));

// ---- nothing kept ----------------------------------------------------------------
~tEq.("with nothing kept, a start loads nothing", r.("TSMEGA"), false);
~tEq.("...and the levels are megalooper's own", [\guitar, \loop, \drums, \onsetKit, \synth, \master].collect(db),
    [0, -3, -10.6, -15.7, -6, 0]);
~tEq.("...which is no mark on Start with this", ~saLevelsDirty.(), false);

// ---- kept for a rig --------------------------------------------------------------
~megaSA.setLevel(\guitar, -1.5.dbamp);
~megaSA.setLevel(\loop, -6.dbamp);
~megaSA[\mutes][\guitar] = true;
~tEq.("a level moved marks Start with this", ~saLevelsDirty.(), true);
~tEq.("Start with this keeps them", keep.(), [true, nil]);
~tEq.("...for this rig, in dB", [rigs.()["TSMEGA"][\guitar], rigs.()["TSMEGA"][\loop], rigs.()["TSMEGA"][\drums]],
    [-1.5, -6.0, -10.6]);
text = File.readAllString(path);
~tAssert.("...as a megalooper levels file", text.beginsWith("{\"format\": \"megalooper levels\", \"version\": 1"), text);
~tAssert.("...and not the mutes", text.contains("mute").not, text);
~tEq.("...and the mark is gone", ~saLevelsDirty.(), false);

// Another rig: the laptop's own devices. Nothing kept for it yet.
~tEq.("another rig starts with megalooper's own", [r.("MacBook Pro Microphone → MacBook Pro Speakers"), db.(\guitar)],
    [false, 0]);
~megaSA.setLevel(\drums, -20.dbamp);
~tEq.("...kept for it", keep.(), [true, nil]);
~tEq.("...beside the first rig's, which stays as it was",
    [rigs.()["MacBook Pro Microphone → MacBook Pro Speakers"][\drums], rigs.()["TSMEGA"][\guitar], rigs.()["TSMEGA"][\drums]],
    [-20.0, -1.5, -10.6]);

// The next start on the first rig.
~tEq.("the next start on a rig loads its levels", r.("TSMEGA"), true);
~tEq.("...those it kept", [\guitar, \loop, \drums].collect(db), [-1.5, -6, -10.6]);
~tEq.("...with no mark", ~saLevelsDirty.(), false);

// ---- rigs of yours ----------------------------------------------------------------
~tEq.("a rig of yours keeps them by its name", r.(nil, \myRig), false);
~megaSA.setLevel(\synth, -12.dbamp);
keep.();
~tEq.("...under it", rigs.()["myRig"][\synth], -12.0);
~tEq.("a setup that took its numbers from that rig starts with its levels", [r.("New Interface", \saSystem, \myRig), db.(\synth)],
    [true, -12]);
~tEq.("...and keeps its own under the setup", [keep.(), rigs.()["New Interface"].notNil], [[true, nil], true]);

// ---- strips there are and are not -------------------------------------------------
~tEq.("a rig without instrument 2 has no strip for it", [r.("TSMEGA"), ~megaSA.level(\bass)], [true, nil]);
r.("Duo", \saSystem, nil, true);
~megaSA.setLevel(\bass, -4.dbamp);
keep.();
~tEq.("...is kept where there is one", rigs.()["Duo"][\bass], -4.0);
~tEq.("...and a start without it has no strip for it", [r.("Duo"), ~megaSA.level(\bass), db.(\guitar)], [true, nil, 0]);
File.use(path, "w", { |f| f.write("{\"format\": \"megalooper levels\", \"version\": 1, \"rigs\": "
    ++ "{\"Hot\": {\"guitar\": 20, \"loop\": \"loud\", \"tuba\": -3}}}\n") });
~tEq.("a level above the faders' top comes in at +6 dB; what is not a level is left out",
    [r.("Hot"), db.(\guitar), db.(\loop)], [true, 6, -3]);

// ---- Reset --------------------------------------------------------------------------
File.delete(path);
r.("TSMEGA");
~megaSA.setLevel(\guitar, -9.dbamp);
keep.();
~saResetLevels.();
~tEq.("Reset: megalooper's own levels, now", [\guitar, \loop, \drums].collect(db), [0, -3, -10.6]);
~tEq.("...which differ from those kept, so the mark is there", ~saLevelsDirty.(), true);
~tEq.("...and the file still holds them", rigs.()["TSMEGA"][\guitar], -9.0);

// ---- a file that is not one --------------------------------------------------------
File.use(path, "w", { |f| f.write("not json") });
~tEq.("a file that can't be read loads nothing", r.("TSMEGA"), false);
~tEq.("...the levels are megalooper's own", db.(\guitar), 0);
~megaSA.setLevel(\guitar, -2.dbamp);
~tEq.("...and Start with this leaves it as it is, saying why", keep.()[0], false);
~tEq.("...untouched", File.readAllString(path), "not json");
File.use(path, "w", { |f| f.write("{\"format\": \"megalooper levels\", \"version\": 2, \"rigs\": {\"TSMEGA\": {\"guitar\": -2}}}") });
~tEq.("one from a newer megalooper is not read either", [r.("TSMEGA"), db.(\guitar)], [false, 0]);

// Everything as it was.
~midiUserRootOverride = was[\root];
~megaSA = was[\megaSA];
~rp = was[\rp];
~routingProfile = was[\profile];
~saLevelsStart = was[\start];
~tRemoveTree.(root);
~tAssert.("the scratch folder is gone again", File.exists(root).not);
}.value;
