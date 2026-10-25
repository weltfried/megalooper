// The rigs the tests know: the duo's, as they were in setup-routing.scd until
// 2026-10-25, when they moved out of the release into the duo's own
// profiles.scd. The harness hands them to setup-routing.scd
// (~routingProfilesExtra), so every test sees the same profile table it was
// written against: Live rigs with a clean tap (bhTsMega), an SA rig with a
// bass on its own interface (sa), and a looper with no Live and no SA
// (standalone). Device names are the duo's; no test opens a device.
(
    // Guitar is on analog in 1 = SC 0, so the tap needs no extra channels.
    // NOTE: fireface / loopback / bhFireface set neither onsetNoteOffsetMs nor
    // abletonSyncMs, so both default to 0 and were absorbing nothing. The
    // 2026-09-07 loopStartTime fix moved them by the full 200 ms as well — from
    // ~185 ms late to ~15 ms early. That is an improvement, but they still owe
    // Live's audio path, so expect to need a positive offset in the same range
    // the calibrated rigs landed in. Left unset rather than guessed: no
    // measurement has ever been taken on any of them.
    fireface: (
        device: "Fireface 400 (E15)", numChans: 18,
        midiMap: "tsmega",
        inChannel: 8, outChannel: 10, returnChannel: 12,
        analysisChannel: 0,
        sessionChannel: nil,
        inChannelCount: 2, latencyMs: 28),
    // The guitar enters as a Loopback SOURCE on ch 3, and what a source feeds is
    // readable on the matching capture channel — so SC reads it at index 2.
    loopback: (
        device: "SC-Live Bridge", numChans: 14,
        midiMap: "tsmega",
        inChannel: 8, outChannel: 10, returnChannel: 12,
        analysisChannel: 2,
        sessionChannel: nil,
        inChannelCount: 2, latencyMs: 28),
    // BlackHole rigs. Identical apart from the aggregate they name: BlackHole
    // is first in every one, so it owns ch 1-16 and SC's offsets never change.
    // numChans 16 asks for the BlackHole block only — the interface sits above
    // it at ch 17+ and belongs to Live, not to us. The ONE exception is the
    // analysis tap: the interface's input 1 (the guitar) is aggregate ch 17 =
    // SC index 16, so inputs reach 17 while outputs stay at 16. Where latencyMs
    // is still 15 it is a STARTING GUESS (the round trip is BlackHole + both
    // buffers, no hardware) — measure it with the Overdub lat slider and write
    // the value back here, as bhTsMega below has been.
    //
    // `members` is what the aggregate is supposed to CONTAIN, in order. It is not
    // used to build anything — it is there so the preflight can say "BlackHole
    // 16ch is present, TSMEGA is gone" instead of only "this device has 2 fewer
    // channels than it should". A member that comes and goes (headphones!) moves
    // every channel above it, silently.
    bhFireface: (
        device: "MegaLoop BH (Fireface)", numChans: 16, numInChans: 17,
        midiMap: "tsmega",
        members: ["BlackHole 16ch", "Fireface 400 (E15)"],
        inChannel: 8, outChannel: 10, returnChannel: 12,
        analysisChannel: 16,
        sessionChannel: nil,
        inChannelCount: 2, latencyMs: 15, sampleRate: 48000),
    // Device name has NO space in "TSMega" — it must match CoreAudio exactly
    // enough for the boot guard's lenient match, and "TS Mega" does not.
    // Aggregate member order is BlackHole -> TSMEGA -> MacBook Pro Speakers, so
    // outputs run BlackHole 1-16, TSMEGA 17-18, speakers 19-20 (Live's Master
    // goes to 19/20 — Live refuses to drive TSMEGA's own outputs), while inputs
    // are BlackHole 1-16 then TSMEGA 17-18, which is why the guitar — and so
    // analysisChannel — sits at ch 17 = SC index 16.
    //
    // Overdub round trip, by ear: 33 ms on 2026-08-12, re-dialled to 54 on
    // 2026-09-07. Independent of that day's loopStartTime fix — `latencyMs` never
    // read loopStartTime — so the change reflects the rig (buffer size, sample
    // rate, Live's plugin chain), not the fix. Its only consumers are the engine's
    // overdub write head and, on rigs that analyse the RECORDED input rather than
    // the clean tap, the overdub onset folding; this rig uses the tap, so that
    // second path reads 0 here.
    //
    // `latencyMs` stays at its measured 33 and is NOT one of the offsets below:
    // it compensates a round trip into the buffer rather than an offset out to
    // Live, only ever runs in one direction (the setter clips it at 0), and its
    // slider tops out at 100.
    //
    // THE TWO OFFSETS ARE NOT THE SAME NUMBER. They both sat at -132 before the
    // 2026-09-07 fix and that looked like a law; it was not. Both had been
    // dialled by ear, and ear precision here is ~±15 ms, so -132 was merely
    // "close enough" for both. With the fix in and everything else correct the
    // difference became audible, and they were split: the clock wants +68, the
    // notes want +53. Different streams — the clock drives Live's transport
    // while notes are quantised to its next audio block and then run a drum
    // rack — so there was never a reason to expect them to agree.
    bhTsMega: (
        device: "MegaLoop BH (TSMega)", numChans: 16, numInChans: 17,
        midiMap: "tsmega",
        members: ["BlackHole 16ch", "TSMEGA", "MacBook Pro Speakers"],
        inChannel: 8, outChannel: 10, returnChannel: 12,
        analysisChannel: 16,
        // BlackHole 1-2, which this rig leaves unused. Needs the Resampling
        // track in the Ableton set (Audio From: Resampling, Monitor: In, Audio
        // To: Ext. Out 1/2) — without it the master file records silence. See
        // "Recording the set" in docs/routing.md.
        sessionChannel: 0,
        //
        // 2026-09-07: loopStartTime stopped carrying the skew these three were
        // each silently absorbing (see spawnEngine).
        //
        // The shift to apply is the CONSTANT THE CODE REMOVED — `server.latency`,
        // exactly 0.200 — not the 185 ms that was measured. Those are different
        // quantities: the measured skew is the gap between loopStartTime and the
        // audio, while what determines behaviour is how far loopStartTime itself
        // moved, and it moved by exactly the constant. Anything firing at
        // `loopStartTime + p + trim` now fires 200 ms earlier, so each trim needs
        // exactly +200 to sit where it did.
        //     onsetNoteOffsetMs  -132 -> +68 -> +53   (CONFIRMED by ear)
        //     abletonSyncMs      -132 -> +68           (CONFIRMED by ear)
        //     chainRecOffsetMs   -134 -> +59           (MEASURED, tool-verified)
        //
        // All three are now settled on this rig. The notes landing 15 ms below
        // the +200 arithmetic is the old -132 having been ~15 ms off within ear
        // precision, not the shift being wrong: the clock, dialled from the same
        // old -132, confirmed at exactly +68.
        //
        // chainRecOffsetMs is the one re-measured after the fix: with +51 in place
        // check-chain-align.scd reported an 8 ms residual on both copies at
        // correlation 0.956. Note it implies a shift of ~193, not 200 — both it
        // and the -134 before it were measured at 2 ms resolution, so the 7 ms
        // gap is real and unexplained. Treat the two DERIVED values as +68 ± 10
        // and settle them by ear; do not "correct" the measured 59 to match.
        //
        // They should now be small and physically meaningful — the real path
        // difference between what SC sends and what Live puts out — rather than
        // a large number dominated by a bug. `latencyMs` is unaffected: it never
        // read loopStartTime.
        inChannelCount: 2, latencyMs: 54,
        onsetNoteOffsetMs: 53, abletonSyncMs: 68, chainRecOffsetMs: 59,
        sampleRate: 48000),
    // The awkward one. "External Headphones" only exists in CoreAudio while
    // something is plugged into the jack, and it sits BELOW the speakers in the
    // member list — so unplugging headphones does not just change where you
    // monitor, it slides every output above it down by two. Live's Master at
    // 17/18 lands on the headphones with them in and on the speakers with them
    // out. The preflight reports the member as missing for exactly that reason.
    bhBuiltin: (
        device: "MegaLoop BH (Built-in)", numChans: 16, numInChans: 17,
        midiMap: "tsmega",
        members: ["BlackHole 16ch", "External Headphones",
            "MacBook Pro Speakers", "stereo mic"],
        inChannel: 8, outChannel: 10, returnChannel: 12,
        analysisChannel: 16,
        sessionChannel: nil,
        // Dialled in by ear on the rig 2026-09-11, replacing the +84/+84 that
        // had only been DERIVED (calibrated at -116 on 2026-09-06, then shifted
        // +200 on 2026-09-07 when loopStartTime stopped carrying that skew).
        //
        // They split widely — 63 against 150 — which is the same lesson bhTsMega
        // taught at a smaller scale: these two travel different paths to the ear
        // and there is no reason for them to agree. Dial them independently.
        //
        // NOTE abletonSyncMs 150 is exactly ~syncMax, the Live-sync slider's
        // half-range (gui-main.scd). It is reachable, but there is no headroom
        // left in that direction — if the sync still wants pushing later, raise
        // ~syncMax rather than assuming 150 is the optimum.
        //
        // latencyMs 68 was dialled in by ear the same day, replacing a guessed
        // 15. It is far above the 20-40 ms docs/manual.md suggests for built-in
        // audio, and rightly: that figure describes a direct interface round
        // trip, whereas here the loop goes SC -> BlackHole -> Live -> out, so
        // Live's own buffers are inside the trip being compensated for. The
        // TSMega aggregate sits at 54 for the same reason.
        //
        // chainRecOffsetMs has never been measured on this rig —
        // scripts/check-chain-align.scd does that.
        inChannelCount: 2, latencyMs: 68,
        onsetNoteOffsetMs: 63, abletonSyncMs: 150,
        sampleRate: 48000),
    // The no-hardware rig: whatever CoreAudio calls the default input and the
    // default output. Nothing to install, nothing to create, nothing to plug in —
    // this is what a fresh clone boots on, so someone can hear the looper work
    // before deciding whether the rest of the setup is worth it.
    //
    // `device: \systemDefault` is a SENTINEL, not a device name. ~applyRoutingProfile
    // maps it to `s.options.device = nil`, which makes SC omit -H entirely so
    // scsynth opens the default input AND the default output. That matters on a
    // laptop, where the mic and the speakers are two separate CoreAudio devices
    // and no single device name can name both.
    //
    // What this rig cannot do, and why:
    //   returnChannel  nil — loop chaining reads Live's processed loop back, and
    //                  there is no Live. Chaining is disabled rather than pointed
    //                  at a channel that would feed the looper its own output.
    //   MIDI clock     no IAC bus is assumed; setup-midi.scd already leaves
    //                  ~midiOut nil when it finds none.
    //   analysisChannel nil — meaning "analyse the recorded input", which on this
    //                  rig is already the dry signal: nothing processes it on the
    //                  way in, because there is no Live in the path. A separate
    //                  tap would read the same microphone twice.
    // latencyMs 10 is a placeholder for a direct in->out round trip. It is the one
    // number worth dialling by ear even on this rig.
    standalone: (
        device: \systemDefault, numChans: 2, numInChans: 2,
        inChannel: 0, outChannel: 0, returnChannel: nil,
        analysisChannel: nil,
        sessionChannel: nil,
        inChannelCount: 1, latencyMs: 10,
        live: false),
    // Megalooper SA (docs/dev/megalooper-sa.md): TSMEGA alone, no Live, no
    // aggregate. Guitar on input 1, the mix on outputs 1/2.
    //
    // inChannel is the guitar's hardware input, which the guitar chain (Bias
    // FX) reads; scripts/setup-sa.scd then points the Looper's input at the
    // chain's bus and its output at the mixer's, so outChannel has no channel of
    // its own here. analysisChannel 0 is the same input read dry: the onset
    // analysis hears the attacks before Bias FX colours them, as on the Live
    // rigs' clean tap.
    //
    // TSMEGA comes up at 44.1 kHz when plugged in alone; megalooper works at 48,
    // so the preflight switches it (setSampleRate). 64 frames measured 9.3 ms
    // round trip on the rig at 44.1 kHz (CoreAudio's figures, 2026-10-05), and
    // latencyMs starts there; dial it by ear like every rig's.
    //
    // returnChannel and sessionChannel are nil here for the same reason as
    // outChannel: setup-sa.scd sets them to the busses MegaSA makes (the loop
    // after its effects, for loop chaining; the mix, for the session's master
    // file). chainRecOffsetMs 20 is computed, not measured: the Looper's master
    // Limiter (0.01 s lookahead) delays the loop by exactly 20 ms before it
    // reaches that return. Measure it with scripts/check-chain-align.scd.
    // memSize: SA's effects take about 5 MB of scsynth's real-time pool (delay
    // lines, PitchLoop's memory) beside the Looper's own, against a default of
    // 8 MB; a failed allocation silences a synth, so SA asks for 64 MB, which
    // also leaves room for the devices a chain edit adds (MegaSA.memoryBudget).
    // bassChannel 1: the bass on the interface's input 2, through the bass
    // chain onto its own strip.
    // inChannelCount 2: the Looper records both sides of the guitar chain
    // (docs/dev/device-chains.md, decision 5). Today's chain is dual mono, so the
    // loop holds the same samples; a stereo device or plugin on the guitar
    // chain is recorded as it plays. It costs no memory: the Looper's buffers
    // are stereo either way.
    sa: (
        device: "TSMEGA", numChans: 2, numInChans: 2,
        midiMap: "tsmega",
        inChannel: 0, outChannel: nil, returnChannel: nil,
        analysisChannel: 0,
        sessionChannel: nil,
        bassChannel: 1,
        inChannelCount: 2, latencyMs: 9, chainRecOffsetMs: 20,
        sampleRate: 48000, setSampleRate: true, hardwareBufferSize: 64, memSize: 65536,
        sa: true, live: false)
)
