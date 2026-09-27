import QtQuick
import Quickshell
import Quickshell.Io

// Colours come from the current Omarchy theme (colors.toml), reloaded live when
// the theme changes. The defaults below are only used if the file can't be read.
QtObject {
  id: theme

  property color bg: "#070a12"
  property color bgGlow: "#121a33"
  property color panel: "#0d1220"
  property color grid: "#1a2238"
  property color text: "#e7ebf7"
  property color dim: "#64708f"
  property color good: "#6ff0c4"
  property color warn: "#ffc56b"
  property color bad: "#ff6b8b"
  property color root: "#6aa8ff"
  property color third: "#c28bff"
  property color fifth: "#ff9a5c"
  property color seventh: "#5cd6ff"
  property string font: "JetBrainsMono Nerd Font"

  readonly property string themeFile: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme/colors.toml"

  function mix(a, b, t) {
    return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, 1)
  }
  function luminance(c) {
    const f = v => v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4)
    return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b)
  }
  function contrast(a, b) {
    const la = luminance(a), lb = luminance(b)
    return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05)
  }
  function distance(a, b) {
    return Math.sqrt(Math.pow(a.r - b.r, 2) * 2 + Math.pow(a.g - b.g, 2) * 4 + Math.pow(a.b - b.b, 2) * 3)
  }

  // Themes name colours either semantically (red, accent, …) or as color0..15.
  function apply(raw) {
    const c = {}
    for (const line of String(raw || "").split("\n")) {
      const m = line.match(/^\s*([A-Za-z0-9_-]+)\s*=\s*["']?(#[0-9A-Fa-f]{6})/)
      if (m) c[m[1]] = Qt.color(m[2])
    }
    const pick = (...keys) => { for (const k of keys) if (c[k] !== undefined) return c[k]; return undefined }

    const background = pick("background", "color0")
    const foreground = pick("foreground", "color7")
    if (!background || !foreground) return

    bg = background
    text = pick("bright_foreground", "light_foreground", "color15") || foreground
    dim = pick("muted", "dark_foreground", "color8") || mix(background, foreground, 0.45)
    panel = mix(background, foreground, 0.035)
    bgGlow = pick("lighter_background") || mix(background, foreground, 0.08)
    grid = mix(background, foreground, 0.13)
    good = pick("green", "color2") || good
    warn = pick("yellow", "color3") || warn
    bad = pick("red", "color1") || bad

    // Chord-tone colours: the accent for the root, then the three remaining theme
    // colours that stand furthest apart from it and each other, skipping any
    // too dark to read on the background.
    const accent = pick("accent", "color4") || foreground
    const candidates = ["blue", "magenta", "cyan", "orange", "yellow", "green", "red",
                        "bright_blue", "bright_magenta", "bright_cyan", "bright_yellow", "bright_green",
                        "color4", "color5", "color6", "color12", "color13", "color14", "color3", "color2"]
      .map(k => c[k]).filter(x => x !== undefined && contrast(x, background) >= 3)
    let best = [], bestScore = -1
    for (let i = 0; i < candidates.length; i++)
      for (let j = i + 1; j < candidates.length; j++)
        for (let k = j + 1; k < candidates.length; k++) {
          const a = candidates[i], b = candidates[j], d = candidates[k]
          const score = Math.min(distance(a, accent), distance(b, accent), distance(d, accent),
                                 distance(a, b), distance(a, d), distance(b, d))
          if (score > bestScore) { bestScore = score; best = [a, b, d] }
        }
    root = accent
    if (best.length === 3) { third = best[0]; fifth = best[1]; seventh = best[2] }
  }

  property FileView file: FileView {
    path: theme.themeFile
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: theme.apply(text())
  }
}
