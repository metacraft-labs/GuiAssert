## Reads the DLL names a Windows PE image imports, from its import directory.
##
## The core purity test asks which DLLs a probe binary links. On Windows it
## used to shell out to `objdump -p`, and that call hung for 90 minutes on the
## shared CI runner with no output, so this module reads the same table
## in-process instead. It needs no external tool, runs on every platform, and
## can be checked on Linux against any PE file.
##
## The layout follows Microsoft's PE format specification: the DOS header
## points at the `PE\0\0` signature, which is followed by the COFF header,
## the optional header (PE32 or PE32+) with its data directories, and the
## section table. Data directory 1 is the import directory: a list of 20-byte
## descriptors ended by an all-zero one, each naming its DLL by RVA.
## https://learn.microsoft.com/en-us/windows/win32/debug/pe-format

proc readU16(image: string, off: int): int =
  if off < 0 or off + 2 > image.len:
    raise newException(ValueError, "PE: read of 2 bytes past the end at " & $off)
  result = int(uint8(image[off])) or (int(uint8(image[off + 1])) shl 8)

proc readU32(image: string, off: int): int =
  if off < 0 or off + 4 > image.len:
    raise newException(ValueError, "PE: read of 4 bytes past the end at " & $off)
  result = readU16(image, off) or (readU16(image, off + 2) shl 16)

proc readCString(image: string, off: int): string =
  var stop = off
  while stop < image.len and image[stop] != '\0': inc stop
  if stop >= image.len:
    raise newException(ValueError, "PE: unterminated name at " & $off)
  result = image[off ..< stop]

proc peImportNames*(image: string): seq[string] =
  ## The DLL names in the import directory of `image`, in table order, as the
  ## image spells them (`KERNEL32.dll`, `libstdc++-6.dll`, ...). An image with
  ## no import directory returns an empty sequence. Raises `ValueError` when
  ## the bytes are not a PE image or the tables point outside the file.
  if image.len < 0x40 or image[0 .. 1] != "MZ":
    raise newException(ValueError, "not a PE image: no MZ header")
  let sig = readU32(image, 0x3C)
  if sig + 4 > image.len or image[sig ..< sig + 4] != "PE\0\0":
    raise newException(ValueError, "not a PE image: no PE signature")

  let coff = sig + 4
  let sectionCount = readU16(image, coff + 2)
  let optionalSize = readU16(image, coff + 16)
  let optional = coff + 20

  # PE32 and PE32+ differ in where the data directories start (96 and 112
  # bytes into the optional header), and the directory count sits just
  # before them.
  let dataDirs = case readU16(image, optional)
    of 0x10B: optional + 96
    of 0x20B: optional + 112
    else: raise newException(ValueError, "PE: unknown optional header magic")
  if readU32(image, dataDirs - 4) < 2:
    return @[]
  let importRva = readU32(image, dataDirs + 8)
  if importRva == 0:
    return @[]

  # Section headers are 40 bytes each, right after the optional header. A
  # section maps RVAs in [address, address + max(virtual, raw)) to the file
  # offset `rawPointer` onwards.
  let sections = optional + optionalSize
  proc fileOffset(rva: int): int =
    for i in 0 ..< sectionCount:
      let s = sections + 40 * i
      let address = readU32(image, s + 12)
      let span = max(readU32(image, s + 8), readU32(image, s + 16))
      if rva >= address and rva < address + span:
        return readU32(image, s + 20) + (rva - address)
    raise newException(ValueError, "PE: RVA " & $rva & " lies in no section")

  let table = fileOffset(importRva)
  var i = 0
  while true:
    let d = table + 20 * i
    # OriginalFirstThunk, Name, and FirstThunk all zero marks the end.
    if readU32(image, d) == 0 and readU32(image, d + 12) == 0 and
       readU32(image, d + 16) == 0:
      break
    result.add readCString(image, fileOffset(readU32(image, d + 12)))
    inc i
    if i > 65536:
      raise newException(ValueError, "PE: import table does not end")
