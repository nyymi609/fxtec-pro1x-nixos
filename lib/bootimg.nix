# Android boot.img parameters for the Pro1X.
{
  pagesize = "4096";
  base = "0x00000000";
  kernelOffset = "0x00008000";
  ramdiskOffset = "0x01000000";
  secondOffset = "0x00f00000";
  tagsOffset = "0x00000100";

  mkbootimgFlags = c:
    "--pagesize ${c.pagesize} --base ${c.base} --kernel_offset ${c.kernelOffset} "
    + "--ramdisk_offset ${c.ramdiskOffset} --second_offset ${c.secondOffset} "
    + "--tags_offset ${c.tagsOffset}";
}
