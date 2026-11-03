# Aggregate for the standalone Control Center bundles EchoReborn ships.
#
#  * the seven 连接 (Connectivity) tiles, one bundle per tile; see
#    ERConnectivityModule.h for why each needs its own principal class.
#  * the 32 快捷指令 (Shortcut) slots, one bundle per slot; see
#    ERShortcutModule.h. They are REAL Control Center modules, which is
#    what makes Control Center itself place, size, page and draw them, instead
#    of EchoReborn reproducing Control Center's layout arithmetic for a tile it
#    drew itself.
#
# common.mk has to be loaded before aggregate.mk: this Makefile defines no
# instance of its own, and without it Theos runs `rm -rf ""` during
# `make clean` and the build dies before compiling anything.
include $(THEOS)/makefiles/common.mk

SUBPROJECTS += shortcut1 shortcut2 shortcut3 shortcut4 shortcut5 shortcut6 shortcut7 shortcut8 shortcut9 shortcut10 shortcut11 shortcut12 shortcut13 shortcut14 shortcut15 shortcut16 shortcut17 shortcut18 shortcut19 shortcut20 shortcut21 shortcut22 shortcut23 shortcut24 shortcut25 shortcut26 shortcut27 shortcut28 shortcut29 shortcut30 shortcut31 shortcut32

include $(THEOS_MAKE_PATH)/aggregate.mk
