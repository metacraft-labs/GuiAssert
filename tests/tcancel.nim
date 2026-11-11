## tcancel — `cancel.sleepCancellable`, which every timed input step, poll
## interval and settle wait sleeps through: it sleeps at least what it is
## asked for (never a millisecond short per call, which adds up over a
## drag's or a typed text's many steps), and a cancellation still ends it at
## the next slice.

import std/[monotimes, times, unittest]

import ../src/gui_assert/cancel
import ../src/gui_assert/core/contract

proc elapsedNs(start: MonoTime): int64 = (getMonoTime() - start).inNanoseconds

suite "sleepCancellable":
  test "test_sleep_never_returns_early":
    let t = newCancelToken()
    defer: t.free()
    # Single calls of a few milliseconds each, where a truncated remainder
    # loses the largest share.
    for ms in [1, 2, 3, 5, 7]:
      for _ in 1 .. 5:
        let t0 = getMonoTime()
        t.sleepCancellable(ms)
        check elapsedNs(t0) >= int64(ms) * 1_000_000
    # Many steps add up to at least their sum (twelve 25 ms drag steps).
    let t0 = getMonoTime()
    for _ in 1 .. 12: t.sleepCancellable(25)
    check elapsedNs(t0) >= 300 * 1_000_000

  test "test_cancelled_sleep_raises_at_once":
    let t = newCancelToken()
    defer: t.free()
    t.cancel(crRequest)
    let t0 = getMonoTime()
    expect ContractError:
      t.sleepCancellable(5_000)
    check elapsedNs(t0) < 1_000 * 1_000_000

  test "test_deadline_ends_a_sleep_at_the_next_slice":
    # A deadline that passes DURING the sleep ends it within a slice or so
    # (the rounding up adds at most 1 ms per slice), never at the sleep's
    # own end.
    let t = newCancelToken()
    defer: t.free()
    t.setDeadline(40)
    let t0 = getMonoTime()
    var kind = ekInternal
    try:
      t.sleepCancellable(5_000)
    except ContractError as e:
      kind = e.kind
    let ms = elapsedNs(t0) div 1_000_000
    check kind == ekTimeout
    check ms >= 40
    check ms < 250
