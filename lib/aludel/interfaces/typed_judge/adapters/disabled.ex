defmodule Aludel.Interfaces.TypedJudge.Adapters.Disabled do
  @moduledoc """
  Disabled typed-judge adapter used when no external service is configured.
  """

  @behaviour Aludel.Interfaces.TypedJudge

  @impl true
  def ask(_context, _assertion, _opts) do
    {:error, :not_configured}
  end
end
