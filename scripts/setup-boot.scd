// megalooper — the boot's steps (docs/dev/architecture.md, 5, step 3).
//
// boot.scd runs what comes after the server is up as named steps through
// ~bootStep. Each runs in `try`; the first that throws stops the boot there:
// the steps after it do not run, the error and its stack go to the post
// window (the log), and ~bootFailed, if someone set it, is told which step
// and why. The launcher sets it, so its window says where a start stopped
// instead of "Booting…" for ever, and offers Start again. Before this, a
// throw in ~setupSA or the window's build stopped the boot's routine with
// nothing on the screen.
//
// Loaded by boot.scd through parts.scd; defines only, runs nothing.
//   ~bootReset    — a new boot: no step yet, none failed
//   ~bootStep     — runs one named step, unless an earlier one failed;
//                   answers whether the boot is still going
//   ~bootFinish   — after the last step: \done, and ~bootFinished told
//   ~bootStage    — the step running, the one that failed, or \done
//   ~bootFailure  — nil, or (step:, error:) for the step that failed
//
// A step may wait (~looper.waitForReady, MegaSA's): `try` holds across a wait
// inside the boot's routine (checked on 3.14.1, 2026-11-08).
(
~bootReset = {
    ~bootStage = nil;
    ~bootFailure = nil;
};
~bootReset.();
~bootStep = { |name, fn|
    if(~bootFailure.isNil) {
        ~bootStage = name;
        try { fn.value } { |err|
            ~bootFailure = (step: name, error: err);
            err.reportError;
            ("megalooper: the start stopped at " ++ name ++ ": " ++ err.errorString
                ++ ". What comes after it did not run; Start again (or re-run boot.scd) once it is put right.").postln;
            ~bootFailed !? { |f| try { f.value(name, err) } { |e| e.reportError } };
        };
    };
    ~bootFailure.isNil
};
~bootFinish = {
    if(~bootFailure.isNil) {
        ~bootStage = \done;
        ~bootFinished !? { |f| try { f.value } { |e| e.reportError } };
    };
};
)
