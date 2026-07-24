## Shared POSIX non-blocking pipe I/O helpers.
##
## Used by both the shell tool (talos_agent/src/tools/shell.nim) and the
## coding harness's compile runner (talos_code/src/talos_code/compile.nim)
## to drain a subprocess's output pipe incrementally without blocking,
## so a command producing more than one pipe buffer (~64 KiB) of output
## doesn't deadlock while it's still running.

when defined(posix):
  import std/posix

  proc setNonBlocking*(fd: FileHandle) =
    ## Best-effort: put the pipe read end into non-blocking mode so we can
    ## drain it without blocking the poll loop.
    let flags = fcntl(fd.cint, F_GETFL)
    if flags != -1:
      discard fcntl(fd.cint, F_SETFL, flags or O_NONBLOCK)

  proc drainAvailable*(fd: FileHandle; buf: var string; total: var int;
                       cap: int): bool =
    ## Reads all bytes currently available on `fd` (a non-blocking pipe),
    ## appending up to `cap` total bytes into `buf` and counting every byte
    ## produced in `total`. Bytes past the cap are read and discarded so the
    ## child process never blocks on a full pipe. Returns true once EOF is
    ## reached (the write end has been closed).
    var tmp {.noinit.}: array[8192, char]
    while true:
      let n = read(fd.cint, addr tmp[0], tmp.len)
      if n == 0:
        return true            # EOF: writer closed
      if n < 0:
        return false           # EAGAIN/EWOULDBLOCK (or error): nothing more now
      total += n
      if cap <= 0 or buf.len < cap:
        let take = if cap <= 0: n else: min(n, cap - buf.len)
        let oldLen = buf.len
        buf.setLen(oldLen + take)
        copyMem(addr buf[oldLen], addr tmp[0], take)
