import QtQuick
import qs.Commons

// Frequency response plot: 20 Hz–20 kHz on a log axis, ±12 dB.
// `points` comes from Model.response(); an empty list draws the grid only.
Canvas {
  id: root

  property var points: []
  property bool dimmed: false       // bypassed: draw the curve in grey
  property color foreground: "white"
  property color accent: "white"
  property string fontFamily: Style.font.family

  readonly property real rangeDb: 12

  antialiasing: true

  onPointsChanged: requestPaint()
  onDimmedChanged: requestPaint()
  onForegroundChanged: requestPaint()
  onAccentChanged: requestPaint()
  onWidthChanged: requestPaint()
  onHeightChanged: requestPaint()

  function xFor(f) {
    var lo = Math.log(20), hi = Math.log(20000)
    return (Math.log(f) - lo) / (hi - lo) * width
  }

  function yFor(db) {
    var clamped = Math.max(-rangeDb, Math.min(rangeDb, db))
    return height / 2 - clamped / rangeDb * (height / 2 - 2)
  }

  function rgba(c, alpha) {
    return "rgba(" + Math.round(c.r * 255) + "," + Math.round(c.g * 255) + "," + Math.round(c.b * 255) + "," + alpha + ")"
  }

  function line(ctx, x1, y1, x2, y2) {
    ctx.beginPath(); ctx.moveTo(x1, y1); ctx.lineTo(x2, y2); ctx.stroke()
  }

  onPaint: {
    var ctx = getContext("2d")
    ctx.reset()
    drawGrid(ctx)
    if (points.length > 0) drawCurve(ctx)
  }

  function drawGrid(ctx) {
    ctx.lineWidth = 1

    // Faint lines at the usual frequencies and at ±6 dB, a stronger 0 dB.
    ctx.strokeStyle = rgba(foreground, 0.08)
    var freqs = [50, 100, 200, 500, 1000, 2000, 5000, 10000]
    for (var i = 0; i < freqs.length; i++) {
      var x = Math.round(xFor(freqs[i])) + 0.5
      line(ctx, x, 0, x, height)
    }
    line(ctx, 0, Math.round(yFor(6)) + 0.5, width, Math.round(yFor(6)) + 0.5)
    line(ctx, 0, Math.round(yFor(-6)) + 0.5, width, Math.round(yFor(-6)) + 0.5)

    ctx.strokeStyle = rgba(foreground, 0.2)
    line(ctx, 0, Math.round(yFor(0)) + 0.5, width, Math.round(yFor(0)) + 0.5)

    ctx.fillStyle = rgba(foreground, 0.4)
    ctx.font = Style.font.caption + "px '" + fontFamily + "'"
    ctx.fillText("100", xFor(100) + 3, height - 3)
    ctx.fillText("1k", xFor(1000) + 3, height - 3)
    ctx.fillText("10k", xFor(10000) + 3, height - 3)
    ctx.fillText("+" + rangeDb, 3, Style.font.caption + 1)
    ctx.fillText("-" + rangeDb, 3, height - 3)
  }

  function drawCurve(ctx) {
    // Shaded area between the curve and 0 dB.
    ctx.beginPath()
    ctx.moveTo(0, yFor(0))
    for (var i = 0; i < points.length; i++) ctx.lineTo(xFor(points[i].f), yFor(points[i].db))
    ctx.lineTo(width, yFor(0))
    ctx.closePath()
    ctx.fillStyle = dimmed ? rgba(foreground, 0.05) : rgba(accent, 0.16)
    ctx.fill()

    // The curve itself.
    ctx.beginPath()
    for (var j = 0; j < points.length; j++) {
      var x = xFor(points[j].f), y = yFor(points[j].db)
      if (j === 0) ctx.moveTo(x, y)
      else ctx.lineTo(x, y)
    }
    ctx.lineWidth = 2
    ctx.lineJoin = "round"
    ctx.strokeStyle = dimmed ? rgba(foreground, 0.35) : rgba(accent, 1)
    ctx.stroke()
  }
}
