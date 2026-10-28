// The megalooper side of tools/test-megalooper-mcp.py's round trip: a
// MegaRemote on this sclang's own port, answering from a MegaSA on the stub
// server and a Looper stub with an uneven reading, in the harness's scratch
// user root (never yours), with a drum and a synth preset of its own there
// (load_drum_preset, load_synth_preset). Writes the handshake's path into the file named
// in argv[1] (stdout is block-buffered when piped, so a printed line would
// come too late), then answers until the file named in argv[0] appears, or
// 60 s pass.

(thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load;
{
var stop = thisProcess.argv[0], ready = thisProcess.argv[1], looper = ~tLooper.(), sa = MegaSA(~tStubServer.()), remote;
var drumsDir = ~tTrapRoot +/+ "drum-presets", synthDir = ~tTrapRoot +/+ "synth-presets", was;
looper.instVarPut(\lastResult, (numerator: 7, denominator: 8, bpm: 132.5, k: 4, sub: 1, n: 29,
    tau: 0.2264, loopDur: 6.566, bars: [7, 7, 7, 8], phase: 0, onsetCount: 40));
looper.instVarPut(\state, \playing);
// A take: hits on beat one of the first two bars (a sixteenth is 0.2264 / 2 s).
looper.instVarPut(\onsets, List[[0.0, 1.0], [1.5848, 0.5]]);
// The presets: the main pattern's first delay step at 11, the synth's root
// at 5; what plays stays as it was.
was = sa.drums.patterns[\main].deepCopy;
sa.drums.setPattern(\main, MegaRemote.mergePattern(was, (delay: [11])));
sa.drums.savePreset(drumsDir, "Peer Groove");
sa.drums.setPattern(\main, was);
was = MegaSANoteSeq.copyPattern(sa.drums.notes);
sa.drums.setNotes(MegaRemote.mergePattern(was, (root: 5)));
sa.saveSynthPreset(synthDir, "Peer Line");
sa.drums.setNotes(was);
remote = MegaRemote({ (looper: looper, sa: sa, profile: \sa, drumsPresetDir: drumsDir, synthPresetDir: synthDir) }).start;
// The reader waits for the whole path: it ends in remote.json.
ready !? { |p| File.use(p, "w", { |f| f.write(MegaRemote.handshakePath) }) };
Routine {
    var waited = 0;
    while { (stop.notNil and: { File.exists(stop) }).not and: { waited < 60 } } { 0.05.wait; waited = waited + 0.05 };
    remote.stop;
    sa.free;
    ~tRemoveTree.(~tTrapRoot);
    "PEER DONE".postln;
    0.exit;
}.play(AppClock);
}.value;
