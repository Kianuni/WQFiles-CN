# Worse Query Files

**WQ Files** is a file browser, app data manager and cache cleaner for iOS 27.
"WQ" stands for worse_query, the sandbox technique it is built on. It reaches
other apps' and system containers with no jailbreak and no kernel exploit.
Built and tested on iOS 27.0.1.

## What it opens

- **App Data**: every app's data container (`Containers/Data/Application`),
  shown with the app's name and icon instead of a UUID.
- **App Groups**: shared group containers.
- **Extension Data** and **Internal Daemons**.
- **System Data**: `/var/containers/Data/System` (listing only; its contents
  are owned by root).
- **System Groups**: the parent cannot be listed on 27.0.1, so known container
  names are tried one by one; tap **+** to try another name. Covers the
  MobileGestalt cache and the configuration-profiles (Supervision) folder.
- **Go to Path** for any absolute path.

The container parents give no access token on 27.0.1, so their contents are
found by asking the kernel for the path of each inode number (`fsgetpath`),
the way KAMUI does it.

## Tools

- **Apps**: every app with its data size. Back up an app's **Documents and
  Library**, restore the latest backup, clear its data (Documents, Library,
  and tmp), open its folder, or share a backup as a ZIP over AirDrop, Files,
  Mail and so on. `tmp` is intentionally ephemeral: clear removes it, but app
  backups do not include it and restore leaves the current `tmp` untouched.
- **Cache Cleaner**: cache and temp size per app, with search, Select All /
  None / Large Caches (50 MB+) and crash logs. Long-press an app to jump to its
  Caches, tmp or data folder.
- **Files**: browse, read and share files; each opens in the fitting tool,
  and **Open As** switches between them. Saving writes back in place (same
  inode, owner and attributes). Create folders, import files, rename and
  delete. Long-press a folder to share it as a ZIP.
  - **Plist editor**: browse dictionaries and arrays, edit values by type
    (switches for booleans, numbers, text, dates, data as hex), add, delete,
    rename and reorder. Saves in the file's own format (binary or XML).
  - **Hex viewer and editor**: any file size (read in pages), go to offset,
    find hex bytes or text, overwrite bytes in place. Changed bytes are
    highlighted until saved; the file size never changes.
  - **Text and images**: text is editable, images render, plists can also be
    edited as XML text.
- **Log**: file writes, backups, deletions, restores and errors the app handled, plus the App Group it received.

App names come from LaunchServices' own database, read from lsd's container
(the LaunchServices API itself refuses this app on 27.x). Apple services that
only have localized names use a built-in table. Services without an icon get a
symbol tile.

## Safety

Before a regular file is overwritten or deleted, its contents are copied to
**Backups** inside the app (also reachable in the Files app). Long-press a
backup to restore it to its original location. In the file browser only empty
folders can be deleted; symbolic links are removed as links. Clearing an app's
data and cleaning caches delete without a file-by-file backup; Apps offers to
back up Documents and Library first, while `tmp` is discarded and cannot be
restored. Close the target app before backup, restore, or clear. App copies are
verified by a source-stability digest, a destination-shape digest and stored
part content hashes (rechecked before restore and rollback), and purge
postconditions are rechecked, but the operations are not filesystem snapshots
if the target app keeps running. Target data is changed only in response to
explicit actions; interrupted safety transactions may be recovered on startup.

File saves retain the original inode and verify descriptor identity and saved
contents. Locks are advisory: another app that ignores them can still write
concurrently, and in-place writes are not crash-atomic. Close the target app and
keep the durable backups. Recovery fails closed when required safety material is
missing. Generic overwrite/delete operations on backup-storage files are refused
to avoid recursively backing up backups; valid backups can still be restored.
App backups live in **App Backups** (also in the Files app); old ones are never
pruned automatically. Tap **Select** in **Backups** or **App Backups** to
choose one or more complete backup folders and delete them together; a single
folder can still be removed with **Delete Backup**. Automatic pruning is
intentionally left out so a safety copy is never discarded without a user
decision.

Editing another app's or the system's files can break things. Keep the backups
and only change what you understand.

## Troubleshooting

- **Apps list is empty**: the Apps screen depends on a full `fsgetpath` scan of
  the data volume. A missing/denied container parent, an unavailable inode
  probe, or an exhausted scan bound is logged as `enumerate: …` and
  `app scan: …` in **Log**. The current build only treats a *missing* parent as
  failure; a denied parent and a completion-probe miss still return the
  scanned subset, so refresh instead of assuming there are no apps.
- **`NO TOKEN`**: the container path was visible but `wq_grant` could not
  obtain a sandbox token. Common causes are a signer that dropped the App
  Group, an app-group cache-swap failure, or a container the app-group query
  refuses. See the `grant failed`/`enumerate` lines in **Log**.
- **`(no label)`**: a token was obtained, but the container identifier
  (`com.apple.containermanager.identifier` xattr or the container metadata
  plist) could not be read. System/daemon containers often have no identifier;
  for app containers this usually means the xattr is unavailable or the
  metadata plist is root-only. The folder remains browsable, but apps with no
  identifier cannot be backed up or cleared until identity is available.

## Install with AltStore or SideStore

Add this source to get WQ Files and its updates:

```
https://raw.githubusercontent.com/kolbicz/WQFiles/main/source.json
```

Or download `WQFiles.ipa` from [Releases](https://github.com/kolbicz/WQFiles/releases) and sign it yourself.

## Build and signing

`./build.sh` compiles an arm64 binary and ad-hoc signs it with an App Group
entitlement (`group.cz.kolbi.wqfiles`). The technique needs an App Group, so
re-sign with a tool that keeps one; the app uses whichever group it actually
receives and shows it at the top of the **Log**. If it reports "No App Group",
the signer dropped it.

The deployment minimum is iOS 27.0. Builds first run the host regression suite,
then stage and validate the archive, metadata, signature and App Group before
replacing `WQFiles.ipa` in the project directory. Set `WQ_SKIP_PREFLIGHT=1` for
fixture builds that do not have a test tree. For a separate output, set
`WQFILES_FINAL_IPA` to an absolute path in an existing directory. The source
updater validates the IPA's embedded metadata before atomically replacing
`source.json`; its version/build arguments must match the artifact, and an
existing release description is preserved when no new notes are supplied.

## Regression tests

Run `./tests/run_all_tests.sh` on macOS with Xcode and Python 3. It runs twelve
portable Foundation fixture executables, the Python release fixtures, static
browser checks, and strict iOS arm64 compilation/linkage. Logs and generated
files stay under `.work/tests/`; the existing IPA is not replaced. With only
Command Line Tools installed, set `WQ_SKIP_IOS_CHECK=1` to run the host tests.
Set `WQ_ASAN=1` to compile the host fixtures with AddressSanitizer.

These tests use disposable files and entitlement/access doubles. They do not
issue sandbox tokens or mutate installed app containers. Real iOS signing,
token issuance, navigation/lifecycle timing, power-loss behavior and app-side
concurrent writes still require supported-device validation.

## Credit and license

- Sandbox technique: [worse_query](https://github.com/forcequitOS/worse_query)
  by Taj C (forcequit), GPL-3.0-or-later. This app reimplements it.
- Container enumeration with `fsgetpath`: from
  [KAMUI](https://github.com/murk-sus/kamui-escape) by murk-sus.

WQ Files is GPL-3.0-or-later (see `LICENSE`).
