## What one `guiassert` invocation runs with, besides its argv.
##
## The CLI and `serve` run verbs through the same `runInvocation`
## (`cli/run`); they differ only in the context they pass: the environment
## (a snapshot, so a daemon's requests all see the environment it was started
## with), the cancellation token, where streaming events go, the defaults the
## daemon's own global flags set, and whether the caller can own a session
## (`--lifetime owner` is honoured only under `serve`).

import std/[json, options, tables]

import ../cancel

type
  EventSink* = proc (event: string, data: JsonNode) {.closure.}
    ## Receives the streaming events of a verb (spec §8.4).

  RunContext* = object
    env*: Table[string, string]
      ## The environment the invocation sees (never read from the process
      ## directly by the library).
    cwd*: string
      ## The directory relative paths are resolved against.
    selfExe*: string
      ## The `guiassert` executable, for the processes it starts itself
      ## (fixture session hosts).
    token*: CancelToken
      ## Cancellation and the `--timeout-ms` deadline. Required.
    emit*: EventSink
      ## Where events go; nil drops them (the one-shot CLI).
    owner*: Option[string]
      ## Set under `serve`: the connection that may own sessions.
    defaults*: Table[string, string]
      ## Global flag values that apply when an invocation does not give its
      ## own (the `serve` daemon's flags).
    nested*: bool
      ## True under `serve`: a `serve` verb is refused.

  Outcome* = object
    ## The result of one invocation: the exit code, the one stdout line, the
    ## verb as reported, and the envelope as an object.
    exit*: int
    line*: string
    verb*: string
    envelope*: JsonNode
