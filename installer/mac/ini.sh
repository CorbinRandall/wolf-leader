# shellcheck shell=bash
# Wolf Leader answer-file (wolf-leader-setup.ini) reader for the Mac installer.
# Contract: installer/CONFIG.md. Pure bash + POSIX awk on purpose: it has to work on a fresh Mac
# with no Command Line Tools (no python3) and under macOS's bash 3.2 / BWK awk.
#
#   wl_ini_extract <file>          print just the INI text (drops a ```ini fence, prose, CR, BOM)
#   wl_ini_parse <file> [os]       validate strictly; on success print section.key=value lines
#                                  (plus meta.shares=share1 share2 ...) and return 0; on failure
#                                  print one error per problem (with line number + line) and return 1
#   wl_cfg_load <parsed-file>      load parsed lines into CFG_<section>_<key> shell variables
#   wl_cfg <section> <key>         print a loaded value (empty if absent)

wl__ini_extract_awk() {
  cat <<'AWK'
NR == 1 && substr($0, 1, 3) == bom { $0 = substr($0, 4) }
{ line[++n] = $0 }
END {
  start = 0; stop = n + 1
  for (i = 1; i <= n; i++) if (line[i] ~ /^[ \t]*```[ \t]*[Ii][Nn][Ii][ \t]*$/) { start = i; break }
  if (!start) for (i = 1; i <= n; i++) if (line[i] ~ /^[ \t]*```/) { start = i; break }
  if (start) for (i = start + 1; i <= n; i++) if (line[i] ~ /^[ \t]*```/) { stop = i; break }
  for (i = start + 1; i < stop; i++) print line[i]
}
AWK
}

wl__ini_parse_awk() {
  cat <<'AWK'
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function bad(msg) { nerr++; errs[nerr] = "Line " NR ": " msg "\n      > " raw }
function badk(s, k, msg) { nerr++; errs[nerr] = "Line " lineno[s, k] ": " msg "\n      > " rawline[s, k] }
function missing(s, k) { nerr++; errs[nerr] = "Missing " k "= in [" s "]" }
function known(s, k) {
  if (s == "wolf") return (k ~ /^(format|os|hub_url|mcp_url|timezone|device_name)$/)
  if (s == "detected") return (k ~ /^(git|python|python_version|docker|obsidian|cursor|claude_code|wolf_client)$/)
  if (s == "backup") return (k ~ /^(done|path|files)$/)
  if (s == "original") return (k ~ /^(found|where|folder|ssh_target|ssh_port|ssh_key)$/)
  return (k ~ /^(unc|smb_url|letter|user|password|role)$/)
}
function tzknown(v,   f, r, junk) {
  f = zdir "/" v
  r = (getline junk < f)
  close(f)
  return r >= 0
}
function check(s, k, v,   hp, i, j) {
  if (s == "wolf") {
    if (k == "format") { if (v != "1") bad("format must be 1 (this installer only reads format=1)") }
    else if (k == "os") { if (v != "mac" && v != "windows") bad("os must be mac or windows") }
    else if (k == "hub_url" || k == "mcp_url") {
      if (v !~ /^https?:\/\/[^\/ \t]+/ || v ~ /[ \t]/) bad(k " must start with http:// or https:// followed by a host, no spaces")
    }
    else if (k == "timezone") {
      if (v !~ /^[A-Za-z][A-Za-z0-9_+-]*(\/[A-Za-z0-9_+-]+)*$/) bad("timezone must be an IANA zone like America/Chicago")
      else if (zdir != "" && !tzknown(v)) bad("timezone " v " is not a time zone this Mac knows (expected something like America/Chicago)")
    }
    else if (k == "device_name") {
      if (v !~ /^[A-Za-z0-9-]+$/ || length(v) > 32) bad("device_name must be 1-32 letters, digits or hyphens")
    }
  } else if (s == "detected") {
    if (k == "python_version") {
      if (v != "NONE" && v !~ /^[0-9]+\.[0-9]+(\.[0-9]+)?[A-Za-z0-9]*$/) bad("python_version must be a version like 3.13.1, or NONE")
    }
    else if (v != "yes" && v != "no") bad(k " must be yes or no (lowercase)")
  } else if (s == "backup") {
    if (k == "done") { if (v != "yes" && v != "no") bad("done must be yes or no (lowercase)") }
    else if (k == "path") {
      if (v != "NONE" && v !~ /^\// && v !~ /^~\// && v !~ /^[A-Za-z]:\\/ && v !~ /^\\\\/) bad("path must be an absolute folder path (like /Users/you/WolfLeader-backup-20261006-1240), or NONE")
    }
    else if (k == "files") { if (v !~ /^[0-9]+$/) bad("files must be digits only") }
  } else if (s == "original") {
    if (k == "found") { if (v != "yes" && v != "no") bad("found must be yes or no (lowercase)") }
    else if (k == "where") { if (v !~ /^(this|ssh|manual|NONE)$/) bad("where must be this, ssh, manual or NONE") }
    else if (k == "folder") {
      if (v != "NONE" && v !~ /^\// && v !~ /^~\//) bad("folder must be an absolute path on the hub computer (like /opt/wolf-leader), or NONE")
    }
    else if (k == "ssh_target") {
      if (v != "NONE" && v !~ /^[A-Za-z0-9._-]+@[A-Za-z0-9.-]+$/) bad("ssh_target must look like user@host, or NONE")
    }
    else if (k == "ssh_port") {
      if (v != "NONE" && (v !~ /^[0-9]+$/ || v + 0 < 1 || v + 0 > 65535)) bad("ssh_port must be a port number 1-65535, or NONE")
    }
    else if (k == "ssh_key") {
      if (v != "NONE" && v !~ /^\// && v !~ /^~\//) bad("ssh_key must be the path of a key file (like ~/.ssh/id_ed25519), or NONE - never the key itself")
    }
  } else {
    if (k == "smb_url") {
      if (v != "NONE") {
        if (v !~ /^smb:\/\/[^\/ \t]+\/./) bad("smb_url must look like smb://server/share (or NONE)")
        else {
          hp = substr(v, 7); i = index(hp, "/"); hp = substr(hp, 1, i - 1)
          j = index(hp, "@")
          if (j > 0 && index(substr(hp, 1, j - 1), ":") > 0) bad("smb_url must not contain a password")
        }
      }
    }
    else if (k == "unc") { if (v != "NONE" && substr(v, 1, 2) != "\\\\") bad("unc must look like \\\\server\\share, or NONE") }
    else if (k == "letter") { if (v != "NONE" && v !~ /^[A-Za-z]$/) bad("letter must be a single drive letter A-Z without a colon, or NONE") }
    else if (k == "password") { if (v != "ASK" && v != "NONE") bad("password must be ASK or NONE (never a real password)") }
    else if (k == "role") { if (v != "wolf" && v != "extra") bad("role must be wolf or extra") }
  }
}
BEGIN { sec = ""; nerr = 0 }
{
  raw = $0
  line = trim($0)
  if (line == "") next
  c = substr(line, 1, 1)
  if (c == ";" || c == "#") next
  if (c == "[") {
    if (substr(line, length(line), 1) != "]") { bad("broken section header"); sec = "?"; next }
    name = trim(substr(line, 2, length(line) - 2))
    if (name == "wolf" || name == "detected" || name == "backup" || name == "original" || name ~ /^share[1-5]$/) {
      if (name in seen) { bad("section [" name "] appears twice"); sec = "?"; next }
      seen[name] = 1; sec = name
    }
    else if (name ~ /^share[0-9]+$/) { bad("only [share1] to [share5] are allowed"); sec = "?" }
    else { bad("unknown section [" name "] (allowed: [wolf], [detected], [backup], [original], [share1]..[share5])"); sec = "?" }
    next
  }
  eq = index(line, "=")
  if (eq == 0) { bad("expected key=value"); next }
  if (sec == "") { bad("key=value before the first [section]"); next }
  if (sec == "?") next
  key = trim(substr(line, 1, eq - 1))
  val = trim(substr(line, eq + 1))
  if (!known(sec, key)) next
  if ((sec, key) in val_of) { bad(key " appears twice in [" sec "]"); next }
  if (val == "") { bad(key " has no value (blank values are not allowed)"); next }
  if (index(val, "\"") || index(val, "'")) { bad(key " must not be quoted"); next }
  val_of[sec, key] = val; lineno[sec, key] = NR; rawline[sec, key] = raw
  check(sec, key, val)
}
END {
  nw = split("format os hub_url mcp_url timezone device_name", wk, " ")
  nd = split("git python python_version docker obsidian cursor claude_code wolf_client", dk, " ")
  nb = split("done path files", bk, " ")
  ns = split("unc smb_url letter user password role", sk, " ")
  if (!("wolf" in seen)) { nerr++; errs[nerr] = "Missing section [wolf]" }
  else for (i = 1; i <= nw; i++) if (!(("wolf", wk[i]) in val_of)) missing("wolf", wk[i])
  if (!("detected" in seen)) { nerr++; errs[nerr] = "Missing section [detected]" }
  else for (i = 1; i <= nd; i++) if (!(("detected", dk[i]) in val_of)) missing("detected", dk[i])
  if (!("backup" in seen)) { nerr++; errs[nerr] = "Missing section [backup]" }
  else for (i = 1; i <= nb; i++) if (!(("backup", bk[i]) in val_of)) missing("backup", bk[i])
  if ((("backup", "done") in val_of) && (("backup", "path") in val_of) && val_of["backup", "done"] == "yes" && val_of["backup", "path"] == "NONE")
    badk("backup", "path", "done=yes needs the backup folder path (or write done=no)")

  no = split("found where folder ssh_target ssh_port ssh_key", ok, " ")
  if ("original" in seen) {
    for (i = 1; i <= no; i++) if (!(("original", ok[i]) in val_of)) missing("original", ok[i])
    of = val_of["original", "found"]; ow = val_of["original", "where"]
    if (of == "no" && ow != "" && ow != "NONE") badk("original", "where", "found=no needs where=NONE")
    if (of == "yes" && ow == "NONE") badk("original", "where", "found=yes needs where=this, ssh or manual")
    if ((ow == "this" || ow == "ssh") && val_of["original", "folder"] == "NONE")
      badk("original", "folder", "where=" ow " needs the original folder path")
    if (ow == "ssh" && val_of["original", "ssh_target"] == "NONE") badk("original", "ssh_target", "where=ssh needs ssh_target=user@host")
    if (ow == "ssh" && val_of["original", "ssh_port"] == "NONE") badk("original", "ssh_port", "where=ssh needs ssh_port (22 if unsure)")
  }

  os = ""
  if (("wolf", "os") in val_of) os = val_of["wolf", "os"]
  if (os != "" && expect_os != "" && os != expect_os && (os == "mac" || os == "windows"))
    badk("wolf", "os", "this answer file is for os=" os " but this is the " (expect_os == "mac" ? "Mac" : "Windows") " installer - ask your agent again on this computer")

  # Share keys are judged by the OS this installer runs on, so a wrong os= gives one clear error.
  tos = (expect_os != "") ? expect_os : os
  shares = ""
  for (n = 1; n <= 5; n++) {
    s = "share" n
    if (!(s in seen)) continue
    shares = shares (shares == "" ? "" : " ") s
    req = (tos == "windows") ? "unc letter user password role" : "smb_url user password role"
    m = split(req, rk, " ")
    for (i = 1; i <= m; i++) if (!((s, rk[i]) in val_of)) missing(s, rk[i])
    if (tos == "mac" && ((s, "smb_url") in val_of) && val_of[s, "smb_url"] == "NONE")
      badk(s, "smb_url", "smb_url is required on a Mac (smb://server/share)")
    if (tos == "windows" && ((s, "unc") in val_of) && val_of[s, "unc"] == "NONE")
      badk(s, "unc", "unc is required on Windows (\\\\server\\share)")
    if (((s, "user") in val_of) && ((s, "password") in val_of) && val_of[s, "user"] == "NONE" && val_of[s, "password"] == "ASK")
      badk(s, "password", "password=ASK needs a user; for guest access write user=NONE and password=NONE")
  }

  if (nerr) { for (i = 1; i <= nerr; i++) print errs[i]; exit 1 }

  for (i = 1; i <= nw; i++) print "wolf." wk[i] "=" val_of["wolf", wk[i]]
  for (i = 1; i <= nd; i++) print "detected." dk[i] "=" val_of["detected", dk[i]]
  for (i = 1; i <= nb; i++) print "backup." bk[i] "=" val_of["backup", bk[i]]
  if ("original" in seen) for (i = 1; i <= no; i++) print "original." ok[i] "=" val_of["original", ok[i]]
  for (n = 1; n <= 5; n++) {
    s = "share" n
    if (!(s in seen)) continue
    for (i = 1; i <= ns; i++) if ((s, sk[i]) in val_of) print s "." sk[i] "=" val_of[s, sk[i]]
  }
  print "meta.shares=" shares
}
AWK
}

wl_ini_extract() {
  local bom
  bom=$(printf '\357\273\277')
  tr '\r' '\n' <"$1" | LC_ALL=C awk -v bom="$bom" "$(wl__ini_extract_awk)"
}

wl_ini_parse() {
  local zdir=""
  [ -d /usr/share/zoneinfo ] && zdir=/usr/share/zoneinfo
  LC_ALL=C awk -v expect_os="${2:-mac}" -v zdir="$zdir" "$(wl__ini_parse_awk)" "$1"
}

wl_cfg_load() {
  local l k v
  while IFS= read -r l || [ -n "$l" ]; do
    case "$l" in *=*) ;; *) continue ;; esac
    k=${l%%=*}
    v=${l#*=}
    k=${k//./_}
    printf -v "CFG_$k" '%s' "$v"
  done <"$1"
}

wl_cfg() {
  local n="CFG_$1_$2"
  printf '%s' "${!n-}"
}
