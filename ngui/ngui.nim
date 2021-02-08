import std/os

import NimQml
import mainmodel

# Build DOtherSide first! `cd vendor/DOtherSide; mkdir build; cd build; cmake ..; make`
{.passL: "-L " & currentSourcePath.parentDir  & "/../vendor/DOtherSide/build/lib/".}
{.passL: "-lDOtherSideStatic".}
{.passl: gorge("pkg-config --libs --static Qt5Core Qt5Qml Qt5Gui Qt5Quick Qt5QuickControls2 Qt5Widgets").}
{.passl: "-Wl,-as-needed".}

proc mainProc() =
  let app = newQApplication()
  defer: app.delete

  let main = newMainModel(app)
  defer: main.delete

  let engine = newQQmlApplicationEngine()
  defer: engine.delete

  let mainVariant = newQVariant(main)
  defer: mainVariant.delete

  engine.setRootContextProperty("main", mainVariant)

  engine.load("ui/main.qml")
  app.exec()

when isMainModule:
  mainProc()
  GC_fullcollect()
