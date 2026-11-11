import QtQuick
import QtQuick.Window
import CodexTop

// REQ-004 M0：透明、无边框、置顶、不抢焦点的悬浮球。点一下切换“3 个在跑／没有在跑”，按住拖动移动位置。
Window {
    id: orb
    width: canvas.layoutWidth
    height: 44
    visible: true
    color: "transparent"
    flags: Qt.Tool | Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint | Qt.WindowDoesNotAcceptFocus
    x: Screen.desktopAvailableWidth - width - 120
    y: 200

    Rectangle {
        anchors.fill: parent
        radius: Screen.devicePixelRatio >= 2 ? 12 : 12
        color: canvas.dark ? "#0B0D10" : "#F3F4F6"
    }

    LedCanvas {
        id: canvas
        objectName: "canvas"
        x: 0
        y: 0
        width: layoutWidth
        height: 44
        running: 3

        // 彗星：只在有任务在跑时转；停下后不再推动画面，整个窗口不重画。
        // 每秒 30 帧推进（彗星一格 0.05 秒，30 帧已经够顺），比跟着屏幕 60 帧刷省一半。帧率可用环境变量 CODEXTOP_FPS 试。
        Timer {
            interval: Math.round(1000 / fps)
            repeat: true
            running: canvas.running > 0
            property real fps: Number(Qt.application.arguments.find(a => a.startsWith("--fps="))?.slice(6) ?? 30)
            onTriggered: canvas.phase = (canvas.phase + interval / canvas.lapDuration) % 1
        }
    }

    MouseArea {
        anchors.fill: parent
        property point pressAt
        property bool dragging: false
        onPressed: (mouse) => { pressAt = Qt.point(mouse.x, mouse.y); dragging = false }
        onPositionChanged: (mouse) => {
            if (!dragging && Math.hypot(mouse.x - pressAt.x, mouse.y - pressAt.y) >= 4) {
                dragging = true
                orb.startSystemMove()
            }
        }
        onClicked: if (!dragging) canvas.running = canvas.running > 0 ? 0 : 3
    }
}
