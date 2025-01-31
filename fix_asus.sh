#!/bin/bash

##
## Cron startup script incl notify
# add to sudoers
# jurgen ALL=(ALL:ALL) NOPASSWD: /home/jurgen/sleep_fix/fix.sh
# crontab
# */5 * * * * sudo /home/jurgen/sleep_fix/fix.sh ; [[ $? -eq 5 ]] && /usr/bin/notify-send "Sleep fix script updated, need a reboot"

## diff -Naru orig_dsdt.dsl dsdt.dsl 

####### dsdt patch data ########

PATCH=$(cat <<EOF
--- orig_dsdt.dsl	2025-01-30 20:24:47.000217836 +0100
+++ dsdt.dsl	2025-01-30 19:54:38.981725330 +0100
@@ -18,7 +18,7 @@
  *     Compiler ID      "INTL"
  *     Compiler Version 0x20200717 (538969879)
  */
-DefinitionBlock ("", "DSDT", 2, "_ASUS_", "Notebook", 0x01072009)
+DefinitionBlock ("", "DSDT", 2, "_ASUS_", "Notebook", 0x01072010)
 {
     External (_SB_.ALIB, MethodObj)    // 2 Arguments
     External (_SB_.APTS, MethodObj)    // 1 Arguments
@@ -3067,7 +3067,14 @@
         Zero, 
         Zero, 
         Zero
-    })  
+    })
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

SUSPEND_SCRIPT=$(cat <<'EOF'
#!/bin/bash

if [ "${1}" == "pre" ]; then
    rm /tmp/usb_devices -f;find  /sys/bus/pci/drivers/xhci_hcd -name '0000*' | xargs -i bash -c 'echo $(basename {}) >> /tmp/usb_devices'
    while read p; do
        echo "$p" > /sys/bus/pci/drivers/xhci_hcd/unbind
    done </tmp/usb_devices
elif [ "${1}" == "post" ]; then
    while read p; do
        echo "$p" > /sys/bus/pci/drivers/xhci_hcd/bind
    done </tmp/usb_devices
fi
EOF
)

####### Fix sleep bug HP pavillion linux HP Pavilion 15.6 inch Laptop PC 15-eh1000 (2H5A7AV) ########
RED="\e[1;31m"
GREEN="\e[1;32m"
NC="\e[0m"

redEcho () {
  printf "\n${RED}${1}${NC}\n\n"
  logger "S3 Patch script " ${1}
}

greenEcho () {
  printf "\n${GREEN}${1}${NC}\n\n"
  logger "S3 Patch script " ${1}
}

# check if we are root
if [[ $EUID -ne 0 ]]; then
   redEcho "The S3 Patch script can only be started as root user, exiting now"
   exit 1
fi

greenEcho "S3 Patch script started"

greenEcho "Lets see if we need to run"
MEMSLEEP=$(cat /sys/power/mem_sleep)

greenEcho "Current sleep state $MEMSLEEP"

S2IDLE=$(cat /sys/power/mem_sleep|grep '\[s2idle\]')
DEEP=$(cat /sys/power/mem_sleep|grep '\[deep\]')

greenEcho "S2IDLE State $S2IDLE"
greenEcho "DEEP State $DEEP"

if [[ ! -z "$DEEP" ]]; then
    greenEcho "Deep sleep already active, exiting script"
    exit 0;
fi

# install iasl tools (ubuntu/debian) and binwalk, to extract the initrd
# apt update
# apt install -y acpica-tools binwalk

if ! which iasl > /dev/null; then
   redEcho "iasl is not installed on Ubuntu / debian `apt install acpica-tools`";
   exit 1;
fi

if ! which binwalk > /dev/null; then
   redEcho "binwalk is not installed on Ubuntu / debian `apt install binwalk`";
   exit 1;
fi

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

mkdir /tmp/sleep_fix -p
rm -rf /tmp/sleep_fix/*
cd /tmp/sleep_fix

# get original dsdt
cat /sys/firmware/acpi/tables/DSDT > dsdt.aml
# decompile it
iasl -d dsdt.aml
## patch it
echo "$PATCH" | patch --ignore-whitespace  -N

## That doesnt work if the script runs unattented after a kernel update :)
# greenEcho "check if the patch is applied successfully or else exit the script with CRTL-C"
# read -rsn1 -p"Press any key to continue";echo

# compile it again -ve to make it less verbose
iasl -ve  dsdt.dsl

# build structure for kernel
mkdir -p kernel/firmware/acpi
cp dsdt.aml kernel/firmware/acpi/
find kernel | cpio -H newc --create > dsdt_patch

# get current initrd image
INITRD="/boot/initrd.img-$(uname -r)"
greenEcho "Found running initrd.img $INITRD"

# grub setting file
GRUB="/etc/default/grub"

## DEBUG
#cp $INITRD.bck /tmp/initrd
#INITRD="/tmp/initrd"
#cp /etc/default/grub /tmp/grub
#GRUB="/tmp/grub"
## END

# check if file is not patched yet
greenEcho "Checking if initrd is already patched, this can take a few seconds"
if binwalk $INITRD|grep "kernel/firmware/acpi/dsdt.aml"; then
    redEcho "File is already patched, ignore initrd update"
else
    greenEcho "Patching initrd"
    # make a backup if the backup does not exist yet
    cp -n $INITRD $INITRD.bck.s3patch
    cat dsdt_patch $INITRD.bck.s3patch > $(basename $INITRD)
    cp $(basename $INITRD) $INITRD
    greenEcho "yeah initrd is patched"
fi

# adding mem_sleep_default=deep to grub and pcie_aspm=force since its disabled without a reason
GRUB_CMDLINE=""
if ! cat $GRUB|grep -E "(GRUB_CMDLINE_LINUX_DEFAULT.+mem_sleep_default=deep)"; then
    greenEcho "Adding mem_sleep_default=deep to grub cmdline"
    GRUB_CMDLINE=" mem_sleep_default=deep"
fi

if ! cat $GRUB|grep -E "(GRUB_CMDLINE_LINUX_DEFAULT.+pcie_aspm=force)"; then
    greenEcho "Adding pcie_aspm=force to grub cmdline"
    GRUB_CMDLINE=$GRUB_CMDLINE" pcie_aspm=force"
fi

greenEcho "appending $GRUB_CMDLINE to GRUB_CMDLINE_LINUX_DEFAULT"
ORIG_GRUB_CMDLINE=$(grep -oP 'GRUB_CMDLINE_LINUX_DEFAULT="[^"]+' $GRUB)
greenEcho $ORIG_GRUB_CMDLINE
sed -i "s/$ORIG_GRUB_CMDLINE/$ORIG_GRUB_CMDLINE$GRUB_CMDLINE/" $GRUB
greenEcho "grub settings patched from"
redEcho $ORIG_GRUB_CMDLINE
greenEcho "to"
greenEcho $ORIG_GRUB_CMDLINE$GRUB_CMDLINE

update-grub

# work around for the USB system which doesnt come back after sleep
echo "$SUSPEND_SCRIPT" | tee /lib/systemd/system-sleep/usb_wakeup_fix_s3.sh
chmod +x /lib/systemd/system-sleep/usb_wakeup_fix_s3.sh

# Copy myself to /etc/kernel/postinst.d/ so runs after a kernel update
cp $SCRIPT_DIR/$(basename $0) /etc/kernel/postinst.d/yy-s3-sleep-fix
chmod +x /etc/kernel/postinst.d/yy-s3-sleep-fix

# done
greenEcho " "
greenEcho "All done"
greenEcho "To remove everything:"
greenEcho "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"
greenEcho "rm /etc/kernel/postinst.d/yy-s3-sleep-fix"
greenEcho "rm /lib/systemd/system-sleep/usb_wakeup_fix_s3.sh"
greenEcho "mv $INITRD.bck.s3patch $INITRD"
greenEcho "apt remove acpica-tools binwalk"
greenEcho "Manualy remove 'mem_sleep_default=deep' and 'pcie_aspm=force' from /etc/default/grub"
greenEcho "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"

# 5 triggers the notify script
exit 5;