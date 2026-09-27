import QtQuick

// Chromatic circle (C at top). Chord tones sit on the rim; completed ones are
// joined into the triad's shape. The live pitch is a needle + fading trail.
Canvas {
  id: c
  property var game

  function rgba(col, a) {
    return "rgba(" + Math.round(col.r * 255) + "," + Math.round(col.g * 255) + "," + Math.round(col.b * 255) + "," + a + ")"
  }

  onPaint: {
    const g = game, pal = g.pal, ctx = getContext("2d")
    const w = width, h = height, cx = w / 2, cy = h / 2
    const R = Math.min(w, h) / 2 - 34, inner = R * 0.64
    const ang = p => p / 12 * Math.PI * 2 - Math.PI / 2
    const pt = (p, r) => [cx + Math.cos(ang(p)) * r, cy + Math.sin(ang(p)) * r]
    const now = Date.now() / 1000
    ctx.reset()

    // disc + rim
    const disc = ctx.createRadialGradient(cx, cy, 0, cx, cy, R)
    disc.addColorStop(0, rgba(pal.panel, 1)); disc.addColorStop(1, rgba(pal.bgGlow, 1))
    ctx.fillStyle = disc
    ctx.beginPath(); ctx.arc(cx, cy, R, 0, Math.PI * 2); ctx.fill()
    ctx.strokeStyle = rgba(pal.grid, 1); ctx.lineWidth = 2
    ctx.beginPath(); ctx.arc(cx, cy, R, 0, Math.PI * 2); ctx.stroke()
    ctx.beginPath(); ctx.arc(cx, cy, inner, 0, Math.PI * 2); ctx.stroke()

    // ticks + labels
    const tones = g.intervals.map((_, i) => i)
    const chordPcs = tones.map(i => g.pc(g.rootMidi + g.intervals[i]))
    ctx.font = "13px '" + pal.font + "'"
    ctx.textAlign = "center"; ctx.textBaseline = "middle"
    for (let p = 0; p < 12; p++) {
      const a = pt(p, R - 10), b = pt(p, R), l = pt(p, R + 20)
      const member = chordPcs.indexOf(p)
      ctx.strokeStyle = rgba(pal.dim, 0.6); ctx.lineWidth = 2
      ctx.beginPath(); ctx.moveTo(a[0], a[1]); ctx.lineTo(b[0], b[1]); ctx.stroke()
      ctx.fillStyle = member >= 0 ? rgba(g.toneColors[member], 1) : rgba(pal.dim, 0.8)
      ctx.fillText(g.noteNames[p], l[0], l[1])
    }

    // triad shape from completed tones
    // Completed tones joined in circle order, so a 4-note chord draws a clean shape.
    const donePts = tones.filter(i => g.done[i]).sort((a, b) => chordPcs[a] - chordPcs[b]).map(i => pt(chordPcs[i], R))
    if (donePts.length >= 2) {
      ctx.beginPath(); ctx.moveTo(donePts[0][0], donePts[0][1])
      for (const q of donePts.slice(1)) ctx.lineTo(q[0], q[1])
      ctx.closePath()
      ctx.fillStyle = rgba(g.unlocked ? pal.good : pal.text, g.unlocked ? 0.16 + 0.06 * Math.sin(now * 3) : 0.06)
      ctx.fill()
      ctx.strokeStyle = rgba(g.unlocked ? pal.good : pal.text, g.unlocked ? 0.95 : 0.6); ctx.lineWidth = g.unlocked ? 4 : 2; ctx.stroke()
    }

    // unlock moment: ripples roll out of each chord note, and a ring bursts from the centre
    if (g.unlocked && g.unlockedAt > 0) {
      const t = (Date.now() - g.unlockedAt) / 1000
      if (t < 1.4) {
        const burst = ctx.createRadialGradient(cx, cy, 0, cx, cy, R * (0.3 + t))
        burst.addColorStop(0, rgba(pal.good, 0)); burst.addColorStop(0.85, rgba(pal.good, 0.22 * (1 - t / 1.4))); burst.addColorStop(1, rgba(pal.good, 0))
        ctx.fillStyle = burst
        ctx.beginPath(); ctx.arc(cx, cy, R * (0.3 + t), 0, Math.PI * 2); ctx.fill()
      }
      for (let i = 0; i < g.toneCount; i++) {
        const q = pt(chordPcs[i], R)
        for (let k = 0; k < 3; k++) {
          const ph = (t * 0.8 + k / 3 + i * 0.11) % 1
          ctx.strokeStyle = rgba(g.toneColors[i], 0.7 * (1 - ph)); ctx.lineWidth = 3 * (1 - ph) + 0.5
          ctx.beginPath(); ctx.arc(q[0], q[1], 12 + ph * 64, 0, Math.PI * 2); ctx.stroke()
        }
      }
    }

    // live trail (pitch class only, so octave doesn't matter here)
    const hist = g.history, n = hist.length, trail = 45
    for (let i = Math.max(0, n - trail); i < n; i++) {
      const p = hist[i]
      if (!p) continue
      const age = (n - 1 - i) / trail, q = pt(((p.m % 12) + 12) % 12, inner - 4)
      ctx.fillStyle = rgba(p.ok ? pal.good : pal.warn, 0.5 * (1 - age))
      ctx.beginPath(); ctx.arc(q[0], q[1], 4 * (1 - age) + 1, 0, Math.PI * 2); ctx.fill()
    }

    // needle
    if (g.voiced) {
      const lp = ((g.liveMidi % 12) + 12) % 12, tip = pt(lp, inner - 4)
      const col = g.inTune ? pal.good : Math.abs(g.errCents) < 100 ? pal.warn : pal.bad
      ctx.strokeStyle = rgba(col, 0.9); ctx.lineWidth = 3; ctx.lineCap = "round"
      const base = pt(lp, 78)
      ctx.beginPath(); ctx.moveTo(base[0], base[1]); ctx.lineTo(tip[0], tip[1]); ctx.stroke()
      const glow = ctx.createRadialGradient(tip[0], tip[1], 0, tip[0], tip[1], 20)
      glow.addColorStop(0, rgba(col, 0.7)); glow.addColorStop(1, rgba(col, 0))
      ctx.fillStyle = glow; ctx.beginPath(); ctx.arc(tip[0], tip[1], 20, 0, Math.PI * 2); ctx.fill()
    }

    // chord nodes on the rim
    for (let i = 0; i < g.toneCount; i++) {
      const q = pt(chordPcs[i], R), col = g.toneColors[i]
      if (g.done[i]) {
        const halo = ctx.createRadialGradient(q[0], q[1], 0, q[0], q[1], 26)
        halo.addColorStop(0, rgba(col, 0.6)); halo.addColorStop(1, rgba(col, 0))
        ctx.fillStyle = halo; ctx.beginPath(); ctx.arc(q[0], q[1], 26, 0, Math.PI * 2); ctx.fill()
        ctx.fillStyle = rgba(col, 1); ctx.beginPath(); ctx.arc(q[0], q[1], 11, 0, Math.PI * 2); ctx.fill()
      } else if (i === g.tone) {
        const pulse = 0.5 + 0.5 * Math.sin(now * 5)
        ctx.fillStyle = rgba(pal.bg, 1); ctx.beginPath(); ctx.arc(q[0], q[1], 12, 0, Math.PI * 2); ctx.fill()
        ctx.strokeStyle = rgba(col, 0.6 + 0.4 * pulse); ctx.lineWidth = 3
        ctx.beginPath(); ctx.arc(q[0], q[1], 12 + 2 * pulse, 0, Math.PI * 2); ctx.stroke()
        const prog = g.hold / g.holdNeeded
        if (prog > 0) {
          ctx.strokeStyle = rgba(col, 1); ctx.lineWidth = 4; ctx.lineCap = "round"
          ctx.beginPath(); ctx.arc(q[0], q[1], 21, -Math.PI / 2, -Math.PI / 2 + prog * Math.PI * 2); ctx.stroke()
        }
      } else {
        ctx.fillStyle = rgba(pal.bg, 1); ctx.beginPath(); ctx.arc(q[0], q[1], 9, 0, Math.PI * 2); ctx.fill()
        ctx.strokeStyle = rgba(col, 0.35); ctx.lineWidth = 2
        ctx.beginPath(); ctx.arc(q[0], q[1], 9, 0, Math.PI * 2); ctx.stroke()
      }
    }
  }

  // live readout in the hub
  Column {
    anchors.centerIn: parent
    spacing: 2
    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: c.game.voiced ? c.game.noteName(c.game.liveMidi) : "···"
      color: c.game.voiced ? (c.game.inTune ? c.game.pal.good : c.game.pal.text) : c.game.pal.dim
      font { family: c.game.pal.font; pixelSize: 44; weight: Font.Bold }
    }
    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: c.game.voiced ? c.game.liveHz.toFixed(1) + " Hz" : "sing"
      color: c.game.pal.dim
      font { family: c.game.pal.font; pixelSize: 15 }
    }
  }
}
