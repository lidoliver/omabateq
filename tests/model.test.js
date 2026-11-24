// Run with: node tests/model.test.js
// Loads Model.js outside QML (minus its `.pragma library` line) and checks
// the parsers and the response math.

const fs = require("fs")
const path = require("path")
const assert = require("assert")

const source = fs.readFileSync(path.join(__dirname, "..", "Model.js"), "utf8")
  .replace(/^\.pragma library\s*$/m, "")
const Model = new Function(source +
  "; return { parseBattery, parseEqState, parsePreset, isPresetName, prettyPreset, response }")()

function test(name, fn) {
  try { fn(); console.log("  ok  " + name) }
  catch (e) { console.log("  FAIL " + name + "\n       " + e.message); process.exitCode = 1 }
}

// Value of a response curve at the point nearest to frequency f.
function dbAt(curve, f) {
  return curve.reduce((best, p) =>
    Math.abs(Math.log(p.f / f)) < Math.abs(Math.log(best.f / f)) ? p : best).db
}

const device = battery => JSON.stringify({ devices: [{ device: "Test Headset", battery }] })

test("battery: level while connected", () => {
  const b = Model.parseBattery(device({ status: "BATTERY_AVAILABLE", level: 87 }))
  assert.deepStrictEqual(b, { present: true, status: "available", level: 87, name: "Test Headset" })
})

test("battery: charging without a level", () => {
  const b = Model.parseBattery(device({ status: "BATTERY_CHARGING", level: -1 }))
  assert.deepStrictEqual([b.status, b.level], ["charging", -1])
})

test("battery: headset switched off", () => {
  assert.strictEqual(Model.parseBattery(device({ status: "BATTERY_UNAVAILABLE" })).status, "off")
})

test("battery: no device, bad JSON, out-of-range level", () => {
  assert.strictEqual(Model.parseBattery('{"device_count":0,"devices":[]}').present, false)
  assert.strictEqual(Model.parseBattery("not json").present, false)
  assert.strictEqual(Model.parseBattery(device({ status: "BATTERY_AVAILABLE", level: 900 })).level, -1)
})

test("eq state: parses and drops unsafe preset names", () => {
  const s = Model.parseEqState([
    "running=1", "preset=HyperX-Cloud-Alpha", "bypass=2",
    "presetItem=HyperX-Cloud-Alpha", "presetItem=Flat",
    "presetItem=../escape", "presetItem=<img src=x>"
  ].join("\n"))
  assert.deepStrictEqual(s, { running: true, preset: "HyperX-Cloud-Alpha", bypassed: false, presets: ["HyperX-Cloud-Alpha", "Flat"] })
  assert.strictEqual(Model.parseEqState("running=1\nbypass=1").bypassed, true)
  assert.strictEqual(Model.parseEqState("running=0").running, false)
})

test("preset names", () => {
  assert.strictEqual(Model.isPresetName("Flat"), true)
  assert.strictEqual(Model.isPresetName("../x"), false)
  assert.strictEqual(Model.prettyPreset("HyperX-Cloud-Alpha"), "HyperX Cloud Alpha")
})

test("response: a +6 dB bell at 1 kHz peaks at +6 and is flat far away", () => {
  const preset = { output: { "equalizer#0": { "input-gain": -6, "num-bands": 1,
    left: { band0: { type: "Bell", frequency: 1000, gain: 6, q: 1 } } } } }
  const p = Model.parsePreset(JSON.stringify(preset))
  assert.strictEqual(p.inputGain, -6)
  const curve = Model.response(p.bands, 400)
  assert(Math.abs(dbAt(curve, 1000) - 6) < 0.15)
  assert(Math.abs(dbAt(curve, 20)) < 0.1 && Math.abs(dbAt(curve, 20000)) < 0.2)
})

test("response: shelves reach their gain at the far end only", () => {
  const low = Model.response([{ type: "Lo-shelf", f: 105, gain: -4.6, q: 0.7 }], 400)
  assert(Math.abs(dbAt(low, 20) + 4.6) < 0.3 && Math.abs(dbAt(low, 5000)) < 0.1)
  const high = Model.response([{ type: "Hi-shelf", f: 10000, gain: -2.2, q: 0.7 }], 400)
  assert(Math.abs(dbAt(high, 20)) < 0.05 && dbAt(high, 20000) < -1.5)
})

test("preset: muted and unsupported bands are skipped", () => {
  const preset = { output: { "equalizer#0": { "num-bands": 3, left: {
    band0: { type: "Bell", frequency: 100, gain: 3, q: 1, mute: true },
    band1: { type: "Notch", frequency: 100, gain: 3, q: 1 },
    band2: { type: "Bell", frequency: 100, gain: 3, q: 1 } } } } }
  assert.strictEqual(Model.parsePreset(JSON.stringify(preset)).bands.length, 1)
})
