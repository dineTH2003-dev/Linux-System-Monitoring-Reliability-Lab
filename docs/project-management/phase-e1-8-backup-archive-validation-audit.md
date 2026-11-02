# Phase E.1.8 — Archive Member Type and Configuration Content Validation Audit Report

**Date:** 2026-10-29  
**Role:** Senior Site Reliability Engineer / Disaster Recovery & Linux Storage Engineer  
**Repository:** `/home/dineth/dev/Linux-System-Monitoring-Reliability-Lab`  
**Target File Modified:** `deployment/backup.sh` (exclusive authorized file modification)  
**Report Document:** `docs/project-management/phase-e1-8-backup-archive-validation-audit.md`  
**Final Review Verdict:** `PATCH READY FOR INDEPENDENT REVIEW`

---

## 1. Executive Summary & Objective

Phase E.1.8 resolves the remaining independent-review findings in [`deployment/backup.sh`](file:///home/dineth/dev/Linux-System-Monitoring-Reliability-Lab/deployment/backup.sh). This remediation focuses on archive member type safety, structural configuration directory validation, robust table-of-contents parsing under unusual filenames, and deterministic validation of human-readable archive sizes.

### Primary Corrections Implemented
1. **Structural Configuration Directory Validation:** Upgraded candidate archive inspection to distinguish genuine directory entries and directory descendants from regular files or special entries. A regular file, symlink, or hardlink named `configs/<required-directory>` is strictly rejected. Every required configuration directory must be represented by an actual directory structure in the outer archive without extracting archive contents to disk.
2. **Nested Archive Member Type Verification:** Enforces that every required volume archive member in the outer archive is strictly a regular file (`-`). Symbolic links, hard links, directories, character/block devices, and FIFOs are detected and rejected. Streamed byte sizes are cross-verified against the manifest, nested tar readability is verified, and pipeline failure detection via `set -Eeuo pipefail` is preserved.
3. **Deterministic `archive_size_human` Validation:** Replaced basic pattern checking of `archive_size_human` with deterministic verification against actual on-disk file usage computed via `du -h` and apparent size via `du -h --apparent-size`, matching the exact formatting logic emitted by the writer and rejecting tampered size metadata.
4. **Robust Archive Table-of-Contents Parsing:** Replaced raw `tar -tzf` parsing with structured parsing of `tar -tvzf --quoting-style=escape`. Quoting escapes guarantee that filenames with embedded newlines, carriage returns, or control characters occupy exactly one line, preventing line-splitting ambiguities and path injection vulnerabilities.
5. **Preservation of Existing Safety Controls:** Retained strict fail-closed checkpoint gating, exclusion of partial routine backups from retention pruning, multi-phase destination permissions/symlink checks, atomic publication, and idempotent cleanup traps.

---

## 2. Exact Changes and Source Line References

All modifications were applied strictly to [`deployment/backup.sh`](file:///home/dineth/dev/Linux-System-Monitoring-Reliability-Lab/deployment/backup.sh):

| Component / Finding | Lines in Script | Description of Change |
| :--- | :---: | :--- |
| **Deterministic `archive_size_human` Cross-Check** | Lines 1313–1329 | Extracts actual disk usage (`du -h`) and apparent usage (`du -h --apparent-size`) of `$candidate_set/$expected_archive`. Requires manifest `archive_size_human` to match one of these deterministic values, failing candidate validation on mismatch. |
| **Escaped Detailed TOC Reader** | Lines 1459–1516 | Executes `tar -tvzf "$candidate_set/$expected_archive" --quoting-style=escape`. Parses each entry into member mode/type (`TOC_TYPES`), normalized member path (`TOC_PATHS`), link target (`TOC_TARGETS`), and byte size (`TOC_SIZES`). Rejects path traversal (`..`) and absolute paths (`^/`). |
| **Configuration Directory Structure Verification** | Lines 1518–1558 | For every directory in `REQUIRED_CONFIG_DIRS`, verifies that any entry matching `configs/<dir>` is marked as a directory (`t == "d"`), and confirms that either a genuine directory entry (`configs/<dir>/`) or valid descendants exist. Rejects regular files or symlinks with directory names. |
| **Nested Volume Archive Regular File Enforcement** | Lines 1560–1649 | For every volume in `REQUIRED_VOLUMES`, verifies exactly one matching member in `TOC_PATHS`. Rejects ambiguous prefixes or suffix extensions. Strictly verifies `vol_entry_type == "-"` (regular file), rejecting symbolic links (`l`), hard links (`h`), directories (`d`), and special files. Streams to `wc -c` and `tar -tzf -` under `pipefail`. |

---

## 3. How Directory Entries Are Distinguished from Regular Files

In previous revisions, table-of-contents validation relied on name matching from `tar -tzf`. Because `tar -tzf` only outputs paths, a regular file named `./configs/prometheus` matched the regex `^(\./)?configs/${cfg_dir}(/.*)?$`.

In Phase E.1.8, `deployment/backup.sh` uses `tar -tvzf --quoting-style=escape`:
1. **Mode String Inspection:** The first character of the permissions field indicates POSIX file type:
   - `d` = Directory
   - `-` = Regular file
   - `l` = Symbolic link
   - `h` = Hard link
2. **Explicit Regular File Rejection:** For each required directory in `REQUIRED_CONFIG_DIRS`:
   ```bash
   if [[ "$p" =~ ^(\./)?configs/${cfg_dir}$ ]]; then
       if [[ "$t" != "d" ]]; then
           echo "  [WARN] Skipping candidate '$set_name': archive entry 'configs/$cfg_dir' is not a directory (member type: '$t'). Regular files or special files for configuration directories are prohibited." >&2
           return 1
       fi
       dir_entry_found=1
   ```
   If an entry named `configs/prometheus` exists and its type is `-` (regular file) or `l` (symlink), candidate validation immediately aborts.
3. **Genuine Directory or Descendant Presence:**
   ```bash
   elif [[ "$p" =~ ^(\./)?configs/${cfg_dir}/$ ]]; then
       if [[ "$t" != "d" ]]; then
           echo "  [WARN] Skipping candidate '$set_name': archive entry 'configs/$cfg_dir/' is not marked as directory (member type: '$t')." >&2
           return 1
       fi
       dir_entry_found=1
   elif [[ "$p" =~ ^(\./)?configs/${cfg_dir}/.+ ]]; then
       descendant_count=$((descendant_count + 1))
   fi
   ```
   A configuration directory is accepted if and only if:
   - It is explicitly entered as a directory (`t == "d"`), OR
   - Valid descendant entries exist under `configs/<cfg_dir>/...`.
   - If `dir_entry_found == 0` and `descendant_count == 0`, the candidate is preserved and skipped.

---

## 4. How Nested Archive Member Types Are Verified

For each required volume in `REQUIRED_VOLUMES`:
1. **Cardinality & Ambiguity Check:**
   Iterates through `TOC_PATHS`. Requires exactly one entry matching `^(\./)?volumes/${vol}\.tar\.gz$`. Rejects any entry using the volume name as a directory prefix (e.g., `volumes/<vol>.tar.gz/payload`) or malformed extension (e.g., `volumes/<vol>.tar.gz.bak`).
2. **Regular File Type Enforcement:**
   Inspects `vol_entry_type` (`${mode:0:1}` from `tar -tvzf`):
   ```bash
   if [[ "$vol_entry_type" != "-" ]]; then
       case "$vol_entry_type" in
           l)
               echo "  [WARN] Skipping candidate '$set_name': nested archive for '$vol' is a symbolic link (target: '$vol_entry_target'). Volume archives must be regular files." >&2
               ;;
           h)
               echo "  [WARN] Skipping candidate '$set_name': nested archive for '$vol' is a hard link (target: '$vol_entry_target'). Volume archives must be regular files." >&2
               ;;
           d)
               echo "  [WARN] Skipping candidate '$set_name': nested archive for '$vol' is a directory. Volume archives must be regular files." >&2
               ;;
           *)
               echo "  [WARN] Skipping candidate '$set_name': nested archive for '$vol' is a special entry (type '$vol_entry_type'). Volume archives must be regular files." >&2
               ;;
       esac
       return 1
   fi
   ```
3. **Streamed Content Integrity:**
   Only verified regular files are streamed to `wc -c` and `tar -tzf -`. Symbolic links targeting external paths or empty directories cannot pass validation.

---

## 5. How Unusual Filenames Are Handled

### The Ambiguity in Line-Delimited `tar -tzf`
Standard `tar -tzf` emits raw paths separated by newlines. If an archive member contains a newline character in its filename, `tar -tzf` emits multiple lines for a single file. A naive `while read -r` loop will interpret the second half of the filename as a separate entry, potentially corrupting array parsing or causing false-negative matches.

### Quoted/Escaped Table-of-Contents Architecture
Phase E.1.8 specifies `--quoting-style=escape` when listing archive contents:
```bash
tar -tvzf "$candidate_set/$expected_archive" --quoting-style=escape
```
1. **Deterministic Single-Line Invariant:** GNU tar converts newlines to `\n`, carriage returns to `\r`, tabs to `\t`, and backslashes to `\\`. Every archive member is guaranteed to occupy exactly one newline-terminated line.
2. **Strict Regex Parsing:** Each line is parsed with:
   ```bash
   re_tar_entry='^([-dlhcbp?][rwxstST-]{9})[[:space:]]+([^[:space:]]+)[[:space:]]+([0-9]+)[[:space:]]+([0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]+[0-9]{2}:[0-9]{2}(:[0-9]{2})?)[[:space:]]+(.*)$'
   ```
   If any line in the table of contents does not strictly match this standard format, candidate validation immediately rejects the candidate (`unparseable or ambiguous entry line`).
3. **Link Target Separation:** For symbolic links (`l`) and hard links (`h`), regex patterns `^(.*)[[:space:]]->[[:space:]](.*)$` and `^(.*)[[:space:]]link[[:space:]]to[[:space:]](.*)$` isolate the link path from the target destination.
4. **Path Traversal Shielding:** Validates that no parsed path contains `..` segments or leading slashes (`/`), protecting against directory traversal attacks.

---

## 6. How `archive_size_human` Is Validated

In Phase E.1.7, `archive_size_human` was validated only against a generic pattern (`^[0-9]+(\.[0-9]+)?[A-Za-z]?$`), allowing inconsistent metadata (e.g. `archive_size_human: "1K"` for a 50MB archive) to pass validation.

### Deterministic Cross-Validation Rule
In `deployment/backup.sh` (Section 9, line 745), the writer generates `archive_size_human` via:
```bash
ARCHIVE_SIZE=$(du -h "$TMP_ARCHIVE" | cut -f1)
```
In `validate_retention_candidate()` (Section 10, lines 1313–1329), the validator reproduces this measurement against the published archive `$candidate_set/$expected_archive`:
```bash
local actual_du_h=""
local actual_du_app=""
actual_du_h="$(du -h "$candidate_set/$expected_archive" 2>/dev/null | cut -f1 | tr -d ' \t\r\n')"
actual_du_app="$(du -h --apparent-size "$candidate_set/$expected_archive" 2>/dev/null | cut -f1 | tr -d ' \t\r\n')"

if [[ "$m_human" != "$actual_du_h" && "$m_human" != "$actual_du_app" ]]; then
    echo "  [WARN] Skipping candidate '$set_name': manifest archive_size_human ('$m_human') does not match actual archive size (disk: '$actual_du_h', apparent: '$actual_du_app')." >&2
    return 1
fi
```
* **Deterministic Matching:** The manifest value must match either the disk-allocated human size (`du -h`) or the apparent human size (`du -h --apparent-size`).
* **Zero Silent Drift:** Inconsistent, forged, or drifted human size metadata triggers immediate rejection and candidate preservation.

---

## 7. Audit of All `local` Declarations

Every `local` declaration across [`deployment/backup.sh`](file:///home/dineth/dev/Linux-System-Monitoring-Reliability-Lab/deployment/backup.sh) was verified to reside strictly inside a function definition:

```
Function: cleanup_temp_artifacts() (Lines 106–141)
  Line 108:    local err=0

Function: on_exit() (Lines 143–155)
  Line 144:    local rc=$?

Function: validate_no_symlink_components() (Lines 200–214)
  Line 201:    local target_path="$1"
  Line 202:    local desc="$2"
  Line 203:    local p="$target_path"

Function: revalidate_destination_security() (Lines 216–256)
  Line 217:    local target_dir="$1"
  Line 218:    local phase_name="$2"
  Line 236:    local d_owner
  Line 243:    local d_mode

Function: validate_retention_candidate() (Lines 897–1650)
  Lines 898–903:   candidate_set, set_name, expected_id, expected_archive, expected_manifest, expected_sha
  Lines 920–921:   sidecar_sha, sidecar_file
  Line 939:        actual_archive_bytes
  Lines 948–961:   SEEN_TOP_KEYS, MANIFEST_SCALARS, PARSED_REQ_CONFIGS, PARSED_REQ_VOLS,
                   PARSED_ARCH_VOLS, PARSED_MISS_VOLS, PARSED_FAIL_VOLS, SEEN_VOL_RESULTS,
                   V_PROP_STATUS, V_PROP_EXISTS, V_PROP_ARCHIVE_VERIFIED, V_PROP_ARCHIVE_BYTES,
                   SEEN_V_PROPS, ARRAY_EXPLICIT_EMPTY
  Lines 963–966:   current_section, current_sub_vol, line_num, seen_notice_content
  Lines 978–979:   re_unsupported, re_yaml_tag
  Lines 988–990:   tkey, rest, tval
  Line 1097:       item
  Lines 1157–1164: vprop, vpval, prop_key
  Line 1198:       MANDATORY_KEYS
  Lines 1220–1313: m_schema, m_status, m_id, m_set_dir, m_archive, m_sha, m_bytes, m_utc,
                   m_epoch, m_mode, m_class, m_repo, m_pdir, m_pfiles, m_sec, m_human
  Lines 1318–1319: actual_du_h, actual_du_app
  Lines 1337, 1356, 1375, 1440: found, is_req
  Lines 1417–1420: v_stat, v_exists, v_ver, v_bytes
  Lines 1466–1475: re_tar_entry, re_symlink, re_hardlink, TOC_TYPES, TOC_PATHS, TOC_TARGETS,
                   TOC_SIZES, toc_line
  Lines 1481–1486: mode, ftype, size, raw_path, path, target
  Lines 1523–1526: dir_entry_found, descendant_count, idx
  Lines 1528–1529: p, t
  Lines 1567–1572: vol_match_count, vol_entry_path, vol_entry_type, vol_entry_target, idx
  Lines 1574–1576: p, t, tgt
  Lines 1620, 1632: actual_vol_bytes, expected_vol_bytes
```

**Result:** Zero `local` declarations exist in the global execution scope. All variables are safely bound to their respective function lifecycles.

---

## 8. Static Syntax Verification & Execution Boundaries

### 8.1 Syntax Check Command & Output
Syntax verification was performed using GNU Bash 5.2 against [`deployment/backup.sh`](file:///home/dineth/dev/Linux-System-Monitoring-Reliability-Lab/deployment/backup.sh):

```bash
dineth@dineth-Aspire-A715-42G:~/dev/Linux-System-Monitoring-Reliability-Lab$ bash -n deployment/backup.sh
dineth@dineth-Aspire-A715-42G:~/dev/Linux-System-Monitoring-Reliability-Lab$ echo $?
0
```

### 8.2 Confirmation of Non-Execution
In adherence to the strict execution boundaries:
* `deployment/backup.sh` was **NOT** executed.
* No `docker`, `docker run`, or `docker compose` commands were executed.
* No containers were started, stopped, restarted, created, or inspected.
* No Docker volumes were inspected, mounted, created, modified, or deleted.
* No host system services, packages, or configurations were altered.
* No backup, restore, retention, or cleanup operations were performed.
* No Git state-changing operations (`git commit`, `git push`, `git reset`, `git checkout`, `git stash`, `git add`) were performed.

---

## 9. Final Review Status

Every required correction specified for Phase E.1.8 has been implemented in source code and validated via static code inspection and syntax checking.

**Status:** `PATCH READY FOR INDEPENDENT REVIEW`
