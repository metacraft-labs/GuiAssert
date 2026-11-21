## Running one `guiassert` invocation: argv in, one envelope line out.
##
## `runInvocation` is the library entry point behind both the one-shot CLI
## (`src/guiassert.nim`) and every `run` request of `guiassert serve`, so the
## two produce byte-identical envelopes for the same argv and state (spec
## §8.3). It never raises and never writes to stdout itself: every failure,
## including a bug, becomes a failure envelope whose code is the exit code
## (spec §7.2, §7.3).

import std/[json, options]

import ../core/[contract, interfaces]
import ../cancel
import ./[args, context, registry, verbs]

proc runInvocation*(argv: seq[string], ctx: RunContext): Outcome =
  ## Parse and run one invocation and return its exit code and envelope
  ## line. `ctx.token` carries cancellation and receives the `--timeout-ms`
  ## deadline.
  var verb = findVerbToken(argv)
  var envelope: JsonNode
  var feature = ""   # the verb's feature, once the invocation parsed
  try:
    if verb == "serve":
      raise badArgs("invalid-value", (if ctx.nested:
        "a serve request cannot start a nested daemon" else:
        "serve is not run through runInvocation"))
    let inv = parseInvocation(argv)
    verb = inv.verb
    feature = verbFeature(inv)
    let env = prepare(inv, ctx)
    if env.timeoutMs.isSome: ctx.token.setDeadline(env.timeoutMs.get)
    ctx.token.checkpoint()
    fixtureInjection(env)
    let data = dispatch(env)
    ctx.token.checkpoint()
    envelope = successEnvelope(verb, data)
  except ContractError as e:
    # Every exit 4 / exit 6 envelope names its feature (spec §7.3); one that
    # did not come through a `featured` call names the verb's.
    envelope = failureEnvelope(verb, withFeature(e, feature))
  except BackendError as e:
    envelope = failureEnvelope(verb, withFeature(fromBackendError(e), feature))
  except CatchableError as e:
    envelope = failureEnvelope(verb, newContractError(ekInternal, "exception",
      "unexpected " & $e.name & ": " & e.msg))
  except Defect as e:
    envelope = failureEnvelope(verb, newContractError(ekInternal, "exception",
      "internal defect " & $e.name & ": " & e.msg))
  # A cancellation or deadline that interrupted a backend mid-way is reported
  # as such, whatever error the interrupted operation surfaced.
  if not envelope["ok"].getBool and envelope["error"]["code"].getInt notin {7, 8}:
    let r = ctx.token.reason
    if r != crNone:
      envelope = failureEnvelope(verb, cancelledError(r))
  var line: string
  try:
    line = renderEnvelope(envelope)
  except ContractError as e:
    envelope = failureEnvelope(verb, e)
    line = renderEnvelope(envelope)
  Outcome(exit: envelopeExitCode(envelope), line: line, verb: verb, envelope: envelope)

const helpText* = """guiassert - look at, read and drive a desktop (contract guiassert-desktop/1)

Usage:
  guiassert [global flags] <verb> [positionals] [verb flags] [-- <argv>]
  guiassert serve [--stdio | --listen unix:<path>] [--max-concurrency N] [global flags]

Every invocation prints exactly one JSON envelope line on stdout and exits
with its code: 0 ok, 1 internal, 2 bad-args, 3 not-found,
4 backend-unavailable, 5 backend-error, 6 permission-denied, 7 timeout,
8 cancelled.

Global flags:
  --state-dir <dir>  --session <id>  --backend <name>  --<module>-backend <name>
  --timeout-ms <n>   --contract <major>  --fixture-scenario <file>

Verbs:
"""

proc help*(): string =
  ## The human help text (the only output that is not an envelope).
  result = helpText
  for v in verbSpecs:
    result.add "  " & v.name
    for p in v.positionals: result.add " <" & p & ">"
    for f in v.flags:
      result.add " [--" & f.name & (if f.kind == fkSwitch: "" else: " <v>") &
                 (if f.kind == fkRepeated: "…" else: "") & "]"
    if v.passthrough: result.add " [-- <argv…>]"
    result.add "\n"
