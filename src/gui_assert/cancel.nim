## Cancellation and deadlines for long-running operations.
##
## A `CancelToken` is shared between the code that runs an operation and
## whoever may stop it: the `serve` daemon's main thread (`cancel`, shutdown,
## a request's `timeoutMs`), the one-shot CLI's signal handler (SIGINT /
## SIGTERM), or the global `--timeout-ms` deadline. The operation calls
## `checkpoint` at its safe points (between input events, between poll
## attempts, at frame boundaries; spec §8.6), which raises the matching
## `ContractError`:
##
## * cancelled by the caller: `cancelled` (exit 8) with reason `request`,
##   `signal` or `shutdown`;
## * past the deadline: `timeout` (exit 7) / `deadline`.
##
## The token lives in the shared heap so it can be handed to another thread
## and to a signal handler: setting it is a single atomic store, which is
## async-signal-safe. Whoever creates a token frees it with `free`, after the
## operation that uses it has finished.

import std/[atomics, monotimes, os, times]

import ./core/contract

type
  CancelReason* = enum
    ## Why a token was cancelled; `crNone` while it is not.
    crNone, crRequest, crSignal, crShutdown

  CancelState = object
    flag: Atomic[int]        ## ord(CancelReason)
    deadlineNs: Atomic[int64] ## monotonic deadline in ns; 0 = none

  CancelToken* = ptr CancelState
    ## A shared cancellation flag plus an optional deadline. `nil` is never a
    ## valid token: use `newCancelToken`.

proc nowNs(): int64 = getMonoTime().ticks

proc newCancelToken*(): CancelToken =
  ## A fresh token with no deadline. Free it with `free`.
  result = cast[CancelToken](allocShared0(sizeof(CancelState)))

proc free*(t: CancelToken) =
  ## Release a token created by `newCancelToken`.
  if t != nil: deallocShared(t)

proc setDeadline*(t: CancelToken, timeoutMs: int) =
  ## Make the token expire `timeoutMs` milliseconds from now. A later call
  ## can only bring the deadline forward, never push it back, so two
  ## deadlines (a request's and a daemon's) compose to the earlier one.
  let d = nowNs() + int64(timeoutMs) * 1_000_000
  let cur = t.deadlineNs.load
  if cur == 0 or d < cur: t.deadlineNs.store(d)

proc cancel*(t: CancelToken, reason: CancelReason) =
  ## Cancel the token. The first reason wins; later calls change nothing.
  ## Safe to call from a signal handler.
  var expected = ord(crNone)
  discard t.flag.compareExchange(expected, ord(reason))

proc reason*(t: CancelToken): CancelReason =
  ## The reason the token was cancelled, or `crNone`.
  CancelReason(t.flag.load)

proc expired*(t: CancelToken): bool =
  ## True when the token has a deadline and it has passed.
  let d = t.deadlineNs.load
  d != 0 and nowNs() >= d

proc remainingMs*(t: CancelToken): int =
  ## Milliseconds until the deadline (0 when past), or `high(int)` without one.
  let d = t.deadlineNs.load
  if d == 0: return high(int)
  max(0, int((d - nowNs()) div 1_000_000))

proc cancelledError*(r: CancelReason): ref ContractError =
  ## The `cancelled` error for reason `r` (which must not be `crNone`).
  let reason = case r
    of crRequest: "request"
    of crSignal: "signal"
    of crShutdown: "shutdown"
    of crNone: "request"
  newContractError(ekCancelled, reason, "cancelled (" & reason & ")")

proc deadlineError*(): ref ContractError =
  ## The `timeout` / `deadline` error.
  newContractError(ekTimeout, "deadline", "the --timeout-ms deadline expired")

proc checkpoint*(t: CancelToken) =
  ## Raise when the token is cancelled or past its deadline; a cancellation
  ## takes precedence over the deadline.
  let r = t.reason
  if r != crNone: raise cancelledError(r)
  if t.expired: raise deadlineError()

proc sleepCancellable*(t: CancelToken, ms: int) =
  ## Sleep `ms` milliseconds in short slices, calling `checkpoint` between
  ## them, so a cancellation or deadline interrupts the sleep within about
  ## 10 ms.
  let until = nowNs() + int64(ms) * 1_000_000
  t.checkpoint()
  while true:
    let left = (until - nowNs()) div 1_000_000
    if left <= 0: break
    sleep(int(min(left, 10)))
    t.checkpoint()

proc elapsedMsSince*(startNs: int64): int =
  ## Milliseconds since a `monoNowNs` reading.
  int((nowNs() - startNs) div 1_000_000)

proc monoNowNs*(): int64 =
  ## The monotonic clock in nanoseconds.
  nowNs()

proc unixNowMs*(): int64 =
  ## The wall clock as Unix milliseconds.
  let t = getTime()
  t.toUnix * 1000 + int64(t.nanosecond div 1_000_000)
