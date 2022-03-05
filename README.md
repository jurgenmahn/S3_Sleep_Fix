# S3_Sleep_Fix

Hardware: Pavilion 15-eh1000 (Ryzen 5000) 
Software: Ubuntu 21.10 (But should work on all recent Debian / Ubuntu versions

Fixes the issue that the HP Pavilion 15-eh1000 (Ryzen 5000) doesnt go into S3 sleep under linux.

Issue: The HP Pavilion 15-eh1000 for some strange reason doent support S3 sleep. This script patches the ACPI table and adds the S3 mode.

Patch, basically add this block to the dsdt

+    Name (_S3, Package (0x04)  // _S3_: S3 System State
+    {
+        0x03, 
+        0x03, 
+        Zero, 
+        Zero
+    })


Somehow all USB controllers are not responding anymore after wakeup from S3, so a small script in /lib/systemd/system-sleep/ fixes this by unbinding and binding the USB devices

Also adds mem_sleep_default=deep and pcie_aspm=force to grub (pcie_aspm=force is not needed for this fis, but disabled without a good reason)