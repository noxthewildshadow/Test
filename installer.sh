#!/usr/bin/env bash
RESET="\e[0m"
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
ORANGE="\e[38;5;208m"
BLUE="\e[34m"
BOLD="\e[1m"

step_counter=0
step() {
  step_counter=$((step_counter+1))
  printf "\n${BOLD}${BLUE}STEP %02d:${RESET} %s\n" "$step_counter" "$1"
}
msg_ok() { printf "  ${GREEN}[OK]${RESET} %s\n" "$1"; }
msg_warn() { printf "  ${ORANGE}[WARN]${RESET} %s\n" "$1"; }
msg_err() { printf "  ${RED}[ERROR]${RESET} %s\n" "$1"; }

run_cmd() {
  bash -c "$1"
  rc=$?
  if [ $rc -eq 0 ]; then msg_ok "Command succeeded: $1"; return 0; else
    if [ "$2" = "critical" ]; then msg_err "Critical failure (code $rc): $1"; exit 1; else msg_warn "Non-critical failure (code $rc): $1"; return $rc; fi
  fi
}

download_file() {
  url="$1"; out="$2"; critical="$3"
  printf "  Downloading: %s -> %s\n" "$url" "$out"
  curl -fSL --retry 3 --retry-delay 2 "$url" -o "$out"
  rc=$?
  if [ $rc -eq 0 ]; then chmod +x "$out" 2>/dev/null || true; msg_ok "Downloaded: $out"; return 0; else
    if [ "$critical" = "critical" ]; then msg_err "Failed to download (critical): $url"; exit 1; else msg_warn "Failed to download (non-critical): $url"; return $rc; fi
  fi
}

printf "${BOLD}Starting installer and patcher for Ubuntu 22.04 environment${RESET}\n"

WORKDIR="$(pwd)/blockheads_install_$(date +%s)"
mkdir -p "$WORKDIR" || { msg_err "Cannot create workdir: $WORKDIR"; exit 1; }
step "Preparing work directory: $WORKDIR"
msg_ok "Work directory: $WORKDIR"
cd "$WORKDIR" || { msg_err "Cannot cd to $WORKDIR"; exit 1; }

step "Detecting OS and version"
if [ -f /etc/os-release ]; then
  . /etc/os-release
  if [ "${NAME:-}" = "Ubuntu" ] && [ "${VERSION_ID:-}" = "22.04" ]; then
    msg_ok "Running on Ubuntu 22.04"
  else
    msg_warn "OS is ${NAME:-unknown} ${VERSION_ID:-unknown} — intended target is Ubuntu 22.04"
  fi
else
  msg_warn "/etc/os-release not found — cannot verify distribution"
fi

step "Ensuring required packages (curl, tar, patchelf) are installed"
if command -v apt-get >/dev/null 2>&1; then
  sudo apt-get update -y
  sudo apt-get install -y curl tar patchelf >/dev/null 2>&1
  if command -v patchelf >/dev/null 2>&1; then
    msg_ok "Required packages are present"
  else
    msg_warn "patchelf not installed after apt attempt"
  fi
else
  msg_warn "apt-get not found; please ensure curl, tar and patchelf are installed manually"
fi

step "Download and extract tarball (critical)"
TARBALL_URL="https://web.archive.org/web/20240309015235if_/https://majicdave.com/share/blockheads_server171.tar.gz"
bash -c "curl -fSL \"$TARBALL_URL\" | tar xvz"
if [ $? -ne 0 ]; then msg_err "Failed to download or extract tarball from $TARBALL_URL"; exit 1; else msg_ok "Tarball downloaded and extracted"; fi

BIN_NAME="blockheads_server171"
if [ ! -f "$BIN_NAME" ]; then
  FOUND_BIN="$(find . -maxdepth 2 -type f -executable -iname 'blockheads*' -print -quit)"
  if [ -n "$FOUND_BIN" ]; then BIN="$FOUND_BIN"; msg_warn "Expected name not found; using: $BIN"; else msg_err "Binary $BIN_NAME not found and no executable discovered"; exit 1; fi
else
  BIN="./$BIN_NAME"
  msg_ok "Binary to patch: $BIN"
fi

step "Checking patchelf (critical)"
if command -v patchelf >/dev/null 2>&1; then msg_ok "patchelf found: $(command -v patchelf)"; else msg_err "patchelf not installed. Install it and re-run."; exit 1; fi

step "Applying patchelf replacements (non-critical failures will continue)"
REPLACEMENTS=(
  "libgnustep-base.so.1.24|libgnustep-base.so.1.28"
  "libobjc.so.4.6|libobjc.so.4"
  "libgnutls.so.26|libgnutls.so.30"
  "libgcrypt.so.11|libgcrypt.so.20"
  "libffi.so.6|libffi.so.8"
  "libicui18n.so.48|libicui18n.so.70"
  "libicuuc.so.48|libicuuc.so.70"
  "libicudata.so.48|libicudata.so.70"
  "libdispatch.so|libdispatch.so.0"
)
for r in "${REPLACEMENTS[@]}"; do
  orig="${r%%|*}"; new="${r##*|}"
  printf "  Trying: replace %s -> %s\n" "$orig" "$new"
  patchelf --replace-needed "$orig" "$new" "$BIN"
  if [ $? -eq 0 ]; then msg_ok "Replaced: $orig -> $new"; else msg_warn "Failed replace: $orig -> $new"; fi
done

step "Downloading helper scripts from GitHub (non-critical)"
RAW_BASE="https://raw.githubusercontent.com/noxthewildshadow/Test/refs/heads/main"
GITHUB_FILES=( "server_manager.sh" "server_patcher.sh" "common_functions.sh" "server_commands" )
for f in "${GITHUB_FILES[@]}"; do
  url="${RAW_BASE}/${f}"; out="./${f}"
  download_file "$url" "$out" || true
done

step "Download and run installer.sh via curl | sudo bash"
INSTALLER_URL="${RAW_BASE}/installer.sh"
bash -c "curl -fSL \"$INSTALLER_URL\" | sudo bash"
rc_installer=$?
if [ $rc_installer -eq 0 ]; then msg_ok "installer.sh executed successfully"; else msg_warn "installer.sh execution failed (code $rc_installer)"; fi

step "Ensure downloaded scripts are executable"
for f in "${GITHUB_FILES[@]}"; do
  if [ -f "./${f}" ]; then chmod +x "./${f}" 2>/dev/null || true; msg_ok "Made executable: ./${f}"; else msg_warn "Not found: ./${f}"; fi
done

step "Final summary"
msg_ok "Workdir: $WORKDIR"
msg_ok "Binary: $BIN"
msg_warn "Warnings (orange) indicate issues to review but the script continued"
msg_ok "If any errors (red) appeared, the script stopped at that point"

printf "\n${BOLD}END${RESET}\n"
