.pragma library
// Shared by the lock and the settings panel.

// Average of unlocks that leaves out unusually slow ones (walked away mid-chord, got
// distracted): once there are at least 4, anything above Q3 + 1.5×IQR is skipped.
function typical(list) {
  if (!list || !list.length) return { secs: 0, cents: 0, kept: 0, total: 0 }
  let keep = list
  if (list.length >= 4) {
    const t = list.map(u => u.secs).sort((a, b) => a - b)
    const q = p => t[Math.floor(p * (t.length - 1))]
    const cutoff = q(0.75) + 1.5 * (q(0.75) - q(0.25))
    keep = list.filter(u => u.secs <= cutoff)
  }
  const avg = f => keep.reduce((a, u) => a + u[f], 0) / keep.length
  return { secs: avg("secs"), cents: avg("cents"), kept: keep.length, total: list.length }
}

// Unlocks recorded at one difficulty and voice type (scores are kept separately for each).
function forCombo(list, difficulty, voice) {
  return (list || []).filter(u => u.difficulty === difficulty && u.voice === voice)
}

function best(list) {
  return list && list.length ? Math.min.apply(null, list.map(u => u.secs)) : 0
}
