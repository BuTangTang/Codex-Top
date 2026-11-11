cmake_minimum_required(VERSION 3.21)
project(CodexTopQt VERSION 0.1.0 LANGUAGES CXX)

# REQ-004 M0 技术验证：只做悬浮球（点阵画布 + 彗星动画 + 不抢焦点的透明置顶窗口）。
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 6.5 REQUIRED COMPONENTS Core Gui Quick)
qt_standard_project_setup(REQUIRES 6.5)

# 数据层：只依赖 QtCore。M0 只有悬浮球排版。
add_library(codextop_core STATIC
    core/led_layout.h core/led_layout.cpp)
target_include_directories(codextop_core PUBLIC core)
target_link_libraries(codextop_core PUBLIC Qt6::Core)

qt_add_executable(CodexTopQt MACOSX_BUNDLE WIN32
    app/main.cpp
    app/led_canvas.h app/led_canvas.cpp
    platform/platform.h)
if(APPLE)
    target_sources(CodexTopQt PRIVATE platform/mac/platform_mac.mm)
    target_link_libraries(CodexTopQt PRIVATE "-framework AppKit")
    set_target_properties(CodexTopQt PROPERTIES
        MACOSX_BUNDLE_GUI_IDENTIFIER dev.butang.codextop.qt
        MACOSX_BUNDLE_BUNDLE_NAME "Codex Top Qt")
elseif(WIN32)
    target_sources(CodexTopQt PRIVATE platform/win/platform_win.cpp)
endif()

qt_add_qml_module(CodexTopQt
    URI CodexTop
    VERSION 1.0
    QML_FILES qml/Main.qml
)
target_include_directories(CodexTopQt PRIVATE app)
target_link_libraries(CodexTopQt PRIVATE codextop_core Qt6::Quick)
