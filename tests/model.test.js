// Run with: node tests/model.test.js
// Loads Model.js outside QML (minus its `.pragma library` line) and checks
// the parsers and the response math.

const fs = require("fs")
const path = require("path")
const assert = require("assert")

const source = fs.readFileSync(path.join(__dirname, "..", "Model.js"), "utf8")
  .replace(/^\.pragma library\s*$/m, "")
const Model = new Function(source +
  "; return { parseBattery, confirmBattery, mouseBattery, parseSolaarMouse, parseEqState, parsePreset, isPresetName, prettyPreset, response }")()

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

test("battery: a one-off bogus reading is never shown", () => {
  const charging = Model.parseBattery(device({ status: "BATTERY_CHARGING", level: -1 }))
  const bogus = Model.parseBattery(device({ status: "BATTERY_AVAILABLE", level: 1 }))
  let s = { shown: charging, pending: null, attempts: 0 }
  s = Model.confirmBattery(s, bogus)        // differs: hold it, read again
  assert.deepStrictEqual([s.shown, s.recheck], [charging, true])
  s = Model.confirmBattery(s, charging)     // the re-read disagrees with it: dropped
  assert.deepStrictEqual([s.shown, s.pending, s.recheck], [charging, null, false])
})

test("battery: a real change is shown once a second read agrees", () => {
  const charging = Model.parseBattery(device({ status: "BATTERY_CHARGING", level: -1 }))
  const unplugged = Model.parseBattery(device({ status: "BATTERY_AVAILABLE", level: 93 }))
  let s = Model.confirmBattery({ shown: charging, pending: null, attempts: 0 }, unplugged)
  assert.strictEqual(s.shown, charging)
  s = Model.confirmBattery(s, unplugged)
  assert.deepStrictEqual([s.shown, s.recheck], [unplugged, false])
})

test("battery: readings that never agree stop rechecking after 3 tries", () => {
  // As in the panel: a poll, then re-reads only while `recheck` asks for one.
  const level = n => Model.parseBattery(device({ status: "BATTERY_AVAILABLE", level: n }))
  let s = Model.confirmBattery({ shown: level(50), pending: null, attempts: 0 }, level(1))
  let reads = 1
  while (s.recheck && reads < 20) s = Model.confirmBattery(s, level(++reads))
  assert.strictEqual(reads, 4)              // the poll + 3 re-reads
  assert.deepStrictEqual([s.shown.level, s.pending], [50, null])
})

test("mouse: UPower device → level, charging, name", () => {
  const states = { charging: 1, fullyCharged: 4, unknown: 0 }
  assert.strictEqual(Model.mouseBattery({ isPresent: true, percentage: 0.7, state: 0 }, states).present, false)
  assert.deepStrictEqual(Model.mouseBattery({ isPresent: true, percentage: 0.734, state: 2, model: "PRO X2" }, states),
    { present: true, level: 73, charging: false, name: "PRO X2" })
  assert.strictEqual(Model.mouseBattery({ isPresent: true, percentage: 1, state: 4 }, states).charging, true)
  assert.strictEqual(Model.mouseBattery({ isPresent: false, percentage: 0.5 }, states).present, false)
  assert.strictEqual(Model.mouseBattery(null, states).present, false)
})

// Trimmed `solaar show` with the mouse on its cable: the receiver (whose
// paired mouse is "not found" while wired) comes first, then the mouse.
const SOLAAR_WIRED = `solaar version 1.1.20
Lightspeed Receiver
  Device path  : /dev/hidraw6
  USB id       : 046d:C54D
  Has 1 paired device(s) out of a maximum of 2.
  1: Device not found
PRO X2 SUPERSTRIKE
     Device path  : /dev/hidraw18
     USB id       : 046d:C0A8
     Codename     : PRO X2 SUPERSTRIKE
     Kind         : mouse
     Protocol     : HID++ 4.2
     Supports 36 HID++ 2.0 features:
         6: UNIFIED BATTERY        {1004} V5
            Battery: 75%, BatteryStatus.RECHARGING.
         7: XY STATS               {2250} V1
`

test("solaar: wired mouse charging", () => {
  assert.deepStrictEqual(Model.parseSolaarMouse(SOLAAR_WIRED),
    { present: true, level: 75, charging: true, name: "PRO X2 SUPERSTRIKE" })
})

test("solaar: the mouse's own name wins over the receiver's codename", () => {
  const viaReceiver = SOLAAR_WIRED
    .replace("Codename     : PRO X2 SUPERSTRIKE", "Codename     : X2 SUPERSTRIKE")
    .replace("     Supports 36", "         3: DEVICE NAME {0005} V5\n            Name: PRO X2 SUPERSTRIKE\n     Supports 36")
    .replace("RECHARGING", "DISCHARGING")
  assert.strictEqual(Model.parseSolaarMouse(viaReceiver).name, "PRO X2 SUPERSTRIKE")
  // Without a Name line, the codename.
  assert.strictEqual(Model.parseSolaarMouse(SOLAAR_WIRED.replace("Codename     : PRO X2", "Codename     : X2")).name, "X2 SUPERSTRIKE")
})

test("solaar: discharging, keyboards skipped, nothing found", () => {
  const discharging = SOLAAR_WIRED.replace("RECHARGING", "DISCHARGING")
  assert.strictEqual(Model.parseSolaarMouse(discharging).charging, false)
  const keyboardFirst = "Codename : G915\n Kind : keyboard\n Battery: 40%, BatteryStatus.DISCHARGING.\n" + SOLAAR_WIRED
  assert.strictEqual(Model.parseSolaarMouse(keyboardFirst).level, 75)
  assert.strictEqual(Model.parseSolaarMouse("Lightspeed Receiver\n  1: Device not found\n").present, false)
  assert.strictEqual(Model.parseSolaarMouse("").present, false)
})

test("solaar: the live reading, if there is one", () => {
  const live = path.join(process.env.XDG_RUNTIME_DIR || "/tmp", "omabateq/solaar.txt")
  if (!fs.existsSync(live)) return
  const m = Model.parseSolaarMouse(fs.readFileSync(live, "utf8"))
  console.log("       live: " + JSON.stringify(m))
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
