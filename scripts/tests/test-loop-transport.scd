// The transports that follow the loop (LoopTransport, the Looper's own code
// until 2026-11-09): the boundary a Start aims at, Live's clock stream and
// its Start aimed early by the port's latency and the sync trim, the count a
// reading asks, a reading's new tempo and its Start again (kept to itself in
// Live while a set is recorded), Stop, free and Cmd-period. MegaSATransport,
// the drums' sibling, is tested with the drums (test-megadrums.scd). The
// clock routine is stepped by hand, each tick at its own logical time.

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-loop-transport");

{
var at = { |w, fn| var out; Routine { thisThread.seconds = w; out = fn.value }.next; out };
var port = (log: List.new, latency: 0.05);
var transport, r, w, dt, startAt, ticks, n, now = 100.0, b;
port[\start] = { |self| self[\log].add([\start, thisThread.seconds]); self };
port[\stop] = { |self| self[\log].add([\stop, thisThread.seconds]); self };
port[\midiClock] = { |self| self[\log].add([\tick, thisThread.seconds]); self };

// ---- the boundary ---------------------------------------------------------------------
~tEq.("a Start's boundary: the first from the origin at least a beat and the latency on",
    LoopTransport.startBoundary(100.0, 120, 2.0, 99.75, 0.1), 101.75);
~tEq.("...one closer than the pre-roll is skipped (never a partial pass)",
    LoopTransport.startBoundary(100.0, 120, 2.0, 98.5, 0.1), 102.5);
~tEq.("...and with no loop length, none", LoopTransport.startBoundary(100.0, 120, nil, 99.0), nil);

// ---- Live's -----------------------------------------------------------------------------
transport = LiveMidiTransport({ port });
~tEq.("Live's: connected while there is a port; a Start relocates (the arrangement)",
    [transport.connected, transport.startsRelocate, transport.running], [true, true, false]);
~tEq.("...no port, not connected", LiveMidiTransport({ nil }).connected, false);
transport.syncMs = -20;
at.(now, { transport.start(120, 2.0, 99.75) });
r = transport.routine;
~tEq.("start: the clock runs, no count before the Start", [transport.running, transport.ticksAt(102)], [true, nil]);
// Step the stream tick by tick to two seconds on.
w = now;
while { w < (now + 2.0) } { dt = at.(w, { r.next }); w = w + dt };
startAt = (101.75 - 0.05) + -0.02;
n = port[\log].detect { |e| e[0] == \start };
~tAssert.("the clock streams from the start, before the Start", port[\log].first[0] == \tick and: { port[\log].first[1] == now });
~tAssert.("the Start goes on the first tick at or after the boundary less the port's latency and the trim",
    n.notNil and: { n[1] >= (startAt - 1e-9) } and: { n[1] < (startAt + (60 / (120 * 24))) }, n.asString);
ticks = port[\log].select { |e| e[0] == \tick };
~tNear.("...the ticks 24 a beat", ticks[1][1] - ticks[0][1], 60 / (120 * 24), 1e-9);
~tNear.("the count begins on the boundary, not the tick it went on", transport.ticksAt(102.75), 48, 1e-9);
// The trim moved while the clock runs: folded into the ticks, half a tick at most each.
port[\log] = List.new;
transport.syncMs = 0;
dt = at.(w, { r.next });
~tNear.("a trim moved while it runs nudges the next tick (at most half a tick)", dt, (60 / (120 * 24)) * 1.5, 1e-9);
dt = at.(w + dt, { r.next });
~tNear.("...the rest the tick after", dt, (60 / (120 * 24)) + (0.02 - ((60 / (120 * 24)) * 0.5)), 1e-9);

// A reading lands at 103.75 at 90 BPM: the count carried there, the period moved.
b = transport.ticksAt(103.75);
transport.landTempo(90, 103.75, false, false);
~tNear.("a reading's tempo: the count goes on from where it stood", transport.ticksAt(103.75), b, 1e-9);
~tNear.("...at the new rate", transport.ticksAt(104.75) - transport.ticksAt(103.75), 36, 1e-9);
~tNear.("...and the clock ticks at it", transport.clockPeriod, 60 / (90 * 24), 1e-12);
port[\log] = List.new;
at.(105.0, { transport.landTempo(90, 105.0, true, true) });
~tEq.("one that restarts while a set is recorded keeps its Start to itself in Live", port[\log].size, 0);
at.(105.5, { transport.landTempo(90, 105.5, true, false) });
~tEq.("...not recording, Start again", port[\log].asArray, [[\start, 105.5]]);
~tNear.("...and the count from that boundary", transport.ticksAt(106.5), 36, 1e-9);
port[\log] = List.new;
transport.free(false);
~tEq.("free without a Stop: the clock stops, nothing said", [transport.running, port[\log].size], [false, 0]);
at.(now, { transport.start(120, 2.0, 99.75) });
r = transport.routine;
at.(107.0, { transport.stop });
// (Stop itself goes to the port too, which an Event stub can't see: Object
// answers stop. The drums' sibling is checked saying it, test-megadrums.scd.)
~tEq.("stop: the clock stops", transport.running, false);
~tEq.("...the routine with it", r.next, nil);
at.(now, { transport.start(120, nil, nil) });
r = transport.routine;
port[\log] = List.new;
w = now;
while { w < (now + 1.0) } { dt = at.(w, { r.next }); w = w + dt };
n = port[\log].detect { |e| e[0] == \start };
~tAssert.("with no loop to align to, the Start goes a beat in (and the trim)", n.notNil and: { (n[1] - (now + 0.5)).abs < (60 / (120 * 24)) });
~tEq.("...and no count (no boundary to count from)", transport.ticksAt(now + 1), nil);
transport.forget;
~tEq.("forget (Cmd-period stopped its routine): not running", transport.running, false);
r.stop;
}.value;

// ---- the Looper's ----------------------------------------------------------------------
// Live's on its midiOut unless another is put there; transportMode \off
// starts nothing; the Live sync trim goes to Live's.
{
var l = ~tLooper.(), port = (latency: 0, log: List.new), sa, old;
port[\start] = { |self| self[\log].add(\start); self };
port[\stop] = { |self| self[\log].add(\stop); self };
port[\midiClock] = { |self| self };
~tPut.(l, \midiOut, port);
~tEq.("the Looper's transport is Live's, on its MIDI port", [l.transport.class, l.transport.port === port], [LiveMidiTransport, true]);
l.abletonSyncMs = -15;
~tEq.("the Live sync trim is handed to it", l.transport.syncMs, -15);
l.transportMode = \off;
l.startMidiClock(120, 2.0);
~tEq.("transportMode \\off starts nothing", l.midiClockRunning, false);
l.transportMode = \full;
l.startMidiClock(120, 2.0);
~tEq.("\\full starts it", l.midiClockRunning, true);
sa = MegaSATransport((alive: true, lead: 0.1, transportStart: { |self| self }, transportStop: { |self| self }));
old = l.transport;
l.transport = sa;
~tEq.("another transport put in: the old clock stops, saying nothing",
    [old.running, port[\log].asArray, l.transport === sa, l.startsRelocate], [false, [], true, false]);
l.transport = nil;
~tEq.("nil: Live's again", l.transport.class, LiveMidiTransport);
~tEq.("...with the trim", l.transport.syncMs, -15);
try { l.free } { |err| ~tFail.("free threw", err.errorString) };
}.value;
