#import <Foundation/Foundation.h>

// Scans the user's Shortcuts store from INSIDE the Preferences process, which —
// unlike SpringBoard — has sandbox access to /var/mobile/Library/Shortcuts/
// Shortcuts.sqlite. This is the exact trick EvoCenter16 uses: its Settings
// bundle (injected into com.apple.Preferences) opens the store directly with
// libsqlite3, while its runtime dylib (in SpringBoard) never touches the file.
//
// We mirror that split:
//   * this scanner runs in Preferences (via the EchoRebornPrefs bundle) and reads
//     the store, then publishes the resulting catalog to the shared EchoReborn
//     preference domain;
//   * Tweak.xm (SpringBoard) only *consumes* that catalog via
//     ERPreferenceArray(@"ShortcutCatalog") and never opens the sandboxed
//     store itself.
//
// The result: shortcuts that SpringBoard could never read become available,
// because the read happens where the OS actually permits it.
void ERShortcutScanAndPublish(void);
