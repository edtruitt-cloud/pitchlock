import QtQuick

// Notes you sing rise up the background like Matrix Rain streams, trailing fainter
// copies, coloured by how in tune they were. Across the screen by note name (C at the
// left). In pass-notes mode they show "♪" only, so nothing on screen spells out a note.
Canvas {
  id: c
  property var game
  property bool hideNames: false
  property var particles: []

  function rgba(col, a) {
    return "rgba(" + Math.round(col.r * 255) + "," + Math.round(col.g * 255) + "," + Math.round(col.b * 255) + "," + a + ")"
  }

  function spawn(midi, inTune) {
    const pc = ((Math.round(midi) % 12) + 12) % 12
    particles.push({
      x: (pc + 0.5) / 12 * width + (Math.random() - 0.5) * width / 24,
      y: height + 20,
      speed: 70 + Math.random() * 50,
      text: hideNames ? "♪" : game.noteNames[pc],
      good: inTune,
      life: 1
    })
    if (particles.length > 60) particles.shift()
    if (!ticker.running) ticker.start()
  }

  Timer {
    id: ticker
    interval: 33
    repeat: true
    onTriggered: {
      const dt = interval / 1000
      for (const p of c.particles) { p.y -= p.speed * dt; p.life -= dt / 5 }
      c.particles = c.particles.filter(p => p.life > 0 && p.y > -80)
      if (!c.particles.length) stop()
      c.requestPaint()
    }
  }

  onPaint: {
    const ctx = getContext("2d")
    ctx.reset()
    const pal = game.pal
    ctx.textAlign = "center"
    ctx.textBaseline = "middle"
    for (const p of particles) {
      const col = p.good ? pal.good : pal.dim
      for (let k = 4; k >= 0; k--) {
        const a = p.life * (k === 0 ? 0.95 : 0.4 / k)
        ctx.font = (k === 0 ? "bold " : "") + (34 - k * 3) + "px '" + pal.font + "'"
        ctx.fillStyle = rgba(col, a)
        ctx.fillText(p.text, p.x, p.y + k * 26)
      }
    }
  }
}
