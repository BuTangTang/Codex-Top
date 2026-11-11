cmake_minimum_required(VERSION 3.21)
project(CodexTopQt VERSION 0.1.0 LANGUAGES CXX)

# REQ-004：Codex Top 的 Qt 版。数据层按模块拆成几个静态库，各自只依赖 QtCore（和需要的 Sql），
# 每个模块的测试单独编，这样一个模块没写完不会把别的模块的编译和测试拖坏。
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 6.5 REQUIRED COMPONENTS Core Gui Quick Sql Test)
qt_standard_project_setup(REQUIRES 6.5)
enable_testing()

# 数据层模块：目录名即模块名，目录里的 .cpp 全部编进去。
function(codextop_core_module name)
    file(GLOB sources CONFIGURE_DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/core/${name}/*.cpp ${CMAKE_CURRENT_SOURCE_DIR}/core/${name}/*.h)
    add_library(codextop_${name} STATIC ${sources})
    target_include_directories(codextop_${name} PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/core)
    target_link_libraries(codextop_${name} PUBLIC Qt6::Core ${ARGN})
endfunction()

codextop_core_module(models)
codextop_core_module(led)
codextop_core_module(codex codextop_models Qt6::Sql)
codextop_core_module(claude codextop_models)
codextop_core_module(policy codextop_models)
codextop_core_module(usage codextop_models)

# 压缩记录要用的 zstd：直接复用原生版带着的源码（只要解压部分）。
file(GLOB zstd_sources CONFIGURE_DEPENDS
    ${CMAKE_CURRENT_SOURCE_DIR}/../Sources/CZstd/vendor/lib/common/*.c
    ${CMAKE_CURRENT_SOURCE_DIR}/../Sources/CZstd/vendor/lib/decompress/*.c)
enable_language(C)
add_library(codextop_zstd STATIC ${zstd_sources})
target_include_directories(codextop_zstd PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/../Sources/CZstd/vendor/lib)
target_compile_definitions(codextop_zstd PRIVATE ZSTD_DISABLE_ASM)
target_link_libraries(codextop_codex PUBLIC codextop_zstd)

# 测试：tests/<模块>/test_*.cpp 每个文件一个 Qt Test 程序，链接同名模块。
file(GLOB test_dirs LIST_DIRECTORIES true ${CMAKE_CURRENT_SOURCE_DIR}/tests/*)
foreach(dir ${test_dirs})
    if(IS_DIRECTORY ${dir})
        get_filename_component(module ${dir} NAME)
        file(GLOB tests CONFIGURE_DEPENDS ${dir}/test_*.cpp)
        foreach(test ${tests})
            get_filename_component(test_name ${test} NAME_WE)
            add_executable(${module}_${test_name} ${test})
            target_link_libraries(${module}_${test_name} PRIVATE codextop_${module} Qt6::Test)
            add_test(NAME ${module}_${test_name} COMMAND ${module}_${test_name})
        endforeach()
    endif()
endforeach()

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
target_link_libraries(CodexTopQt PRIVATE codextop_led codextop_models Qt6::Quick)
