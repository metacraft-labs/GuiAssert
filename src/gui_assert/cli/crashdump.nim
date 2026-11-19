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
    UnhandledFilter = proc (info: pointer): clong {.stdcall.}

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

  var crashDumpDir: string

  proc writeDump(info: pointer): clong {.stdcall.} =
    # Returning 0 (EXCEPTION_CONTINUE_SEARCH) hands the fault on, so the
    # process still ends with the exception's own exit code.
    {.cast(gcsafe).}:
      let path = crashDumpDir / ("serve-" & $getCurrentProcessId() & ".dmp")
      let file = createFileA(path.cstring, genericWrite, 0, nil, createAlways,
                             attributeNormal, nil)
      if file != invalidHandle:
        let ok = miniDumpWriteDump(getCurrentProcess(), uint32(getCurrentProcessId()),
                                   file, miniDumpNormal, nil, nil, nil)
        discard closeHandle(file)
        if ok != 0:
          stderr.writeLine("crash dump written: " & path)
        else:
          stderr.writeLine("crash dump not written to " & path)
    result = 0

  proc installCrashDump*(dir: string) =
    ## Write a minidump into `dir` if this process dies on an unhandled
    ## exception. Call once, early.
    {.cast(gcsafe).}:
      crashDumpDir = dir
    discard setUnhandledExceptionFilter(writeDump)
else:
  proc installCrashDump*(dir: string) =
    discard dir
