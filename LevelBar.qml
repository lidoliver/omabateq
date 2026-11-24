import QtQuick
import qs.Commons

// A thin rounded track with a fill, used for the battery level and the
// output meter. `pulsing` breathes the fill, e.g. while charging.
Item {
  id: root

  property real value: 0            // 0..1
  property color foreground: "white"
  property color fillColor: foreground
  property real fillOpacity: 1
  property bool pulsing: false
  property int fillDuration: 320    // ms for the fill to follow `value`

  implicitHeight: Style.space(8)

  Rectangle {
    id: track
    anchors.fill: parent
    radius: height / 2
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
  }

  Rectangle {
    id: fill
    height: track.height
    radius: track.radius
    color: root.fillColor
    opacity: root.fillOpacity
    width: root.value > 0 ? Math.max(track.height, track.width * Math.min(1, root.value)) : 0

    Behavior on width { NumberAnimation { duration: Style.duration(root.fillDuration); easing.type: Easing.OutCubic } }
    Behavior on color { ColorAnimation { duration: Style.duration(200) } }

    SequentialAnimation on opacity {
      running: root.pulsing && !Style.reduceMotion
      loops: Animation.Infinite
      alwaysRunToEnd: true
      NumberAnimation { from: root.fillOpacity; to: root.fillOpacity * 0.45; duration: Style.duration(950); easing.type: Easing.InOutSine }
      NumberAnimation { from: root.fillOpacity * 0.45; to: root.fillOpacity; duration: Style.duration(950); easing.type: Easing.InOutSine }
    }
  }
}
