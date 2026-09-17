#import <Preferences/PSViewController.h>

// Editor for the Control Center gallery's top-level groups.
//
// Deliberately NOT a PSListController, and deliberately NOT reached through a
// separate PSLinkCell. Both of those produced a page that failed to load:
//
//   * PSLinkCell + bundle + detail resolves the controller class through the
//     Preferences framework's cross-bundle lookup. That lookup is what emitted
//     "There was an error loading the preference bundle" (with the icon key) and
//     then a completely blank pane (without the bundle key). Four releases went
//     into tuning that lookup; the reliable move is to stop depending on it.
//   * PSListController builds its rows from -specifiers, which the framework
//     may call before -viewDidLoad, so a controller whose state is not seeded
//     yet renders a group header and nothing else.
//
// This controller is pushed programmatically by ERRootListController (which
// loads from the same Root.plist that already works) and owns a plain
// UITableView it populates itself. There is no plist loading, no specifier
// cache, and no bundle lookup left to go wrong.
@interface ERCategoryOrderController : PSViewController
@end
