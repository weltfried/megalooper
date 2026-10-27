// megalooper — the status band, its strip, and the MIDI monitor.
//
// Loaded by boot.scd; defines only, runs nothing. Entry points:
//   ~buildStatusBand        — Perform's status band: the state block, the take,
//                             the input, and the bar grid
//   ~buildStatusStrip       — the same, folded into 56 px, for every other view
//   ~statusRefreshAll       — push the whole model state into both
//   ~buildMidiMonitorPanel  — the MIDI-in log, for the Setup view
//
// The shell places the band and the strip and shows one of them; everything
// here PAINTS them. Every painter reaches its views through a nil guard, so a
// painter can run before, after, or entirely without the widget existing.
// That is what lets the model fire notifications at boot, while the GUI is
// still being assembled, without a single ordering rule.
//
// The status is READ-ONLY on purpose (but for Revert, which is part of what
// the reading chip says). It shows what the model REPORTS, never what the
// keypress asked for: every piece is driven from a `this.changed(...)`
// notification in Looper or from the shell's position poll, so a refused
// action leaves the display telling the truth.
//
// Repainting is kept to what changed: the state block on \state and \break
// (and four times a second while it counts something down), the grid at the
// poll's rate only while a loop is playing, and only the one of band and
// strip that shows. That is the same order of Pen calls as the old header's
// position view, which is what the MIDI clock was measured against.
(
// ---- The state block ----------------------------------------------------------------
// What the looper is doing: the fill (a STATE colour, or the hatch for a
// break), the words, and what R does next. Read from the model each time.
~statusLook = { |l|
    var st = (l !? { |x| x.state }) ? \empty;
    var brk = l.notNil and: { l.onBreak };
    var look = case
        { brk } { (label: "BREAK", hatch: true, ink: Color.new255(243, 243, 241)) }
        { st == \recording } { (label: "● REC", fill: ~gt[\rec], ink: Color.white) }
        { st == \playing } { (label: "▶ PLAYING", fill: ~gt[\play], ink: ~gt[\onacc]) }
        { st == \overdubbing } { (label: "● OVERDUB", fill: ~gt[\dub], ink: ~gt[\onacc]) }
        { st == \stopped } { (label: "■ STOPPED", fill: ~gt[\panel2], ink: ~gt[\ink]) }
        { (label: "EMPTY", fill: ~gt[\panel2], ink: ~gt[\ink]) };
    look[\state] = st;
    look[\next] = ~statusNextLine.(l, st, brk);
    look
};

// The line under the state: what the trigger does next, or what is counting.
~statusNextLine = { |l, st, brk|
    var left, t;
    case
    { l.isNil } { "" }
    { brk } {
        left = l.breakEndsAt !? { |at| (at - SystemClock.seconds).max(0) };
        if(left.notNil) { "back on the downbeat in " ++ left.round(0.1) ++ " s" } { "back on the downbeat" }
    }
    { l.dissolving } { "dissolving " ++ (l.dissolvePos * 100).round.asInteger ++ "% · cutter → loop → grains" }
    { st == \recording } {
        t = l.recStartTime !? { |at| (SystemClock.seconds - at).max(0) } ? 0;
        "R → close loop & analyse · " ++ t.round(0.1) ++ " s"
    }
    { st == \playing } { "R → overdub · S stop" }
    { st == \overdubbing } { "R → play · fdbk " ++ l.feedback.round(0.01) }
    { st == \stopped } { "R → play · " ++ l.loopDuration.round(0.01) ++ " s in buffer" }
    { "R → record a phrase" }
};

// Paint a state block: the band's with its caption and next line, the strip's
// with the words alone.
~statusDrawState = { |v, compact|
    var b = v.bounds, w = b.width, h = b.height;
    var look = ~statusShown ?? { ~statusLook.(~looper) };
    var ink = look[\ink] ? ~gt[\ink];
    var fade = { |c, a| Color(c.red, c.green, c.blue, a) };
    var x0;
    if(look[\hatch] == true) {
        Pen.fillColor = ~guiHatchDark;
        Pen.addRect(Rect(0, 0, w, h));
        Pen.fill;
        Pen.strokeColor = ~guiHatchLight;
        Pen.width = 10;
        ((w + h) / 28).ceil.asInteger.do { |i|
            x0 = (i * 28) - h;
            Pen.line(Point(x0, h), Point(x0 + h, 0));
        };
        Pen.stroke;
    } {
        Pen.fillColor = look[\fill] ? ~gt[\panel2];
        Pen.addRect(Rect(0, 0, w, h));
        Pen.fill;
    };
    if(compact == true) {
        Pen.stringInRect(look[\label], Rect(18, 0, w - 36, h), ~statusFitFont.(look[\label], 24, w - 36),
            ink, QAlignment(\left));
    } {
        Pen.stringInRect("LOOPER STATE", Rect(26, 20, w - 52, 18), ~guiMono.(12, true), fade.(ink, 0.8),
            QAlignment(\left));
        Pen.stringInRect(look[\label], Rect(26, 52, w - 52, 80), ~statusFitFont.(look[\label], 58, w - 52),
            ink, QAlignment(\left));
        Pen.stringInRect(look[\next] ? "", Rect(26, h - 40, w - 40, 20), ~guiMono.(13, true), fade.(ink, 0.85),
            QAlignment(\left));
    };
};

// The state's words at `size`, or smaller until they fit `room`: the design's
// Nitti Grotesk is narrower than the system sans a machine without it falls
// back to.
~statusFitFont = { |str, size, room|
    var s = size, f = ~guiSans.(s, true);
    while { (str.bounds(f).width > room) and: { s > 12 } } { s = s - 2; f = ~guiSans.(s, true) };
    f
};

~statusPaintState = {
    ~statusShown = ~statusLook.(~looper);
    [~statusStateLabel, ~statusStateStrip].do { |v| v !? { if(v.isClosed.not) { v.refresh } } };
    ~statusRepaintGrids.();
};

// The state blocks alone, and only if their words or colours moved: for what
// changes often and touches nothing else (a count, the overdub's feedback).
~statusPaintLook = {
    var look = ~statusLook.(~looper);
    if(look != ~statusShown) {
        ~statusShown = look;
        [~statusStateLabel, ~statusStateStrip].do { |v| v !? { if(v.isClosed.not) { v.refresh } } };
    };
};

// Four times a second, from the shell: what counts. The state block while it
// counts down (a break), up (a recording) or along (a dissolve), and the
// Perform tiles that say the same; the input's dB.
~statusPaintCounting = {
    var l = ~looper;
    if(l.notNil and: { l.onBreak or: { l.dissolving } or: { l.state == \recording } }) {
        ~statusPaintLook.();
        ~performPaintCounting !? { |f| f.value };
    };
    ~guiLevelDb !? { |t|
        if(t.isClosed.not and: { ~guiView == \perform }) {
            t.string_(((~analysisPeak ? 0).ampdb.max(-60)).round(0.1).asString ++ " dB");
        };
    };
};

// ---- The take -------------------------------------------------------------------------
// What the analyser decided, as the band shows it: the head, the signature,
// BPM, bars and key, the reading chip and its hint.
~statusTake = { |l|
    var r = l !? { |x| x.lastResult };
    var st = (l !? { |x| x.state }) ? \empty;
    var pend = l !? { |x| x.pendingReading };
    var n = l !? { |x| x.readingCount } ? 0;
    var t = (head: "TAKE · NONE YET", sig: "—", bpm: "—", bars: "—", chip: nil, chipLit: false,
        hint: "R to record. Bar 1 beat 1 is where you press.", line: "no take");
    var up, loops;
    case
    { st == \recording } {
        t[\head] = "TAKE · LISTENING…";
        t[\hint] = "Meter and tempo come from your onsets.";
        t[\line] = "recording…";
    }
    { r.isNil } { }
    { (r[\error].notNil) and: { r[\error] != \lengthAnchored } } {
        t[\head] = "TAKE · NO METER";
        t[\hint] = "No meter: " ++ r[\error] ++ ". The cutter needs one: record again.";
        t[\line] = "no meter";
    }
    {
        t[\sig] = MeterAnalyzer.sigString(r);
        t[\bpm] = (r[\bpm] ? 0).round(0.1).asString;
        t[\bars] = (r[\k] ? 1).asString;
        // Uneven bars spell their own count (7+7+7+8 is four), so the strip
        // gives the cycles instead, and only when there are more than one.
        t[\line] = if(MeterAnalyzer.isUneven(r)) {
            t[\sig] ++ { |c| if(c > 1) { " ×" ++ c } { "" } }.((r[\k] ? 1)
                div: MeterAnalyzer.cycleOf(r[\bars]).size.max(1)) ++ " · " ++ t[\bpm]
        } {
            t[\sig] ++ " · " ++ t[\bpm] ++ " · " ++ t[\bars] ++ " bar" ++ (if((r[\k] ? 1) > 1) { "s" } { "" })
        };
        case
        { r[\error] == \lengthAnchored } {
            t[\head] = "TAKE · ANCHORED";
            t[\hint] = "No beat found: kept at the fallback meter. No cutter on this take.";
        }
        { pend.notNil } {
            loops = ((pend[\at] - SystemClock.seconds) / l.loopDuration.max(1e-6)).ceil.asInteger.max(1);
            t[\head] = "TAKE · READING " ++ (pend[\index] + 1) ++ "/" ++ n;
            t[\chip] = "→ " ++ Looper.prReadingString(pend[\result]) ++ " · lands in " ++ loops
                ++ " loop" ++ (if(loops > 1) { "s" } { "" });
            t[\chipLit] = true;
            t[\hint] = "Lands on the loop boundary where the drums' bar line agrees";
        }
        { l.readingIndex > 0 } {
            t[\head] = if(r[\from] == \hand) { "TAKE · BARS BY HAND" }
                { "TAKE · READING " ++ (l.readingIndex + 1) ++ "/" ++ n };
            t[\chip] = "reading " ++ (l.readingIndex + 1) ++ "/" ++ n;
            t[\hint] = "A again for the next one. It wraps round to the analyser's own.";
        }
        { (l.readingMargin ? 1) < 0.1 } {
            up = l.runnerUp;
            t[\head] = "TAKE · DETECTED";
            t[\chip] = up !? { |u| "or " ++ MeterAnalyzer.sigString(u)
                ++ " @ " ++ (u[\bpm] ? 0).round(0.1) ++ "?" };
            t[\hint] = "Close call: press A or "
                ++ (~midiWords.('looper.nextReading') ? "its footswitch") ++ " for the next reading";
        }
        {
            t[\head] = "TAKE · DETECTED";
            t[\hint] = if(n > 1) { "A tries the analyser's next reading." } { "" };
        };
    };
    // A starved analysis tap (Looper.tapStarvedGap): the reading rests on
    // what crossed the threshold of a signal far too quiet, so the hint says
    // so, in the record colour, until the next take.
    if((st != \recording) and: { r.notNil } and: { (l !? { |x| x.tapStarvedGap }).notNil }) {
        t[\hint] = "The analysis tap heard this take " ++ l.tapStarvedGap.round.asInteger
            ++ " dB under the input: check its gain or channel (Analysis in), then record again.";
        t[\starved] = true;
    };
    t
};

~statusPaintTake = {
    var l = ~looper, t = ~statusTake.(l);
    var set = { |v, str| v !? { if(v.isClosed.not) { v.string_(str) } } };
    set.(~guiTakeHead, t[\head]);
    set.(~guiTakeSig, t[\sig]);
    // 84 pt holds nine characters (7+7+7+8/8); a longer cycle of uneven bars
    // gets smaller rather than push the tempo and the bars out of the band.
    ~guiTakeSig !? { |v| if(v.isClosed.not) {
        v.font_(~guiSans.((84 * 9 / t[\sig].size.max(9)).round.max(36), true)) } };
    set.(~guiTakeBpm, t[\bpm]);
    set.(~guiTakeBars, t[\bars]);
    set.(~guiReadingHint, t[\hint]);
    ~guiReadingHint !? { |v| if(v.isClosed.not) { v.toolTip_(t[\hint] ? "")
        .stringColor_(if(t[\starved] == true) { ~gt[\rec] } { ~gt[\mute] }) } };
    // The strip's 22 pt holds 20 characters (7/8 · 108.3 · 4 bars); a long
    // cycle of uneven bars gets smaller to keep its tempo in view.
    ~guiTakeLabel !? { |v|
        if(v.isClosed.not) { v.string_(t[\line]).toolTip_(~guiTakeString.())
            .font_(~guiSans.((22 * 20 / t[\line].size.max(20)).round.max(14), true)) };
    };
    ~guiReadingChipBox !? { |box|
        if(box.isClosed.not) {
            box.visible_(t[\chip].notNil);
            ~guiReadingChip.string_(t[\chip] ? "")
                .background_(if(t[\chipLit]) { ~gt[\armed] } { ~gt[\bg] })
                .stringColor_(if(t[\chipLit]) { ~gt[\onacc] } { ~gt[\ink] });
        };
    };
    ~revertReadingButton !? { |b|
        if(b.isClosed.not) {
            b.enabled_(l.notNil and: { (l.readingIndex > 0) or: { l.pendingReading.notNil } });
        };
    };
    // What the Perform tiles say about the reading (Next reading's sub).
    ~performPaintReading !? { |f| f.value };
};

// ---- The bar grid --------------------------------------------------------------------
// One UserView, not a widget per beat: per frame n beat cells, n lines and one
// playhead, n <= 28 or so. The beat under the playhead is filled in the
// state's colour (the hatch on a break); the beats behind it in \panel2.
~statusGridInset = 4;
~statusDrawGrid = { |v, compact|
    var b = v.bounds, w = b.width, h = b.height, top = ~statusGridInset, gh = h - (2 * ~statusGridInset);
    var l = ~looper, pos = ~guiLoopPos, phase = ~guiLoopPhase;
    var st = (l !? { |x| x.state }) ? \empty;
    // The length of every bar in beats (Looper.loopPositionAt): 7 7 7 8 draws
    // its fourth bar an eighth longer.
    var lens = pos !? { |p| p[\bars] };
    var frac = (pos !? { |p| p[\fraction] }) ? 0;
    var running = phase.notNil and: { (st == \playing) or: { st == \overdubbing } };
    var brk = l.notNil and: { l.onBreak };
    var r = l !? { |x| x.countResult };
    var n, bi, cw, x, cur, ink, i, text, stripe, starts, inBar, heads, shade, a, bar0, counting;
    Pen.fillColor = ~gt[\panel];
    Pen.addRect(Rect(0, top, w, gh));
    Pen.fill;
    if((st == \empty) or: { st == \recording }) {
        // No grid until the loop closes: a hatch of thin rules and what is
        // happening instead.
        stripe = 24;
        Pen.fillColor = ~gt[\panel2];
        (w / stripe).ceil.asInteger.do { |k| Pen.addRect(Rect((k * stripe) + 22, top, 2, gh)) };
        Pen.fill;
        if(compact != true) {
            text = if(st == \recording) {
                "● " ++ ((l.recStartTime !? { |at| (SystemClock.seconds - at).max(0) }) ? 0).round(0.1)
                    ++ " s · no grid until the loop closes"
            } { "empty buffer" };
            Pen.stringInRect(text, Rect(18, top, w - 36, gh), ~guiMono.(15, true),
                if(st == \recording) { ~gt[\rec] } { ~gt[\mute] }, QAlignment(\left));
        };
    } {
        if(lens.notNil and: { lens.notEmpty } and: { lens.sum > 0 }) {
            n = lens.sum;
            starts = lens.inject([0], { |acc, b| acc.add(acc.last + b) }).drop(-1);
            inBar = lens.collect { |b| (1..b) }.flatten;
            cw = w / n;
            bi = (frac * n).floor.asInteger.clip(0, n - 1);
            cur = if(st == \overdubbing) { ~gt[\dub] } { ~gt[\play] };
            // The beat groups (MeterAnalyzer.beatGrouping, as the count has
            // them): a heavier line at each group's head, every other group
            // faintly shaded, so 2+2+3 reads without a number.
            heads = Set.new;
            shade = List.new;
            starts.do { |s0, bk|
                a = s0;
                MeterAnalyzer.beatGrouping(lens[bk], (r !? { |x| x[\denominator] }) ? 4).do { |g, gi|
                    if(gi > 0) { heads.add(a) };
                    if(gi.odd) { shade.add([a, g]) };
                    a = a + g;
                };
            };
            if(compact != true) {
                Pen.fillColor = Color(~gt[\panel2].red, ~gt[\panel2].green, ~gt[\panel2].blue, 0.5);
                shade.do { |sg| Pen.addRect(Rect(cw * sg[0], top, cw * sg[1], gh)) };
                Pen.fill;
            };
            // The beats played this pass, and the one under the playhead.
            if(running) {
                if(bi > 0) {
                    Pen.fillColor = ~gt[\panel2];
                    Pen.addRect(Rect(0, top, cw * bi, gh));
                    Pen.fill;
                };
                if(brk) {
                    Pen.push;
                    Pen.addRect(Rect(cw * bi, top, cw, gh));
                    Pen.clip;
                    Pen.strokeColor = ~gt[\ink];
                    Pen.width = 3;
                    ((cw + gh) / 9).ceil.asInteger.do { |k|
                        x = (cw * bi) + (k * 9) - gh;
                        Pen.line(Point(x, top + gh), Point(x + gh, top));
                    };
                    Pen.stroke;
                    Pen.pop;
                } {
                    Pen.fillColor = cur;
                    Pen.addRect(Rect(cw * bi, top, cw, gh));
                    Pen.fill;
                };
            };
            // The beat lines, then the bar lines over them: a bar line is a
            // beat line too, and drawing the heavy one second means it wins.
            Pen.fillColor = ~gt[\line];
            n.do { |k| if((inBar[k] != 1) and: { heads.includes(k).not }) { Pen.addRect(Rect((cw * k).round, top, 1, gh)) } };
            Pen.fill;
            Pen.fillColor = ~gt[\mute];
            heads.do { |k| Pen.addRect(Rect((cw * k).round, top, 2, gh)) };
            Pen.fill;
            Pen.fillColor = ~gt[\ink];
            starts.do { |k| if(k > 0) { Pen.addRect(Rect(((cw * k) - 1).round, top, 3, gh)) } };
            Pen.fill;
            if(compact != true) {
                // The odd bar of uneven bars, marked across its top.
                if(MeterAnalyzer.isUneven(r)) {
                    Pen.fillColor = ~gt[\ink];
                    starts.do { |k, bk| if(lens[bk] != r[\numerator]) { Pen.addRect(Rect(cw * k, top, cw * lens[bk], 5)) } };
                    Pen.fill;
                };
                // The bar a count-in counts down in.
                counting = running and: { ~countShown.notNil } and: { ~countShown[\c].notNil }
                    and: { ~countShown[\c][\countdown].notNil };
                if(counting) {
                    bar0 = starts.lastIndexForWhich { |k| k <= bi } ? 0;
                    Pen.strokeColor = ~gt[\armed];
                    Pen.width = 4;
                    Pen.addRect(Rect((cw * starts[bar0]) + 2, top + 2, (cw * lens[bar0]) - 4, gh - 4));
                    Pen.stroke;
                };
            };
            // The beat numbers, where a cell can hold one: a multiplied loop
            // of hundreds of beats shows its lines alone.
            if((compact != true) and: { cw >= 16 }) {
                text = ~guiMono.(11, true);
                n.do { |k|
                    ink = if(running and: { k == bi } and: { brk.not }) { ~gt[\onacc] } { ~gt[\mute] };
                    Pen.stringAtPoint(inBar[k].asString, Point((cw * k) + 6, top + gh - 18), text, ink);
                };
            };
        } {
            // A take with no grid to count on: elapsed against the length.
            if(running) {
                Pen.fillColor = ~gt[\panel2];
                Pen.addRect(Rect(0, top, w * frac, gh));
                Pen.fill;
            };
        };
        // The playhead, standing proud of the grid.
        if(running) {
            Pen.fillColor = ~gt[\ink];
            Pen.addRect(Rect(((w * frac) - 1).round, 0, if(compact == true) { 2 } { 3 }, h));
            Pen.fill;
        };
    };
};

// The position in words: the band's two lines and the strip's short one.
~statusPositionWords = {
    var l = ~looper, pos = ~guiLoopPos, phase = ~guiLoopPhase;
    var st = (l !? { |x| x.state }) ? \empty;
    var dur = (l !? { |x| x.loopDuration }) ? 0;
    var bars = pos !? { |p| p[\barCount] };
    case
    { st == \recording } {
        ["RECORDING · " ++ ((l.recStartTime !? { |at| (SystemClock.seconds - at).max(0) }) ? 0).round(0.01) ++ " s",
            "free time · no grid yet", "rec"]
    }
    { dur <= 0 } { ["NO LOOP", "press R to record", "—"] }
    // Recorded but not playing. Calling a stopped loop "no loop" would be the
    // display lying about what is in the buffer.
    { phase.isNil } {
        ["STOPPED", dur.round(0.01).asString ++ " s" ++ (bars !? { |b| " · " ++ b ++ " bars" } ? ""), "■"]
    }
    { pos.notNil and: { pos[\bar].notNil } } {
        // At half-time the loop's own bars, each now two drum bars long: ½.
        ["BAR " ++ pos[\bar] ++ "/" ++ pos[\barCount] ++ " · BEAT " ++ pos[\beat] ++ "/" ++ pos[\beatsPerBar]
            ++ (if((l.speed ? 1) != 1) { " · ½" } { "" }),
            phase.round(0.01).asString ++ " / " ++ dur.round(0.01) ++ " s",
            pos[\bar].asString ++ "·" ++ pos[\beat]]
    }
    // No grid to count on, so elapsed/total alone rather than an invented
    // beat. asString first: a Number does not answer ++.
    { [phase.round(0.01).asString ++ " / " ++ dur.round(0.01) ++ " s", "no bar grid on this take",
        phase.round(0.1).asString] }
};

// The words are kept per label rather than read back from Qt: this runs at
// 20 Hz while a loop moves.
~statusPosShown = IdentityDictionary.new;
~statusRepaintGrids = {
    var words = ~statusPositionWords.();
    var set = { |v, str|
        v !? { if(v.isClosed.not and: { ~statusPosShown[v] != str }) { ~statusPosShown[v] = str; v.string_(str) } } };
    if(~guiView == \perform) {
        set.(~guiPosBig, words[0]);
        set.(~guiPosSmall, words[1]);
        ~guiPositionView !? { |v| if(v.isClosed.not) { v.refresh } };
    } {
        set.(~guiPosShort, words[2]);
        ~guiPositionStrip !? { |v| if(v.isClosed.not) { v.refresh } };
    };
};

// ---- The count ---------------------------------------------------------------------------
// Perform's count, under the state block (docs/dev/rc600-picks.md, Phase 1):
// the group of the bar the playhead is in, big (1 2 3 in 7/8, the analyser's
// 2+2+3), its beats as squares, the bar, the bar's groups as a strip, the odd
// bar of uneven bars a bar ahead, and in the last bar before an event that
// lands on a loop boundary, the groups left: 3 2 1, then the event's word for
// a group. The arithmetic is Looper.beatCountAt; what is coming,
// Looper:upcoming.
//
// It is painted ON the beat, not sampled: the shell's count routine sleeps to
// the next beat line (~countTick), and the position between polls is predicted
// from the last answer (~countAnchor: the phase, when it came, the length it
// was of). The 20 Hz poll paints the grid from the same prediction, so the two
// never show different beats.
//
// ~countDelay moves what is shown later than the engine plays it. 0: the
// master's 20 ms look-ahead and the output buffer come to about what the
// screen takes to show a repaint. If the count looks early or late against the
// drums on the rig, this is the knob.
~countDelay = ~countDelay ? 0;
~countAnchor = nil;
~countShown = nil;
~countKey = nil;
~countPrevNear = nil;
~countFlash = nil;
// What each event is called while it is counted to, and for a group after.
~countWords = (
    break: (cap: "BACK IN", word: "BACK", fill: \play),
    reading: (cap: "NEW READING IN", word: "NEW", fill: \armed),
    recordNextLoop: (cap: "REC NEXT LOOP IN", word: "REC", fill: \rec),
    recordNextLoopEnds: (cap: "NEXT LOOP CLOSES IN", word: "LOOP", fill: \play),
    cutter: (cap: "CUTTER IN", word: "CUT", fill: \cut),
    halfTime: (cap: "HALF-TIME IN", word: "HALF", fill: \loop),
    halfTimeEnds: (cap: "FULL TIME IN", word: "FULL", fill: \loop)
);

// Where the playhead is at `now`, in seconds into the loop, from the poll's
// last answer; nil without one, or with one of a loop that has since changed
// length (a multiply, an undo, a new take: the next answer is 50 ms away).
// At half-time (Looper.speed 0.5) the playhead moves at half the wall's
// pace. A speed changes on a boundary, the engine's phase 0: an answer from
// before the change is not used across it, the playhead is counted from the
// boundary instead.
~countPosAt = { |now, delay|
    var l = ~looper, a = ~countAnchor, dur, shown, v, changed;
    dur = (l !? { |x| x.loopDuration }) ? 0;
    if(l.isNil or: { a.isNil } or: { dur <= 0 } or: { (a[\dur] - dur).abs > 1e-6 }) { nil } {
        shown = now - (delay ?? { ~countDelay ? 0 });
        v = (if(l.reverseFlag) { -1 } { 1 }) * l.speed;
        changed = l.speedChangedAt;
        if(changed.notNil and: { a[\at] < changed } and: { shown >= changed }) {
            (v * (shown - changed)).mod(dur)
        } {
            (a[\phase] + (v * (shown - a[\at]))).mod(dur)
        }
    }
};

// The count at `now` (Main.elapsedTime), shown `delay` behind the engine:
// (st:, brk:, why:, c:, near:, shown:, beatDur:). `c` is Looper.beatCountAt's
// answer, nil when there is nothing to count (`why` says what); `near` the
// next event. Changes nothing: the window's count and the lights each ask.
~countAt = { |now, delay|
    var l = ~looper, out = (brk: false, why: ""), st, dur, r, pos;
    st = (l !? { |x| x.state }) ? \empty;
    out[\st] = st;
    out[\brk] = l.notNil and: { l.onBreak };
    dur = (l !? { |x| x.loopDuration }) ? 0;
    r = l !? { |x| x.countResult };
    out[\shown] = now - delay;
    pos = ~countPosAt.(now, delay);
    case
    { st == \recording } { out[\why] = "starts when\nthe loop closes" }
    { dur <= 0 } { out[\why] = "no loop" }
    { (st != \playing) and: { st != \overdubbing } } { out[\why] = "stopped" }
    { pos.isNil } { }
    { Looper.beatCountAt(0, r, dur)[\group].isNil } { out[\why] = "no grid\non this take" }
    {
        // Looper.beatCountAt counts in the loop's own time; at half-time a
        // wall second is half of one, and a beat lasts twice as long.
        out[\near] = l.upcoming(out[\shown]).select { |e| e[\at] > out[\shown] }.minItem { |e| e[\at] };
        out[\c] = Looper.beatCountAt(pos, r, dur, out[\near] !? { |e| (e[\at] - out[\shown]) * l.speed }, l.reverseFlag);
        out[\c][\toEdge] = out[\c][\toEdge] / l.speed;
        out[\beatDur] = (r[\tau] * (r[\sub] ? 1)) / l.speed;
        out[\speed] = l.speed;
    };
    out
};

// What the window's count shows at `now`: ~countAt's answer, and `flash`, an
// event just landed, and `wait`, the seconds to the next beat line, at most a
// tenth.
~countCompute = { |now|
    var out = ~countAt.(now, ~countDelay ? 0), c = out[\c], shown = out[\shown], prev;
    out[\wait] = 0.1;
    if(c.notNil) {
        // An event counted to and now past: its word, for the group it lands
        // on. One that went before its time was cancelled, and says nothing.
        prev = ~countPrevNear;
        if(prev.notNil and: { shown >= prev[\at] } and: { shown < (prev[\at] + 1) }) {
            ~countFlash = (what: prev[\what], until: prev[\at] + (c[\groups][c[\group] - 1] * out[\beatDur]));
        };
        ~countPrevNear = out[\near];
        out[\wait] = ((c[\toEdge] ? 0.1) + 0.002).clip(0.004, 0.1);
    } {
        ~countPrevNear = nil;
    };
    // Ended on its beat line, with slack for the anchor's few ms against the
    // boundary's own clock.
    if(~countFlash.notNil and: { c.isNil or: { shown >= (~countFlash[\until] - 0.01) } }) { ~countFlash = nil };
    out[\flash] = ~countFlash;
    out
};

// One step of the shell's count routine: work out the count, and repaint it,
// and the grid with it, when what it shows has moved. Answers the seconds to
// sleep.
~countTick = {
    var now = Main.elapsedTime, s = ~countCompute.(now), c = s[\c], key, pos;
    key = [s[\st], s[\brk], s[\why], s[\speed], c !? { [c[\bar], c[\beat], c[\countdown], c[\nextOdd], c[\loopsLeft], c[\groups]] },
        s[\near] !? { |e| e[\what] }, s[\flash] !? { |f| f[\what] }];
    ~countShown = s;
    if(key != ~countKey) {
        ~countKey = key;
        if(~guiView == \perform) {
            ~statusCountView !? { |v| if(v.isClosed.not) { v.refresh } };
            // The grid's beat on the same line as the count.
            pos = ~countPosAt.(now);
            if(pos.notNil and: { c.notNil }) {
                ~guiLoopPhase = pos;
                ~guiLoopPos = Looper.loopPositionAt(pos, ~looper.countResult, ~looper.loopDuration);
                ~statusRepaintGrids.();
            };
        };
    };
    s[\wait]
};

// ---- The count's lights -------------------------------------------------------------
// The count on a controller's button lights (docs/dev/rc600-picks.md, Phase 2):
// the controls setup-miditargets.scd's count family makes, learned onto a
// button like any mapping, sent back to like a toggle's light (5.7 of
// docs/dev/midi-map.md), so a thru's echo is dropped and a press that lit or
// darkened the button has it put right. Nothing the button sends acts.
//   beatLight     flashes on each beat group's first beat, longer on a bar's
//   countInLight  lit through the last bar before an event the count counts in
//                 to; it goes out on the boundary
//   oddBarLight   lit through the bar before the odd one of uneven bars
// On SystemClock, not the send-back's 20 Hz tick, which would put the beat
// on its 50 ms grid: ~countLightStep sleeps to the next beat line (or the
// flash's end) and sends what changed then. The tick sends what this missed
// (a controller sent everything again, a press).
//
// ~countLightDelay is when the beat is heard after the engine plays it: the
// master's 20 ms look-ahead and a few ms of output buffer. A button lights
// at once, so the lights wait for it; the screen, which takes about as long
// to show a repaint, doesn't (~countDelay).
~countLights = (beatLight: false, countInLight: false, oddBarLight: false);
~countLightDelay = ~countLightDelay ? 0.025;
~countLightFlash = 0.1;
~countLightBarFlash = 0.25;
~countLightEdge = nil;
~countLightOff = nil;

// Is a light learned and sent back to? Then the clock works the lights out.
~countLightsBound = {
    ~midiBackList.notNil and: { ~midiBackSrcs.notNil } and: { ~midiBackSrcs.notEmpty }
        and: { ~midiBackList.().any { |e| e[\target][\kind] == \light } }
};

// What the lights show at `now`, and when to look again.
~countLightStep = { |now|
    var s, c, want, since, edge, wait, changed;
    if(~countLightsBound.().not) {
        ~countLights = (beatLight: false, countInLight: false, oddBarLight: false);
        0.25
    } {
        s = ~countAt.(now, ~countLightDelay);
        c = s[\c];
        if(c.isNil) {
            want = (beatLight: false, countInLight: false, oddBarLight: false);
            ~countLightOff = nil;
            wait = 0.1;
        } {
            // The beat line last crossed, and the flash it starts: on a
            // group's first beat, once, and only if the step is on time (a
            // late flash would say the beat was later than it was).
            since = s[\beatDur] - c[\toEdge];
            edge = now - since;
            if((c[\groupBeat] == 1) and: { since < 0.05 }
                and: { ~countLightEdge.isNil or: { (edge - ~countLightEdge).abs > 0.01 } }) {
                ~countLightEdge = edge;
                ~countLightOff = edge + if(c[\group] == 1) {
                    ~countLightBarFlash.min(c[\groups][0] * s[\beatDur] * 0.7) } { ~countLightFlash };
            };
            want = (beatLight: ~countLightOff.notNil and: { now < ~countLightOff },
                countInLight: c[\countdown].notNil, oddBarLight: c[\nextOdd]);
            wait = c[\toEdge] + 0.001;
            if(want[\beatLight]) { wait = wait.min((~countLightOff - now) + 0.001) };
            wait = wait.clip(0.002, 0.1);
        };
        changed = [\beatLight, \countInLight, \oddBarLight].select { |k| want[k] != ~countLights[k] };
        if(changed.notEmpty) {
            ~countLights = want;
            ~countLightSend.(~midiNow.(), changed);
        };
        wait
    }
};

// The lights that changed (`which`, as ~countLights names them), to each
// place each is sent back to, if it shows other than it should: the
// ~midiBackTick's light, at once. One whose place isn't known yet (a boot, a
// controller sent everything again) the tick sends.
~countLightSend = { |now, which|
    if(~midiMap.notNil and: { ~midiLearning.isNil }) {
        ~midiBackList.().do { |e|
            var t = e[\target], b = e[\slot][\binding], w, r, at;
            if((t[\kind] == \light) and: { e[\how] == \light }
                and: { which.includes(t[\id].asString.drop(6).asSymbol) }) {
                w = LooperMidiMap.backValue(b, \light, t[\get].value, nil);
                e[\addrs].do { |a|
                    if(w.notNil and: { ~midiBackOuts[a[2]] != \dead } and: { ~midiBackOwns.(e, a[4]) }) {
                        r = ~midiBackRecord.(e[\slot], a[0], a[1]);
                        if(r[\wire] != w) {
                            at = ~midiBackSend.(a[2], b, a[1], w, a[0], \light, now);
                            at !? { r[\wire] = w; r[\at] = at; ~midiBackOthers.(e, a, w) };
                        };
                    };
                };
            };
        };
    };
};

// The lights' clock: generation-guarded, so a new one stops the old; started
// with the send-back's (~midiBackClock), and cleared by Cmd-period with it.
~countLightClock = {
    var gen = (~countLightGen ? 0) + 1;
    ~countLightGen = gen;
    SystemClock.sched(0.5, {
        if(gen == ~countLightGen) {
            try { ~countLightStep.(Main.elapsedTime) } { |err|
                ("megalooper: the count's lights: " ++ err.errorString ++ ". Tried again in a second.").warn;
                1
            }
        }
    });
};

// The break's hatch over a rectangle (the state block's).
~statusHatch = { |rect, step = 28, width = 10|
    var x0;
    Pen.fillColor = ~guiHatchDark;
    Pen.addRect(rect);
    Pen.fill;
    Pen.push;
    Pen.addRect(rect);
    Pen.clip;
    Pen.strokeColor = ~guiHatchLight;
    Pen.width = width;
    ((rect.width + rect.height) / step).ceil.asInteger.do { |i|
        x0 = rect.left + (i * step) - rect.height;
        Pen.line(Point(x0, rect.bottom), Point(x0 + rect.height, rect.top));
    };
    Pen.stroke;
    Pen.pop;
};

~statusDrawCount = { |v|
    var b = v.bounds, w = b.width, h = b.height;
    var s = ~countShown ? (why: ""), c = s[\c], near = s[\near], fl = s[\flash];
    var counting = c.notNil and: { c[\countdown].notNil } and: { fl.isNil };
    var fill = ~gt[\panel], ink = ~gt[\ink], hatch = false;
    var fade = { |col, a| Color(col.red, col.green, col.blue, a) };
    // The number's column narrows with the block (~guiStatusFit), as the
    // state's words do.
    var right = (w * 0.455).round, room = w - right - 20, big = (132 * w / 330).clip(84, 132), cap, num, cells, sq = 20, gap = 7, total, acc = 0, gx, gw, tag, tw, f, word;
    case
    { fl.notNil } { fill = ~gt[~countWords[fl[\what]][\fill]]; ink = ~gt[\onacc] }
    { counting } { fill = ~gt[\armed]; ink = ~gt[\onacc] }
    { s[\brk] == true } { hatch = true; ink = Color.new255(243, 243, 241) };
    if(hatch) { ~statusHatch.(Rect(0, 0, w, h)) } {
        Pen.fillColor = fill;
        Pen.addRect(Rect(0, 0, w, h));
        Pen.fill;
    };
    if(c.isNil) {
        Pen.stringInRect("COUNT", Rect(22, 12, w - 44, 18), ~guiMono.(12, true), fade.(~gt[\mute], 1), QAlignment(\left));
        Pen.stringInRect("–", Rect(16, 26, right - 16, h - 30), ~guiSans.(big, true), ~gt[\line], QAlignment(\left));
        Pen.stringInRect(s[\why] ? "", Rect(right, 40, room, 60), ~guiMono.(13, true), ~gt[\mute], QAlignment(\topLeft));
    } {
        if(fl.notNil) {
            word = ~countWords[fl[\what]][\word];
            Pen.stringInRect(word, Rect(18, 14, w - 36, h - 20), ~statusFitFont.(word, 116, w - 36), ink, QAlignment(\left));
        } {
            // The odd bar, a bar ahead: a tag in the top corner.
            if(c[\nextOdd] and: { counting.not }) {
                tag = c[\nextBeatsPerBar].asString ++ " NEXT";
                f = ~guiMono.(14, true);
                tw = tag.bounds(f).width + 18;
                Pen.fillColor = ~gt[\armed];
                Pen.addRect(Rect(w - tw - 14, 10, tw, 24));
                Pen.fill;
                Pen.stringInRect(tag, Rect(w - tw - 14, 10, tw, 24), f, ~gt[\onacc], QAlignment(\center));
            };
            cap = case
                { counting } { ~countWords[near[\what]][\cap] }
                { near.notNil } { ~countWords[near[\what]][\cap] ++ " " ++ c[\loopsLeft]
                    ++ (if(c[\loopsLeft] == 1) { " LOOP" } { " LOOPS" }) }
                { "COUNT · " ++ c[\groups].collect(_.asString).join("+")
                    ++ (if(c[\barOdd]) { " · THE " ++ c[\beatsPerBar] } { "" })
                    ++ (if((s[\speed] ? 1) != 1) { " · ½" } { "" }) };
            Pen.stringInRect(cap, Rect(22, 12, w - 44 - (if(c[\nextOdd] and: { counting.not }) { tw ? 0 } { 0 }), 18),
                ~guiMono.(12, true), fade.(if(near.notNil and: { counting.not }) { ~gt[\armed] } { ink }, 0.9),
                QAlignment(\left));
            // The number: the count-in, or the group (in 4/4, where every
            // group is one beat, that is the beat).
            num = if(counting) { c[\countdown] } { c[\group] };
            Pen.stringInRect(num.asString, Rect(14, 26, right - 14, h - 30), ~guiSans.(big, true), ink, QAlignment(\left));
            // The group's beats, or the bar's when every group is one beat.
            if(counting.not) {
                cells = if(c[\groups].every { |g| g == 1 }) {
                    c[\groups].collect { |g, i| i < c[\group] }
                } {
                    Array.fill(c[\groups][c[\group] - 1], { |i| i < c[\groupBeat] })
                };
                cells.do { |on, i|
                    gx = right + (i * (sq + gap));
                    if((gx + sq) <= (right + room)) {
                        if(on) {
                            Pen.fillColor = ink;
                            Pen.addRect(Rect(gx, 46, sq, sq));
                            Pen.fill;
                        } {
                            Pen.strokeColor = ink;
                            Pen.width = 2;
                            Pen.addRect(Rect(gx + 1, 47, sq - 2, sq - 2));
                            Pen.stroke;
                        };
                    };
                };
            };
            Pen.stringInRect("BAR " ++ c[\bar] ++ "/" ++ c[\barCount], Rect(right, 82, room, 24),
                ~guiMono.(18, true), ink, QAlignment(\left));
            // The bar's groups as a strip: those played faint, this one full.
            total = c[\groups].sum;
            c[\groups].do { |g, i|
                gx = right + (acc / total * room);
                gw = (g / total * room) - 4;
                case
                { (i + 1) < c[\group] } {
                    Pen.fillColor = fade.(ink, 0.45);
                    Pen.addRect(Rect(gx, h - 40, gw, 12));
                    Pen.fill;
                }
                { (i + 1) == c[\group] } {
                    Pen.fillColor = ink;
                    Pen.addRect(Rect(gx, h - 40, gw, 12));
                    Pen.fill;
                }
                {
                    Pen.strokeColor = ink;
                    Pen.width = 2;
                    Pen.addRect(Rect(gx + 1, h - 39, gw - 2, 10));
                    Pen.stroke;
                };
                acc = acc + g;
            };
        };
    };
};

// ---- The input: a level and the onset lamp ---------------------------------------------------
// The meter: the level in dB over -60..0 (a guitar's linear amplitude spends
// almost all its time in the bottom tenth of a bar), the clip mark at 92 %.
~statusDrawMeter = { |v, mark|
    var b = v.bounds, w = b.width, h = b.height;
    var norm = (((~analysisLevel ? 0).ampdb + 60) / 60).clip(0, 1);
    Pen.fillColor = ~gt[\panel2];
    Pen.addRect(Rect(0, 0, w, h));
    Pen.fill;
    Pen.fillColor = if(norm > 0.95) { ~gt[\rec] } { ~gt[\play] };
    Pen.addRect(Rect(0, 0, w * norm, h));
    Pen.fill;
    if(mark == true) {
        Pen.fillColor = ~gt[\rec];
        Pen.addRect(Rect((w * 0.92).round, 0, 2, h));
        Pen.fill;
    };
};

// The lamp: a square (the brand has no curves), lit \rec on every onset the
// detector fires and fading in about 200 ms. The unlit square is always drawn:
// a dark lamp must read as "nothing detected", never as "nothing running".
~statusDrawLamp = { |v|
    var b = v.bounds, f = ~analysisFlash ? 0;
    Pen.fillColor = ~gt[\panel2].blend(~gt[\rec], f.clip(0, 1));
    Pen.addRect(Rect(0, 0, b.width, b.height));
    Pen.fill;
    Pen.strokeColor = ~gt[\line];
    Pen.width = 1;
    Pen.addRect(Rect(0.5, 0.5, b.width - 1, b.height - 1));
    Pen.stroke;
};

~statusRepaintLamps = {
    (if(~guiView == \perform) { ~guiOnsetLampView } { ~guiOnsetLampStrip }) !? { |v|
        if(v.isClosed.not) { v.refresh } };
};
~statusRepaintMeters = {
    (if(~guiView == \perform) { ~guiLevelView } { ~guiLevelStrip }) !? { |v|
        if(v.isClosed.not) { v.refresh } };
};

// "thr 0.50 · CC 7": the threshold, and what drives it in the map.
~statusPaintThreshold = {
    ~guiOnsetThrLabel !? { |t|
        if(t.isClosed.not) {
            t.string_("thr " ++ ((~looper !? { |l| l.onsetThreshold }) ? 0.5).round(0.01)
                ++ (~midiWords.('looper.onsetThreshold') !? { |w| " · " ++ w } ? ""));
        };
    };
};

// ---- Building them ---------------------------------------------------------------------------
~buildStatusBand = {
    var caption = { |str| ~guiCaption.(str) };
    var number = { |str| ~guiMonoText.(str, 40, ~gt[\ink]) };
    var stack = { |big, label| VLayout(big, caption.(label)).spacing_(2).margins_(0) };
    var row1, row2, band;
    ~statusStateLabel = UserView().canFocus_(false).fixedWidth_(330)
        .drawFunc_({ |v| ~statusDrawState.(v, false) });
    ~guiTakeHead = caption.("TAKE · NONE YET");
    ~guiTakeSig = ~guiText.("—", 84, nil, true);
    ~guiTakeBpm = number.("—");
    ~guiTakeBars = number.("—");
    ~rootLabel = number.("—");
    // The chip on one line at its own width; the hint takes what is left and
    // is cut at the right rather than widen the window (a label that doesn't
    // wrap asks for its whole line unless given a minimum).
    ~guiReadingChip = ~guiMonoText.("", 13, ~gt[\ink]).align_(\center);
    ~guiReadingChip.setProperty(\wordWrap, false);
    ~guiReadingChipBox = View().background_(~gt[\armed]).fixedHeight_(28)
        .layout_(HLayout(~guiReadingChip).margins_([10, 2, 10, 2]));
    ~guiReadingHint = ~guiText.("", 15, ~gt[\mute]).minWidth_(10);
    ~guiReadingHint.setProperty(\wordWrap, false);
    ~revertReadingButton = ~mapTag.(LooperTile().states_([["Revert ↺", ~gt[\ink], nil]])
        .border_(~gt[\line]).font_(~guiSans.(13)).fixedSize_(Size(92, 28)).pad_(6)
        .action_({ ~looper !? { |l| l.revertReading } }),
        'looper.revertReading', "Back to what the analyser heard, on the next loop boundary.");
    ~guiLevelView = UserView().canFocus_(false).fixedHeight_(18)
        .drawFunc_({ |v| ~statusDrawMeter.(v, true) });
    ~guiLevelDb = ~guiMonoText.("—", 12, ~gt[\mute]).align_(\center);
    ~guiOnsetLampView = UserView().canFocus_(false).fixedSize_(Size(30, 30))
        .toolTip_("Flashes on every onset the detector fires at the current threshold.\n"
            "Flashes between notes mean ghosts (raise it); a hit that leaves it\n"
            "dark means it is too high. Live on the analysis monitor (Setup).")
        .drawFunc_({ |v| ~statusDrawLamp.(v) });
    ~guiOnsetThrLabel = ~guiMonoText.("thr —", 12, ~gt[\mute]);
    ~midiWatch.(~guiOnsetThrLabel, { ~statusPaintThreshold.() });
    ~statusPosShown = IdentityDictionary.new;
    ~guiPosBig = ~guiMonoText.("NO LOOP", 22, ~gt[\ink]);
    ~guiPosSmall = ~guiMonoText.("", 15, ~gt[\mute], true).align_(\right);
    ~guiPositionView = UserView().canFocus_(false).minHeight_(60)
        .drawFunc_({ |v| ~statusDrawGrid.(v, false) });
    ~statusCountView = UserView().canFocus_(false).fixedWidth_(330)
        .toolTip_("The count: the group of the bar the playhead is in (7/8 is 2+2+3), its beats,\n"
            "the bar. In the last bar before a break ends, a reading lands, the next loop\n"
            "records or the cutter comes in, the groups left: 3 2 1.")
        .drawFunc_({ |v| ~statusDrawCount.(v) });
    // In MIDI Map mode the count learns the beat light; the other two lights
    // are under Add a mapping › Perform › Count lights.
    ~mapTag.(~statusCountView, 'count.beatLight', ~statusCountView.toolTip);

    row1 = View().fixedHeight_(190).layout_(HLayout(
        ~statusStateLabel,
        [View().layout_(VLayout(
            ~guiTakeHead,
            nil,
            HLayout(
                [~guiTakeSig, align: \bottom],
                [stack.(~guiTakeBpm, "BPM"), align: \bottom],
                [stack.(~guiTakeBars, "BARS"), align: \bottom],
                [stack.(~rootLabel, "KEY"), align: \bottom],
                nil
            ).spacing_(34).margins_(0),
            nil,
            View().fixedHeight_(28).layout_(HLayout(~guiReadingChipBox, [~guiReadingHint, stretch: 1],
                ~revertReadingButton).spacing_(10).margins_(0))
        ).margins_([30, 22, 30, 18]).spacing_(0)), stretch: 1],
        ~guiRule.(true),
        ~guiStatusInput = View().fixedWidth_(300).layout_(VLayout(
            caption.("INPUT"),
            nil,
            ~guiLevelView,
            HLayout(~guiMonoText.("-60", 12, ~gt[\mute]), nil, ~guiLevelDb, nil,
                ~guiMonoText.("0", 12, ~gt[\mute])).margins_(0),
            nil,
            HLayout(~guiOnsetLampView, VLayout(~guiText.("Onset", 15, nil, true), ~guiOnsetThrLabel)
                .spacing_(0).margins_(0), nil).spacing_(14).margins_(0)
        ).margins_([24, 22, 24, 18]).spacing_(8))
    ).margins_(0).spacing_(0));
    // The count under the state block, the grid beside it.
    row2 = View().fixedHeight_(172).layout_(HLayout(
        ~statusCountView,
        ~guiRule.(true),
        [View().layout_(VLayout(
            HLayout(~guiPosBig, nil, ~guiPosSmall).margins_(0),
            [~guiPositionView, stretch: 1]
        ).margins_([26, 16, 26, 16]).spacing_(10)), stretch: 1]
    ).margins_(0).spacing_(0));
    band = View().background_(~gt[\bg]).fixedHeight_(364).layout_(VLayout(
        row1, ~guiRule.(), row2, ~guiRule.()
    ).margins_(0).spacing_(0));
    ~guiStatusBandMin = band.minSizeHint.width;
    band
};

~buildStatusStrip = {
    var strip;
    ~statusStateStrip = UserView().canFocus_(false).fixedWidth_(220)
        .drawFunc_({ |v| ~statusDrawState.(v, true) });
    ~guiTakeLabel = ~guiText.("no take", 22, nil, true);
    ~guiTakeLabel.setProperty(\wordWrap, false);
    ~guiPosShort = ~guiMonoText.("—", 14, ~gt[\ink]).fixedWidth_(70);
    ~guiPositionStrip = UserView().canFocus_(false).fixedHeight_(18 + (2 * ~statusGridInset))
        .drawFunc_({ |v| ~statusDrawGrid.(v, true) });
    ~guiOnsetLampStrip = UserView().canFocus_(false).fixedSize_(Size(16, 16))
        .drawFunc_({ |v| ~statusDrawLamp.(v) });
    ~guiLevelStrip = UserView().canFocus_(false).fixedHeight_(10)
        .drawFunc_({ |v| ~statusDrawMeter.(v, false) });
    strip = View().background_(~gt[\bg]).fixedHeight_(57).layout_(VLayout(
        View().fixedHeight_(56).layout_(HLayout(
            ~statusStateStrip,
            ~guiStatusTake = View().fixedWidth_(280).layout_(HLayout(~guiTakeLabel).margins_([18, 0, 18, 0])),
            ~guiRule.(true),
            [View().layout_(HLayout(~guiPosShort, [~guiPositionStrip, stretch: 1])
                .margins_([18, 0, 18, 0]).spacing_(14)), stretch: 1],
            ~guiRule.(true),
            ~guiStatusOnset = View().fixedWidth_(180).layout_(HLayout(~guiOnsetLampStrip, [~guiLevelStrip, stretch: 1])
                .margins_([16, 0, 16, 0]).spacing_(10))
        ).margins_(0).spacing_(0)),
        ~guiRule.()
    ).margins_(0).spacing_(0));
    ~guiStatusStripMin = strip.minSizeHint.width;
    strip
};

// The band and the strip each give their fixed columns a narrower width when
// the window is narrower than they are as designed (the words in the state
// blocks are fitted to what they get, see ~statusFitFont). Called with the
// window's width, as the top bar is (~guiTopBarFit).
~guiStatusFit = { |width|
    var band = width < (~guiStatusBandMin ? 0), strip = width < (~guiStatusStripMin ? 0);
    [
        [~statusStateLabel, band, 330, 220], [~statusCountView, band, 330, 220], [~guiStatusInput, band, 300, 210],
        [~statusStateStrip, strip, 220, 150], [~guiStatusTake, strip, 280, 190], [~guiStatusOnset, strip, 180, 130]
    ].do { |item|
        var v = item[0], to = if(item[1]) { item[3] } { item[2] };
        if(v.notNil and: { v.isClosed.not } and: { v.bounds.width != to }) { v.fixedWidth_(to) };
    };
};

// Push the whole model state into the status and the tiles at once. Used on
// build (so a rebuilt window starts correct rather than waiting for the next
// event) and available for a manual resync.
~statusRefreshAll = {
    ~statusPaintState.();
    ~statusPaintTake.();
    ~statusPaintThreshold.();
    ~statusRepaintGrids.();
    ~performRefreshAll !? { |f| f.value };
    ~bbcutPaintHeader !? { |f| f.value };
    ~granularPaintHeader !? { |f| f.value };
};

// ---- MIDI monitor -------------------------------------------------------------------------
// A controller sending a CC sweep produces messages far faster than a text view
// should be redrawn, so incoming lines are appended to a bounded buffer by the
// MIDI thread and the view is repainted on a timer, only when something changed.
// Without that throttle a knob sweep can stall the GUI.
~midiMonitorMax   = 200;   // lines kept; the oldest are dropped
~midiMonitorShown = 60;    // lines drawn: the panel shows about 30
~midiMonitorHz    = 10;    // view repaints per second
~midiMonitorLines = ~midiMonitorLines ? List.new;
~midiMonitorDirty = false;
~midiMonitorPaused = ~midiMonitorPaused ? false;

// The sink setup-midi.scd calls for every logged message. Runs on the MIDI
// thread: it may touch only plain data, never a view. It also stamps the top
// bar's MIDI lamp, paused or not.
~midiMonitorPush = { |line|
    ~guiMidiSeenAt = Main.elapsedTime;
    if(~midiMonitorPaused.not) {
        ~midiMonitorLines.add(line);
        while { ~midiMonitorLines.size > ~midiMonitorMax } { ~midiMonitorLines.removeAt(0) };
        ~midiMonitorDirty = true;
    };
};

~midiMonitorClear = {
    ~midiMonitorLines = List.new;
    ~midiMonitorDirty = true;
};

// ---- Panel ----------------------------------------------------------------
// Returns a View for the Setup view to place. Safe to re-run: the generation
// token retires the previous repaint timer.
~buildMidiMonitorPanel = {
    var gen, panel = View().background_(~gt[\bg]);
    var link = { |label| LooperTile().states_([[label, ~gt[\mute], nil]]).font_(~guiSans.(13))
        .fixedHeight_(24).pad_(4) };
    // The log's colour is its palette's, so a repaint sets the text and
    // nothing else (recolouring 200 lines took 5 ms of a 10 ms repaint).
    var pal = ~guiPalette.();
    pal.baseText = ~gt[\mute];
    ~statusGen = ~statusGen + 1;
    gen = ~statusGen;

    panel.layout_(VLayout(
        HLayout(
            ~guiText.("MIDI in", 16, nil, true),
            nil,   // spacer: pushes the links to the right
            ~midiMonitorPauseButton = link.("Pause").fixedWidth_(64)
                .states_([["Pause", ~gt[\mute], nil], ["Paused", ~gt[\onacc], ~gt[\dub]]])
                .value_(if(~midiMonitorPaused) { 1 } { 0 })
                .action_({ |b| ~midiMonitorPaused = (b.value == 1) }),
            link.("Clear").fixedWidth_(56).action_({ ~midiMonitorClear.() })
        ).margins_(0).spacing_(6),
        // Monospaced so the aligned num=/vel=/chan= columns stay readable.
        // Not editable — it is a log, and an editable view would also steal
        // the keyboard from the window's single-key shortcuts.
        [~midiMonitorView = TextView()
            .canFocus_(false)
            .editable_(false)
            .minHeight_(140)
            .palette_(pal)
            .background_(~gt[\panel])
            .font_(~guiMono.(12, false))
            .string_(~midiMonitorLines.asArray.keep(~midiMonitorShown.neg).join("\n")), stretch: 1]
    ).margins_([22, 16, 22, 16]).spacing_(8));

    ~midiMonitorPanel = panel;

    // Repaint timer. AppClock so it can touch views directly. Returning nil
    // from the function stops the clock — that is the only kill switch, so it
    // has to test every way this panel can go away, not just a closed window.
    ~midiMonitorRoutine = AppClock.sched(0, {
        var shown;
        if(gen != ~statusGen
            or: { ~guiWindow.isNil } or: { ~guiWindow.isClosed }
            or: { ~midiMonitorPanel.isNil } or: { ~midiMonitorPanel.isClosed }) {
            nil   // retired: unschedule
        } {
            // ~midiMonitorPush keeps filling the buffer while Setup is hidden
            // — it is plain data, already bounded at ~midiMonitorMax — so
            // there is nothing to catch up on but one repaint on return.
            if(~midiMonitorDirty and: {
                ~guiPaneSeen.(\midi)
            }) {
                ~midiMonitorDirty = false;
                // The newest lines only, and their length from here rather
                // than read back from Qt: every Qt call here holds the language,
                // and with it the MIDI clock (docs/dev/roadmap.md, MIDI clock
                // jitter: 10 ms a repaint swung Live's tempo; this is 1.5 ms).
                shown = ~midiMonitorLines.asArray.keep(~midiMonitorShown.neg).join("\n");
                ~midiMonitorView !? { |v|
                    v.string_(shown);
                    // Keep the newest line visible without fighting a manual
                    // scroll: only pin to the bottom, never restore a position.
                    v.select(shown.size, 0);
                };
            };
            ~midiMonitorHz.reciprocal
        };
    });

    panel
};
)
