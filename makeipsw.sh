#!/bin/bash


# makeipsw13.sh: makeipsw.sh adapted for 13.x-style OTAs (audioOS 13.4.8 / 17M61).
# Differences from makeipsw.sh are listed in README.md next to this file.
SCRIPTDIR="$(cd "$(dirname "$0")" && pwd)"

## DO NOT MODIFY VARIABLES BELOW THIS LINE ##
tmpdir=""

help(){
  echo "Usage: makeipsw13.sh <ota.zip> <donor.ipsw> <output.ipsw> [keys-zip.zip]"
}

cleanup(){
  echo "Performing cleanup"

  echo "Deleting '${tmpdir}'"
  rm -rf ${tmpdir} 2>/dev/null || sudo rm -rf ${tmpdir}
}

getTicket(){
  target=$1
  buildmanifest=$2
  output=$3
  if [ "x${target}" == "x" ] || [ "x${buildmanifest}" == "x" ] || [ "x${output}" == "x" ]; then
    echo "Arguments error in getTicket"
    exit 1
  fi
  echo "Getting OTA ticket for target '${target}'"
  tsschecker -d "${target}" -m "${buildmanifest}" -s"${output}"
}

patchasr(){
  asrpath=$1
  if [ "x${asrpath}" == "x" ]; then
    echo "Arguments error in patchasr"
    exit 1
  fi

  strloc=$(binrider --string "Image failed signature verification." "${asrpath}" | grep "Found 'Image failed signature verification.' at" | rev | cut -d ' ' -f1 | rev)
  echo "strloc=${strloc}"
  if [ "x${strloc}" == "x" ]; then
    # 13.x asr: the message has no trailing full stop, so the finder above misses it. The check is a memcmp of the computed image hash against --expectedhash (Apple's OS image digest), followed by
    #     0x10002469c  cbnz w0, <print "Image failed signature verification">
    # Patch that one branch out. Offsets are for the 17M61 Apple TV ramdisk asr and are only applied if the bytes there are exactly that instruction.
    fof=$((0x2469c))
    have=$(xxd -s ${fof} -l 4 -p "${asrpath}")
    if [ "${have}" != "20110035" ]; then
      echo "asr: unexpected bytes '${have}' at 0x2469c, not patching. Stopping."
      exit 3
    fi
    echo "Patching asr hash compare at file offset 0x2469c"
    echo -en "\x1F\x20\x03\xD5" | sudo dd of="${asrpath}" bs=1 seek=${fof} conv=notrunc count=4
    echo "Resigning file"
    sudo ldid -s "${asrpath}"
    return 0
  fi
  strref=$(binrider --xref "${strloc}" "${asrpath}" | grep "Found xrefs at" | rev | cut -d ' ' -f1 | rev)
  echo "strref=${strref}"
  bof=$(binrider --bof "${strref}" "${asrpath}" | grep "Found beginning of function at" | rev | cut -d ' ' -f1 | rev)
  echo "bof=${bof}"
  cref=$(binrider --cref "${bof}" "${asrpath}" | grep "Found call refs at" | rev | cut -d ' ' -f1 | rev)
  echo "cref=${cref}"
  paddr=""
  for i in $(seq 0 4 0x30); do
    tgtdec=$((${cref} - ${i}))
    tgt=$(printf '0x%x\n' ${tgtdec})
    failstr="No refs found to ${tgt}"
    bref=$(binrider --bref "${tgt}" "${asrpath}")
    if echo "${bref}" | grep "${failstr}"; then
      continue
    fi
    paddr=$(echo "${bref}" | grep "Found branch refs at" | head -n1 | rev | cut -d ' ' -f1 | rev)
    break
  done
  if [ "x${paddr}" == "x" ]; then
    echo "Patchfinder failed to find patch addr"
    exit 3
  fi
  echo "Found patch address at '${paddr}'"
  fof=$(binrider --fof "${paddr}" "${asrpath}" | grep "Found fileoffset at" | rev | cut -d ' ' -f1 | rev)
  echo "fof=${fof}"

  echo "Patching file"
  echo -en "\x1F\x20\x03\xD5" | sudo dd of="${asrpath}" bs=1 seek=$((${fof})) conv=notrunc count=4

  echo "Resigning file"
  sudo ldid -s "${asrpath}"
}

makerootfs(){
  otadir="$1"
  outramdisk="$2"
  wrkdir="$3"
  if [ "x${otadir}" == "x" ] || [ "x${outramdisk}" == "x" ] || [ "x${wrkdir}" == "x" ]; then
    echo "Arguments error in makerootfs"
    exit 1
  fi

  echo "Creating a rootfs needs root. You may be asked for your password."
  sudo echo "ok" || exit 99

  pv2="${otadir}/AssetData/payloadv2"
  # 13.x OTAs: pbzx record stream, not AppleArchive. No payload_chunks.txt,
  # no fixup.manifest, no mtree. links.txt must be empty (hard links unhandled).
  if [[ -s "${pv2}/links.txt" ]]; then
    echo "Image contains hard links (links.txt), not handled."
    exit 1
  fi
  if [[ "$(head -c 4 "${pv2}/payload.000")" != "pbzx" ]]; then
    echo "payload.000 is not a pbzx stream; this script is for 13.x-style OTAs only."
    exit 1
  fi

  rootfsdir="${wrkdir}/rootfs"
  mkdir -p "${rootfsdir}"

  chunks=()
  for f in "${pv2}"/payload.[0-9][0-9][0-9]; do chunks+=("$f"); done
  # data_payload holds the /private/var skeleton. On an erase restore it has to
  # be in the OS image; restored moves it to the Data volume.
  if [[ -s "${pv2}/data_payload" ]]; then chunks+=("${pv2}/data_payload"); fi
  echo "Extracting ${#chunks[@]} chunks..."
  sudo /usr/bin/python3 "${SCRIPTDIR}/ota_payload_extract.py" "${rootfsdir}" "${chunks[@]}" || exit 1

  # copy UNMODIFIED update ramdisk to rootfs
  sudo mkdir -p "${rootfsdir}/usr/standalone/update/ramdisk"
  sudo cp -a "${otadir}/AssetData/payload/replace/usr/standalone/update/ramdisk/arm64SURamDisk.dmg" "${rootfsdir}/usr/standalone/update/ramdisk/"
  sudo chown root:wheel "${rootfsdir}/usr/standalone/update/ramdisk/arm64SURamDisk.dmg"
  sudo chmod 644 "${rootfsdir}/usr/standalone/update/ramdisk/arm64SURamDisk.dmg"
  sudo /usr/bin/xattr -c "${rootfsdir}/usr/standalone/update/ramdisk/arm64SURamDisk.dmg"

  BUILDTRAIN="$(/usr/bin/plutil -extract "BuildIdentities".0."Info"."BuildTrain" raw -o - "${otadir}/AssetData/boot/BuildManifest.plist")"
  BUILDNUMBER="$(/usr/bin/plutil -extract "BuildIdentities".0."Info"."BuildNumber" raw -o - "${otadir}/AssetData/boot/BuildManifest.plist")"
  UNIQUEBUILDID="$(/usr/bin/plutil -extract  "BuildIdentities".0."UniqueBuildID" raw -o - "${otadir}/AssetData/boot/BuildManifest.plist")"
  # 13.x manifests have no Ap,TargetType. The volume name is cosmetic.
  VOLNAME="${BUILDTRAIN}${BUILDNUMBER}.AudioAccessoryOS"
  IMGSIZE_MB=$(($(sudo du -A -s -m "${rootfsdir}" | awk '{ print $1 }')+100))

  echo "Creating a dmg with ${IMGSIZE_MB} MB"
  IMGFILEINFO="$(hdiutil create -megabytes "${IMGSIZE_MB}" -layout NONE -attach -volname RESTORE -fs 'exFAT' "${wrkdir}/os.udrw.dmg")"
  IMGNODE="$(echo "$IMGFILEINFO" | head -n1 | awk '{print $1}')"
  diskutil unmountDisk "${IMGNODE}"
  diskutil partitionDisk -noEFI ${IMGNODE} 1 "GPT" "Free Space" "${VOLNAME}" 100
  APFSOUTPUT="$(diskutil apfs createContainer "${IMGNODE}")"
  APFSNODE="$(echo "$APFSOUTPUT" | grep 'Disk from APFS operation' | awk '{print $5}')"
  APFSVOLOUTPUT="$(diskutil apfs addVolume "${APFSNODE}" "Case-sensitive APFS" "${VOLNAME}" -role S)"
  APFSVOLNODE="$(echo "$APFSVOLOUTPUT" | grep 'Disk from APFS operation' | awk '{print $5}')"

  sudo diskutil enableOwnership ${APFSVOLNODE}

  if [[ $(diskutil info "${APFSVOLNODE}" | grep 'Mounted' | grep 'Yes') ]]; then
    MOUNTPOINT="$(diskutil info "${APFSVOLNODE}" | grep 'Mount Point' | sed 's/[[:space:]]*Mount\ Point:[[:space:]]*//')"
  else
    echo "Disk image is not mounted or could not determine mountpoint."
    exit 1
  fi

  echo "Copying to ${APFSVOLNODE} aka ${MOUNTPOINT}"
  sudo ditto "${rootfsdir}" "${MOUNTPOINT}"
  sudo rm -rf "${MOUNTPOINT}/.fseventsd"

  # No mtree in 13.x. Sanity check instead: count entries against the source.
  echo "Entries in image: $(sudo find "${MOUNTPOINT}" | wc -l)  in extraction: $(sudo find "${rootfsdir}" | wc -l)"

  hdiutil detach "${MOUNTPOINT}"

  echo hdiutil convert -format ULFO -o "${outramdisk}" "${wrkdir}/os.udrw.dmg"
  hdiutil convert -format ULFO -o "${outramdisk}" "${wrkdir}/os.udrw.dmg"
  asr imagescan --source "${outramdisk}"
  echo "Done creating rootfs"
}

##### MAIN ######
main(){
  otaPath=$1
  donorPath=$2
  outputPath=$3
  keysPath=$4

  if [ "x${otaPath}" == "x" ] || [ "x${donorPath}" == "x" ] || [ "x${outputPath}" == "x" ]; then
    help
    exit 1
  fi

  echo "otaPath=${otaPath}"
  echo "donorPath=${donorPath}"
  echo "outputPath=${outputPath}"

  for v in otaPath donorPath keysPath; do
    p="${!v}"; [ -n "$p" ] || continue
    [ -f "$p" ] || { echo "No such file: $p"; exit 1; }
    printf -v "$v" '%s' "$(cd "$(dirname "$p")" && pwd)/$(basename "$p")"
  done

  tmpdir=$(mktemp -d /tmp/homepodtmpXXXXXXXXXX)
  echo "tmpdir=${tmpdir}"
  ipswdir=${tmpdir}/ipsw
  otadir=${tmpdir}/ota
  ra1nsn0wdir=${tmpdir}/ra1nsn0w
  rootfswrkdir=${tmpdir}/rootfswrkdir
  mkdir -p ${ipswdir}
  mkdir -p ${otadir}
  mkdir -p ${ra1nsn0wdir}
  mkdir -p ${rootfswrkdir}

  echo "extracting ota to '${otadir}'"
  unzip -q "${otaPath}" -d "${otadir}" || { echo "Could not unzip the OTA"; exit 1; }

  # Set PREBUILT_ROOTFS=/path/to/myrootfs.dmg to reuse the image from an earlier run.
  if [[ -n "${PREBUILT_ROOTFS}" && -f "${PREBUILT_ROOTFS}" ]]; then
    echo "Reusing root filesystem image ${PREBUILT_ROOTFS}"
    cp "${PREBUILT_ROOTFS}" "${ipswdir}/myrootfs.dmg"
    UNIQUEBUILDID="$(/usr/bin/plutil -extract "BuildIdentities".0."UniqueBuildID" raw -o - "${otadir}/AssetData/boot/BuildManifest.plist")"
  else
    makerootfs ${otadir} "${ipswdir}/myrootfs.dmg" ${rootfswrkdir}
  fi

  mv "${otadir}/AssetData/boot/"* "${ipswdir}/"
  rm -rf "${otadir}/AssetData/boot/"

  # 13.x manifests have no Ap,ProductType / Ap,Target; the OTA Info.plist has them.
  targetProduct=$(plutil -extract "ProductType" raw "${otadir}/AssetData/Info.plist")
  targetHardware=$(plutil -extract "HardwareModel" raw "${otadir}/AssetData/Info.plist")
  echo "Found target: '${targetProduct}' '${targetHardware}"
  getTicket ${targetProduct} "${ipswdir}/BuildManifest.plist" "${tmpdir}/ticket.shsh2"

  # No --ipatch-no-force-dfu: ra1nsn0w's finder for it fails on iBoot-5540.
  # That patch only disables the upside-down check, so keep the pod UPRIGHT
  # for the whole restore (the check sits at file offset 0x11354 in this iBEC).
  ra1nsn0w -t "${tmpdir}/ticket.shsh2" \
    --kpatch-codesignature \
    -b "rd=md0 -v serial=3 nand-enable-reformat=1 -restore" \
    --dry-run "${targetProduct}":"${targetHardware}":1 \
    --dry-out "${ra1nsn0wdir}" \
    --ota "${otaPath}" \
    ${keysPath:+--keys-zip "${keysPath}"}

  if [[ ! -f "${ra1nsn0wdir}/component1.bin" || ! -f "${ra1nsn0wdir}/component2.bin" ]]; then
    echo "ra1nsn0w did not produce patched boot loaders (wrong keys?). Stopping."
    exit 4
  fi

  iBSSPathPart=$(plutil -extract "BuildIdentities".0.Manifest.iBSS.Info.Path raw "${ipswdir}/BuildManifest.plist")
  iBECPathPart=$(plutil -extract "BuildIdentities".0.Manifest.iBEC.Info.Path raw "${ipswdir}/BuildManifest.plist")

  echo "Deploying patched bootloaders"

  rm "${ipswdir}/${iBSSPathPart}"
  img4tool -e -p "${ipswdir}/${iBSSPathPart}" "${ra1nsn0wdir}/component1.bin"

  rm "${ipswdir}/${iBECPathPart}"
  img4tool -e -p "${ipswdir}/${iBECPathPart}" "${ra1nsn0wdir}/component2.bin"

  echo "Deploying patched kernel"

  ra1nsn0wLastComponent=$(ls -l ${ra1nsn0wdir} | tail -n1 | rev | cut -d ' ' -f1 | rev)
  img4tool -e -p "${ipswdir}/restorekernel.im4p" "${ra1nsn0wdir}/${ra1nsn0wLastComponent}"

  plutil -replace "BuildIdentities".0.Manifest.RestoreKernelCache.Info.Path -string restorekernel.im4p -o "${ipswdir}/BuildManifest_new.plist" "${ipswdir}/BuildManifest.plist"
  mv -f "${ipswdir}/BuildManifest_new.plist" "${ipswdir}/BuildManifest.plist"

  echo "Extract donor BuildManifest.plist"
  unzip -o "${donorPath}" -d "${tmpdir}" BuildManifest.plist

  cntIdentites=$(plutil -extract "BuildIdentities" raw ${tmpdir}/BuildManifest.plist)
  foundident="-1"
  echo "Donor has ${cntIdentites} buildidentities"
  for i in $(seq 0 $((${cntIdentites}-1))); do
    echo "checking ident ${i}..."
    variant=$(plutil -extract "BuildIdentities.${i}.Info.Variant" raw ${tmpdir}/BuildManifest.plist)
    if echo ${variant} | grep "Customer Erase Install (IPSW)"; then
      foundident=${i}
      break
    fi
  done

  if [[ $foundident  -eq "-1" ]]; then
    echo "Failed to find target buildidentity"
    exit 2
  fi
  echo "Found target buildidentity (${foundident}), getting ramdisk"
  restoreramdisk=$(plutil -extract "BuildIdentities.${foundident}.Manifest.RestoreRamDisk.Info.Path" raw ${tmpdir}/BuildManifest.plist)

  echo "Extracting ramdisk '${restoreramdisk}'"
  unzip -o "${donorPath}" -d "${tmpdir}" "${restoreramdisk}"
  img4tool -e -o "${tmpdir}/rdsk.dmg" "${tmpdir}/${restoreramdisk}"

  echo "Mounting ramdisk"
  mntpoint=$(hdiutil attach "${tmpdir}/rdsk.dmg" | tail -n1 | cut -d $'\t' -f3)
  echo "Ramdisk mounted at '${mntpoint}'"

  if [[ ! -f "${mntpoint}/usr/local/bin/restored_external" ]]; then
    echo "Ramdisk does not contain a restored_external binary. Either the ipsw is corrupt/incorrect, or this script has a bug."
    exit 3
  fi

  echo "Patching asr"
  patchasr "${mntpoint}/usr/sbin/asr"

  echo "Unmounting ramdisk"
  hdiutil detach "${mntpoint}"

  # RestoreTrustCache is left as Apple's file for this build. Its digest is in
  # the manifest and in the ticket request, so it must not be swapped; the
  # donor ramdisk's binaries are covered by the kernel code-signing patch.

  echo "Patching RestoreRamDisk path in BuildManifest"
  plutil -replace "BuildIdentities".0.Manifest.RestoreRamDisk.Info.Path -string myramdisk.dmg -o "${ipswdir}/BuildManifest_new.plist" "${ipswdir}/BuildManifest.plist"
  mv -f "${ipswdir}/BuildManifest_new.plist" "${ipswdir}/BuildManifest.plist"

  echo "Packing ramdisk to im4p file"
  img4tool -c "${ipswdir}/myramdisk.dmg" -t rdsk "${tmpdir}/rdsk.dmg"

  echo "Patching OS path in BuildManifest"
  plutil -replace "BuildIdentities".0.Manifest.OS.Info.Path -string myrootfs.dmg -o "${ipswdir}/BuildManifest_new.plist" "${ipswdir}/BuildManifest.plist"
  mv -f "${ipswdir}/BuildManifest_new.plist" "${ipswdir}/BuildManifest.plist"

  echo "Setting Restore behavior in BuildManifest"
  plutil -replace "BuildIdentities".0.Info.RestoreBehavior -string "Erase" -o "${ipswdir}/BuildManifest_new.plist" "${ipswdir}/BuildManifest.plist"
  mv -f "${ipswdir}/BuildManifest_new.plist" "${ipswdir}/BuildManifest.plist"

  echo "Setting Variant in BuildManifest to match Erase Install"
  plutil -replace "BuildIdentities".0.Info.Variant -string "Customer Erase Install (IPSW)" -o "${ipswdir}/BuildManifest_new.plist" "${ipswdir}/BuildManifest.plist"
  mv -f "${ipswdir}/BuildManifest_new.plist" "${ipswdir}/BuildManifest.plist"

  echo "Setting RecoveryVariant in BuildManifest to match Recovery Customer Install"
  plutil -replace "BuildIdentities".0.Info.RecoveryVariant -string "Recovery Customer Install" -o "${ipswdir}/BuildManifest_new.plist" "${ipswdir}/BuildManifest.plist"
  mv -f "${ipswdir}/BuildManifest_new.plist" "${ipswdir}/BuildManifest.plist"

  echo "Setting RecoveryVariant in BuildManifest to match Recovery Customer Install"
  plutil -replace "BuildIdentities".0.Info.RecoveryVariant -string "Recovery Customer Install" -o "${ipswdir}/BuildManifest_new.plist" "${ipswdir}/BuildManifest.plist"
  mv -f "${ipswdir}/BuildManifest_new.plist" "${ipswdir}/BuildManifest.plist"

  # The donor's erase identity carries two Info keys the OTA manifest lacks.
  for k in OSVarContentSize MobileDeviceMinVersion; do
    v=$(plutil -extract "BuildIdentities.${foundident}.Info.${k}" raw ${tmpdir}/BuildManifest.plist 2>/dev/null) || continue
    if [[ "$k" == "OSVarContentSize" ]]; then t="-integer"; else t="-string"; fi
    plutil -replace "BuildIdentities".0.Info.${k} ${t} "${v}" -o "${ipswdir}/BuildManifest_new.plist" "${ipswdir}/BuildManifest.plist"
    mv -f "${ipswdir}/BuildManifest_new.plist" "${ipswdir}/BuildManifest.plist"
  done

  echo "Setting UniqueBuildID in BuildManifest to OTA UUID"
  plutil -replace "BuildIdentities".0.UniqueBuildID -data "${UNIQUEBUILDID}" -o "${ipswdir}/BuildManifest_new.plist" "${ipswdir}/BuildManifest.plist"
  mv -f "${ipswdir}/BuildManifest_new.plist" "${ipswdir}/BuildManifest.plist"

  echo "Compressing IPSW"

  (
    cd "${ipswdir}"
    zip -r "${tmpdir}/mycfw.ipsw" .
  )
  mv "${tmpdir}/mycfw.ipsw" "${outputPath}"

  cleanup
  echo "Done!!"
}

main "$@"
