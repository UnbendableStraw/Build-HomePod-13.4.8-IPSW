# makeipsw13: building a restore image for audioOS 13.4.8 (17M61)

    ./makeipsw13.sh  <17M61 ota.zip>  <AppleTV5,3_13.4.8_17M61_Restore.ipsw>  out.ipsw  firmware_keys_17M61.zip

## Why makeipsw.sh originally couldn't build 13.4.8

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


## ota_payload_extract.py

Record layout is documented at the top of the file. Checked on Linux against
the 17M61 OTA: 16,890 root entries plus 75 in `data_payload`, 89 symlinks with
correct targets, modes and times applied. Ownership needs root (the script runs
it under sudo).

Tested working on real hardware, from setup to reset; https://x.com/NicFixEm/status/2125745502939750523?a=dZBh7l_8-ByZXQt-Mf8&s=20
