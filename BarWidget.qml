import QtQuick
import qs.Ui

// A bar button that opens the panel to arrange the displays.
BarWidget {
  id: root
  moduleName: "smartres1.display-layout"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰍺"
    onPressed: function(b) {
      if (root.bar) root.bar.run("omarchy-shell shell toggle smartres1.display-layout")
    }
  }
}
