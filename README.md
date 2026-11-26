# makeipsw13: building a restore image for audioOS 13.4.8 (17M61)

    ./makeipsw13.sh  <17M61 ota.zip>  <AppleTV5,3_13.4.8_17M61_Restore.ipsw>  out.ipsw  firmware_keys_17M61.zip

## Why makeipsw.sh cannot build 13.4.8 (each checked against the real files)

1. **Payload format.** 13.x `payloadv2/payload.NNN` are pbzx record streams, not
   AppleArchive, so `yaa extract` cannot read them. There is no
   `payload_chunks.txt` and no `fixup.manifest`. -> `ota_payload_extract.py`.
2. **`data_payload` is not empty.** It holds the `/private/var` skeleton (75
   entries). makeipsw.sh stops with "not supported". Here it is extracted into
   the image; on an erase restore that content has to come from the OS image.
3. **Manifest keys that do not exist in 2020:** `Ap,ProductType`, `Ap,Target`,
   `Ap,TargetType`, `Ap,SystemVolumeCanonicalMetadata`. Product and hardware
   now come from the OTA `Info.plist`; the mtree check is dropped (13.x has no
   mtree) and replaced by an entry count.
4. **Encrypted loaders.** 17M61 iBSS/iBEC carry key bags and the shared
   `firmware_keys.zip` has no 17M61 entry. `firmware_keys_17M61.zip` is in the
   same JSON shape, with the IV/key pairs the pod produced on 2026-11-23
   (`oldfw/17M61/decrypt-*.log`) and the key bags read from the im4p files.
5. **Donor Info keys.** The Apple TV erase identity has `OSVarContentSize` and
   `MobileDeviceMinVersion`; they are copied across.

## Not verified, in the order I would expect trouble

* **The asr patch finder.** The Apple TV 13.4.8 restore ramdisk is a raw HFSX
  image inside an im4p; the string "Image failed signature verification." is
  not visible in the raw image (files are probably compressed), so whether
  `patchasr` finds it in the mounted `asr` is unknown.
* **APFS made by a current macOS, mounted by a 2020 kernel.** `diskutil` on a
  new macOS may set container or volume features the 13.4.8 kernel refuses.
  If the restore fails at mount or first boot, look here first.
* **KPP.** The 13.4.8 kernelcache carries a KPP image. Whether ra1nsn0w's
  kernel patches are tolerated for the length of a restore on this build is
  unknown.
* **Volume name** is a guess (`<train><build>.AudioAccessoryOS`); believed
  cosmetic.
* Whether the tvOS 13 `restored_external` accepts an AudioAccessory target the
  way the 18.x one does.

## ota_payload_extract.py

Record layout is documented at the top of the file. Checked on Linux against
the 17M61 OTA: 16,890 root entries plus 75 in `data_payload`, 89 symlinks with
correct targets, modes and times applied. Ownership needs root (the script runs
it under sudo).
