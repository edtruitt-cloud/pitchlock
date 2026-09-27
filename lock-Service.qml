import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pam
import Quickshell.Hyprland
import Quickshell.Services.Mpris
import Quickshell.Wayland
import qs.Commons

Item {
  id: root

  property var shell: null
  property string omarchyPath: ""

  readonly property string home: Quickshell.env("HOME")
  readonly property string stateHome: home + "/.local/state"
  readonly property string userName: Quickshell.env("USER") || Quickshell.env("LOGNAME")
  readonly property string currentBackgroundLink: stateHome + "/omarchy/current/background"

  property bool lockRequested: false
  property bool pendingSessionLock: false
  property bool authenticatingPassword: false
  property bool fingerprintAuthenticating: false
  property bool passwordPamConfigured: false
  property bool fingerprintConfigured: false
  property bool previewVisible: false
  property string enteredPassword: ""
  property string pendingPassword: ""
  property string failureMessage: ""
  property int failedAttempts: 0
  property string backgroundPath: ""
  property int backgroundVersion: 0
  property string lastEvent: "init"
  property string lastEventAt: ""
  property bool strandedLock: false
  property bool strandedLockResolved: false

  // ── pitchlock ────────────────────────────────────────────────────────────
  // The monitor that gets the sing-to-unlock game; any others keep the password view.
  property string primaryScreenName: ""
  property string previewText: ""
  readonly property string pitchdPath: {
    var u = String(Qt.resolvedUrl("pitchd"))
    return u.indexOf("file://") === 0 ? decodeURIComponent(u.slice(7))
      : home + "/.config/omarchy/plugins/ertiv.lock/pitchd"
  }

  // All pitchlock tuning lives in ~/.config/pitchlock/settings.json (edited from the
  // bar widget's settings panel); the lock picks changes up live.
  property PitchSettings pitchSettings: PitchSettings {}

  // Secret bypass: typing this word anywhere on the lock screen unlocks it (blank = off).
  readonly property string bypassWord: String(pitchSettings.bypassWord || "").toLowerCase()

  // "Singing only" mode: only the chord unlocks: no password, bypass word or fingerprint.
  // Safety net: if the microphone stops working, the password comes back.
  property bool pitchMicFailed: false
  readonly property bool singingOnly: pitchSettings.unlockMode === "singing" && !pitchMicFailed

  // "Pass-notes" (secure) mode: a memorised 4-note sequence, or a typed pass-code, unlocks;
  // the bypass word is off; the account password + Enter still works as a backup.
  // Checked here only, against salted hashes; nothing sung or typed is logged.
  readonly property bool passMode: pitchSettings.unlockMode === "passnotes"
  property var passHeard: []           // the last notes held on the lock (cleared on unlock)

  // A sung note only counts if it's the right next pass-note; wrong notes are ignored
  // (progress is kept). 15 s without a right note starts over.
  //
  // Guessing guard: after 20 clearly wrong notes, notes are ignored for a minute. A note one
  // semitone from the right one isn't counted as wrong (voices flicker between neighbours).
  readonly property int passWrongLimit: 20
  property int passWrong: 0
  property real passCooldownUntil: 0
  property int passCooldownLeft: 0     // seconds, shown on the lock
  function passNoteSung(midi) {
    if (!lockRequested || !passMode) return
    if (Date.now() < passCooldownUntil) return
    if (!pitchSettings.passNoteFits(passHeard, midi)) {
      const nearMiss = pitchSettings.passNoteFits(passHeard, midi - 1) || pitchSettings.passNoteFits(passHeard, midi + 1)
      if (!nearMiss && ++passWrong >= passWrongLimit) {
        passWrong = 0
        passHeard = []
        passCooldownUntil = Date.now() + 60000
        passCooldownLeft = 60
        passCooldownTimer.start()
        logEvent("pass-notes: too many wrong notes, pausing for a minute")
      }
      return
    }
    passHeard = passHeard.concat([midi])     // the lock's game dings this note when it sees it
    passResetTimer.restart()
    if (passHeard.length === 4) {
      passResetTimer.stop()
      passWrong = 0
      logEvent("unlock: pass-notes")
      // Let the game ding the last note before the lock closes.
      Qt.callLater(function() { root.passHeard = []; root.finishUnlock() })
    }
  }
  Timer { id: passResetTimer; interval: 15000; onTriggered: root.passHeard = [] }
  Timer {
    id: passCooldownTimer
    interval: 250
    repeat: true
    onTriggered: {
      root.passCooldownLeft = Math.max(0, Math.ceil((root.passCooldownUntil - Date.now()) / 1000))
      if (root.passCooldownLeft === 0) stop()
    }
  }

  function isBypass(text) {
    return !passMode && bypassWord.length > 0 && String(text || "").toLowerCase().endsWith(bypassWord)
  }


  function handleTyped(text) {
    if (singingOnly) { enteredPassword = ""; return }
    text = String(text || "").slice(-128)
    enteredPassword = text
    if (text.length > 0 && failureMessage.length > 0) failureMessage = ""
    if (lockRequested && isBypass(text)) {
      logEvent("unlock: bypass word")
      finishUnlock()
    } else if (lockRequested && passMode && pitchSettings.passCodeEndsStream(text)) {
      logEvent("unlock: pass-code")
      finishUnlock()
    }
  }

  // Random root for every challenge, chosen from the roots the game says fit the pocket,
  // never the same note name as the previous one. Kept here, and on disk, because each
  // lock screen's game is created fresh.
  function pickPitchRoot(candidates) {
    var last = ((pitchState.lastRoot % 12) + 12) % 12
    var fresh = candidates.filter(function(r) { return ((r % 12) + 12) % 12 !== last })
    var from = fresh.length ? fresh : candidates
    var r = from[Math.floor(Math.random() * from.length)]
    pitchState.lastRoot = r
    logEvent("pitch root " + r)
    return r
  }

  FileView {
    path: root.stateHome + "/pitchlock.json"
    printErrors: false
    watchChanges: true          // the settings panel can reset the history
    onFileChanged: reload()
    onAdapterUpdated: writeAdapter()
    onLoadFailed: writeAdapter()
    JsonAdapter {
      id: pitchState
      property int lastRoot: -1
      property var unlocks: []          // {at, secs, cents, root, quality}, newest last
    }
  }

  function recordPitchUnlock(stats) {
    pitchState.unlocks = (pitchState.unlocks || []).concat([stats]).slice(-500)
  }

  // Matrix Rain's music (its synth) would drown out singing, so it's stopped while locked
  // and started again on unlock, but only if it was playing. Uses Matrix Rain's own IPC;
  // does nothing when that plugin isn't installed.
  // Any other music (Spotify, a browser, …) is paused the same way, through MPRIS.
  // Setting: pauseMusic (on by default).
  property bool rainMusicPaused: false
  property var pausedPlayers: []
  function pauseRainMusic() {
    if (pitchSettings.pauseMusic === false) return
    if (!rainMusicCheck.running) rainMusicCheck.running = true
    const playing = (Mpris.players ? Mpris.players.values : []).filter(p => p && p.isPlaying && p.canPause)
    playing.forEach(p => p.pause())
    pausedPlayers = playing
    if (playing.length) logEvent("paused " + playing.length + " music player(s)")
  }
  function resumeRainMusic() {
    const players = pausedPlayers
    pausedPlayers = []
    players.forEach(p => { if (p && p.canPlay) p.play() })
    if (!rainMusicPaused) return
    rainMusicPaused = false
    Quickshell.execDetached(["omarchy-shell", "matrix-rain", "technoPlay"])
    logEvent("matrix rain music resumed")
  }
  Process {
    id: rainMusicCheck
    command: ["bash", "-c", "f=\"$HOME/.local/state/ertiv.matrix-rain/state.json\"; [ -f \"$f\" ] && jq -e '.technoOn == true' \"$f\" >/dev/null 2>&1 && omarchy-shell matrix-rain technoStop >/dev/null 2>&1 && echo stopped"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (String(text || "").trim() !== "stopped") return
        // Unlocked before the check finished: put the music straight back.
        if (!root.lockRequested) { Quickshell.execDetached(["omarchy-shell", "matrix-rain", "technoPlay"]); return }
        root.rainMusicPaused = true
        root.logEvent("matrix rain music paused")
      }
    }
  }

  function pitchUnlock() {
    if (!lockRequested) return
    logEvent("unlock: pitch match")
    finishUnlock()
  }

  readonly property bool locked: lockRequested || sessionLock.locked || sessionLock.secure
  readonly property bool authenticating: authenticatingPassword || fingerprintAuthenticating

  function realScreenCount() {
    var screens = Quickshell.screens || []
    var count = 0

    for (var i = 0; i < screens.length; i++) {
      var screen = screens[i]
      if (screen && screen.name && screen.width > 0 && screen.height > 0) count += 1
    }

    return count
  }

  function hasRealScreen() {
    return realScreenCount() > 0
  }

  function queueSessionLock() {
    pendingSessionLock = true
    if (!sessionLockStabilizeTimer.running) logEvent("lock-pending: screen-stabilizing")
    sessionLockStabilizeTimer.restart()
    if (!pendingSessionLockTimer.running) pendingSessionLockTimer.start()
  }

  function requestSessionLock() {
    if (!lockRequested || sessionLock.locked || sessionLock.secure) return
    if (sessionLockStabilizeTimer.running) return

    if (!hasRealScreen()) {
      if (!pendingSessionLock || lastEvent !== "lock-pending: no-real-screen") logEvent("lock-pending: no-real-screen")
      pendingSessionLock = true
      if (!pendingSessionLockTimer.running) pendingSessionLockTimer.start()
      return
    }

    pendingSessionLock = false
    pendingSessionLockTimer.stop()
    sessionLock.locked = true
  }

  // ext-session-lock outlives its client, and a restart carries no lock over, so
  // a session locked this early is an orphan behind Hyprland's failsafe. Outputs
  // are often still absent here, so ask until the answer means something.
  function checkStrandedLock() {
    if (strandedLockResolved || strandedLockCheckProc.running) return

    // A lock this shell took is nobody's orphan.
    if (locked || lockRequested) {
      strandedLockResolved = true
      return
    }

    strandedLockCheckProc.running = true
  }

  function recoverStrandedLock() {
    if (!strandedLock || locked || !passwordPamConfigured) return

    strandedLock = false
    logEvent("lock-stranded: recovering")
    beginLock()
  }

  function refreshBackground() {
    if (!readlinkProc.running) readlinkProc.running = true
  }

  function refreshFingerprintStatus() {
    if (!fingerprintCheckProc.running) fingerprintCheckProc.running = true
  }

  function logEvent(event) {
    lastEvent = event
    lastEventAt = new Date().toISOString()
    console.log("omarchy lock " + lastEventAt + " " + event)
  }

  function resetAuthenticationState() {
    enteredPassword = ""
    pendingPassword = ""
    failureMessage = ""
    failedAttempts = 0
    authenticatingPassword = false
    fingerprintAuthenticating = false
    fingerprintRetryTimer.stop()
    if (passwordPam.active) passwordPam.abort()
    if (fingerprintPam.active) fingerprintPam.abort()
  }

  function beginLock() {
    if (!passwordPamConfigured) {
      logEvent("lock-denied: missing-pam")
      return false
    }

    resetAuthenticationState()
    primaryScreenName = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
    pitchMicFailed = false
    pauseRainMusic()
    passHeard = []
    passWrong = 0
    lockRequested = true
    armBlankTimer()
    logEvent("lock-requested")
    queueSessionLock()

    Qt.callLater(function() {
      root.refreshBackground()
      root.refreshFingerprintStatus()
    })

    return true
  }

  function finishUnlock() {
    if (!root.locked && !lockRequested) return
    resumeRainMusic()

    lockRequested = false
    pendingSessionLock = false
    sessionLockStabilizeTimer.stop()
    pendingSessionLockTimer.stop()
    resetAuthenticationState()
    idleBlankTimer.stop()
    sessionLock.locked = false
    logEvent("unlocked")
    runWake()
  }

  function armBlankTimer() {
    idleBlankTimer.armedAt = Date.now()
    idleBlankTimer.restart()
  }

  function runWake() {
    if (!wakeProcess.running) wakeProcess.running = true
    if (lockRequested) armBlankTimer()
  }

  function runBlank() {
    if (!blankProcess.running) blankProcess.running = true
  }

  function submitPassword(value) {
    if (singingOnly) return
    var password = String(value || "")
    if (!lockRequested || authenticatingPassword || password.length === 0) return

    runWake()
    pendingPassword = password
    failureMessage = ""
    authenticatingPassword = true

    if (!passwordPam.start()) {
      handlePasswordFailure()
      return
    }

    Qt.callLater(respondToPasswordPrompt)
  }

  function respondToPasswordPrompt() {
    if (!authenticatingPassword || !passwordPam.active || !passwordPam.responseRequired) return
    passwordPam.respond(pendingPassword)
  }

  function handlePasswordFailure() {
    if (!lockRequested) return

    authenticatingPassword = false
    enteredPassword = ""
    pendingPassword = ""
    failedAttempts += 1
    failureMessage = "Authentication failed (" + failedAttempts + ")"
    runWake()
  }

  function startFingerprint() {
    if (!lockRequested || !sessionLock.secure || !fingerprintConfigured) return
    if (singingOnly) return
    if (fingerprintPam.active || fingerprintAuthenticating) return

    fingerprintAuthenticating = true
    if (!fingerprintPam.start()) {
      fingerprintAuthenticating = false
    }
  }

  function handleFingerprintFinished(result) {
    fingerprintAuthenticating = false

    if (!lockRequested) return
    if (result === PamResult.Success) {
      finishUnlock()
    } else if (fingerprintConfigured) {
      fingerprintRetryTimer.restart()
    }
  }

  WlSessionLock {
    id: sessionLock

    locked: false

    onSecureStateChanged: {
      root.logEvent("secure=" + secure)
      if (secure) {
        root.pendingSessionLock = false
        sessionLockStabilizeTimer.stop()
        pendingSessionLockTimer.stop()
        root.startFingerprint()
      }
    }

    onLockStateChanged: {
      root.logEvent("session-locked=" + locked)

      if (locked) {
        root.pendingSessionLock = false
        sessionLockStabilizeTimer.stop()
        pendingSessionLockTimer.stop()
      }

      if (!locked) root.resumeRainMusic()
      if (!locked && root.lockRequested) {
        root.lockRequested = false
        root.pendingSessionLock = false
        sessionLockStabilizeTimer.stop()
        pendingSessionLockTimer.stop()
        root.resetAuthenticationState()
        root.runWake()
      }
    }

    WlSessionLockSurface {
      id: lockSurface
      color: Color.background

      readonly property bool pitchScreen: root.primaryScreenName === ""
        || (lockSurface.screen && lockSurface.screen.name === root.primaryScreenName)

      // Keyboard focus in a lock surface isn't automatic for a Loader-hosted item,
      // so keep claiming it while locked. If the game still can't get focus, the
      // stock password field takes over (pitchFocusFailed) so typing never goes nowhere.
      property bool pitchFocusFailed: false

      Timer {
        interval: 100
        repeat: true
        running: pitchLoader.status === Loader.Ready && root.lockRequested
        property int misses: 0
        onRunningChanged: { misses = 0; lockSurface.pitchFocusFailed = false }
        onTriggered: {
          var game = pitchLoader.item
          if (!game || game.activeFocus) { misses = 0; return }
          game.forceActiveFocus()
          if (!game.activeFocus && ++misses === 20 && !lockSurface.pitchFocusFailed) {
            root.logEvent("pitch: no keyboard focus, falling back to password field")
            lockSurface.pitchFocusFailed = true
          }
        }
      }

      Loader {
        id: pitchLoader
        anchors.fill: parent
        active: lockSurface.pitchScreen
        focus: active
        onLoaded: Qt.callLater(function() { if (pitchLoader.item) pitchLoader.item.forceActiveFocus() })
        sourceComponent: PitchGame {
          lockMode: true
          active: root.lockRequested
          pitchd: root.pitchdPath
          pickRootFn: root.pickPitchRoot
          settings: root.pitchSettings
          pastUnlocks: pitchState.unlocks || []
          onUnlockRecorded: function(stats) { root.recordPitchUnlock(stats) }
          fontFamily: Style.font.family
          backgroundPath: root.backgroundPath
          backgroundVersion: root.backgroundVersion
          typedText: root.enteredPassword
          failureMessage: root.failureMessage
          authenticating: root.authenticatingPassword
          onTypedTextEdited: function(text) { root.handleTyped(text) }
          onSubmitPassword: function(text) { root.submitPassword(text) }
          onUnlockRequested: root.pitchUnlock()
          singingOnly: root.singingOnly
          passMode: root.passMode
          passProgress: root.passHeard.length
          passCooldown: root.passCooldownLeft
          onNoteSung: function(midi) { root.passNoteSung(midi) }
          onMicErrorChanged: {
            root.pitchMicFailed = micError
            if (micError) root.logEvent("pitch: microphone failed" + (root.pitchSettings.unlockMode === "singing" ? ", password re-enabled" : ""))
          }
          onWakeRequested: root.runWake()
        }
      }

      LockView {
        id: lockView
        visible: !lockSurface.pitchScreen
        anchors.fill: parent
        backgroundPath: root.backgroundPath
        backgroundVersion: root.backgroundVersion
        fingerprintConfigured: root.fingerprintConfigured
        authenticatingPassword: root.authenticatingPassword
        failureMessage: root.failureMessage
        failedAttempts: root.failedAttempts
        // Hidden on the pitch screen: it must not hold keyboard focus there, or keys
        // (space, shortcuts) land in its invisible password field instead of the game.
        inputEnabled: root.lockRequested && !root.singingOnly && (!lockSurface.pitchScreen || lockSurface.pitchFocusFailed)
        loadBackground: root.locked
        passwordText: root.enteredPassword
        onPasswordTextEdited: function(password) { root.handleTyped(password) }
        onSubmitPassword: function(password) { root.submitPassword(password) }
        onClearFailureRequested: root.failureMessage = ""
        onWakeRequested: root.runWake()
      }

    }
  }

  PanelWindow {
    id: previewWindow
    visible: root.previewVisible
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-lock-preview"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Loader {
      anchors.fill: parent
      active: root.previewVisible
      focus: active
      sourceComponent: PitchGame {
        lockMode: true
        active: root.previewVisible
        pitchd: root.pitchdPath
        pickRootFn: root.pickPitchRoot
        settings: root.pitchSettings
        pastUnlocks: pitchState.unlocks || []
        fontFamily: Style.font.family
        backgroundPath: root.backgroundPath
        backgroundVersion: root.backgroundVersion
        typedText: root.previewText
        onTypedTextEdited: function(text) {
          root.previewText = root.isBypass(text) ? "" : text
          if (root.isBypass(text)) root.previewVisible = false
        }
        onSubmitPassword: root.previewText = ""
        onUnlockRequested: root.previewVisible = false
      }
    }

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.RightButton
      onClicked: root.previewVisible = false
    }
  }

  PamContext {
    id: passwordPam
    config: "omarchy-lock-password"
    user: root.userName

    onResponseRequiredChanged: root.respondToPasswordPrompt()
    onPamMessage: root.respondToPasswordPrompt()

    onCompleted: function(result) {
      root.authenticatingPassword = false
      root.pendingPassword = ""

      if (!root.lockRequested) return
      if (result === PamResult.Success) root.finishUnlock()
      else root.handlePasswordFailure()
    }

    onError: function(error) {
      root.handlePasswordFailure()
    }
  }

  PamContext {
    id: fingerprintPam
    config: "omarchy-lock-fingerprint"
    user: root.userName

    onCompleted: function(result) {
      root.handleFingerprintFinished(result)
    }

    onError: function(error) {
      root.fingerprintAuthenticating = false
      if (root.lockRequested && root.fingerprintConfigured) fingerprintRetryTimer.restart()
    }
  }

  Timer {
    id: fingerprintRetryTimer
    interval: 250
    repeat: false
    onTriggered: root.startFingerprint()
  }

  Process {
    id: readlinkProc
    command: ["readlink", "-f", root.currentBackgroundLink]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var next = String(text || "").trim()
        if (next !== root.backgroundPath) {
          root.backgroundPath = next
          root.backgroundVersion += 1
        }
      }
    }
  }

  Process {
    id: fingerprintCheckProc
    command: ["bash", "-c", "if [[ -f /etc/pam.d/omarchy-lock-fingerprint ]] && command -v fprintd-list >/dev/null 2>&1 && fprintd-list \"$USER\" 2>/dev/null | grep -qi finger; then echo yes; else echo no; fi"]
    stdout: StdioCollector { id: fingerprintCheckStdout; waitForEnd: true }
    onExited: {
      root.fingerprintConfigured = String(fingerprintCheckStdout.text || "").trim() === "yes"
      if (root.lockRequested && root.fingerprintConfigured) root.startFingerprint()
      else if (!root.fingerprintConfigured && fingerprintPam.active) fingerprintPam.abort()
    }
  }

  Process {
    id: strandedLockCheckProc
    command: ["bash", "-c", "omarchy-hyprland-session-locked"]
    onExited: function(exitCode) {
      // No output to read the lock off yet.
      if (exitCode === 2) return

      root.strandedLockResolved = true

      // A lock taken while this was in flight is this shell's own.
      root.strandedLock = exitCode === 0 && !root.locked && !root.lockRequested
      root.recoverStrandedLock()
    }
  }

  Process {
    id: wakeProcess
    command: ["bash", "-c", "omarchy-system-wake"]
  }

  Process {
    id: blankProcess
    command: ["bash", "-c", "omarchy-brightness-keyboard off; omarchy-brightness-display off"]
  }

  Timer {
    id: idleBlankTimer
    interval: 20000
    repeat: false
    property double armedAt: 0
    onTriggered: {
      // A countdown frozen by suspend fires right after resume, which would
      // blank the freshly woken unlock screen under the user. Wall-clock time
      // exposes the gap: take a fresh run-up instead of blanking.
      if (Date.now() - armedAt > interval + 2000) {
        root.armBlankTimer()
        return
      }
      // Only a password check in flight should hold the display up. The
      // fingerprint PAM stays armed for the whole lock, so gating on
      // `authenticating` here would keep the panel lit until unlock.
      if (root.lockRequested && !root.authenticatingPassword) root.runBlank()
    }
  }

  Timer {
    id: sessionLockStabilizeTimer
    interval: 500
    repeat: false
    onTriggered: root.requestSessionLock()
  }

  Timer {
    id: pendingSessionLockTimer
    interval: 100
    repeat: true
    onTriggered: root.requestSessionLock()
  }

  Timer {
    id: strandedLockRetryTimer
    interval: 500
    repeat: true
    // Covers the compositor settling; screens coming back re-arm it.
    readonly property int budget: 20
    property int remaining: 20
    running: !root.strandedLockResolved && remaining > 0

    function rearm() {
      if (!root.strandedLockResolved) remaining = budget
    }

    onTriggered: {
      remaining -= 1
      root.checkStrandedLock()
    }
  }

  Connections {
    target: Quickshell
    function onScreensChanged() {
      root.requestSessionLock()

      // A monitor still coming up has no workspace, so cannot answer yet.
      strandedLockRetryTimer.rearm()
      root.checkStrandedLock()
    }
  }

  onAuthenticatingPasswordChanged: {
    if (!lockRequested) return
    if (authenticatingPassword) idleBlankTimer.stop()
    else armBlankTimer()
  }

  FileView {
    path: "/etc/pam.d/omarchy-lock-password"
    watchChanges: true
    printErrors: false
    onLoaded: root.passwordPamConfigured = true
    onLoadFailed: root.passwordPamConfigured = false
    onFileChanged: reload()
  }

  // No lock before PAM is known good. An answer from before then may be stale --
  // the failsafe can be cleared from a TTY -- so re-ask rather than act on it.
  onPasswordPamConfiguredChanged: {
    if (!passwordPamConfigured) return

    strandedLock = false
    strandedLockResolved = false
    strandedLockRetryTimer.rearm()
    checkStrandedLock()
  }

  Component.onCompleted: {
    refreshBackground()
    refreshFingerprintStatus()
    checkStrandedLock()
  }

  IpcHandler {
    target: "lock"

    function lock(): string {
      if (!root.passwordPamConfigured) return "missing-pam"
      if (!root.locked && !root.beginLock()) return "failed"
      return "ok"
    }

    function isLocked(): string {
      return root.locked ? "true" : "false"
    }

    function status(): string {
      return JSON.stringify({
        locked: root.locked,
        requested: root.lockRequested,
        pending: root.pendingSessionLock,
        sessionLocked: sessionLock.locked,
        secure: sessionLock.secure,
        realScreens: root.realScreenCount(),
        passwordPam: root.passwordPamConfigured,
        fingerprint: root.fingerprintConfigured,
        authenticating: root.authenticating,
        lastEvent: root.lastEvent,
        lastEventAt: root.lastEventAt
      })
    }

    function preview(): string {
      root.refreshBackground()
      root.refreshFingerprintStatus()
      root.previewText = ""
      root.previewVisible = true
      return "ok"
    }

    function hidePreview(): string {
      root.previewVisible = false
      return "ok"
    }
  }
}
