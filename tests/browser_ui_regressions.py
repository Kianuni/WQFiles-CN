#!/usr/bin/env python3
"""Static regression checks for UIKit-only browser and sharing paths."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
main = (ROOT / "main.m").read_text()
sharing = (ROOT / "WQSharing.m").read_text()
ui = (ROOT / "WQUI.m").read_text()
header = (ROOT / "WQSharing.h").read_text()


def require(text: str, needle: str, label: str) -> None:
    if needle not in text:
        raise AssertionError(f"missing {label}: {needle}")


def forbid(text: str, needle: str, label: str) -> None:
    if needle in text:
        raise AssertionError(f"stale {label}: {needle}")


require(main, "BOOL _scanNeedsRefresh;", "scan refresh state")
require(main, "if (_scanNeedsRefresh) [self reload];", "restart after canceled scan")
require(main, "self->_scanStatus = nil;", "canceled scan status cleanup")
require(main, "self->_scanInFlight = NO;", "scan completion state cleanup")
require(main, "self->_error = (names || childPaths != nil) ? nil : error;", "empty enumeration success")
require(main, "item.isRegular = S_ISREG(st.st_mode);", "regular-file metadata")
require(main, "Only regular files can be viewed.", "special-file view refusal")
require(main, "wq_backup_original_path(item.path)", "typed backup path derivation")
require(main, "initWithPath:wq_backup_root() title:@\"Backups\"", "Backups root navigation")
require(main, "if (!_version)", "nil editor version refusal")
forbid(main, "childPaths.count) ? nil : error", "count-based enumeration success check")
forbid(main, "wq_backup_root().stringByDeletingLastPathComponent title:@\"Backups\"", "parent-path Backups navigation")

require(header, "void wq_share_cancel(UIViewController *host);", "share cancellation API")
require(sharing, "__weak UIViewController *weakHost", "weak sharing host")
require(sharing, "preparation.cancelled", "abandoned folder preparation")
require(sharing, "wq_remove_export(outDir)", "abandoned export cleanup")
require(sharing, "Only regular files can be shared.", "special-file share refusal")
require(ui, "host.presentedViewController && !host.presentedViewController.isBeingDismissed", "validated alert host")

print("browser UI regression checks: PASS")
