defmodule Aludel.Interfaces.TypedJudge do
  @moduledoc """
  Boundary for typed model-backed judgments.

  The default adapter is disabled so Aludel can expose the `typed_judge`
  assertion contract without requiring a specific external service at compile
  time. Applications can configure an adapter that implements this behaviour.
  """

  alias Aludel.Evals.Metric.Context

  @type answer :: %{
          required(String.t()) => term()
        }

  @type error_reason :: term()

  @callback ask(Context.t(), map(), keyword()) ::
              {:ok, answer()}
              | {:error, error_reason()}
              | {:error, error_reason(), map()}

  @default_adapter Aludel.Interfaces.TypedJudge.Adapters.Disabled

  @doc """
  Sends a typed judgment request through the configured adapter.
  """
  @spec ask(Context.t(), map(), keyword()) ::
          {:ok, answer()}
          | {:error, error_reason()}
          | {:error, error_reason(), map()}
  def ask(%Context{} = context, assertion, opts \\ []) when is_map(assertion) and is_list(opts) do
    adapter().ask(context, assertion, opts)
  end

  @doc """
  Returns the configured typed-judge adapter.
  """
  @spec adapter() :: module()
  def adapter do
    case Application.get_env(:aludel, :typed_judge_adapter, @default_adapter) do
      adapter when is_atom(adapter) and not is_nil(adapter) -> adapter
      _other -> @default_adapter
    end
  end
end
