## A minidump of this process when it dies on an unhandled exception.
##
## On Windows an access violation ends a process with no record of where it
## was. `installCrashDump` registers a top-level exception filter that writes
## a minidump (`MiniDumpWriteDump`, every thread's stack) into a directory the
## caller names, then lets the process die with its own exit code. Nothing
## happens unless the caller asks for it, so a normal run is unchanged. POSIX
## has no such filter here, and `installCrashDump` does nothing there.
##
## The dump is written from inside the failing process, after the fault, with
## the heap possibly damaged; that is why the filter does no allocation beyond
## the path it is given. Documentation for the API used:
## https://learn.microsoft.com/en-us/windows/win32/api/errhandlingapi/nf-errhandlingapi-setunhandledexceptionfilter
## https://learn.microsoft.com/en-us/windows/win32/api/minidumpapiset/nf-minidumpapiset-minidumpwritedump

import std/os

when defined(windows):
  const
    genericWrite = 0x40000000'u32
    createAlways = 2'u32
    attributeNormal = 0x80'u32
    miniDumpNormal = 0'u32
    invalidHandle = cast[pointer](-1)

  type
    ExcRecord {.importc: "EXCEPTION_RECORD", header: "<windows.h>", final, pure.} = object
      ExceptionCode: uint32
      ExceptionFlags: uint32
      ExceptionRecord: pointer
      ExceptionAddress: pointer
    ExceptionPointers {.importc: "EXCEPTION_POINTERS", header: "<windows.h>",
                        final, pure.} = object
      ExceptionRecord: ptr ExcRecord
      ContextRecord: pointer
    UnhandledFilter = proc (info: ptr ExceptionPointers): clong {.stdcall.}

  proc setUnhandledExceptionFilter(f: UnhandledFilter): pointer
    {.importc: "SetUnhandledExceptionFilter", stdcall, header: "<windows.h>".}
  proc createFileA(name: cstring, access, share: uint32, sa: pointer,
                   disposition, flags: uint32, templateFile: pointer): pointer
    {.importc: "CreateFileA", stdcall, header: "<windows.h>".}
  proc closeHandle(h: pointer): int32
    {.importc: "CloseHandle", stdcall, header: "<windows.h>".}
  proc getCurrentProcess(): pointer
    {.importc: "GetCurrentProcess", stdcall, header: "<windows.h>".}
  proc miniDumpWriteDump(process: pointer, pid: uint32, file: pointer,
                         dumpType: uint32, exceptionParam, userStream,
                         callback: pointer): int32
    {.importc: "MiniDumpWriteDump", stdcall, header: "<dbghelp.h>".}

  {.passL: "-ldbghelp".}

  proc addVectoredExceptionHandler(first: uint32, handler: UnhandledFilter): pointer
    {.importc: "AddVectoredExceptionHandler", stdcall, header: "<windows.h>".}
  proc captureStackBackTrace(framesToSkip, framesToCapture: uint32,
                             backTrace: ptr pointer, hash: pointer): uint16
    {.importc: "CaptureStackBackTrace", stdcall, header: "<windows.h>".}
  proc writeFile(h: pointer, buffer: pointer, n: uint32, written: pointer,
                 overlapped: pointer): int32
    {.importc: "WriteFile", stdcall, header: "<windows.h>".}

  var
    crashDumpDir: string
    vehPrefix: string     ## `<dir>/serve-veh-<pid>.`, built before any fault
    vehCount: int         ## records written so far, capped by `vehMax`
  const vehMax = 8
  const vehFrames = 16

  proc writeDump(info: ptr ExceptionPointers): clong {.stdcall.} =
    # Returning 0 (EXCEPTION_CONTINUE_SEARCH) hands the fault on, so the
    # process still ends with the exception's own exit code.
    {.cast(gcsafe).}:
      let path = crashDumpDir / ("serve-" & $getCurrentProcessId() & ".dmp")
      let file = createFileA(path.cstring, genericWrite, 0, nil, createAlways,
                             attributeNormal, nil)
      if file == invalidHandle:
        stderr.writeLine("crash dump not written: cannot create " & path)
      else:
        let ok = miniDumpWriteDump(getCurrentProcess(), uint32(getCurrentProcessId()),
                                   file, miniDumpNormal, nil, nil, nil)
        discard closeHandle(file)
        if ok != 0:
          stderr.writeLine("crash dump written: " & path)
        else:
          stderr.writeLine("crash dump not written to " & path)
    result = 0

  proc firstChance(info: ptr ExceptionPointers): clong {.stdcall.} =
    # Runs for every exception before any handler, so it sees a fault that
    # an unhandled-exception filter would never be asked about. It writes the
    # code, the faulting address and the stack as raw words: a small binary
    # record per exception, at most `vehMax`, decoded after the run.
    {.cast(gcsafe).}:
      if vehCount < vehMax:
        inc vehCount
        var record: array[2 + vehFrames, uint]
        record[0] = uint(info.ExceptionRecord.ExceptionCode)
        record[1] = cast[uint](info.ExceptionRecord.ExceptionAddress)
        var frames: array[vehFrames, pointer]
        let n = captureStackBackTrace(0, uint32(vehFrames), addr frames[0], nil)
        for i in 0 ..< int(n):
          record[2 + i] = cast[uint](frames[i])
        # The path is built from the prefix made at install time, plus one
        # digit: nothing else is allocated on this path.
        let path = vehPrefix & $vehCount & ".bin"
        let file = createFileA(path.cstring, genericWrite, 0, nil, createAlways,
                               attributeNormal, nil)
        if file != invalidHandle:
          var written: uint32
          discard writeFile(file, addr record[0], uint32(sizeof(record)),
                            addr written, nil)
          discard closeHandle(file)
    result = 0

  proc installCrashDump*(dir: string) =
    ## Write a minidump into `dir` if this process dies on an unhandled
    ## exception, and a first-chance record of each fault there. Call once,
    ## early.
    {.cast(gcsafe).}:
      crashDumpDir = dir
      vehPrefix = dir / ("serve-veh-" & $getCurrentProcessId() & ".")
    discard setUnhandledExceptionFilter(writeDump)
    discard addVectoredExceptionHandler(1, firstChance)
else:
  proc installCrashDump*(dir: string) =
    discard dir
