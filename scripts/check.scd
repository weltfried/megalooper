// megalooper — static check for the boot scripts. No server, no windows, no
// MIDI, no audio hardware. Run it headless after editing anything under
// scripts/:
//
//     /Applications/SuperCollider.app/Contents/MacOS/sclang scripts/check.scd
//
// It does three things the IDE won't do for you until the middle of a gig:
//
//   1. PARSE   — String:compile every .scd WITHOUT executing it, so a syntax
//                error is caught here rather than halfway through a boot that
//                has already freed the previous Looper.
//   2. LOAD    — actually .load the part-files (they only DEFINE, so this
//                is side-effect free) and assert every entry point exists and
//                is a Function. Catches a typo'd assignment, which parsing
//                cannot: `~buildGuiWindow = ...` misspelled still parses fine
//                and only fails when boot.scd calls it.
//   3. PROFILE — every routing profile resolves, is complete, keeps
//                returnChannel distinct from inChannel (equal channels make
//                overdubs re-record the loop's own output and feed back), and
//                puts analysisChannel on a pair that both exists within numChans
//                and does not collide with a pair SC already drives.
//
// Exits non-zero on any failure, so it works as a pre-commit hook. Its
// companion is scripts/tests/run-tests.scd, which exercises the MODEL's logic
// the same way — this file checks that the scripts hold together, that one
// checks that Looper still computes what it used to. Run both.
(
var dir = thisProcess.nowExecutingPath !? { |p| p.dirname }
    ?? { Looper.repoRoot +/+ "scripts" };
var parts = [
    "setup-routing.scd", "setup-midi.scd", "setup-model.scd", "setup-sa.scd", "setup-miditargets.scd", "setup-midimap.scd",
    "gui-const.scd", "gui-theme.scd", "gui-presets.scd", "gui-status.scd", "gui-perform.scd",
    "gui-bbcut.scd", "gui-granular.scd", "gui-analysis.scd", "gui-sa.scd", "gui-midimap.scd", "gui-mapmode.scd", "gui-effects.scd",
    "gui-drums.scd",
    "gui-rig.scd",
    "gui-calibrate.scd", "calibrate-measure.scd",
    "gui-shell.scd", "gui-wiring.scd"
];
// launcher.scd builds its window at load time, so it is parsed but never
// loaded here — loading it would open a window in a headless check. Note that
// gui-shell.scd IS loaded: it is the only file that constructs a Window, and it
// does so strictly inside ~buildGuiWindow, which is what keeps that safe.
// check-onset-notes.scd is parsed but not loaded: loading it RUNS the report,
// which is noise in a static check and wants a live ~looper to say anything.
// check-gui.scd boots a server and opens a window at load time, for the same
// reason launcher.scd does: that IS what it checks. Parsed, never loaded.
// check-gui-effects.scd builds the Effects pane's views and exits: parsed only.
// check-gui-drums.scd likewise, for the Drums pane.
// check-gui-midimap.scd likewise, for the Rig pane's MIDI section and MIDI
// Map mode; check-gui-maptags.scd likewise, for the whole window's tags.
// probe-meter.scd is parsed but not loaded: loading it RUNS a sweep of several
// thousand analyses and then exits the interpreter, which is its job and not
// this file's. replay-session.scd likewise: loading it renders a recorded set
// through scsynth in non-realtime and exits. The Megalooper SA spikes in sa/
// likewise: one renders through a VST plugin and exits, the other boots a
// server on the interface.
var alsoParse = [
    "boot.scd", "check.scd", "launcher.scd", "check-onset-notes.scd",
    "check-chain-align.scd", "check-loop-phase.scd", "check-gui.scd", "check-gui-effects.scd",
    "check-gui-drums.scd", "check-gui-midimap.scd", "check-gui-maptags.scd",
    "eval_meter_analyzer.scd", "probe-meter.scd", "replay-session.scd",
    "sa/spike-biasfx-nrt.scd", "sa/spike-biasfx-rig.scd", "sa/nrt-drum-voices.scd",
    "sa/nrt-drums-fx.scd", "sa/nrt-drums.scd", "sa/nrt-session.scd"
];
// Entry points boot.scd calls, plus the shared data the callers read.
var expected = [
    \routingProfiles, \defaultRoutingProfile, \applyRoutingProfile, \checkSampleRate,
    \applyServerOptions, \switchDeviceRate, \setupSA,
    \saGuitarPlugin, \saGuitarBankDir, \saGuitarBank, \saKeepSound,
    \saUserDir, \saKeptPath, \saKeptBackupDir, \saSoundsDir, \saRecoveryPath, \saMigrate, \saReadKept,
    \saLoopStopped, \saRecoveryClear, \saRecoveryWrite, \saWatchRecovery, \saRecoveryOffer, \saRecallRecovery,
    \saBuild, \saSessionExtras, \saWatchSession,
    \saPluginLeftOut, \saRestorePlugin, \saPluginsDir, \saReadPlugins, \saPluginKeys, \saScanPlugins, \saRecoveryCheck,
    \saFxVariationsFile, \saLoadFxVariations, \saFxVariations, \saApplyVariation,
    \buildSARigSection, \saLevelSpec,
    \saDrumsKitDir, \saDrumsDefaultKits, \saDrumsStartKit, \saKeptDrumsPath, \saKeptDrumsBefore, \saAdoptKeptDrums, \saKeepDrums, \saLoadKeptDrums,
    \saDrumsKitLine, \setupSADrums,
    \buildEffectsPane, \effectsBlurbs, \effectsFormat, \effectsMap, \effectsUnmap,
    \effectsKnobCell, \effectsTile, \effectsEditor, \effectsSelect, \effectsDraggable, \effectsDropAt, \effectsDropIndex,
    \effectsDragCancel,
    \effectsRefreshParam, \effectsRefreshTile, \effectsRefreshAll, \effectsProgram,
    \buildDrumsPane, \drumsModel, \drumsPresetModel, \drumsStepAt, \drumsValueAt, \drumsColumnAt,
    \drumsPaint, \drumsRefreshAll, \drumsPollPlayhead, \drumsFormat, \drumsTip, \drumsKeep,
    \drumsParamNames, \drumsLaneParamNames, \saLevelRow, \saPaintLevel, \saPaintMute,
    \guiTab, \guiTabWidth,
    \audioDeviceNames, \audioDeviceInfo, \audioNameMatches, \audioDeviceFind, \checkAudioDevice,
    \liveAudioState, \liveDeviceName, \checkLiveAudio, \vstPluginFacts, \checkVSTPlugin,
    \setupMidiIO, \setupMidiBindings, \pcCcChannel,
    \midiTargetsBuild, \midiRouteWith, \midiRoute,
    \midiApply, \midiProxyOk, \midiProxyNoteOn, \midiProxyNoteOff, \midiProxyCc, \midiProxyProgram,
    \midiProxyBend, \midiProxyTouch, \midiProxyPolytouch, \midiPart, \midiOldResponders,
    \midiFreeOldResponders, \midiMapReport,
    \midiShippedDir, \midiUserDir, \midiSettingsRead, \midiSettingsWrite,
    \midiMapNameFor, \midiMapLoad, \midiMapKeep, \midiListenFrom, \midiLearnArm, \midiLearnDisarm,
    \midiLearnLive, \midiLearnAnswer, \midiMapEdit, \midiMapUndo, \midiBindingRemove, \midiBindingChange,
    \midiBindingSetEnd, \midiBindingSwap, \buildMidiMapSection, \midiGuiRefresh, \midiRescan,
    \guiHintRowRefresh, \guiKeyDown,
    \guiThemeSet, \guiThemeToggle, \guiPrefSaved, \guiHelpToggle, \guiKeysHint, \buildSAPerformLevels, \guiSans, \guiMono, \guiBar, \guiTile, \guiSeg, \guiSegSet,
    \guiPresetBar, \guiPresetParts, \guiSelectView, \guiViewOrderFor, \guiSay, \guiFooterRefresh,
    \buildCalibrateSummary, \buildMapButton, \mapButtonPaint,
    \mapTag, \mapRelabel, \mapModeOn, \mapModeOff, \mapModeToggle, \mapModeLeave, \mapKeyDown,
    \mapRepaint, \buildMapBar, \midiTargetsRefresh,
    \midiSweepStart, \midiSweepEnd, \midiDefaultsFrom, \midiGuiDefault,
    \midiIsKnob, \midiForget, \midiGuiRefreshRange,
    \midiBackOpen, \midiBackOutputs, \midiBackOutputFor, \midiBackCan, \midiBackFrom, \midiBackAgain,
    \midiBackHeard, \midiBackTick, \midiBackSend, \midiBackIsEcho, \midiBackClock, \midiGuiSendBack,
    \midiBackRescan, \midiBackClockStep, \midiBackOwns, \midiBackSettle, \midiBackSaid, \midiBackWarn,
    \midiClientSources, \midiClientDestinations, \midiBackSwitch, \midiBackOthers, \midiBackSched,
    \breakMacroCc,
    // NOT ~sessionDir: that one is defined by boot.scd, which this file parses
    // but never loads (loading it would boot a server). Only the part-files in
    // `parts` above are loaded, so only what THEY define can be asserted here.
    // setup-model.scd reads ~sessionDir, and a nil there is harmless — Looper
    // builds a LooperSessionRecorder with no directory either way, and
    // startSessionRecording is what reports which files it opened.
    \setupLooper, \wireLooperCallbacks, \ableton,
    \wireLooperController, \doExport, \exportDenoms,
    \fitOnScreen,
    \latencyMax, \declickMax, \syncMax, \fallbackMeters, \transportModes,
    \onsetThresholdMin, \onsetThresholdMax, \onsetThresholdSpec,
    \inChannelCounts, \keyHintString,
    \guiOn, \guiOff, \guiArmed, \guiDanger, \guiIdleBtn, \guiHint,
    \guiTeardowns, \guiGen, \analysisGen, \statusGen,
    \buildGuiWindow, \guiSwapPane, \guiSelectTab, \guiTabIndex,
    \guiRefreshTabs, \guiSetTyping, \guiTakeString,
    \guiPaneOrder, \guiPaneOrderFor, \guiPaneLabels, \guiPaneActive, \guiPositionHz,
    \buildPerformPane, \performAction, \performRefreshAll, \sessionRecShort,
    \sessionRecString,
    \buildRigPane, \rigRow,
    \buildCalibratePane, \calibrateRefresh, \calibrateEnsure, \calMarks,
    \calRegisterAll, \calScanInputs, \calPreflight, \calMeasureLatency,
    \calMeasureSync, \calMeasureNoteOffset, \calMeasureChain, \calAddDefs,
    \calSplit, \calAnchor, \calCheckReturn, \calProbeReturn,
    \buildBBCutPane, \refreshBBCutPresetList, \refreshBBCutPresetButtons,
    \loadBBCutPreset, \saveBBCutPreset, \deleteBBCutPreset, \revertBBCutPreset,
    \renderBBCutEditor, \renderBBCutVoiceMenu, \bbcutRefreshDensity,
    \bbcutPresetSetStatus,
    \bbcutPresetArm, \bbcutPresetDisarm, \bbcutParamRow, \bbcutPaintHeader, \bbcutRatios,
    \buildMidiMonitorPanel, \statusRefreshAll, \statusPaintState, \statusLook,
    \statusPaintTake, \statusTake, \buildStatusBand, \buildStatusStrip,
    \midiLogLine, \midiMonitorPush, \midiMonitorClear, \midiMonitorMax,
    \buildAnalysisPane, \analysisPush, \analysisResetStats, \analysisRefreshAll,
    \analysisStatsHz, \analysisFlashDecay,
    \onsetNotesRefresh, \midiNoteName,
    \granularPresetSetStatus, \refreshGranularPresetList,
    \refreshGranularPresetButtons, \granularPresetArm, \granularPresetDisarm,
    \loadGranularPreset, \saveGranularPreset, \deleteGranularPreset,
    \revertGranularPreset,
    \presetFamilies, \definePresetFamily, \presetFamily, \presetWidget,
    \presetDir, \presetModel, \presetBarRows,
    \presetSetStatus, \presetRefreshList, \presetRefreshButtons,
    \presetArm, \presetDisarm, \presetLoad, \presetSave, \presetDelete,
    \presetRevert, \presetStopTimers,
    \buildGranularPane, \granularParams, \granularWidgets, \granularRefreshOne,
    \granularRefreshAll, \granularResetTweaks, \granularMapValue,
    \granularUnmapValue, \granularFormat, \granularRow, \granularSection
];
var callables = [
    \applyRoutingProfile, \checkSampleRate, \setupMidiIO, \setupMidiBindings,
    \applyServerOptions, \switchDeviceRate, \setupSA,
    \saGuitarBankDir, \saGuitarBank, \saKeepSound, \buildSARigSection,
    \saUserDir, \saKeptPath, \saKeptBackupDir, \saSoundsDir, \saRecoveryPath, \saMigrate, \saReadKept,
    \saLoopStopped, \saRecoveryClear, \saRecoveryWrite, \saWatchRecovery, \saRecoveryOffer, \saRecallRecovery,
    \saBuild, \saSessionExtras, \saWatchSession,
    \saPluginLeftOut, \saRestorePlugin, \saPluginsDir, \saReadPlugins, \saPluginKeys, \saScanPlugins, \saRecoveryCheck,
    \saFxVariationsFile, \saLoadFxVariations, \saApplyVariation,
    \midiTargetsBuild, \midiRouteWith, \midiRoute, \midiApply,
    \midiProxyOk, \midiProxyNoteOn, \midiProxyNoteOff, \midiProxyCc, \midiProxyProgram,
    \midiProxyBend, \midiProxyTouch, \midiProxyPolytouch, \midiPart, \midiFreeOldResponders,
    \midiMapReport,
    \midiShippedDir, \midiUserDir, \midiSettingsRead, \midiSettingsWrite,
    \midiMapNameFor, \midiMapLoad, \midiMapKeep, \midiListenFrom, \midiLearnArm, \midiLearnDisarm,
    \midiLearnLive, \midiLearnAnswer, \midiMapEdit, \midiMapUndo, \midiBindingRemove, \midiBindingChange,
    \midiBindingSetEnd, \midiBindingSwap, \buildMidiMapSection, \midiGuiRefresh, \midiRescan,
    \guiHintRowRefresh, \guiKeyDown,
    \guiThemeSet, \guiThemeToggle, \guiPrefSaved, \guiHelpToggle, \guiKeysHint, \buildSAPerformLevels, \guiSans, \guiMono, \guiBar, \guiTile, \guiSeg, \guiSegSet,
    \guiPresetBar, \guiPresetParts, \guiSelectView, \guiViewOrderFor, \guiSay, \guiFooterRefresh,
    \buildCalibrateSummary, \buildMapButton, \mapButtonPaint,
    \mapTag, \mapRelabel, \mapModeOn, \mapModeOff, \mapModeToggle, \mapModeLeave, \mapKeyDown,
    \mapRepaint, \buildMapBar, \midiTargetsRefresh,
    \midiSweepStart, \midiSweepEnd, \midiDefaultsFrom, \midiGuiDefault,
    \midiIsKnob, \midiForget, \midiGuiRefreshRange,
    \midiBackOpen, \midiBackOutputs, \midiBackOutputFor, \midiBackCan, \midiBackFrom, \midiBackAgain,
    \midiBackHeard, \midiBackTick, \midiBackSend, \midiBackIsEcho, \midiBackClock, \midiGuiSendBack,
    \midiBackRescan, \midiBackClockStep, \midiBackOwns, \midiBackSettle, \midiBackSaid, \midiBackWarn,
    \midiClientSources, \midiClientDestinations, \midiBackSwitch, \midiBackOthers, \midiBackSched,
    \saDrumsKitDir, \saKeptDrumsPath, \saKeepDrums, \saLoadKeptDrums, \saDrumsKitLine,
    \setupSADrums,
    \buildEffectsPane, \effectsFormat, \effectsMap, \effectsUnmap, \effectsKnobCell,
    \effectsTile, \effectsEditor, \effectsSelect, \effectsRefreshParam,
    \effectsRefreshTile, \effectsRefreshAll, \effectsProgram, \guiPaneOrderFor,
    \buildDrumsPane, \drumsModel, \drumsPresetModel, \drumsStepAt, \drumsValueAt, \drumsColumnAt,
    \drumsPaint, \drumsRefreshAll, \drumsPollPlayhead, \drumsFormat, \drumsTip, \drumsKeep,
    \saLevelRow, \saPaintLevel, \saPaintMute, \guiTab, \guiTabWidth,
    \audioDeviceNames, \audioDeviceInfo, \audioNameMatches, \audioDeviceFind, \checkAudioDevice,
    \liveAudioState, \liveDeviceName, \checkLiveAudio, \vstPluginFacts, \checkVSTPlugin,
    \setupLooper, \wireLooperCallbacks, \wireLooperController,
    \fitOnScreen, \guiHint, \guiTopBarFit, \guiStatusFit, \performFit, \guiSideRowsFit,
    \buildGuiWindow, \guiSwapPane, \guiSelectTab, \guiTabIndex,
    \guiRefreshTabs, \guiSetTyping, \guiTakeString,
    \buildPerformPane, \performAction, \performRefreshAll, \sessionRecShort, \buildRigPane, \rigRow,
    \doExport, \sessionRecString, \liveRecordToggle, \liveRecordSet,
    \buildBBCutPane, \refreshBBCutPresetList, \renderBBCutEditor,
    \bbcutRefreshDensity,
    \bbcutParamRow, \bbcutPaintHeader,
    \buildMidiMonitorPanel, \statusRefreshAll, \statusPaintState, \statusPaintTake,
    \buildStatusBand, \buildStatusStrip,
    \midiLogLine, \midiMonitorPush, \midiMonitorClear,
    \buildAnalysisPane, \analysisPush, \analysisResetStats, \analysisRefreshAll,
    \onsetNotesRefresh, \midiNoteName,
    \buildGranularPane, \granularRefreshOne, \granularRefreshAll,
    \granularResetTweaks, \granularMapValue, \granularUnmapValue,
    \granularFormat, \granularRow, \granularSection,
    \granularPresetSetStatus, \refreshGranularPresetList,
    \refreshGranularPresetButtons, \granularPresetArm, \granularPresetDisarm,
    \loadGranularPreset, \saveGranularPreset, \deleteGranularPreset,
    \revertGranularPreset,
    \definePresetFamily, \presetFamily, \presetWidget, \presetDir,
    \presetModel, \presetBarRows,
    \presetSetStatus, \presetRefreshList, \presetRefreshButtons,
    \presetArm, \presetDisarm, \presetLoad, \presetSave, \presetDelete,
    \presetRevert, \presetStopTimers
];
// The test suite is GLOBBED, not listed: adding a test file should not need a
// second edit here before it is parse-checked. Parsed only — actually running
// them is scripts/tests/run-tests.scd's job, and it has its own exit code.
var testFiles = (dir +/+ "tests" +/+ "*.scd").pathMatch.sort
    .collect { |p| "tests" +/+ PathName(p).fileName };
// Derived, not listed: a second copy of the rig names goes stale the first time
// one is added. launcher.scd reads ~routingProfiles.keys for the same reason.
// Filled in after setup-routing.scd is loaded, below.
var rigs;
var bad = 0;

"== parse ==".postln;
(parts ++ alsoParse ++ testFiles).do { |f|
    var src = File.readAllString(dir +/+ f);
    if(src.isNil) {
        ("  UNREADABLE " ++ f).postln; bad = bad + 1;
    } {
        if(src.compile.isNil) { ("  FAIL  " ++ f).postln; bad = bad + 1 }
                              { ("  ok    " ++ f).postln };
    };
};

"== load ==".postln;
parts.do { |f|
    protect { (dir +/+ f).load; ("  ok    " ++ f).postln } { |err|
        if(err.notNil) {
            ("  FAIL  " ++ f ++ " — " ++ err.errorString).postln; bad = bad + 1;
        };
    };
};

"== definitions ==".postln;
expected.do { |k|
    if(currentEnvironment[k].isNil) { ("  UNDEFINED ~" ++ k).postln; bad = bad + 1 };
};
callables.do { |k|
    var v = currentEnvironment[k];
    if(v.isKindOf(Function).not) {
        ("  NOT A FUNCTION ~" ++ k ++ " is a " ++ v.class).postln; bad = bad + 1;
    };
};
("  " ++ expected.size ++ " symbols, " ++ callables.size ++ " entry points").postln;

// The granular window renders itself from ~granularParams and the MIDI CCs map
// through the same table, so a row naming a parameter Looper does not have is a
// window that throws on open — and it throws at boot, after the previous Looper
// has already been freed. Cheap to assert here instead.
"== granular parameter table ==".postln;
~granularParams.do { |p|
    var key = p[\key];
    if(Looper.findRespondingMethodFor(key).isNil) {
        ("  NO GETTER  Looper:" ++ key).postln; bad = bad + 1;
    };
    if(Looper.findRespondingMethodFor(key.asSetter).isNil) {
        ("  NO SETTER  Looper:" ++ key.asSetter).postln; bad = bad + 1;
    };
    // Reset writes the default straight to the model; if the slider cannot
    // reach it, the knob lands somewhere the mouse can never put it back.
    if(~granularUnmapValue.(p, p[\default]).inclusivelyBetween(0, 1).not) {
        ("  DEFAULT UNREACHABLE  ~granularParams " ++ key).postln; bad = bad + 1;
    };
};
// The one CC megalooper SENDS (the break's rack-macro switch) shares a channel
// with the proxied program changes, which arrive in Live as CC number = program
// number. The proxy leaves that program out, and the MIDI map section below
// asserts that no shipped map binds it.
("  break macro CC " ++ ~breakMacroCc ++ " out on channel " ++ ~pcCcChannel).postln;
if(~breakMacroCc.inclusivelyBetween(0, 127).not) {
    "  BREAK MACRO CC OUT OF RANGE (0-127)".postln; bad = bad + 1;
};

[\granularPresetNames, \granularPresetSlug, \granularPresetPath,
 \granularPresetData, \granularPresetString, \granularPresetVersion,
 \applyGranularPreset, \saveGranularPreset, \loadGranularPreset,
 \deleteGranularPreset].do { |sel|
    if(Looper.findRespondingMethodFor(sel).isNil) {
        ("  MISSING  Looper:" ++ sel).postln; bad = bad + 1;
    };
};
// The preset table names accessors by symbol, so a renamed setter would only
// surface as a throw the first time someone recalls a preset.
Looper.granularPresetFields.do { |f|
    if(Looper.findRespondingMethodFor(f[1]).isNil) {
        ("  MISSING  Looper:" ++ f[1] ++ " (granularPresetFields)").postln; bad = bad + 1;
    };
    if(Looper.findRespondingMethodFor(f[1].asSetter).isNil) {
        ("  MISSING  Looper:" ++ f[1].asSetter ++ " (granularPresetFields)").postln;
        bad = bad + 1;
    };
};
("  " ++ ~granularParams.size ++ " parameters, "
    ++ Looper.granularEnvNames.size ++ " grain windows, "
    ++ Looper.granularPresetFields.size ++ " saved fields").postln;

// The onset-notes panel calls these by name on ~looper; unlike the granular
// window there is no table to generate them from, so a rename on the class side
// would only show up as a throw the next time a take is analysed.
"== onset notes ==".postln;
[\onsetNotes, \onsetNotes_, \onsetNote, \onsetNote_,
 \onsetNoteChannel, \onsetNoteChannel_, \onsetNoteVelLo, \onsetNoteVelLo_,
 \onsetNoteVelHi, \onsetNoteVelHi_, \onsetNoteDynRange, \onsetNoteDynRange_,
 \onsetNoteGateMs, \onsetNoteGateMs_, \onsetNoteOffsetMs, \onsetNoteOffsetMs_,
 \chainRecOffsetMs, \chainRecOffsetMs_,
 \onsetNoteChance, \onsetNoteChance_, \rerollOnsetNotes,
 \onsetNoteCount, \onsetNotePlayingCount, \onsetNotePatternDur,
 \startOnsetNotes, \stopOnsetNotes].do { |sel|
    if(Looper.findRespondingMethodFor(sel).isNil) {
        ("  MISSING  Looper:" ++ sel).postln; bad = bad + 1;
    };
};
("  default note " ++ ~midiNoteName.(36) ++ " (36), Ableton octave numbering").postln;

// The Drums pane draws MegaSASteps' rows by name (gui-drums.scd), so a row
// renamed on the class side would throw when the tab builds, at boot, with the
// previous Looper already freed. Its tooltips quote the device's own help by
// key, which would go quietly missing instead.
"== drums tab tables ==".postln;
~drumsParamNames.do { |n|
    if(MegaSASteps.paramSpec(n).isNil) {
        ("  NO ROW  MegaSASteps.paramSpec(" ++ n ++ ")").postln; bad = bad + 1 };
};
~drumsLaneParamNames.do { |n|
    if(MegaSASteps.laneParamSpec(n).isNil) {
        ("  NO ROW  MegaSASteps.laneParamSpec(" ++ n ++ ")").postln; bad = bad + 1 };
};
MegaSASteps.pages.do { |pg|
    if(~drumsPageLabels[pg].isNil or: { ~drumsPageHints[pg].isNil } or: { ~drumsLengthTips[pg].isNil }) {
        ("  PAGE  " ++ pg ++ " has no label, hint or length tip in gui-drums.scd").postln; bad = bad + 1 };
};
("  " ++ ~drumsParamNames.size ++ " pattern settings, " ++ ~drumsLaneParamNames.size
    ++ " lane settings, " ++ MegaSASteps.pages.size ++ " pages").postln;

// The Calibrate pane repaints from LooperCalibrator and is nil-guarded
// throughout, because a pane rebuild calls the refresh before its widgets are
// swapped in. A throw there happens at boot, with the previous Looper already
// freed — the exact failure this file exists to prevent, and provable with no
// Qt and no server.
"== calibration wizard ==".postln;
// Both wizards: a rig with Live, and one without (SA, standalone).
[true, false].do { |live|
    ~calibrator = LooperCalibrator.new(nil, live);
    try {
        ~calibrator.stepCount.do { |i|
            ~calibrator.goTo(i);
            ~calibrateRefresh.();
        };
        ("  refresh survives all " ++ ~calibrator.stepCount
            ++ " steps " ++ if(live) { "with Live" } { "without Live" } ++ ", with no widgets and no looper").postln;
    } { |err|
        ("  THREW  ~calibrateRefresh: " ++ (err.errorString ? "?")).postln;
        bad = bad + 1;
    };
};
~calibrator = nil;

"== Megalooper SA ==".postln;
// The kits a boot starts the drums with are named by key, and a typo (or a
// kit the importer renamed) would leave that slot silent at every boot with
// only a warning to say so. Their JSON files are committed, so this holds on
// any clone; the audio beside them is the importer's, git-ignored, and not
// looked at here.
try {
    var dir = ~saDrumsKitDir.();
    [\steps, \onset].do { |slot|
        var key = ~saDrumsDefaultKits[slot];
        var kit = key !? { |k| MegaSAKit.read(MegaSAKit.fileFor(dir, k), List.new) };
        if(kit.isNil) {
            ("  NO KIT  ~saDrumsDefaultKits[\\" ++ slot ++ "] = " ++ key
                ++ ": no readable kit of that name in " ++ dir).postln;
            bad = bad + 1;
        } {
            ("  ok    default " ++ slot ++ " kit " ++ key ++ " (" ++ kit.name ++ ", "
                ++ kit.notes.size ++ " pads)").postln;
        };
    };
} { |err|
    ("  THREW  the default kits check: " ++ (err.errorString ? "?")).postln;
    bad = bad + 1;
};

// The MIDI maps megalooper ships (presets/midi/) load at every boot, so one
// that doesn't read, or binds a control the router doesn't have, or a message
// twice, would be footswitches doing the wrong thing with no word said. Every
// control is checked too: a knob and the mouse must agree, so its law back
// and forth is the identity. On rigs that proxy to Live, no binding may sit on
// the program whose number is the break macro's CC (LooperMidiMap.proxyProblems),
// and every rig's profile must name a map there is.
"== MIDI map ==".postln;
try {
    var targets = ~midiTargetsBuild.();
    var kinds = #[\trigger, \toggle, \continuous, \step, \choice];
    var names = ~midiMapNames.(~midiShippedDir.());
    targets.keysValuesDo { |id, t|
        case
        { t[\id] != id } { ("  TARGET " ++ id ++ " says it is " ++ t[\id]).postln; bad = bad + 1 }
        { kinds.includes(t[\kind]).not } { ("  TARGET " ++ id ++ " has no kind").postln; bad = bad + 1 }
        { (t[\kind] == \trigger) and: { t[\fire].isNil } } {
            ("  TARGET " ++ id ++ " is a trigger with nothing to fire").postln; bad = bad + 1 }
        { (t[\kind] == \toggle) and: { t[\flip].isNil } and: { t[\set].isNil } } {
            ("  TARGET " ++ id ++ " is a switch that can't be switched").postln; bad = bad + 1 }
        { (t[\kind] != \trigger) and: { t[\kind] != \toggle }
            and: { t[\set].isNil or: { t[\fromPos].isNil } or: { t[\toPos].isNil } } } {
            ("  TARGET " ++ id ++ " has no set or no law").postln; bad = bad + 1 };
        // A knob and the mouse must agree: the law back and forth is the identity.
        if(t[\kind] == \continuous) {
            [0, 0.25, 0.5, 0.75, 1].do { |c|
                var back = try { t[\toPos].value(t[\fromPos].value(c)) } { nil };
                if(back.isNil or: { (back - c).abs > 1e-6 }) {
                    ("  LAW " ++ id ++ ": position " ++ c ++ " comes back as " ++ back).postln;
                    bad = bad + 1;
                };
            };
        };
    };
    ("  " ++ targets.size ++ " controls").postln;
    if(names.isEmpty) { "  NO SHIPPED MIDI MAPS in presets/midi".postln; bad = bad + 1 };
    names.do { |name|
        var r = LooperMidiMap.parse(~midiReadText.(~midiMapPath.(~midiShippedDir.(), name)));
        var map;
        if(r.isString) {
            ("  MAP " ++ name ++ " can't be read: " ++ r).postln; bad = bad + 1;
        } {
            map = LooperMidiMap(r[\bindings], name, r[\basedOn], r[\revision]);
            (r[\problems] ++ map.problems).do { |p| ("  MAP " ++ name ++ ": " ++ p).postln; bad = bad + 1 };
            if(r[\name] != name) {
                ("  MAP " ++ name ++ " calls itself " ++ r[\name]).postln; bad = bad + 1;
            };
            map.bindings.reject { |b| targets.includesKey(b[\target]) }.do { |b|
                ("  MAP " ++ name ++ ": " ++ LooperMidiMap.describe(b) ++ " names " ++ b[\target]
                    ++ ", which the router does not have").postln;
                bad = bad + 1;
            };
            LooperMidiMap.proxyProblems(map.bindings, ~breakMacroCc).do { |p|
                ("  MAP " ++ name ++ ": " ++ p).postln; bad = bad + 1 };
            ("  ok    " ++ name ++ ": " ++ map.bindings.size ++ " bindings").postln;
        };
    };
    ~routingProfiles.keysValuesDo { |rig, rp|
        rp[\midiMap] !? { |m|
            if(names.includesEqual(m.asString).not) {
                ("  RIG " ++ rig ++ " names the MIDI map " ++ m ++ ", which is not shipped").postln;
                bad = bad + 1;
            };
        };
    };
    // MIDI Map mode's tags (~mapTag, gui-const.scd) are made inside the pane
    // builders, which only check-gui-maptags.scd runs, with Qt. Here, without
    // it: every control id a gui file writes out as a quoted symbol must be
    // one the router has, or its mask would map nothing. Ids made from parts
    // ("sa.fxOn." ++ key) are left to that check.
    (dir +/+ "gui-*.scd").pathMatch.do { |path|
        var ids = File.readAllString(path)
            .findRegexp("'looper\\.[A-Za-z0-9.]+'|'sa\\.[A-Za-z0-9.]+'|'live\\.[A-Za-z0-9.]+'")
            .collect { |m| m[1].drop(1).drop(-1).asSymbol }.asSet;
        ids.do { |id|
            if(targets.includesKey(id).not) {
                ("  TAG " ++ path.basename ++ " names " ++ id ++ ", which the router does not have").postln;
                bad = bad + 1;
            };
        };
        if(ids.notEmpty) { ("  ok    " ++ path.basename ++ ": " ++ ids.size ++ " control ids").postln };
    };
} { |err|
    ("  THREW  the MIDI map check: " ++ (err.errorString ? "?")).postln;
    bad = bad + 1;
};

"== routing profiles ==".postln;
rigs = ~routingProfiles.keys.asArray.sort { |a, b| a.asString < b.asString };
rigs.do { |p|
    var rp = ~routingProfiles[p];
    case
        { rp.isNil } { ("  MISSING " ++ p).postln; bad = bad + 1 }
        { rp[\device].isNil or: { rp[\numChans].isNil } } {
            ("  INCOMPLETE " ++ p).postln; bad = bad + 1 }
        // returnChannel nil means the rig has no path back from Live, so loop
        // chaining is off — honest on \builtin, where there is no Live at all.
        // Only a DECLARED return channel can collide with the input.
        { rp[\returnChannel].notNil and: { rp[\returnChannel] == rp[\inChannel] } } {
            ("  FEEDBACK RISK " ++ p ++ ": returnChannel == inChannel").postln;
            bad = bad + 1 }
        // analysisChannel is optional (nil = analyse the recorded input). If
        // declared it is ONE input channel and must actually exist: a channel at
        // or past the input count reads a bus the driver never fills, and past
        // the input block entirely it reads a PRIVATE bus — the looper's own
        // output bus is the first one allocated, so that is a feedback path into
        // onset detection, not merely silence. numInChans defaults to numChans.
        { rp[\analysisChannel].notNil
            and: { rp[\analysisChannel] >= (rp[\numInChans] ? rp[\numChans]) } } {
            ("  OUT OF RANGE " ++ p ++ ": analysisChannel " ++ rp[\analysisChannel]
                ++ " needs input channels >= " ++ (rp[\analysisChannel] + 1)
                ++ ", profile exposes " ++ (rp[\numInChans] ? rp[\numChans])).postln;
            bad = bad + 1 }
        // The loop SC writes must never be what SC analyses. returnChannel is
        // Live's processed loop and outChannel is the loop itself; either one
        // under the tap would make the looper analyse its own output.
        // A channel the profile leaves nil (\sa's outChannel is the mixer's bus,
        // set at boot) has nothing to collide with.
        { rp[\analysisChannel].notNil and: {
            [\outChannel, \returnChannel].any { |k|
                rp[k].notNil and: {
                    (rp[\analysisChannel] == rp[k]) or: { rp[\analysisChannel] == (rp[k] + 1) } } } } } {
            ("  BAD ANALYSIS " ++ p ++ ": analysisChannel " ++ rp[\analysisChannel]
                ++ " lands on outChannel/returnChannel").postln;
            bad = bad + 1 }
        // bassChannel is SA's alone (Live plays the bass on the other rigs),
        // one input channel the profile asks for, and never the guitar's
        // input or the tap: that would play the guitar twice, once through
        // each chain.
        { rp[\bassChannel].notNil and: { rp[\sa] != true } } {
            ("  BASS WITHOUT SA " ++ p ++ ": bassChannel is set, but only SA plays a bass").postln;
            bad = bad + 1 }
        { rp[\bassChannel].notNil
            and: { rp[\bassChannel] >= (rp[\numInChans] ? rp[\numChans]) } } {
            ("  OUT OF RANGE " ++ p ++ ": bassChannel " ++ rp[\bassChannel]
                ++ " needs input channels >= " ++ (rp[\bassChannel] + 1)
                ++ ", profile exposes " ++ (rp[\numInChans] ? rp[\numChans])).postln;
            bad = bad + 1 }
        { rp[\bassChannel].notNil and: {
            [\inChannel, \analysisChannel].any { |k| rp[k].notNil and: { rp[\bassChannel] == rp[k] } } } } {
            ("  BAD BASS " ++ p ++ ": bassChannel " ++ rp[\bassChannel]
                ++ " is the guitar's input or the analysis tap").postln;
            bad = bad + 1 }
        // A profile's calibrated sync offset has to be reachable on the bipolar
        // "Live sync" slider, or the GUI opens showing a value it cannot
        // represent and the first touch of the slider jumps the offset.
        { rp[\abletonSyncMs].notNil
            and: { rp[\abletonSyncMs].abs > (~syncMax ? 100) } } {
            ("  UNREACHABLE SYNC " ++ p ++ ": abletonSyncMs " ++ rp[\abletonSyncMs]
                ++ " is outside the slider's +/-" ++ (~syncMax ? 100)
                ++ " — raise ~syncMax in gui-const.scd or lower the offset").postln;
            bad = bad + 1 }
        // The overdub slider is unipolar and full-scale at ~latencyMax, so a
        // profile outside 0..that opens showing a value it cannot represent —
        // and the first touch of the slider jumps the compensation.
        { rp[\latencyMs].notNil
            and: { (rp[\latencyMs] < 0) or: { rp[\latencyMs] > (~latencyMax ? 100) } } } {
            ("  UNREACHABLE LATENCY " ++ p ++ ": latencyMs " ++ rp[\latencyMs]
                ++ " is outside the slider's 0.." ++ (~latencyMax ? 100)
                ++ " — raise ~latencyMax in gui-const.scd or lower the value").postln;
            bad = bad + 1 }
        // Same trap for the onset-note trim: the "Offset" box clips at +/-500,
        // so a profile outside that opens showing a number it cannot represent.
        { rp[\onsetNoteOffsetMs].notNil
            and: { rp[\onsetNoteOffsetMs].abs > 500 } } {
            ("  UNREACHABLE OFFSET " ++ p ++ ": onsetNoteOffsetMs "
                ++ rp[\onsetNoteOffsetMs] ++ " is outside the Offset box's +/-500"
                ++ " — raise its clip in gui-analysis.scd or lower the offset").postln;
            bad = bad + 1 }
        { true } { ("  ok    " ++ p ++ " (" ++ rp[\device] ++ ")").postln };
};
// The editor default and the launcher's fallback are the same symbol, so a
// typo here would leave boot.scd resolving a nil profile.
if(rigs.includes(~defaultRoutingProfile).not) {
    ("  BAD DEFAULT ~defaultRoutingProfile = " ++ ~defaultRoutingProfile
        ++ " is not a known rig").postln;
    bad = bad + 1;
} {
    ("  ok    default = " ++ ~defaultRoutingProfile).postln;
};

"".postln;
if(bad == 0) {
    "CHECK PASSED".postln;
    0.exit;
} {
    ("CHECK FAILED — " ++ bad ++ " problem(s)").postln;
    1.exit;
};
)
