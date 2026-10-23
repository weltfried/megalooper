// megalooper as a tool for an AI app (MegaRemote, docs/dev/ai-tool.md, Phase 0):
// who may ask (127.0.0.1 and this boot's token, an id that names nothing
// but its own two files), what is answered (ping, the context, what every
// setting means), and that every answer is JSON that reads back. The OSC
// round trip itself is tools/megalooper-mcp.py's check
// (tools/test-megalooper-mcp.py).

if(~tAssert.isNil) { (thisProcess.nowExecutingPath.dirname +/+ "_harness.scd").load };
~tFile.("test-megaremote");

{
var ask, r, got, o, ctx, stub, sa, looper, here, there, ids, path, text, other, reading;

// The request's text answered, as it reads back from its JSON.
ask = { |remote, text| MegaFiles.parseObject(MegaFiles.json(remote.handle(text))) };

// ---- the requests ------------------------------------------------------------------
r = MegaRemote({ (looper: nil, sa: nil, profile: \sa) });
got = ask.(r, "{\"command\": \"ping\"}");
~tEq.("a ping is answered with the format, its version and the pid",
    [got.at("ok"), got.at("result").at("format"), got.at("result").at("version"), got.at("result").at("pid")],
    [true, "megalooper remote", 1, thisProcess.pid]);
got = ask.(r, "{\"command\": \"tune the guitar\"}");
~tEq.("a command there is not is refused, naming those there are",
    [got.at("ok"), got.at("error").contains("ping, context, describe")], [false, true]);
got = ask.(r, "tune the guitar");
~tEq.("...as is a request that is not JSON", [got.at("ok"), got.at("error").contains("not JSON")], [false, true]);
got = ask.(r, nil);
~tEq.("...or none at all (the request file was gone)", [got.at("ok"), got.at("error").contains("empty")], [false, true]);
got = ask.(r, "{\"command\": \"describe\", \"args\": [1]}");
~tEq.("...and args that are not an object", [got.at("ok"), got.at("error")], [false, "args must be an object"]);

// ---- describe ----------------------------------------------------------------------
got = ask.(r, "{\"command\": \"describe\"}");
~tEq.("describe with no topic lists the topics", got.at("result").at("topics"), ["drums", "synth", "effects"]);
got = ask.(r, "{\"command\": \"describe\", \"args\": {\"topic\": \"kazoo\"}}");
~tEq.("...a topic there is not is refused", [got.at("ok"), got.at("error").contains("drums, synth, effects")], [false, true]);

got = ask.(r, "{\"command\": \"describe\", \"args\": {\"topic\": \"drums\"}}").at("result");
o = got.at("settings").detect { |row| row.at("name") == "clockSpeed" };
~tEq.("the drums: every pattern setting, with its range, its choices and its tip",
    [got.at("settings").size, o.at("min"), o.at("max"), o.at("choices")[3], o.at("tip").contains("16th")],
    [MegaSASteps.paramSpecs.size, 0, 5, [3, "100 %"], true]);
~tEq.("...the lane settings, the pages, the step values, and how a pattern works",
    [got.at("laneSettings").size, got.at("pages"), got.at("stepValues").at("max"),
        got.at("velocities"), got.at("about").contains("bar line")],
    [MegaSASteps.laneParamSpecs.size, ["chance", "velo", "alt", "roll", "slide"], 6,
        MegaSASteps.velocities.asArray, true]);
o = got.at("laneSettings").detect { |row| row.at("name") == "mute" };
~tEq.("...a switch says it is one, and has no range", [o.at("switch"), o.at("min")], [true, nil]);

got = ask.(r, "{\"command\": \"describe\", \"args\": {\"topic\": \"synth\"}}").at("result");
~tEq.("the synth: its lanes with their ranges, the scales, the divisions, the Wave synth's settings",
    [got.at("lanes").collect { |l| l.at("name") }, got.at("lanes")[0].at("min"), got.at("lanes")[0].at("max"),
        got.at("scales").size, got.at("scales")[1], got.at("divisions")[4], got.at("wave").size],
    [MegaSANoteSeq.laneNames.collect(_.asString), -12, 12, MegaSANoteSeq.scales.size,
        [1, "Minor", [0, 2, 3, 5, 7, 8, 10]], [4, "1/16"], MegaSAWave.params.size]);

got = ask.(r, "{\"command\": \"describe\", \"args\": {\"topic\": \"effects\"}}").at("result");
o = got.at("effects").detect { |e| e.at("key") == "shifter" };
~tEq.("the effects: every type, its chain, what it does, and its settings",
    [got.at("effects").size, o.at("track"), o.at("about"), o.at("settings").size],
    [MegaSAFx.types.size, "guitar", MegaSAFx.type(\shifter)[\blurb], MegaSAFx.paramsOf(\shifter).size]);
o = o.at("settings").detect { |row| row.at("name") == "shifterCoarse" };
~tEq.("...a setting as the window has it: range, step, units, bipolar, the tip on one line",
    [o.at("min"), o.at("max"), o.at("step"), o.at("units"), o.at("bipolar"), o.at("tip").contains("\n")],
    [-24, 24, 1, "st", true, false]);

// ---- the context -------------------------------------------------------------------
got = ask.(r, "{\"command\": \"context\"}").at("result");
~tEq.("with no Looper and no SA the context says so, with nulls",
    [got.at("profile"), got.at("standalone"), got.at("loop"), got.at("drums"), got.at("chains"), got.includesKey("tempo")],
    ["sa", false, nil, nil, nil, true]);

looper = ~tLooper.();
reading = (numerator: 7, denominator: 8, bpm: 132.5, k: 4, sub: 1, n: 29, tau: 0.2264, loopDur: 6.566,
    bars: [7, 7, 7, 8], phase: 0, onsetCount: 40);
looper.instVarPut(\lastResult, reading);
looper.instVarPut(\state, \playing);
o = MegaRemote.loopOf(looper);
~tEq.("the loop: its state and its reading, uneven bars as the window shows them",
    [o.at("state"), o.at("reading").at("signature"), o.at("reading").at("bars"), o.at("reading").at("barCount"),
        o.at("reading").at("bpm"), o.at("reading").at("loopSeconds"), o.at("reading").at("byHand")],
    ["playing", "7+7+7+8/8", [7, 7, 7, 8], 4, 132.5, 6.566, false]);
looper.instVarPut(\lastResult, (numerator: 7, denominator: 8, bpm: 140, k: 2, sub: 1, loopDur: 3.43, from: \hand));
o = MegaRemote.loopOf(looper).at("reading");
~tEq.("...even bars are listed all the same, and a reading given by hand says so",
    [o.at("signature"), o.at("bars"), o.at("byHand")], ["7/8", [7, 7], true]);
looper.instVarPut(\lastResult, (numerator: nil, denominator: nil, bpm: nil, error: \insufficientOnsets));
~tEq.("...a reading that found nothing is none", MegaRemote.loopOf(looper).at("reading"), nil);

stub = ~tStubServer.();
sa = ~tCheck.("a MegaSA is made on the stub", { MegaSA(stub) });
if(sa.notNil) {
    looper.instVarPut(\lastResult, reading);
    r = MegaRemote({ (looper: looper, sa: sa, profile: \sa) });
    text = MegaFiles.json(r.handle("{\"command\": \"context\"}"));
    got = MegaFiles.parseObject(text);
    ~tAssert.("the whole context is JSON that reads back", got.isKindOf(MegaJsonObject), text.keep(200));
    ctx = got.at("result");
    ~tEq.("...the profile, the loop's reading", [ctx.at("standalone"), ctx.at("loop").at("reading").at("signature")],
        [true, "7+7+7+8/8"]);
    o = ctx.at("drums").at("patterns").at("main");
    ~tEq.("...both drum patterns, every page of every lane as the model holds it",
        [o.at("steps").at("chance"), o.at("steps").at("velo"), o.at("note"), o.at("clockSpeed"),
            ctx.at("drums").at("patterns").at("break").at("note")],
        [sa.drums.patterns[\main][\steps][\chance], sa.drums.patterns[\main][\steps][\velo],
            sa.drums.patterns[\main][\note], sa.drums.patterns[\main][\clockSpeed], sa.drums.patterns[\break][\note]]);
    ~tEq.("...the drums' switches and their kits",
        [ctx.at("drums").at("on"), ctx.at("drums").at("breakActive"), ctx.at("drums").at("kits").class],
        [sa.drums.on, false, Array]);
    o = ctx.at("synth");
    ~tEq.("...the note sequence, and what plays it",
        [o.at("notes").at("lanes").at("pitch").at("values"), o.at("notes").at("scale"), o.at("instrument"),
            o.at("wave").size],
        [sa.drums.notes[\lanes][\pitch][\values], sa.drums.notes[\scale], "wave", sa.wave.settings.size]);
    ids = ctx.at("chains").collect { |c| [c.at("track"), c.at("devices").collect { |d| d.at("id") }] };
    ~tEq.("...every chain, its devices in order", ids,
        sa.chains.collect { |c| [c.track.asString, c.devices.collect { |d| d.id.asString }.asArray] });
    o = ctx.at("chains")[0].at("devices")[0];
    ~tEq.("...each with its switch and its settings",
        [o.at("on"), o.at("settings").at("shifterCoarse")], [sa.guitarChain.devices[0].on,
            sa.guitarChain.devices[0].param(\shifterCoarse)]);
    sa.free;
};

// ---- who may ask -------------------------------------------------------------------
~tEq.("an id is letters, digits and dashes, 1 to 64 of them",
    ["a-1", "A", "x" ! 64, "", "x" ! 65, "../x", "a/b", "a.b", "a b"].collect { |s|
        MegaRemote.idOk(if(s.isKindOf(Array)) { s.join } { s }) },
    [true, true, true, false, false, false, false, false, false]);
~tEq.("only 127.0.0.1 is local",
    [NetAddr("127.0.0.1", 1), NetAddr("192.168.1.5", 1), NetAddr("0.0.0.0", 1), nil].collect { |a| MegaRemote.isLocal(a) },
    [true, false, false, false]);
o = MegaRemote.newToken;
~tEq.("a token is 32 hex digits, and a new one each time",
    [o.size, o.every { |c| c.isDecDigit or: { "abcdef".includes(c) } }, o == MegaRemote.newToken], [32, true, false]);

protect {
    MegaFiles.alwaysSync = true;
    r = MegaRemote({ (looper: nil, sa: nil, profile: \sa) });
    r.start(57999);
    here = NetAddr("127.0.0.1", 50000);
    there = NetAddr("192.168.1.5", 50000);
    o = MegaFiles.parseObject(MegaFiles.readText(MegaRemote.handshakePath));
    ~tEq.("start writes the handshake: the port, this boot's token, the pid, where the files go",
        [o.at("format"), o.at("port"), o.at("token"), o.at("pid"), o.at("oscPath"), o.at("dir")],
        ["megalooper remote", 57999, r.token, thisProcess.pid, "/megalooper/remote", MegaRemote.dir]);
    ~tEq.("...for you alone to read (mode 600)",
        ("ls -l " ++ MegaRemote.handshakePath.shellQuote).unixCmdGetStdOut.keep(10), "-rw-------");
    ~tAssert.("...and listens", OSCdef.all[\megalooperRemote].notNil and: { OSCdef.all[\megalooperRemote].enabled });

    path = { |id| File.use(MegaRemote.requestPath(id), "w", { |f| f.write("{\"command\": \"ping\"}") }) };
    path.("t-1");
    r.receive([MegaRemote.oscPath, r.token, 't-1'], here);
    got = MegaFiles.parseObject(MegaFiles.readText(MegaRemote.replyPath("t-1")));
    ~tEq.("a request from here with the token is answered in its reply file, and its request goes",
        [got.isKindOf(MegaJsonObject) and: { got.at("ok") }, File.exists(MegaRemote.requestPath("t-1"))], [true, false]);
    path.("t-2");
    r.receive([MegaRemote.oscPath, r.token, 't-2'], there);
    r.receive([MegaRemote.oscPath, "0" ! 32, 't-2'], here);
    r.receive([MegaRemote.oscPath, nil, 't-2'], here);
    ~tEq.("...from elsewhere, or with a wrong token or none, it is not even read",
        [File.exists(MegaRemote.replyPath("t-2")), File.exists(MegaRemote.requestPath("t-2"))], [false, true]);
    r.receive([MegaRemote.oscPath, r.token, '../remote']);
    r.receive([MegaRemote.oscPath, r.token, '../remote'], here);
    ~tAssert.("...an id that would name another file is dropped, and the handshake stays",
        File.exists(MegaRemote.handshakePath) and: { File.exists(MegaRemote.dir +/+ "../remote.reply.json").not });

    other = MegaRemote({ () });
    other.start(57998);
    ~tAssert.("a second start (boot.scd run again) takes the handshake over, with a token of its own",
        MegaFiles.readText(MegaRemote.handshakePath).contains(other.token) and: { other.token != r.token });
    ~tEq.("...and clears the requests and replies left over", (MegaRemote.dir +/+ "*.json").pathMatch, []);
    r.stop;
    ~tAssert.("the first one stopping leaves the second's handshake alone",
        MegaFiles.readText(MegaRemote.handshakePath).contains(other.token));
    other.stop;
    ~tEq.("the second one stopping removes it, and the listener goes",
        [File.exists(MegaRemote.handshakePath), OSCdef.all[\megalooperRemote]], [false, nil]);
} {
    MegaFiles.alwaysSync = false;
    r !? { |x| x.stop };
    other !? { |x| x.stop };
};
}.value;
