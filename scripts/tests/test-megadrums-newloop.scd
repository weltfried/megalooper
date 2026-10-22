// A new loop with the drums off (MegaSADrums.newLoopOff, the Setup view's
// "New loop" switch): a first take starting to record switches PC 17 off, so
// the loop's Start runs the transport with the steps silent; overdubs and the
// other states leave the switch as it is, and with the option off nothing
// changes at all. The setting is kept in settings.json's "gui" part.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-megadrums-newloop");

{
var stub, sa, l, d, heard, said, saved, wasSave, wasSaved;

heard = { |obj, fn|
    var got = List.new, f = { |o, what ... more| got.add([what] ++ more) };
    obj.addDependant(f);
    protect { fn.value } { obj.removeDependant(f) };
    got.asArray
};

MegaSA.loadSynthDefs;
stub = ~tStubServer.();
sa = ~tMegaSA.(stub);
Synth.tail(stub[\defaultGroup], \looperMaster);
l = ~tLooper.();
Routine { sa.attachLooper(l) }.next;
d = sa.drums;

~tEq.("by default a new loop plays the drums, as Live's set did", [d.newLoopOff, d.on], [false, true]);
l.changed(\state, \recording);
~tEq.("...a take starting leaves them on", d.on, true);

d.newLoopOff = true;
said = heard.(d, { l.changed(\state, \recording) });
~tEq.("with the option on, a take starting switches them off, as PC 17 does", d.on, false);
~tAssert.("...and says so, so the switches on screen follow", said.any { |x| (x[0] == \on) and: { x[1] == false } }, said.asString);
l.changed(\state, \playing);
~tEq.("the loop's Start finds them off: the take ending does not switch them on", d.on, false);
d.setOn(true);
l.changed(\state, \overdubbing);
l.changed(\state, \playing);
l.changed(\state, \stopped);
~tEq.("switched on by hand, they stay on through an overdub and a stop", d.on, true);
l.changed(\state, \empty);
~tEq.("...and a clear", d.on, true);
l.changed(\state, \recording);
~tEq.("the next new loop switches them off again", d.on, false);
said = heard.(d, { l.changed(\state, \recording) });
~tAssert.("already off, nothing more is done", said.select { |x| x[0] == \on }.isEmpty, said.asString);

// ---- kept in settings.json, through setup-sa.scd's two functions ---------------
wasSave = ~guiPrefSave;
wasSaved = ~guiPrefSaved;
saved = ();
~guiPrefSave = { |key, value| saved.put(key.asSymbol, value) };
~guiPrefSaved = { |key| saved[key.asSymbol] };
(Looper.repoRoot +/+ "scripts" +/+ "setup-sa.scd").load;
~megaSA = sa;
~saDrumsNewLoopSet.(false);
~tEq.("the Setup view's switch sets the drums and keeps the choice", [d.newLoopOff, saved[\drumsNewLoop]], [false, "play"]);
~saDrumsNewLoopSet.(true);
~tEq.("...either way", [d.newLoopOff, saved[\drumsNewLoop]], [true, "off"]);
d.newLoopOff = false;
~saDrumsNewLoopApply.();
~tEq.("a boot applies what was kept", d.newLoopOff, true);
saved = ();
~saDrumsNewLoopApply.();
~tEq.("with nothing kept, the drums play", d.newLoopOff, false);
~guiPrefSave = wasSave;
~guiPrefSaved = wasSaved;
~megaSA = nil;
sa.free;
}.value;
