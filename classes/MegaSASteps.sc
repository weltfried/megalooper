// Rhythmic Steps, the step sequencer from Live 12's Sequencers 2 pack that the
// Live set played Kit-Carbon from, as Megalooper SA plays it
// (docs/dev/megalooper-sa.md, Phase 4): the device's tables, the arithmetic it does
// for every step, and its two patterns as the set left them. Everything is a
// class method that takes all of its inputs as arguments, so all of it is
// testable with no server and no clock. Nothing here keeps time or makes a
// sound: MegaSADrums owns the transport, the dice's seed, the kits and the
// voices, and calls these.
//
// Reconstructed from the device's own patch (Rhythmic Steps.amxd, run by the
// Max 9.1.5 bundled with Live 12.4.6) by reading it and disassembling the three
// Max objects that decide a number (scale, function, metro). Nothing was run
// in Live or Max, so the rules below are the patch's, not measurements of it.
//
// A PATTERN (one per device: \main, and \break, which Live switched in while a
// break was open) is an Event:
//
//   (steps: (chance: [l0, l1, l2, l3], velo:, alt:, roll:, slide:)
//                   each lane 16 Integers 0..6, as the device stores them
//    lengths: (chance: [16, 16, 16, 16], velo:, alt:, roll:, slide:)   2..16
//    globalLength: [16, 16, 16, 16], lock: [false x4]
//                   a locked lane plays globalLength on every page (effectiveLength)
//    note: [42, 37, 38, 36], altNote: [44, 50, 40, 41]                  36..51
//    delay: [0.0 x4] (ms, 0..50), mute: [false x4],
//    clockSpeed: 3 (an index into stepTicks), rollRate: 5 (into rollTicks),
//    shuffle: [8 Floats] (%: Shuffle 1 0..50, the others -50..50),
//    shuffleLength: 7 (2..8), globalShuffle: 0.0 (%, 0..100),
//    autoRetrigger: true, autoTriggerRate: 0 (0..3: every 1..4 bars))
//
// Lane 0 is the device's lane 1 (the hats, in the set). Read fields as
// pattern[\key], never pattern.key: some of these names are Collection methods.
//
// What MegaSADrums does per step n of a pattern, n counting the device's steps
// from the transport's origin (the MIDI Start, in Live):
//
//   s     = stepTicks[clockSpeed]       ticks per step, 480 to the quarter note
//   v     = shuffleOffsets(shuffle, shuffleLength, globalShuffle)
//   skip n if skipsStep(n, s, v, shuffleLength)    (Live plays only the later one)
//   tick  = fireTick(n, s, v, shuffleLength)       when it fires, from the origin
//   state = resync(state, n, tick, numerator, autoRetrigger, autoTriggerRate)
//           (Live's rule; SA's default, resyncAtBar, takes the bar step n is in)
//   hits  = decideStep(pattern, n - state[\offset],
//               { |lane, kind| dice(seed, which, n, lane, kind) })
//
// then for each lane's hit: the note at the step's time plus delayMs, and its
// roll's extra hits at rollTimes(roll, rollRate, s16) after the note, at
// rollVelocities(vel, roll). A NEW note on a lane drops the hits its roll still
// had to come; a step that does not fire cuts nothing. Mute is read when a hit
// is emitted, so a muted lane still draws, cuts and rolls (decideStep ignores
// it). Both patterns run every step, as Live's switched-off device kept
// running: each draws its dice and keeps its own rolls, and only the one in
// force at a hit's time is heard. A skipped step draws nothing and is not
// offered to resync, as in the device, which never emits it. Live also arms a
// resync on the FIRST Clock Speed or Shuffle Length change after the device
// loads (its ResyncOnNextTimeShiftLoop): the caller's to apply, by setting
// state[\armed].
//
// Not modelled: Slide (CC 74, stored and kept, but one-shots ignore it), and
// the note-offs, which no kit here needs.
MegaSASteps {
    classvar liveData, paramList, paramIndex, laneList, laneParamIndex;

    // ---- The device's tables ----------------------------------------------

    // Ticks per step at 480 per quarter note, for Clock Speed 0..5. A 16th is
    // 120: Clock Speed 3 ("100 %", the set's) steps in 16ths. The labels are
    // the device's and two of them are wrong: "75 %" plays 0.8 and "150 %"
    // 1.33 times as fast.
    *stepTicks { ^#[240, 180, 150, 120, 90, 60] }
    *clockSpeedLabels { ^#["50 %", "66 %", "75 %", "100 %", "150 %", "200 %"] }

    // The spacing of a roll's extra hits, for Roll Rate 0..8, in the same ticks:
    // tempo-relative and not on the step grid. The set's 5 (1/16t) is 80, two
    // thirds of a 16th.
    *rollTicks { ^#[360, 240, 160, 180, 120, 80, 90, 60, 40] }
    *rollRateLabels { ^#["1/8.", "1/8", "1/8t", "1/16.", "1/16", "1/16t", "1/32.", "1/32", "1/32t"] }

    *autoTriggerRateLabels { ^#["1 Bar", "2 Bars", "3 Bars", "4 Bars"] }

    // Velocity per step value 0..6. Max's [scale 0 6 10 127] has integer
    // arguments, so it truncates: not the rounded 30, 69, 108 the exporter's
    // first table had. A velocity step of 0 still sounds, at 10.
    *velocities { ^#[10, 29, 49, 68, 88, 107, 127] }

    // CC 74 (MPE Slide) per step value, truncated the same way. Stored only.
    *slideValues { ^#[0, 21, 42, 63, 84, 105, 127] }

    // The sub-lanes in the device's storage order, and the pages the Drums tab
    // shows (Slide and the device's Timing page are left out of the tiles).
    *subs { ^#[\chance, \velo, \alt, \roll, \slide] }
    *pages { ^#[\chance, \alt, \velo, \roll] }

    // ---- Per step ---------------------------------------------------------

    // The velocity a step value plays at.
    *velocity { |v| ^this.velocities[(v ? 0).asInteger.clip(0, 6)] }

    // A roll's k extra hits: each at the previous velocity times 0.7, truncated,
    // computed one after the other in doubles as the device's [* 0.7] → [i]
    // does (vel 10 gives 7, which 32-bit floats would make 6).
    *rollVelocities { |vel, k|
        var f = (vel ? 0).asFloat;
        ^Array.fill((k ? 0).asInteger.max(0), { f = f * 0.7; f.floor.asInteger })
    }

    // When a roll's extra hits come, in seconds after its note: hit j at j roll
    // ticks, a tick being s16 / 120 (s16: one 16th at the tempo in force).
    *rollTimes { |k, rollRate, s16|
        var ticks = this.rollTicks[(rollRate ? 5).asInteger.clip(0, 8)];
        ^Array.fill((k ? 0).asInteger.max(0), { |i| (((i + 1) * ticks) * s16) / 120 })
    }

    // The shuffle: where step i of each shuffleLength cycle falls, in steps from
    // the cycle's start. The device scales every dial by Global Shuffle / 100
    // first, and a dial at +-50 % moves its step by +-0.4 of a step, later for
    // positive; Shuffle 1 only goes forward, so step 0 never leaves its cycle,
    // and two steps can never cross. Global Shuffle is 0 in both of the set's
    // devices, which makes these exactly 0, 1, 2...: the set plays straight.
    *shuffleOffsets { |shuffle, shuffleLength, globalShuffle|
        var g = (globalShuffle ? 0) / 100;
        ^Array.fill((shuffleLength ? 4).asInteger.clip(2, 8), { |i|
            i + ((0.008 * ((shuffle !? { |s| s[i] }) ? 0)) * g)
        })
    }

    // The tick step n fires on, an Integer from the transport's origin. The
    // device sees steps only on its 1/64-note metro, so a step fires on the
    // first multiple of 30 ticks at or after its shuffled time; the epsilon
    // keeps a time that is a multiple of 30 in exact arithmetic on it. Exactly
    // n * s when nothing is shuffled. `offsets` from shuffleOffsets; the cycle
    // is counted from the origin and shared by all four lanes, whatever their
    // resyncs do.
    *fireTick { |n, s, offsets, shuffleLength|
        var ls = (shuffleLength ? 4).asInteger.max(1);
        var i = n.asInteger % ls;
        var base = n.asInteger - i;
        var v = (offsets !? { |o| o[i] }) ? i;
        ^(30 * (((((base + v) * s) / 30) - 1e-9).ceil)).asInteger
    }

    // Two shuffled steps on one metro tick: the device's [change] only ever
    // sees the later index, so step n never plays (and draws nothing). Happens
    // at Clock Speed 150 % with neighbouring dials pulled together, never when
    // nothing is shuffled.
    *skipsStep { |n, s, offsets, shuffleLength|
        ^this.fireTick(n, s, offsets, shuffleLength) == this.fireTick(n + 1, s, offsets, shuffleLength)
    }

    // The first step that fires after `tick` (the smallest n >= 0 with
    // fireTick(n) > tick): where a pattern carries on after a Clock Speed or
    // shuffle edit, since in the device the step index is a pure function of
    // the song position and a counter kept across the edit would jump. fireTick
    // never decreases with n, and a step is never more than 0.4 of a step plus
    // one metro tick off n * s, so the scan starts two steps short.
    *firstStepAfter { |tick, s, offsets, shuffleLength|
        var n = (((tick / s) - 2).floor).asInteger.max(0);
        while { this.fireTick(n, s, offsets, shuffleLength) <= tick } { n = n + 1 };
        ^n
    }

    // The step a tick falls in, unshuffled. The epsilon keeps a tick computed
    // in floating point a hair under a step boundary on its own step.
    *stepIndexAt { |tick, s| ^(((tick / s) + 1e-6).floor).asInteger }

    // Auto Retrigger, for one step, from its state before the step to the state
    // after: (lastB:, armed:, offset:), a new Event (the one given is not
    // touched; nil is the state at the origin). The device counts pseudo-bars
    // of `numerator` QUARTER notes whatever the denominator, B = floor(floor(q +
    // 0.5) / numerator) at song position q, so a pseudo-bar's count changes an
    // eighth note before its line; every change of B arms when Auto Retrigger
    // is on and B is a multiple of autoTriggerRate + 1. The resync itself waits
    // for the next step whose index is a multiple of 8, and moves the lanes'
    // origin there: lane step = n - offset. At the origin lastB is nil, so step
    // 0 arms and resyncs. In 4/4 that is every bar line; in 3/4 the steps go 0,
    // 16, 24, 40, 48; in 7/8 0, 32, 56, 88, 112, a 16-step lane reshaping
    // itself through four bars.
    *resync { |state, n, fireTick, numerator, autoRetrigger, autoTriggerRate|
        var lastB = state !? { |st| st[\lastB] };
        var armed = (state !? { |st| st[\armed] }) == true;
        var offset = (state !? { |st| st[\offset] }) ? 0;
        var q = fireTick / 480;
        var b = ((((q + 0.5).floor) / (numerator ? 4).asInteger.max(1)).floor).asInteger;
        if(b != lastB) {
            lastB = b;
            if((autoRetrigger == true)
                and: { (b % ((autoTriggerRate ? 0).asInteger.max(0) + 1)) == 0 }) { armed = true };
        };
        if(armed and: { (n % 8) == 0 }) { offset = n; armed = false };
        ^(lastB: lastB, armed: armed, offset: offset)
    }

    // Auto Retrigger on the real bar lines (MegaSADrums.retrigAt \barLine): the
    // same state, but `bar` is the bar step n is in (counted from the origin,
    // uneven bars too), and the lanes start again ON the step where it changes,
    // not on the next multiple of 8. Every rateth bar, as in resync: B a
    // multiple of autoTriggerRate + 1. An armed state (Live's resync on the
    // first time-shift edit) resyncs on the next bar line even with Auto
    // Retrigger off. At the origin lastB is nil, so step 0 resyncs.
    *resyncAtBar { |state, n, bar, autoRetrigger, autoTriggerRate|
        var lastB = state !? { |st| st[\lastB] };
        var armed = (state !? { |st| st[\armed] }) == true;
        var offset = (state !? { |st| st[\offset] }) ? 0;
        if(bar != lastB) {
            lastB = bar;
            if(armed or: { (autoRetrigger == true)
                and: { (bar % ((autoTriggerRate ? 0).asInteger.max(0) + 1)) == 0 } }) {
                offset = n;
                armed = false;
            };
        };
        ^(lastB: lastB, armed: armed, offset: offset)
    }

    // Where a lane step reads a sub-lane of `len` steps: every sub-lane wraps on
    // its own length from the one lane step. Never negative: a lane step
    // before the latest resync (a re-derived old step) still reads a step.
    *laneIndex { |ls, len| ^ls.asInteger % (len ? 16).asInteger.max(1) }

    // The length a sub-lane plays: its own, or the lane's global length while
    // the lane is locked. The device keeps both as separate parameters, so
    // setting the global length never writes the others, and unlocking brings
    // them back.
    *effectiveLength { |pattern, sub, lane|
        ^if(pattern[\lock][lane] == true) { pattern[\globalLength][lane] }
            { pattern[\lengths][sub][lane] }
    }

    // What one step plays: an Array of four entries, index = lane, each nil (no
    // note) or (note:, vel:, roll:, delayMs:, alt:). `ls` is the lane step (n -
    // offset); `diceFunc` is called as diceFunc.(lane, kind) and must answer an
    // Integer 0..5. The draws go in the device's order, its lanes 4, 3, 2, 1
    // (here 3..0), each lane alt first and then chance, and every lane draws
    // both even when muted or at 0: with dice that are a pure function of the
    // step (dice, below) the order changes nothing, but a scripted or
    // sequential source sees what Live's [random 6]s saw. A step fires iff its
    // chance value beats its die (> : 0 never, 6 always, k with probability
    // k/6); alt, its own draw, picks altNote over note the same way. The roll
    // is the number of extra hits; mute is not applied here.
    *decideStep { |pattern, ls, diceFunc|
        var hits = Array.newClear(4);
        var steps = pattern[\steps];
        #[3, 2, 1, 0].do { |lane|
            var alt, fire, read;
            read = { |sub|
                steps[sub][lane][this.laneIndex(ls, this.effectiveLength(pattern, sub, lane))] ? 0
            };
            alt = read.(\alt) > diceFunc.value(lane, \alt);
            fire = read.(\chance) > diceFunc.value(lane, \chance);
            if(fire) {
                hits[lane] = (
                    note: if(alt) { pattern[\altNote][lane] } { pattern[\note][lane] },
                    vel: this.velocity(read.(\velo)),
                    roll: read.(\roll),
                    delayMs: pattern[\delay][lane],
                    alt: alt
                );
            };
        };
        ^hits
    }

    // ---- The dice ---------------------------------------------------------

    // A die, uniform 0..5, that is a pure function of (seed, which pattern,
    // step n, lane, kind), so a step decided twice (a cut re-derives what it
    // cancelled) draws exactly what it drew the first time. The seed is
    // MegaSADrums', drawn again at every transport start. kind: \alt, \chance,
    // \repeat (Beat Repeat's per pad and capture; lane may then be the pad's
    // note) or \onset; anything else shares one code.
    //
    // A tested integer hash rather than the thread's RNG. Reseeding the
    // interpreter's generator for every die (save randData, randSeed = a key
    // packing the inputs, 6.rand, restore) was tried first: with the seed
    // XORed into the key, seed 0's main dice were seed 1's break dice, and one
    // seed's 60000 draws sat at the 0.001 line of the chi-square (21 on 5
    // degrees of freedom). A hash needs no thread state either. Each input
    // goes through murmur3's 32-bit finalizer in turn, which leans on sclang's
    // Integers wrapping at 32 bits; test-megadrums.scd checks it against a
    // reference implementation with explicit masks, and its uniformity and
    // independence by chi-square.
    *dice { |seed, which, n, lane, kind|
        ^((this.uniform(seed, which, n, lane, kind) * 6).floor.asInteger).min(5)
    }

    // The same hash as a Float in [0, 1), for a chance that is not k/6 (Beat
    // Repeat's 0.236 per capture).
    *uniform { |seed, which, n, lane, kind|
        var h = this.prHash([seed ? 0, this.prWhichCode(which), n ? 0, lane ? 0,
            this.prKindCode(kind)]);
        ^h.bitAnd(2147483647) / 2147483648.0
    }

    *prWhichCode { |which| ^case { which == \main } { 0 } { which == \break } { 1 } { 2 } }

    *prKindCode { |kind| ^#[\alt, \chance, \repeat, \onset].indexOf(kind) ? 7 }

    *prHash { |values|
        var h = -2128831035;   // 0x811C9DC5, as a signed 32-bit Integer
        values.do { |x| h = this.prMix(h.bitXor(x.asInteger) - 1640531527) };   // + 0x9E3779B9
        ^h
    }

    // murmur3's fmix32. sclang's >> keeps the sign, so each shift is masked to
    // the logical one; the multipliers are 0x85EBCA6B and 0xC2B2AE35 as signed
    // Integers.
    *prMix { |h|
        h = h.bitXor((h >> 16).bitAnd(65535));
        h = h * -2048144789;
        h = h.bitXor((h >> 13).bitAnd(524287));
        h = h * -1028477387;
        ^h.bitXor((h >> 16).bitAnd(65535))
    }

    // ---- The patterns -----------------------------------------------------

    // The set's pattern for \main or \break, a fresh copy each call (nil, with
    // a warning, for anything else). Generated from presets/sa/rhythmic-
    // steps.json (tools/export-live-set.py steps), which test-megadrums.scd
    // compares field by field: keep the two in step. The two devices differ
    // only in their chance steps; the break plays only its first lane.
    *livePattern { |which|
        var p = this.prLive[which];
        if(p.isNil) {
            ("MegaSASteps: no shipped pattern " ++ which ++ "; there are \\main and \\break.").warn;
            ^nil
        };
        ^p.deepCopy
    }

    *prLive { ^liveData ?? { liveData = this.prLiveData } }

    // A Rhythmic Steps as Live inserts it: every parameter at its patch's
    // initial value (pads 39, 42, 38, 36 with alternates 37, 46, 40, 41, Roll
    // Rate 1/32, Shuffle Length 4, Global Shuffle 100 %, Auto Retrigger off),
    // and the step lists as its Reset buttons leave them: 0, and 4 for velocity.
    *newPattern {
        var lanes = { |v| Array.fill(4, { Array.fill(16, v) }) };
        var lens = { [16, 16, 16, 16] };
        ^(
            steps: (chance: lanes.(0), velo: lanes.(4), alt: lanes.(0), roll: lanes.(0),
                slide: lanes.(0)),
            lengths: (chance: lens.(), velo: lens.(), alt: lens.(), roll: lens.(), slide: lens.()),
            globalLength: lens.(), lock: [false, false, false, false],
            note: [39, 42, 38, 36], altNote: [37, 46, 40, 41],
            delay: [0.0, 0.0, 0.0, 0.0], mute: [false, false, false, false],
            clockSpeed: 3, rollRate: 7, shuffle: Array.fill(8, 0.0), shuffleLength: 4,
            globalShuffle: 100.0, autoRetrigger: false, autoTriggerRate: 0
        )
    }

    // ---- Settings ---------------------------------------------------------
    // One row per pattern setting a player may move, like MegaSAFx's table:
    // name, label, the range as a ControlSpec whose default is the Live set's
    // value (both devices agree on all of these), choices for a setting picked
    // from a list (stored as its index), bool for a switch (stored as a
    // Boolean), centered for a bipolar knob, units, and the tip. A shuffle row
    // also has index: which of pattern[\shuffle] it is. MegaSADrums keeps the
    // values per pattern; the Drums tab draws them.
    *paramSpecs { ^paramList ?? { paramList = this.prParamTable } }

    *paramSpec { |name|
        paramIndex ?? {
            paramIndex = IdentityDictionary.new;
            this.paramSpecs.do { |p| paramIndex.put(p[\name], p) };
        };
        ^paramIndex[name]
    }

    // The per-lane settings: the same shape, plus live: the set's value for
    // each of the four lanes (the spec's default is lane 0's). \length is the
    // per-page length (pattern[\lengths][sub][lane]), the others live at
    // pattern[name][lane].
    *laneParamSpecs { ^laneList ?? { laneList = this.prLaneTable } }

    *laneParamSpec { |name|
        laneParamIndex ?? {
            laneParamIndex = IdentityDictionary.new;
            this.laneParamSpecs.do { |p| laneParamIndex.put(p[\name], p) };
        };
        ^laneParamIndex[name]
    }

    // A step value, 0..6.
    *stepSpec { ^ControlSpec(0, 6, \lin, 1, 0) }

    // A value as a row stores it: held to the range and step (an Integer for a
    // stepped row, a Float otherwise), or a Boolean for a switch (true, false,
    // or a number, 0.5 and up being on). nil when the row is nil or the value is
    // none of those, so the caller can say so.
    *constrainParam { |name, value| ^this.prConstrain(this.paramSpec(name), value) }
    *constrainLaneParam { |name, value| ^this.prConstrain(this.laneParamSpec(name), value) }
    *constrainStep { |value| ^this.prConstrain((spec: this.stepSpec), value) }

    *prConstrain { |row, value|
        var v;
        if(row.isNil) { ^nil };
        if(row[\bool] == true) {
            ^case
                { value == true } { true }
                { value == false } { false }
                { value.isNumber and: { value.isNaN.not } } { value >= 0.5 }
                { nil }
        };
        if(value.isNumber.not or: { value.isNaN } or: { value.abs == inf }) { ^nil };
        v = row[\spec].constrain(value);
        ^if(row[\spec].step >= 1) { v.round.asInteger } { v.asFloat }
    }

    // Reading and writing a pattern's settings by name. The put methods store
    // the constrained value in the pattern given and answer it, or answer nil
    // and change nothing when the name, the lane, the sub-lane, the step or the
    // value is not one there is. They never warn: the model's setters do.
    *getParam { |pattern, name|
        var row = this.paramSpec(name);
        ^case
            { row.isNil } { nil }
            { row[\index].notNil } { pattern[\shuffle][row[\index]] }
            { pattern[name] }
    }

    *putParam { |pattern, name, value|
        var row = this.paramSpec(name);
        var v = this.prConstrain(row, value);
        if(v.isNil) { ^nil };
        if(row[\index].notNil) { pattern[\shuffle].put(row[\index], v) } { pattern.put(name, v) };
        ^v
    }

    *getLaneParam { |pattern, lane, name|
        if(this.prLaneOk(lane).not or: { name == \length }
            or: { this.laneParamSpec(name).isNil }) { ^nil };
        ^pattern[name][lane]
    }

    *putLaneParam { |pattern, lane, name, value|
        var v;
        if(this.prLaneOk(lane).not or: { name == \length }) { ^nil };
        v = this.constrainLaneParam(name, value);
        if(v.isNil) { ^nil };
        pattern[name].put(lane, v);
        ^v
    }

    *putLength { |pattern, sub, lane, value|
        var v;
        if(this.subs.includes(sub).not or: { this.prLaneOk(lane).not }) { ^nil };
        v = this.constrainLaneParam(\length, value);
        if(v.isNil) { ^nil };
        pattern[\lengths][sub].put(lane, v);
        ^v
    }

    // ---- Randomize, as the device's two dice ------------------------------
    // One lane of one page, all 16 steps whatever the lane's length, as the
    // device's patch does it (its "p Setters": Random and NotSoRandom, each
    // acting on the tab shown):
    //   \all   every step a new value from 0 to 6, each as likely ("Randomise
    //          all steps": 16 times `random 7`);
    //   \less  every step moves by -1, 0 or +1, each as likely, and is held
    //          to 0..6 ("Randomize Less": value + `random 3` - 1, clipped).
    // `draw` is called with n and answers an Integer from 0 to n - 1: the
    // language's dice, or a test's. nil for an amount that is neither.
    *randomized { |values, amount = \all, draw|
        draw = draw ?? { { |n| n.rand } };
        ^switch(amount,
            \all, { Array.fill(16, { draw.value(7).asInteger.clip(0, 6) }) },
            \less, { (values ? (0 ! 16)).keep(16).collect { |v| (v + draw.value(3).asInteger - 1).clip(0, 6) } },
            { nil })
    }

    *putStep { |pattern, sub, lane, i, value|
        var v;
        if(this.subs.includes(sub).not or: { this.prLaneOk(lane).not }
            or: { i.isInteger.not } or: { i < 0 } or: { i > 15 }) { ^nil };
        v = this.constrainStep(value);
        if(v.isNil) { ^nil };
        pattern[\steps][sub][lane].put(i, v);
        ^v
    }

    *prLaneOk { |lane| ^lane.isInteger and: { lane >= 0 } and: { lane <= 3 } }

    // An Array or a List: a String is an ArrayedCollection too, and isArray
    // says yes to it.
    *prIsList { |x| ^x.isKindOf(Array) or: { x.isKindOf(List) } }

    // A whole pattern from something read back (a preset), fail-soft by field:
    // every field `data` has and that holds goes in, constrained, and every
    // other one keeps the Live set's value for `which`. A field present but not
    // usable adds a line to `warnings` (a List), as does a key that is no
    // field; a missing field adds nothing (saved before it existed). Answers a
    // new, complete pattern; `data` is not touched.
    *cleanPattern { |data, which, warnings|
        var clean = this.livePattern(which) ?? { this.livePattern(\main) };
        var notes = warnings ?? { List.new };
        var known = [\steps, \lengths, \globalLength, \lock, \note, \altNote, \delay, \mute]
            ++ this.paramSpecs.reject { |p| p[\index].notNil }.collect { |p| p[\name] } ++ [\shuffle];
        // What a put did with a value: refused it (the Live set's stays, said
        // so) or held it to the range (said so too); a value it took as given
        // says nothing.
        var report = { |label, given, stored, fallback|
            case
            { stored.isNil } {
                notes.add(label ++ " " ++ given.asCompileString ++ " is not usable -> "
                    ++ fallback.asCompileString)
            }
            { given.isNumber and: { stored.isNumber }
                and: { (stored - given).abs > (given.abs * 1e-9).max(1e-12) } } {
                notes.add(label ++ " " ++ given ++ " -> " ++ stored ++ " (range)")
            };
        };
        var lanesOf = { |key, put|
            var got = data[key];
            if(got.notNil) {
                if(this.prIsList(got) and: { got.size == 4 }) {
                    got.do { |v, lane|
                        report.(key.asString ++ "[" ++ lane ++ "]", v, put.(lane, v), clean[key][lane]);
                    };
                } { notes.add(key.asString ++ " is not four lanes -> the default") };
            };
        };
        if(data.isKindOf(Dictionary).not) {
            notes.add("not a pattern (expected an Event) -> the default");
            ^clean
        };
        this.subs.do { |sub|
            var got = data[\steps] !? { |st| if(st.isKindOf(Dictionary)) { st[sub] } };
            if(got.notNil) {
                if(this.prIsList(got) and: { got.size == 4 }
                    and: { got.every { |l| this.prIsList(l) and: { l.size == 16 } } }) {
                    got.do { |lane, li| lane.do { |v, i|
                        report.("steps " ++ sub ++ " lane " ++ li ++ " step " ++ i, v,
                            this.putStep(clean, sub, li, i, v), clean[\steps][sub][li][i]);
                    } };
                } { notes.add("steps " ++ sub ++ " are not 4 x 16 values -> the default") };
            };
            got = data[\lengths] !? { |le| if(le.isKindOf(Dictionary)) { le[sub] } };
            if(got.notNil) {
                if(this.prIsList(got) and: { got.size == 4 }) {
                    got.do { |v, li|
                        report.("lengths " ++ sub ++ "[" ++ li ++ "]", v, this.putLength(clean, sub, li, v),
                            clean[\lengths][sub][li]);
                    };
                } { notes.add("lengths " ++ sub ++ " is not four lanes -> the default") };
            };
        };
        [\globalLength, \lock, \note, \altNote, \delay, \mute].do { |key|
            lanesOf.(key, { |lane, v| this.putLaneParam(clean, lane, key, v) });
        };
        this.paramSpecs.do { |p|
            var got = if(p[\index].notNil) { data[\shuffle] !? { |sh| if(this.prIsList(sh)) { sh[p[\index]] } } }
                { data[p[\name]] };
            got !? { |v| report.(p[\name].asString, v, this.putParam(clean, p[\name], v), this.getParam(clean, p[\name])) };
        };
        if(data[\shuffle].notNil and: { this.prIsList(data[\shuffle]).not or: { data[\shuffle].size != 8 } }) {
            notes.add("shuffle is not eight values -> the default where missing");
        };
        data.keys.do { |k|
            if(known.includes(k).not) { notes.add(k.asString ++ " is no pattern field (ignored)") };
        };
        ^clean
    }

    *prParamTable {
        var live = this.livePattern(\main);
        var shuffleTip = { |n|
            var only = if(n == 1) { " Only forward: step 1 cannot leave its cycle." } { "" };
            "Shifts step " ++ n ++ " of each Shuffle Length cycle (the device's \"respective\n"
            "clock division\"): +-50 % is +-0.4 of a step, later for plus, scaled by Global\n"
            "Shuffle and put on Live's 1/64 grid." ++ only
            ++ "\nThe set's dial is heard only with Global Shuffle above 0 %."
        };
        ^[
            (name: \clockSpeed, label: "Clock",
                spec: ControlSpec(0, 5, \lin, 1, live[\clockSpeed]),
                choices: this.clockSpeedLabels.collect { |l, i| [i, l] },
                tip: "The clock speed: how long a step is. 100 % (the set's) is a\n"
                    "16th. The labels are the device's; 75 % really plays 0.8 and 150 % 1.33\n"
                    "times as fast."),
            (name: \rollRate, label: "Roll",
                spec: ControlSpec(0, 8, \lin, 1, live[\rollRate]),
                choices: this.rollRateLabels.collect { |l, i| [i, l] },
                tip: "The frequency of note repeats in beat time: how far apart a roll's extra hits\n"
                    "are, off the step grid. 1/16t in the set, two thirds of a 16th."),
            (name: \autoRetrigger, label: "Retrig", bool: true,
                spec: ControlSpec(0, 1, \lin, 1, live[\autoRetrigger].binaryValue),
                choices: [[0, "Off"], [1, "On"]],
                tip: "Automatically resyncs all sequences, every Auto Trigger Rate. On in the set.\n"
                    "The lanes start again on the first step of every bar, uneven bars too, so\n"
                    "in 7/8 a 16-step lane plays 14 steps a bar and an 8/8 bar all 16. Live's\n"
                    "device waited for pseudo-bars of <numerator> quarter notes instead\n"
                    "(MegaSADrums.retrigAt = \\live)."),
            (name: \autoTriggerRate, label: "Retrig Rate",
                spec: ControlSpec(0, 3, \lin, 1, live[\autoTriggerRate]),
                choices: this.autoTriggerRateLabels.collect { |l, i| [i, l] },
                tip: "With Auto Retrigger on, how often the sequences are resynced: every bar in\n"
                    "the set."),
            (name: \shuffleLength, label: "Shuffle Len",
                spec: ControlSpec(2, 8, \lin, 1, live[\shuffleLength]),
                tip: "How many steps the shuffle's cycle spans: the cycle\n"
                    "Shuffle 1..8 repeat over, counted from the transport's start. 7 in the set."),
            (name: \globalShuffle, label: "Global Shuf.", units: " %",
                spec: ControlSpec(0, 100, \lin, 0, live[\globalShuffle]),
                tip: "Scales every Shuffle dial: the overall amount of timing deviation. 0 % in both\n"
                    "of the set's devices, so the set plays straight 16ths whatever the dials say.")
        ] ++ (1..8).collect { |n|
            (name: ("shuffle" ++ n).asSymbol, index: n - 1, label: "Shuffle " ++ n, units: " %",
                centered: n > 1,
                spec: if(n == 1) { ControlSpec(0, 50, \lin, 0, live[\shuffle][0]) }
                    { ControlSpec(-50, 50, \lin, 0, live[\shuffle][n - 1]) },
                tip: shuffleTip.(n))
        }
    }

    *prLaneTable {
        var live = this.livePattern(\main);
        ^[
            (name: \note, label: "Note", spec: ControlSpec(36, 51, \lin, 1, live[\note][0]),
                live: live[\note],
                tip: "The drum pad this lane plays: 42, 37, 38 and 36 in the set (hats, sidestick,\n"
                    "snare, kick)."),
            (name: \altNote, label: "Alt", spec: ControlSpec(36, 51, \lin, 1, live[\altNote][0]),
                live: live[\altNote],
                tip: "The alternative pad, played when the lane's Alt step wins its own draw: 44,\n"
                    "50, 40 and 41 in the set (the kick's never plays: its Alt steps are 0)."),
            (name: \delay, label: "D", units: " ms", spec: ControlSpec(0, 50, \lin, 0, live[\delay][0]),
                live: live[\delay],
                tip: "Moves this lane later by this many milliseconds: its notes and\n"
                    "their rolls, later only. 0 in the set."),
            (name: \mute, label: "M", bool: true,
                spec: ControlSpec(0, 1, \lin, 1, live[\mute][0].binaryValue),
                choices: [[0, "Off"], [1, "On"]], live: live[\mute],
                tip: "Silences the lane. As in Live, a muted lane keeps drawing its dice and\n"
                    "running its rolls, so it comes back exactly where it would have been."),
            (name: \lock, label: "Lock", bool: true,
                spec: ControlSpec(0, 1, \lin, 1, live[\lock][0].binaryValue),
                choices: [[0, "Off"], [1, "On"]], live: live[\lock],
                tip: "One length for all the lane's pages: while on, every page of the lane plays\n"
                    "Global Len steps; off, each page its own length again (both are kept)."),
            (name: \globalLength, label: "Global Len",
                spec: ControlSpec(2, 16, \lin, 1, live[\globalLength][0]), live: live[\globalLength],
                tip: "The length in steps for the lane's whole sequence, every page at once, while\n"
                    "Lock is on. 16 in the set."),
            (name: \length, label: "L", spec: ControlSpec(2, 16, \lin, 1, live[\lengths][\chance][0]),
                live: live[\lengths][\chance],
                tips: (chance: "The length in steps for the Chance sequence.",
                    velo: "The length in steps for the velocity sequence.",
                    alt: "The length in steps for the alternate pad sequence.",
                    roll: "The length in steps for the Roll sequence.",
                    slide: "The length in steps for the Slide (Modulation) sequence."),
                tip: "The length in steps of this page of the lane: it wraps on its own, from the\n"
                    "one lane step, so pages of different lengths drift against each other. 16 in\n"
                    "the set.")
        ]
    }

    // Generated from presets/sa/rhythmic-steps.json, lanes 1..4 to 0..3: Velo,
    // Alt, Roll, Slide-Steps[n] -> steps; Length Chance, Velocity, Alternate,
    // Roll, Mod n -> lengths (Mod is Slide's); Global Length n, Lock Length n,
    // Pad Note n, Pad Alt Note n, Delay n, Mute n; and the device's Clock Speed,
    // Roll Rate, Shuffle 1..8, Shuffle Length, Global Shuffle, Auto Retrigger,
    // Auto Trigger Rate. Its Timing Page (which shuffle dials Push shows) is not
    // a pattern setting.
    *prLiveData {
        ^(
            main: (
                steps: (
                    chance: [
                        [4, 1, 3, 2, 6, 0, 0, 4, 0, 6, 0, 4, 0, 1, 3, 2],
                        [0, 0, 0, 1, 1, 0, 1, 0, 1, 0, 0, 0, 1, 0, 1, 1],
                        [0, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
                        [4, 0, 0, 0, 2, 0, 0, 0, 2, 0, 0, 0, 2, 0, 0, 0]
                    ],
                    velo: [
                        [4, 4, 1, 0, 4, 1, 3, 0, 1, 1, 2, 2, 4, 6, 4, 6],
                        [3, 0, 1, 6, 6, 0, 1, 1, 1, 4, 6, 6, 1, 4, 0, 3],
                        [4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4],
                        [4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4]
                    ],
                    alt: [
                        [3, 6, 2, 3, 0, 0, 0, 1, 0, 1, 2, 3, 3, 0, 3, 3],
                        [0, 0, 3, 0, 3, 0, 2, 4, 1, 1, 0, 4, 2, 6, 3, 3],
                        [4, 2, 2, 4, 5, 2, 0, 6, 2, 6, 4, 0, 1, 2, 2, 0],
                        [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
                    ],
                    roll: [
                        [0, 2, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 2, 2, 1, 0],
                        [1, 0, 0, 1, 0, 1, 0, 1, 1, 0, 0, 1, 0, 0, 1, 0],
                        [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
                        [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
                    ],
                    slide: [
                        [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
                        [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
                        [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
                        [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
                    ]
                ),
                lengths: (chance: [16, 16, 16, 16], velo: [16, 16, 16, 16], alt: [16, 16, 16, 16],
                    roll: [16, 16, 16, 16], slide: [16, 16, 16, 16]),
                globalLength: [16, 16, 16, 16],
                lock: [false, false, false, false],
                note: [42, 37, 38, 36], altNote: [44, 50, 40, 41],
                delay: [0.0, 0.0, 0.0, 0.0],
                mute: [false, false, false, false],
                clockSpeed: 3, rollRate: 5,
                shuffle: [29.3825111, -39.5962143, -28.469965, -27.4877377, -39.6661339,
                    -21.7250538, 20.3647537, 29.7032642],
                shuffleLength: 7, globalShuffle: 0.0,
                autoRetrigger: true, autoTriggerRate: 0
            ),
            break: (
                steps: (
                    chance: [
                        [6, 0, 0, 0, 6, 0, 0, 0, 6, 0, 0, 0, 6, 0, 0, 0],
                        [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
                        [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
                        [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
                    ],
                    velo: [
                        [4, 4, 1, 0, 4, 1, 3, 0, 1, 1, 2, 2, 4, 6, 4, 6],
                        [3, 0, 1, 6, 6, 0, 1, 1, 1, 4, 6, 6, 1, 4, 0, 3],
                        [4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4],
                        [4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4]
                    ],
                    alt: [
                        [3, 6, 2, 3, 0, 0, 0, 1, 0, 1, 2, 3, 3, 0, 3, 3],
                        [0, 0, 3, 0, 3, 0, 2, 4, 1, 1, 0, 4, 2, 6, 3, 3],
                        [4, 2, 2, 4, 5, 2, 0, 6, 2, 6, 4, 0, 1, 2, 2, 0],
                        [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
                    ],
                    roll: [
                        [0, 2, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 2, 2, 1, 0],
                        [1, 0, 0, 1, 0, 1, 0, 1, 1, 0, 0, 1, 0, 0, 1, 0],
                        [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
                        [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
                    ],
                    slide: [
                        [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
                        [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
                        [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
                        [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
                    ]
                ),
                lengths: (chance: [16, 16, 16, 16], velo: [16, 16, 16, 16], alt: [16, 16, 16, 16],
                    roll: [16, 16, 16, 16], slide: [16, 16, 16, 16]),
                globalLength: [16, 16, 16, 16],
                lock: [false, false, false, false],
                note: [42, 37, 38, 36], altNote: [44, 50, 40, 41],
                delay: [0.0, 0.0, 0.0, 0.0],
                mute: [false, false, false, false],
                clockSpeed: 3, rollRate: 5,
                shuffle: [29.3825111, -39.5962143, -28.469965, -27.4877377, -39.6661339,
                    -21.7250538, 20.3647537, 29.7032642],
                shuffleLength: 7, globalShuffle: 0.0,
                autoRetrigger: true, autoTriggerRate: 0
            )
        )
    }
}
