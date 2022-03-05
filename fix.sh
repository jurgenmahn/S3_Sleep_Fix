#!/bin/bash

####### dsdt patch data ########

PATCH=$(cat <<EOF
--- dsdt_original.dsl	2022-03-05 10:21:26.206900527 +0100
+++ dsdt.dsl	2022-03-05 10:07:51.804059570 +0100
@@ -18,7 +18,7 @@
  *     Compiler ID      "INTL"
  *     Compiler Version 0x20200925 (538970405)
  */
-DefinitionBlock ("", "DSDT", 2, "HPQOEM", "88D0    ", 0x01072009)
+DefinitionBlock ("", "DSDT", 2, "HPQOEM", "88D0    ", 0x01072010)
 {
     External (_PR_.P000, UnknownObj)
     External (_PR_.P000.PPCV, IntObj)
@@ -3089,6 +3089,13 @@
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
@@ -10462,24 +10469,6 @@
                     }
                     Case (0x03)
                     {
-                        DerefOf (Local0 [0x02]) [One] = Zero
-                        DerefOf (Local0 [0x02]) [0x02] = Zero
-                        DerefOf (Local0 [0x02]) [0x03] = Zero
-                        DerefOf (Local0 [0x02]) [0x04] = Zero
-                        DerefOf (Local0 [0x02]) [0x05] = Zero
-                        DerefOf (Local0 [0x02]) [0x06] = Zero
-                        DerefOf (Local0 [0x02]) [0x07] = Zero
-                        DerefOf (Local0 [0x02]) [0x08] = Zero
-                        DerefOf (Local0 [0x02]) [0x09] = Zero
-                        DerefOf (Local0 [0x02]) [0x0A] = Zero
-                        DerefOf (Local0 [0x02]) [0x0B] = Zero
-                        DerefOf (Local0 [0x02]) [0x0C] = Zero
-                        DerefOf (Local0 [0x02]) [0x0D] = Zero
-                        DerefOf (Local0 [0x02]) [0x0E] = Zero
-                        DerefOf (Local0 [0x02]) [0x0F] = Zero
-                    }
-                    Case (0x03)
-                    {
                         DerefOf (Local0 [0x02]) [One] = Zero
                         DerefOf (Local0 [0x02]) [0x02] = Zero
                         DerefOf (Local0 [0x02]) [0x03] = Zero
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

# install iasl tools (ubuntu/debian) and binwalk, to extract the initrd
#sudo apt update
sudo apt install -y acpica-tools binwalk

mkdir sleep_fix -p
rm -rf sleep_fix/*
cd sleep_fix

# get original dsdt
sudo cat /sys/firmware/acpi/tables/DSDT > dsdt.aml
# decompile it
iasl -d dsdt.aml
## patch it
echo "$PATCH" | patch --ignore-whitespace -s -N
# compile it again
iasl dsdt.dsl

# build structure for kernel
mkdir -p kernel/firmware/acpi
sudo cp dsdt.aml kernel/firmware/acpi/
find kernel | cpio -H newc --create > dsdt_patch

# get current initrd image
INITRD="/boot/initrd.img-$(uname -r)"
echo "Found running initrd.img $INITRD"

# grub setting file
GRUB="/etc/default/grub"

## DEBUG
#cp $INITRD.bck /tmp/initrd
#INITRD="/tmp/initrd"
#cp /etc/default/grub /tmp/grub
#GRUB="/tmp/grub"
## END

# check if file is not patched yet
echo "Checking if initrd is already patched, this can take a few seconds"
if binwalk $INITRD|grep "kernel/firmware/acpi/dsdt.aml"; then
    echo "File is already patched, ignore initrd update"
else
    echo "Patching initrd"
    # make a backup if the backup does not exist yet
    sudo cp -n $INITRD $INITRD.bck.s3patch
    sudo cat dsdt_patch $INITRD.bck.s3patch > $INITRD
    echo "yeah initrd is patched"
fi

# adding mem_sleep_default=deep to grub and pcie_aspm=force since its disabled without a reason
GRUB_CMDLINE=""
if ! cat $GRUB|grep -E "(GRUB_CMDLINE_LINUX_DEFAULT.+mem_sleep_default=deep)"; then
    echo "Adding mem_sleep_default=deep to grub cmdline"
    GRUB_CMDLINE=" mem_sleep_default=deep"
fi

if ! cat $GRUB|grep -E "(GRUB_CMDLINE_LINUX_DEFAULT.+pcie_aspm=force)"; then
    echo "Adding pcie_aspm=force to grub cmdline"
    GRUB_CMDLINE=$GRUB_CMDLINE" pcie_aspm=force"
fi

echo "appending $GRUB_CMDLINE to GRUB_CMDLINE_LINUX_DEFAULT"
ORIG_GRUB_CMDLINE=$(grep -oP 'GRUB_CMDLINE_LINUX_DEFAULT="[^"]+' $GRUB)
echo $ORIG_GRUB_CMDLINE
sed -i "s/$ORIG_GRUB_CMDLINE/$ORIG_GRUB_CMDLINE$GRUB_CMDLINE/" $GRUB
echo "grub settings patched"
cat $GRUB 
sudo update-grub

# work around for the USB system which doesnt come back after sleep
echo "$SUSPEND_SCRIPT" | sudo tee /lib/systemd/system-sleep/usb_wakeup_fix_s3.sh
sudo chmod +x /lib/systemd/system-sleep/usb_wakeup_fix_s3.sh