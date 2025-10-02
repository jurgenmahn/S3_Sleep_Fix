#!/usr/bin/env bash
# yy-s3-sleep-fix - robust HP Pavilion S3 sleep fixer (initramfs DSDT patch + GRUB flags)

set -Eeuo pipefail
IFS=$'\n\t'

# ---------- Config / Constants ----------
REQUIRED_PKGS=(acpica-tools binwalk)
GRUB_FILE="/etc/default/grub"
GRUB_KEY="GRUB_CMDLINE_LINUX_DEFAULT"
REQUIRED_KERNEL_FLAGS=("mem_sleep_default=deep" "pcie_aspm=force")
POSTINST_TARGET="/etc/kernel/postinst.d/yy-s3-sleep-fix"
SYSTEMD_SLEEP_FIX="/lib/systemd/system-sleep/usb_wakeup_fix_s3.sh"
INITRD="/boot/initrd.img-$(uname -r)"
LOGGER_TAG="s3-patch"

# ---------- Logging (format-safe) ----------
RED=$'\e[1;31m'; GREEN=$'\e[1;32m'; NC=$'\e[0m'
log_err ()   { printf '%b\n' "${RED}$*${NC}" ; logger -t "$LOGGER_TAG" -- "ERROR: $*"; }
log_info ()  { printf '%b\n' "${GREEN}$*${NC}"; logger -t "$LOGGER_TAG" -- "INFO:  $*"; }

# ---------- Root check ----------
if [[ ${EUID} -ne 0 ]]; then
  log_err "Must run as root."
  exit 1
fi

# ---------- Cleanup ----------
WORKDIR=""
cleanup () {
  if [[ -n "${WORKDIR}" && -d "${WORKDIR}" ]]; then rm -rf -- "${WORKDIR}"; fi
}
trap cleanup EXIT

# ---------- APT install with retries ----------
apt_install_retry () {
  local -a pkgs=("$@")
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    local tries=3
    for ((i=1;i<=tries;i++)); do
      log_info "Installing deps (attempt $i/$tries): ${pkgs[*]}"
      (apt-get update -y || true)
      if apt-get install -y --no-install-recommends "${pkgs[@]}"; then
        return 0
      fi
      log_err "Install failed; fixing and retrying…"
      apt-get -f install -y || true
      sleep 2
    done
    log_err "Failed to install: ${pkgs[*]}"
    return 1
  else
    # Non-Debian: just verify tools exist
    for p in "${pkgs[@]}"; do
      case "$p" in
        acpica-tools) command -v iasl >/dev/null 2>&1 || { log_err "iasl missing. Install acpica-tools."; return 1; } ;;
        binwalk)      command -v binwalk >/dev/null 2>&1 || { log_err "binwalk missing. Install binwalk."; return 1; } ;;
      esac
    done
  fi
}

# ---------- Ensure tools ----------
if ! command -v iasl >/dev/null 2>&1 || ! command -v binwalk >/dev/null 2>&1; then
  apt_install_retry "${REQUIRED_PKGS[@]}"
fi
command -v iasl >/dev/null 2>&1 || { log_err "iasl not available."; exit 1; }
command -v binwalk >/dev/null 2>&1 || { log_err "binwalk not available."; exit 1; }

# ---------- Early exit if deep already active ----------
if [[ -r /sys/power/mem_sleep ]]; then
  MEMSLEEP_CONTENT=$(< /sys/power/mem_sleep)
  log_info "mem_sleep: ${MEMSLEEP_CONTENT}"
  if grep -q '\[deep\]' <<<"$MEMSLEEP_CONTENT"; then
    log_info "Deep sleep already active; nothing to do."
    exit 0
  fi
else
  log_err "/sys/power/mem_sleep not present."
fi

# ---------- Prepare workdir ----------
WORKDIR="$(mktemp -d -t s3fix.XXXXXX)"
cd "$WORKDIR"

# ---------- Extract and patch DSDT ----------
# Capture current raw DSDT
if [[ ! -r /sys/firmware/acpi/tables/DSDT ]]; then
  log_err "Cannot read /sys/firmware/acpi/tables/DSDT"
  exit 1
fi
cat /sys/firmware/acpi/tables/DSDT > dsdt.aml

# Decompile
iasl -d dsdt.aml

# Patch payload
PATCH=$(cat <<'EOF'
--- orig_dsdt.dsl	2025-01-31 01:04:57.678241801 +0100
+++ dsdt.dsl	2025-01-31 01:06:00.852378024 +0100
@@ -18,7 +18,7 @@
  *     Compiler ID      "ACPI"
  *     Compiler Version 0x20190509 (538510601)
  */
-DefinitionBlock ("", "DSDT", 2, "HPQOEM", "88D0    ", 0x01072009)
+DefinitionBlock ("", "DSDT", 2, "HPQOEM", "88D0    ", 0x01072010)
 {
     External (_SB_.ALIB, MethodObj)    // 2 Arguments
     External (_SB_.APTS, MethodObj)    // 1 Arguments
@@ -3176,6 +3176,13 @@
         Zero, 
         Zero
     })
+    Name (_S3, Package (0x04)  // _S3_: S3 System State
+    {
+        0x03,
+        0x03,
+        Zero,
+        Zero
+    })    
     Name (_S4, Package (0x04)  // _S4_: S4 System State
     {
         0x04, 
EOF
)

# Create a baseline copy for patch -- the patch expects orig_dsdt.dsl -> dsdt.dsl
cp dsdt.dsl orig_dsdt.dsl

# Apply patch (tolerant to whitespace & already-applied)
set +e
echo "$PATCH" | patch --ignore-whitespace -N -p0
case $? in
  0) log_info "Patch applied." ;;
  1) log_info "Patch was already applied; continuing." ;;
  *) log_err "Patch failed."; exit 1 ;;
esac
set -e

# Recompile; -ve = less verbose, still bail on errors
iasl -ve dsdt.dsl

# ---------- Build tiny cpio with patched DSDT ----------
mkdir -p kernel/firmware/acpi
cp dsdt.aml kernel/firmware/acpi/
find kernel | cpio -H newc --create > dsdt_patch

# ---------- Patch initrd if not already ----------
if [[ ! -r "$INITRD" ]]; then
  log_err "initrd not found: $INITRD"
  exit 1
fi

log_info "Checking if initrd already contains patched DSDT (binwalk)…"
if binwalk "$INITRD" 2>/dev/null | grep -q "kernel/firmware/acpi/dsdt.aml"; then
    log_info "initrd already contains a dsdt.aml; skipping concat."
else
    log_info "Patching initrd…"
    [[ -f "$INITRD.bck.s3patch" ]] || cp "$INITRD" "$INITRD.bck.s3patch"
    cat dsdt_patch "$INITRD.bck.s3patch" > "$(basename "$INITRD")"
    install -m 0644 "$(basename "$INITRD")" "$INITRD"
    log_info "initrd patched."
fi


# ---------- GRUB editing (idempotent & robust) ----------
backup_file () {
  local f="$1"
  [[ -f "${f}.bak.s3patch" ]] || cp -a "$f" "${f}.bak.s3patch"
}

ensure_kernel_flag () {
  local flag="$1"
  local line cur
  backup_file "$GRUB_FILE"

  # Read existing value (tolerate spaces/quotes)
  if ! grep -qE "^\s*${GRUB_KEY}=" "$GRUB_FILE"; then
    # Create key if missing
    printf '%s\n' "${GRUB_KEY}=\"\"" >> "$GRUB_FILE"
  fi

  # Extract current value between first pair of quotes on the key line
 cur="$(awk -v key="$GRUB_KEY" '
 $0 ~ "^[[:space:]]*"key"=" {
     val=$0
     sub(/^[^"]*"/,"",val)   # drop everything before first "
     sub(/".*$/,"",val)      # drop everything after closing "
     print val
 }' "$GRUB_FILE")"

  # If flag absent, append
  if ! grep -qw -- "$flag" <<<"$cur"; then
    line="$GRUB_KEY=\"${cur:+$cur }$flag\""
    # Replace entire line atomically
    awk -v key="$GRUB_KEY" -v newline="$line" '
      BEGIN{replaced=0}
      $0 ~ "^[[:space:]]*"key"=" && !replaced { print newline; replaced=1; next }
      { print }
      END{ if (!replaced) print newline }
    ' "$GRUB_FILE" > "${GRUB_FILE}.tmp"
    mv "${GRUB_FILE}.tmp" "$GRUB_FILE"
    log_info "Added kernel flag: $flag"
  else
    log_info "Kernel flag already present: $flag"
  fi
}

for f in "${REQUIRED_KERNEL_FLAGS[@]}"; do
  ensure_kernel_flag "$f"
done

# Generate grub config (distro-agnostic helper if present)
if command -v update-grub >/dev/null 2>&1; then
  update-grub
elif command -v grub-mkconfig >/dev/null 2>&1; then
  # Common locations for grub.cfg
  if [[ -d /boot/grub ]]; then
    grub-mkconfig -o /boot/grub/grub.cfg
  elif [[ -d /boot/grub2 ]]; then
    grub-mkconfig -o /boot/grub2/grub.cfg
  else
    log_err "Cannot locate grub.cfg directory; run grub-mkconfig manually."
  fi
else
  log_err "Neither update-grub nor grub-mkconfig found."
fi

# ---------- USB wake workaround ----------
install -Dm0755 /dev/stdin "$SYSTEMD_SLEEP_FIX" <<'EOS'
#!/usr/bin/env bash
# /lib/systemd/system-sleep/usb_wakeup_fix_s3.sh
# Unbind/rebind xhci controllers around suspend to avoid dead USB after resume
set -Eeuo pipefail
if [[ "${1:-}" == "pre" ]]; then
  tmp="/tmp/usb_devices"
  : > "$tmp"
  find /sys/bus/pci/drivers/xhci_hcd -maxdepth 1 -type l -name '0000:*' -print0 \
    | xargs -0 -I '{}' basename '{}' >> "$tmp"
  while IFS= read -r dev; do
    echo "$dev" > /sys/bus/pci/drivers/xhci_hcd/unbind || true
  done < "$tmp"
elif [[ "${1:-}" == "post" ]]; then
  tmp="/tmp/usb_devices"
  [[ -f "$tmp" ]] || exit 0
  while IFS= read -r dev; do
    echo "$dev" > /sys/bus/pci/drivers/xhci_hcd/bind || true
  done < "$tmp"
fi
EOS

# ---------- Self-install to postinst hook ----------
# Determine script source path (works for both one-shot run and postinst invocations)
if [[ -f "${BASH_SOURCE[0]}" ]]; then
    SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
    SCRIPT_NAME="$(basename -- "${BASH_SOURCE[0]}")"
    install -Dm0755 "${SCRIPT_DIR}/${SCRIPT_NAME}" "$POSTINST_TARGET"
else
    log_info "Skipping self-install to $POSTINST_TARGET (script not a file on disk)"
fi

# ---------- Done ----------
log_info "All done."
log_info "To remove:"
log_info "  rm -f \"$POSTINST_TARGET\""
log_info "  rm -f \"$SYSTEMD_SLEEP_FIX\""
log_info "  [[ -f \"$INITRD.bck.s3patch\" ]] && cp -a \"$INITRD.bck.s3patch\" \"$INITRD\""
log_info "  apt-get remove -y acpica-tools binwalk   # on Debian/Ubuntu"
log_info "  Manually remove flags from $GRUB_FILE: ${REQUIRED_KERNEL_FLAGS[*]}"

# Exit code 5 for your cron+notify logic:
exit 5
