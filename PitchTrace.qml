import QtQuick

// Scrolling pitch-over-time trace. Y is log-frequency (one row per semitone),
// centred on the current target; the target lane glows at ±tolerance width.
// The view re-frames so the singer's pitch is always on screen along with the target.
Canvas {
  id: c
  property var game

  readonly property real baseSpan: 8      // semitones shown above/below when singer is near target
  readonly property real comfort: 6       // how far from target the singer can go before the view moves
  // Distance from the target to the singer (live, or last heard), beyond the comfort zone.
  readonly property real away: game.lastMidi > 0 ? game.lastMidi - game.displayTarget : 0
  readonly property real excess: Math.max(0, Math.abs(away) - comfort)
  property real center: game.displayTarget + Math.sign(away) * excess / 2
  property real span: baseSpan + excess / 2
  Behavior on center { NumberAnimation { duration: 350; easing.type: Easing.OutCubic } }
  Behavior on span { NumberAnimation { duration: 350; easing.type: Easing.OutCubic } }
  onCenterChanged: requestPaint()
  onSpanChanged: requestPaint()

  readonly property real stepPx: 2.4      // px per analysis frame
  readonly property real headInset: 140

  function rgba(col, a) {
    return "rgba(" + Math.round(col.r * 255) + "," + Math.round(col.g * 255) + "," + Math.round(col.b * 255) + "," + a + ")"
  }

  onPaint: {
    const g = game, pal = g.pal, ctx = getContext("2d")
    const w = width, h = height, pps = h / (2 * span)
    const y = m => h / 2 - (m - center) * pps
    const now = Date.now() / 1000
    ctx.reset()
    ctx.save()
    ctx.beginPath(); ctx.roundedRect(0, 0, w, h, 17, 17); ctx.clip()

    // semitone grid
    ctx.font = "12px '" + pal.font + "'"
    ctx.textBaseline = "middle"
    for (let m = Math.floor(center - span) - 1; m <= Math.ceil(center + span) + 1; m++) {
      const natural = [0, 2, 4, 5, 7, 9, 11].indexOf(g.pc(m)) >= 0
      ctx.strokeStyle = rgba(pal.grid, natural ? 0.9 : 0.4)
      ctx.lineWidth = g.pc(m) === 0 ? 2 : 1
      ctx.beginPath(); ctx.moveTo(56, y(m)); ctx.lineTo(w, y(m)); ctx.stroke()
      if (natural && (pps >= 13 || g.pc(m) === 0)) { ctx.fillStyle = rgba(pal.dim, 0.9); ctx.fillText(g.noteName(m), 14, y(m)) }
    }

    // chord lanes
    for (let i = 0; i < g.toneCount; i++) {
      const cm = g.chordMidi(i), col = g.toneColors[i], yy = y(cm)
      const current = i === g.tone
      if (current) {
        const half = g.tolerance / 100 * pps, pulse = 0.5 + 0.5 * Math.sin(now * 4)
        const grad = ctx.createLinearGradient(56, 0, w, 0)
        grad.addColorStop(0, rgba(col, 0.02))
        grad.addColorStop(1, rgba(col, 0.20 + 0.10 * pulse))
        ctx.fillStyle = grad
        ctx.fillRect(56, yy - half, w - 56, half * 2)
        ctx.strokeStyle = rgba(col, 0.25); ctx.lineWidth = 10
        ctx.beginPath(); ctx.moveTo(56, yy); ctx.lineTo(w, yy); ctx.stroke()
      }
      ctx.strokeStyle = rgba(col, current ? 1 : g.done[i] ? 0.55 : 0.2)
      ctx.lineWidth = current ? 2 : 1.5
      ctx.beginPath(); ctx.moveTo(56, yy); ctx.lineTo(w, yy); ctx.stroke()

      // lane tag on the right
      const tag = g.toneShort[i], tw = 34
      ctx.fillStyle = rgba(col, current || g.done[i] ? 0.95 : 0.3)
      ctx.beginPath(); ctx.roundedRect(w - tw - 12, yy - 11, tw, 22, 11, 11); ctx.fill()
      ctx.fillStyle = rgba(pal.bg, 1)
      ctx.textAlign = "center"; ctx.fillText(tag, w - tw / 2 - 12, yy + 1); ctx.textAlign = "start"
    }

    // "now" line
    const headX = w - headInset
    ctx.strokeStyle = rgba(pal.dim, 0.25); ctx.lineWidth = 1
    ctx.beginPath(); ctx.moveTo(headX, 0); ctx.lineTo(headX, h); ctx.stroke()

    // trace, drawn in runs of the same colour: wide faint pass for glow, then a crisp pass
    const hist = g.history, n = hist.length
    const colorOf = p => p.ok ? pal.good : Math.abs(p.e) < 100 ? pal.warn : pal.bad
    const xOf = i => headX - (n - 1 - i) * stepPx
    const yOf = p => Math.max(-10, Math.min(h + 10, y(p.m)))
    const edge = 14
    for (const pass of [[10, 0.12], [3, 1]]) {
      ctx.lineWidth = pass[0]; ctx.lineCap = "round"; ctx.lineJoin = "round"
      let i = 0
      while (i < n) {
        if (!hist[i] || xOf(i) < 56) { i++; continue }
        const col = colorOf(hist[i])
        ctx.strokeStyle = rgba(col, pass[1])
        ctx.beginPath(); ctx.moveTo(xOf(i), yOf(hist[i]))
        let j = i + 1
        while (j < n && hist[j] && Math.abs(hist[j].m - hist[j - 1].m) < 1.5) {
          ctx.lineTo(xOf(j), yOf(hist[j]))
          if (colorOf(hist[j]) !== col) break
          j++
        }
        ctx.stroke()
        i = (j < n && hist[j] && colorOf(hist[j]) !== col && Math.abs(hist[j].m - hist[j - 1].m) < 1.5) ? j : j
      }
    }

    // head + error connector. Clamped inside the panel so the monitor never leaves the screen;
    // while silent it rests, dimmed, at the last pitch heard.
    const last = n ? hist[n - 1] : null
    const silentHead = !last && g.lastMidi > 0
    if ((last || silentHead) && !g.unlocked) {
      const lm = last ? last.m : g.lastMidi
      const le = last ? last.e : (g.lastMidi - g.displayTarget) * 100
      const hy = Math.max(edge, Math.min(h - edge, y(lm))), ty = y(g.displayTarget)
      const col = silentHead ? pal.dim : colorOf(last)
      ctx.strokeStyle = rgba(col, 0.5); ctx.lineWidth = 1.5
      ctx.beginPath(); ctx.moveTo(headX + 16, hy); ctx.lineTo(headX + 16, ty); ctx.stroke()
      const halo = ctx.createRadialGradient(headX, hy, 0, headX, hy, 26)
      halo.addColorStop(0, rgba(col, 0.55)); halo.addColorStop(1, rgba(col, 0))
      ctx.fillStyle = halo
      ctx.beginPath(); ctx.arc(headX, hy, 26, 0, Math.PI * 2); ctx.fill()
      ctx.fillStyle = rgba(silentHead ? pal.dim : pal.text, 1)
      ctx.beginPath(); ctx.arc(headX, hy, 6, 0, Math.PI * 2); ctx.fill()
      ctx.fillStyle = rgba(col, 1)
      const label = (le >= 0 ? "+" : "") + Math.round(le) + "¢"
      ctx.fillText(silentHead ? g.noteName(lm) + "  " + label : label, headX + 24, (hy + ty) / 2)
    }
    ctx.restore()
  }
}
