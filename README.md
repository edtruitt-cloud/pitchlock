# Pitchlock

A lock screen for [Omarchy](https://omarchy.org) that you unlock by **singing a chord**: four
notes (a 7th chord), each held in tune for a moment. Your password always works too.

- Live pitch trace and a chord wheel that draws the chord as you sing it
- Fits your voice: presets from bass to soprano, or measure your own range
- Difficulty from Easy to Perfect pitch; optional shuffled note order
- Chords always fit your range, using an inversion when the plain chord doesn't fit
- Chords, melodies (sing back 4–6 notes), or both
- Scores for every voice type × difficulty, a steadiness score, achievements, and a recording
  of your fastest unlock for each difficulty
- A daily challenge (the same chord on every computer, fitted to each voice) with an optional
  warm-up scale first, on your first unlock of the day
- Trouble notes (which notes you tend to sing flat or sharp), a day-streak flame on the lock,
  and a choice of tone sound (organ, piano, soft sine, choir)
- Practice window with ear training (name the chord or interval)
- Optional: easier difficulty early and late, a harmony drone (headphones), notes that float
  up behind the game
- Settings panel on the bar
- Colours, font and wallpaper follow your Omarchy theme

## Install

Needs Omarchy (with its Quickshell lock screen), PipeWire, a microphone and `gcc`.

```sh
git clone https://github.com/edtruitt-cloud/pitchlock
cd pitchlock
./install.sh
```

The installer:

1. Clones Omarchy's own lock as `<your-username>.lock` (so it stays trusted for password
   checks), or backs up an existing clone to `~/.local/share/pitchlock/` first
2. Builds the small pitch detector (`pitchd.c`)
3. Adds the pitch game and a **♪** settings icon to your bar
4. Adds an Omarchy post-update hook that warns you if Omarchy's lock screen changes
5. Restarts the Omarchy shell

It refuses to run while the screen is locked, or if your Omarchy lock differs from the one
pitchlock was built on (`stock-lock-baseline/`), because installing would undo those changes.
Review with `diff -r stock-lock-baseline /usr/share/omarchy/shell/plugins/lock`, then use
`./install.sh --force` if you're happy.

Then click **♪** on the bar → **Measure my voice**, and **Preview** to see the lock.

## Uninstall

```sh
./uninstall.sh
```

Removes the plugin (Omarchy keeps a backup), the bar icon and the hook, and gives the lock screen
back to Omarchy. Your settings (`~/.config/pitchlock/`) and history
(`~/.local/state/pitchlock.json`) are kept in case you reinstall.

## Using it

On the lock screen, **Space** plays the note to sing; it's the only control. The first note plays
when a chord appears, matching a note plays the next one, and the finished chord plays on unlock
(each can be switched off in the panel). Sing in the octave
shown: the same note an octave up or down doesn't count.

You can always type your password and press Enter instead.

## Settings (♪ on the bar)

| Section | What |
|---|---|
| Voice | Preset (bass … soprano, or **All** for wide-range voices), lowest/highest note, **Measure my voice** |
| Challenge | Chords / melodies / both, difficulty (Easy, Normal, Hard, Perfect pitch), pitch accuracy, hold time, chord types, how often diminished/augmented/sus4 appear, random note order, easier early and late, floating notes |
| Sound | Play the first note when a chord appears, the next note after a match, harmony drone, pause music while locked, the chord on unlock, tone volume |
| Microphone | Mic test, noise rejection, how long before the mic sleeps |
| Unlock | What unlocks it: **singing, password or bypass word**; **singing only**; or **pass-notes (secure)**. Optional bypass word, pass-notes and pass-code setup, show time/accuracy, how long the unlock screen stays |
| Scores | A grid of voice types × difficulties for chords or melodies: typical time (last 10, unusually slow ones left out) and best; steadiness |
| Achievements | Reachable goals (unlock counts, day streaks, every difficulty and chord family, melodies, steadiness, ear training…) |
| Best recordings | Your fastest unlock per difficulty as a recording to play back (on this computer only; never in pass-notes mode) |

Buttons: **Practice** opens a practice window with the same settings; **Preview** shows the
lock screen without locking.

Settings live in `~/.config/pitchlock/settings.json` and apply to the lock immediately.

## Good to know

- **Security:** pitchlock is a fun lock, not a strong one. Anyone who can sing the chord gets in,
  and so can someone who knows your bypass word if you set one. Your password is unaffected.
- **Pass-notes (secure)** is for when you need a real lock: four exact notes you memorise (set
  in the panel, then stored only as a salted hash and never shown again), or a typed pass-code
  that unlocks the moment you finish typing it, no Enter. The lock never plays or shows the notes;
  a wrong note is ignored and a right one fills a dot with a short ding of that note (so someone
  could find them by trying notes one at a time; after 20 clearly wrong notes it stops listening
  for a minute, and notes a semitone off don't count as wrong). Your account password + Enter always works as a backup. Someone who hears you
  sing them could learn your pass-notes.
- **Singing only** turns off the password, bypass word and fingerprint on the lock. It isn't more
  secure (anyone who can sing the chord gets in), and a sore throat or a loud room can lock you
  out. If the microphone stops working (won't start, stops sending audio, or is muted) the
  password comes back automatically.
- **Music** that's playing (any player, and Matrix Rain's synth) pauses while the screen is
  locked and carries on when you unlock (setting: *Pause music while locked*).
- **The mic** only listens while the screen is locked, stops after a minute without sound
  (any key wakes it), and nothing is recorded or sent anywhere.
- **Loud rooms:** singing or music nearby that happens to hit the notes can count. Raise
  *Noise rejection* or tighten *Pitch accuracy* if that matters to you.
- **Quiet voices:** if the mic test doesn't show your note, lower *Noise rejection*.

## Files

| File | |
|---|---|
| `PitchGame.qml` | The game: chords, pitch matching, stats, lock-screen behaviour |
| `PitchTrace.qml`, `PitchChordRing.qml`, `PitchCentsMeter.qml`, `PitchStageChip.qml`, `PitchBadge.qml` | Visuals |
| `PitchTheme.qml` | Colours from the current Omarchy theme |
| `PitchSettings.qml` | Settings file, presets, defaults |
| `PitchBarWidget.qml`, `PitchSettingsPanel.qml` | The ♪ bar icon and settings panel |
| `pitchstats.js` | Shared stats (typical time) |
| `pitchd.c` | Pitch detector (YIN) and tone generator, via PipeWire |
| `lock-Service.qml` | Omarchy's lock service with the game wired in |
| `shell.qml`, `pitchlock` | Practice window and its launcher |
| `install.sh`, `uninstall.sh`, `stock-lock-check`, `stock-lock-baseline/` | Installing and update safety |

Development: edit here, run `./install-lock` (copies files only), then `omarchy restart shell`
while unlocked. Changes to the lock service only take effect after that restart.
