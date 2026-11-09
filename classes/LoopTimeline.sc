// megalooper — the loop's time: when the engine playing now began, how long a
// pass is at the speed it plays, where the next boundary falls; and what is
// armed to happen at a time on it (a break's end, a reading landing, a reverse
// or half-time taking effect, the transport starting on a downbeat).
//
// The Looper's (docs/dev/architecture.md 5, step 10). Every language-side
// layer that keeps time with the loop counts from loopStartTime: the onset
// notes, the cutter, the chain recorder, the count on Perform, SA's drums. It
// was the Looper's own variable until 2026-11-09, with speed and the pass
// origin beside it, and each thing armed for a boundary had its own routine,
// its own sequence counter and its own care not to stop itself (seven copies).
// Here once.
//
// Times are SystemClock seconds, logical (Clock.seconds inside a routine).
//
// ---- The arms ----
// armAt(key, at, fn): fn.value(token) at `at`, in a routine of its own on
// SystemClock, unless the arm was taken back or replaced first. One arm per
// key: arming a key again replaces what it held. fn may wait (a reading lands
// in two stages); after a wait it asks holds(key, token) whether it is still
// the arm in force. cancel(key) takes an arm back, and is safe from inside its
// own fn (Routine:stop on the current thread never returns, so the routine is
// left to finish instead). claim(key) is a cancel that answers the token of
// work that will arm later (a break waits for the engine's phase first).
LoopTimeline {
    // { the loop's length at speed 1, in seconds } (the Looper's loopDuration).
    var periodFunc;
    // When the current engine started: the anchor every layer counts from.
    var <loopStartTime;
    // What the engine plays at (1, or 0.5 at half-time); where the half-speed
    // passes began (a boundary), or nil at speed 1; when the speed last changed.
    var <speed = 1, <passOrigin, <speedChangedAt;
    // key -> (token:, at:, routine:), and key -> the last token given out.
    var arms, tokens;
    // How late the loop's audio runs behind this grid (LoopDrift), made when
    // first asked for.
    var drift;

    *new { |periodFunc| ^super.newCopyArgs(periodFunc).init }

    init {
        arms = IdentityDictionary.new;
        tokens = IdentityDictionary.new;
    }

    // ---- The loop's time ---------------------------------------------------

    period { ^(periodFunc.value ? 0) }

    // A pass in wall time: the loop's length at the speed it plays.
    wallPeriod { ^this.period / speed }

    // A new engine started at t.
    restart { |t| loopStartTime = t }

    // The engine plays at `value` from `at` on. A half-speed pass is two loops
    // counted from `origin` (the boundary it landed on); nil at speed 1.
    speedFrom { |value, at, origin|
        speed = value;
        passOrigin = origin;
        speedChangedAt = at;
    }

    // Where a pass at the speed now began (one of them): loopStartTime, or at
    // half-time the boundary it landed on. The onset kit counts from it.
    passStart { ^if((speed != 1) and: { passOrigin.notNil }) { passOrigin } { loopStartTime } }

    // The next loop boundary after `now`, counted from loopStartTime; at
    // half-time, the next end of a half-speed pass, counted from where they
    // began.
    nextBoundaryAt { |now|
        var ld = this.wallPeriod, origin;
        origin = if((speed != 1) and: { passOrigin.notNil }) { passOrigin } { loopStartTime ? now };
        ^origin + ((((now - origin) / ld).floor + 1) * ld)
    }

    // How far into the loop t is, in seconds at speed 1, counted from
    // loopStartTime (t itself when none).
    positionAt { |t, loopSecs|
        loopSecs = loopSecs ?? { this.period };
        ^(t - (loopStartTime ? t)).mod(loopSecs)
    }

    // The drift estimate: how much later than this grid the loop is heard.
    drift { ^drift ?? { drift = LoopDrift.new } }

    // ---- The arms -----------------------------------------------------------

    // fn.value(token) at `at`; answers the token.
    armAt { |key, at, fn|
        var token = this.claim(key), arm = (token: token, at: at);
        arm[\routine] = Routine {
            // Conditional, so an arm whose time has passed (the tests') runs
            // straight through on its first step.
            if(at > SystemClock.seconds) { (at - SystemClock.seconds).wait };
            if(this.holds(key, token)) { fn.value(token) };
            // Done: forgotten, unless fn armed the key again.
            if(arms[key] === arm) { arms.removeAt(key) };
        };
        arms.put(key, arm);
        arm[\routine].play(SystemClock);
        ^token
    }

    // Take back what `key` holds, and answer a new token for it: work that
    // will arm the key later checks holds(key, token) before it does.
    claim { |key|
        var arm = arms.removeAt(key), token = (tokens[key] ? 0) + 1;
        arm !? { |a| a[\routine] !? { |r| if(r !== thisThread) { r.stop } } };
        tokens.put(key, token);
        ^token
    }

    cancel { |key| this.claim(key) }

    cancelAll { arms.keys.asArray.do { |k| this.cancel(k) } }

    // Cmd-period stopped every routine already: forget the arms, and let
    // nothing still in flight count as one.
    forget {
        arms.keys.asArray.do { |k| tokens.put(k, (tokens[k] ? 0) + 1) };
        arms.clear;
    }

    // Whether `token` is still the arm in force for `key` (or, once it has
    // fired, the last one given out).
    holds { |key, token| ^token.notNil and: { (tokens[key] ? 0) == token } }

    // The last token given out for `key` (0 before any).
    token { |key| ^tokens[key] ? 0 }

    // The routine an arm runs in, or nil: the offline renders step it at its
    // logical times, and the tests run it through.
    routine { |key| ^arms[key] !? { |a| a[\routine] } }

    // Whether something waits for its time under `key`, and that time.
    isArmed { |key| ^arms[key].notNil }
    armedAt { |key| ^arms[key] !? { |a| a[\at] } }
    armedKeys { ^arms.keys.asArray.sort }
}
