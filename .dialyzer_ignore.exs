# Dialyzer findings that are correct observations about deliberate code.
#
# Keep this list short and justified. A warning belongs here only when dialyzer is *right* and the
# code is still what we want; anything dialyzer flags that is genuinely wrong gets fixed instead.
[
  # `dispatch/1` runs a one-shot CLI command inside a Task whose entire job is to end the VM:
  # `fn -> System.halt(guarded(fn -> run(command, opts) end)) end`. `System.halt/1` is `no_return`
  # by design, so "the created anonymous function has no local return" is precisely the contract —
  # halting is how a one-shot subcommand exits (see the comment on dispatch/1).
  {"lib/faber/cli.ex", :no_return}
]
