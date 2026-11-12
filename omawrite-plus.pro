QT += core gui concurrent widgets printsupport qml quick quickcontrols2 quickdialogs2 dbus

CONFIG += c++17 release
TARGET = omawrite-plus
TEMPLATE = app

HEADERS += \
    src/backend.h \
    src/calc.h \
    src/cli.h \
    src/notes.h \
    src/markdownhighlighter.h \
    src/systemtheme.h

SOURCES += \
    src/main.cpp \
    src/backend.cpp \
    src/calc.cpp \
    src/cli.cpp \
    src/notes.cpp \
    src/markdownhighlighter.cpp \
    src/systemtheme.cpp

RESOURCES += src/resources.qrc
