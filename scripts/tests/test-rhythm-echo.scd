// The Rhythm Echo's onsets (MegaSAOnsets; docs/dev/rhythm-echo.md, roadmap
// item 23 idea 4): the table and the IR's taps from the take's pattern, the
// buffers reaching a Rhythm Echo's start, and an update in its order. The
// sound itself is rendered by scripts/sa/nrt-rhythm-echo.scd.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-rhythm-echo");

// ---- the table and the taps ----------------------------------------------------
{
var pat = [[0, 1], [0.5, 0.25], [1.0, 0.64]], t, taps, lat = MegaSAFx.rhythmEchoLatency, slots = LooperSynthDefs.groupSlots;
t = MegaSAOnsets.table(pat, 1.5, 3.0);
~tEqArray.("a loop of the pattern twice: its onsets laid end to end", t[0].keep(6), [0, 0.5, 1.0, 1.5, 2.0, 2.5], 1e-9);
~tEqArray.("...their gains the strengths' square roots (accents kept, the quiet ones heard)", t[1].keep(6),
    [1, 0.5, 0.8, 1, 0.5, 0.8], 1e-9);
~tEq.("...six of them, the rest past any time", [t[2], t[0].drop(6).every { |v| v >= 1e9 }, t[0].size], [6, true, slots]);
t = MegaSAOnsets.table(nil, 1.5, 3.0);
~tEq.("no pattern: none", t[2], 0);
t = MegaSAOnsets.table(Array.fill(40, { |i| [i * 0.1, 1] }), 4.0, 8.0);
~tEq.("never more than the buffers' slots", t[2], slots);

taps = MegaSAOnsets.taps(pat, 1, 48000);
~tEq.("the IR's taps: the onsets after the first, from it, PartConv's delay earlier",
    taps, [[24000 - lat, 0.5], [48000 - lat, 0.8]]);
taps = MegaSAOnsets.taps(pat, 0.5, 48000);
~tEq.("...at half-time twice as far apart", taps.collect(_[0]), [48000 - lat, 96000 - lat]);
taps = MegaSAOnsets.taps([[0, 1], [0.01, 1], [3, 1], [9, 1]], 1, 48000);
~tEq.("...one closer than PartConv's delay, or past the IR's 8 s, left out", taps.collect(_[0]), [144000 - lat]);
~tEq.("a pattern of one onset has no taps", MegaSAOnsets.taps([[0, 1]], 1, 48000), []);
}.value;

// ---- on MegaSA -------------------------------------------------------------------
{
var srv = ~tStubServer.(), sa = ~tMegaSA.(srv), o = sa.onsets, d, args, told = List.new, r, msgs, from;
~tAssert.("MegaSA makes the onsets' buffers as it builds", o.notNil and: { o.irBuf.notNil });
d = sa.insertDevice(\guitar, nil, \rhythmEcho);
args = ~tStartArgs.(srv, sa.fxNode(d.id));
~tEq.("a Rhythm Echo starts with the onsets' buffers, never buffer 0",
    [args[\onsetsBuf], args[\gainsBuf], args[\irBuf]], [o.onsetsBuf.bufnum, o.gainsBuf.bufnum, o.irBuf.bufnum]);
~tEq.("...and no loop yet: no echo", [args[\loopDur], args[\onsetCount]], [0, 0]);
args = ~tStartArgs.(srv, sa.fxNode(\delay));
~tAssert.("a device that reads no onsets starts without them", args[\irBuf].isNil);

// An update, stepped: ducked, the IR zeroed, its taps, prepared, the onsets,
// then what they hold.
o.tell = { |c| told.add(c) };
from = srv[\msgs].size;
r = Routine { o.prApply([[0, 1], [0.5, 0.25], [1.0, 0.64]], 1.5, 3.0, 1) };
while { r.next.notNil } { };
msgs = srv[\msgs].copyToEnd(from).collect { |m| m[0].asString.replace("/", "").asSymbol };
~tEq.("an update: ducked first, then said with what it holds", [told.first, ().putPairs(told.last)[\loopDur],
    ().putPairs(told.last)[\onsetCount], ().putPairs(told.last)[\irReady]], [[\irReady, 0], 3.0, 6, 1]);
~tAssert.("...the IR zeroed, its taps set, prepared, the onsets written, in that order",
    { var at = { |cmd| msgs.indexOf(cmd) };
      [\b_zero, \b_set, \b_gen, \b_setn].every { |c| at.(c).notNil } and: { at.(\b_zero) < at.(\b_set) }
          and: { at.(\b_set) < at.(\b_gen) } and: { at.(\b_gen) < at.(\b_setn) } }.value, msgs.asString);
~tEq.("...and a device built after it starts with them", [().putPairs(o.args)[\loopDur], ().putPairs(o.args)[\perPattern]], [3.0, 3]);
sa.free;
}.value;

~tReport.();
