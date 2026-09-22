import Config

config :aludel,
  repo: AludelDash.Repo,
  typed_judge_adapter: AludelDash.TypedJudgeAdapter

config :jev,
  model: "jev-latest",
  max_retries: 3,
  receive_timeout: 30_000

config :aludel_dash, ecto_repos: [AludelDash.Repo]

config :aludel_dash, AludelDash.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [view: AludelDash.ErrorHTML, accepts: ~w(html json), layout: false],
  pubsub_server: AludelDash.PubSub,
  live_view: [signing_salt: "aludel_dash"]

import_config "#{config_env()}.exs"
