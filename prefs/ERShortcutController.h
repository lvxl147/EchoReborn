#import <Preferences/PSViewController.h>

// Manager for the shortcuts EchoReborn has fetched from the Shortcuts store.
//
// Why this pane exists at all: the tweak reads the Shortcuts Core Data store
// from SpringBoard, and when that read fails there is no way to tell from
// Control Center whether the fault is "nothing was fetched" or "something was
// fetched but filtered out". Both look identical — an absent category. This
// pane renders the tweak's own snapshot of the fetch, so an empty list is a
// definite answer ("the tweak got nothing") and a populated list with an empty
// gallery is equally definite ("the data is there, the display side dropped
// it").
//
// It is also the switchboard: every fetched shortcut starts in 未显示控制项,
// and only the ones moved into 显示控制项 are offered in the「添加控制项」
// gallery. The choice is persisted as `ShortcutVisibleIdentifiers` in the
// shared preference domain, which is what Tweak.xm reads.
//
// Like ERCategoryOrderController this is deliberately NOT a PSListController
// and is NOT reached through a PSLinkCell: both of those routes go through the
// Preferences framework's cross-bundle class lookup, which is what produced
// "There was an error loading the preference bundle" and blank panes in the
// past. It is pushed directly by ERRootListController and owns its own table.
@interface ERShortcutController : PSViewController
@end
