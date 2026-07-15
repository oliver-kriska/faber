import Config

# Faber's prod build is a LOCAL CLI (`faber serve`), not a server deploy: its "log aggregator" is
# the user's terminal, and it stays in the foreground while they use the UI. Logger's default level
# is :debug, so an un-tuned release narrates every request, mount, and click back at them
# ("HANDLE EVENT ... Replied in 125µs"). Ship quiet.
#
# :info, not :warning — the goal is to drop the *framework's* chatter while keeping Faber's own
# voice (e.g. Eval's "adapter eval is exec-in-place; using default native scoring" explains why a
# score came out the way it did). The three settings below cut the framework at each source:
#
#   * level: :info      — Phoenix.LiveView.Logger's MOUNT/HANDLE EVENT/Replied and Phoenix's
#                         "Processing with ..." all log at :debug.
#   * :phoenix, :logger — false stops Phoenix.Logger attaching at all, which is what emits the
#                         :info-level "CONNECTED TO Phoenix.LiveView.Socket".
#   * :request_logging  — read by endpoint.ex via compile_env; false drops Plug.Telemetry's
#                         "GET /" + "Sent 200 in 41ms".
#
# Override the level at runtime with FABER_LOG_LEVEL (see config/runtime.exs).
config :logger, level: :info
config :phoenix, :logger, false
config :faber, :request_logging, false
