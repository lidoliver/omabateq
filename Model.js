.pragma library

// Pure helpers with no QML in them, so tests/model.test.js can run this file
// under plain node.
//
//   parseBattery   headsetcontrol JSON      → battery state
//   parseEqState   bin/eq-state output      → Easy Effects state
//   parsePreset    Easy Effects preset JSON → equalizer bands
//   response       equalizer bands          → frequency response curve

var MAX_BANDS = 32
var MAX_PRESETS = 24
// Preset names come from disk and end up in a file path and a command
// argument, so only plain names are accepted.
var PRESET_NAME = /^[A-Za-z0-9 _.+-]{1,80}$/

var EMPTY_BATTERY = { present: false, status: "unknown", level: -1, name: "" }
var EMPTY_EQ = { running: false, preset: "", bypassed: false, presets: [] }
var EMPTY_PRESET = { inputGain: 0, bands: [] }


// ---------- Headset battery ----------

// `headsetcontrol -b -o json` → { present, status, level, name }
//   present  a supported headset (or its receiver) is plugged in
//   status   "available" | "charging" | "off" | "unknown"
//   level    0..100, or -1 when the headset does not report one
//            (many only send a charging flag while on the cable)
function parseBattery(raw) {
  var data = parseJson(raw)
  if (!data || !data.devices || !data.devices.length) return EMPTY_BATTERY

  var device = data.devices[0] || {}
  var battery = device.battery || {}
  var statuses = {
    BATTERY_AVAILABLE: "available",
    BATTERY_CHARGING: "charging",
    BATTERY_UNAVAILABLE: "off"
  }
  var level = Number(battery.level)

  return {
    present: true,
    status: statuses[battery.status] || "unknown",
    level: isFinite(level) && level >= 0 && level <= 100 ? Math.round(level) : -1,
    name: String(device.device || device.product || "").slice(0, 60)
  }
}


// Whether two readings would show the same thing.
function sameBattery(a, b) {
  return !!a && !!b && a.present === b.present && a.status === b.status && a.level === b.level
}

// headsetcontrol reads some headsets' battery as several request/reply pairs
// without checking which reply belongs to which request. Anything else on the
// line in between shifts them, and the read comes back as e.g. "not charging,
// 1 %". The panel already keeps its own reads from overlapping (a lock, see
// Panel.qml); this catches the rest (seen on the HyperX Cloud Alpha Wireless,
// about 1 read in 150): a reading that would change what is shown is only
// taken once a second read agrees with it.
//
//   state    { shown, pending, attempts }
//   returns  the next state, plus `recheck: true` when another read is needed
var MAX_CONFIRM_ATTEMPTS = 3

function confirmBattery(state, reading) {
  if (sameBattery(reading, state.shown))
    return { shown: state.shown, pending: null, attempts: 0, recheck: false }
  if (sameBattery(reading, state.pending))
    return { shown: reading, pending: null, attempts: 0, recheck: false }
  if (state.attempts < MAX_CONFIRM_ATTEMPTS)
    return { shown: state.shown, pending: reading, attempts: state.attempts + 1, recheck: true }
  // Readings keep disagreeing: keep what is shown until the next regular poll.
  return { shown: state.shown, pending: null, attempts: 0, recheck: false }
}


// ---------- Easy Effects state ----------

// bin/eq-state output (key=value lines) → { running, preset, bypassed, presets }
function parseEqState(raw) {
  var state = { running: false, preset: "", bypassed: false, presets: [] }
  var lines = String(raw || "").split("\n").slice(0, 200)

  for (var i = 0; i < lines.length; i++) {
    var split = lines[i].indexOf("=")
    if (split < 0) continue
    var key = lines[i].slice(0, split)
    var value = lines[i].slice(split + 1).trim()

    if (key === "running") state.running = value === "1"
    else if (key === "bypass") state.bypassed = value === "1"
    else if (key === "preset" && isPresetName(value)) state.preset = value
    else if (key === "presetItem" && isPresetName(value) && state.presets.length < MAX_PRESETS)
      state.presets.push(value)
  }
  return state
}

function isPresetName(name) {
  name = String(name)
  return PRESET_NAME.test(name) && name.indexOf("..") < 0
}

// "HyperX-Cloud-Alpha" → "HyperX Cloud Alpha"
function prettyPreset(name) {
  return String(name || "").replace(/[-_]+/g, " ")
}


// ---------- Easy Effects preset file ----------

// ~/.local/share/easyeffects/output/<name>.json → { inputGain, bands }
// Reads the first equalizer in the preset. Only the left channel is read:
// AutoEQ presets keep both channels identical.
function parsePreset(raw) {
  var output = (parseJson(raw) || {}).output
  if (!output) return EMPTY_PRESET

  var eq = null
  for (var key in output) {
    if (key.indexOf("equalizer#") === 0) { eq = output[key]; break }
  }
  if (!eq || eq.bypass === true) return EMPTY_PRESET

  var bands = []
  var left = eq.left || {}
  var count = Math.min(Number(eq["num-bands"]) || 0, MAX_BANDS)
  for (var i = 0; i < count; i++) {
    var band = toBand(left["band" + i])
    if (band) bands.push(band)
  }

  var inputGain = Number(eq["input-gain"])
  return { inputGain: isFinite(inputGain) ? inputGain : 0, bands: bands }
}

// One preset band → { type, f, gain, q }, or null for bands that are muted,
// turned off, or a filter type the curve does not draw.
function toBand(b) {
  if (!b || b.mute === true) return null
  var type = String(b.type || "Bell")
  if (type !== "Bell" && type !== "Lo-shelf" && type !== "Hi-shelf") return null

  var f = Number(b.frequency), gain = Number(b.gain), q = Number(b.q)
  if (!(f > 0 && f < 24000) || !isFinite(gain) || !(q > 0)) return null
  return { type: type, f: f, gain: clamp(gain, -36, 36), q: q }
}


// ---------- Frequency response ----------

var SAMPLE_RATE = 48000

// Summed response of all bands at `points` log-spaced frequencies from
// 20 Hz to 20 kHz → [{ f, db }]. The preamp is left out on purpose: the
// curve shows the shape of the correction, and the panel prints the preamp.
function response(bands, points) {
  var filters = bands.map(function(band) { return biquad(band, SAMPLE_RATE) })
  var lo = Math.log(20), hi = Math.log(20000)
  var curve = []

  for (var p = 0; p < points; p++) {
    var f = Math.exp(lo + (hi - lo) * p / (points - 1))
    var db = 0
    for (var i = 0; i < filters.length; i++) db += magnitudeDb(filters[i], f, SAMPLE_RATE)
    curve.push({ f: f, db: db })
  }
  return curve
}

// Biquad coefficients [b0, b1, b2, a1, a2] (normalised by a0) from the
// RBJ Audio EQ Cookbook, the same formulas Equalizer APO and AutoEQ use.
function biquad(band, fs) {
  var A = Math.pow(10, band.gain / 40)
  var w0 = 2 * Math.PI * band.f / fs
  var cos = Math.cos(w0)
  var alpha = Math.sin(w0) / (2 * band.q)
  var c

  if (band.type === "Lo-shelf") {
    var ls = 2 * Math.sqrt(A) * alpha
    c = [A * ((A + 1) - (A - 1) * cos + ls),
         2 * A * ((A - 1) - (A + 1) * cos),
         A * ((A + 1) - (A - 1) * cos - ls),
         (A + 1) + (A - 1) * cos + ls,
         -2 * ((A - 1) + (A + 1) * cos),
         (A + 1) + (A - 1) * cos - ls]
  } else if (band.type === "Hi-shelf") {
    var hs = 2 * Math.sqrt(A) * alpha
    c = [A * ((A + 1) + (A - 1) * cos + hs),
         -2 * A * ((A - 1) + (A + 1) * cos),
         A * ((A + 1) + (A - 1) * cos - hs),
         (A + 1) - (A - 1) * cos + hs,
         2 * ((A - 1) - (A + 1) * cos),
         (A + 1) - (A - 1) * cos - hs]
  } else {
    c = [1 + alpha * A, -2 * cos, 1 - alpha * A,
         1 + alpha / A, -2 * cos, 1 - alpha / A]
  }

  var a0 = c[3]
  return [c[0] / a0, c[1] / a0, c[2] / a0, c[4] / a0, c[5] / a0]
}

// |H(e^jw)| in dB for one biquad at frequency f.
function magnitudeDb(c, f, fs) {
  var w = 2 * Math.PI * f / fs
  var cos1 = Math.cos(w), sin1 = Math.sin(w)
  var cos2 = Math.cos(2 * w), sin2 = Math.sin(2 * w)

  var numRe = c[0] + c[1] * cos1 + c[2] * cos2
  var numIm = -(c[1] * sin1 + c[2] * sin2)
  var denRe = 1 + c[3] * cos1 + c[4] * cos2
  var denIm = -(c[3] * sin1 + c[4] * sin2)

  var power = (numRe * numRe + numIm * numIm) / (denRe * denRe + denIm * denIm)
  return 10 * Math.log(power) / Math.LN10
}


// ---------- Small helpers ----------

function parseJson(raw) {
  try { return JSON.parse(String(raw || "")) } catch (e) { return null }
}

function clamp(value, lo, hi) {
  return Math.max(lo, Math.min(hi, value))
}
