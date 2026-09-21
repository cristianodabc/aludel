defmodule Aludel.TypedJudgeStub do
  @moduledoc false

  @behaviour Aludel.Interfaces.TypedJudge

  @impl true
  def ask(_context, assertion, _opts) do
    case Map.get(assertion, "stub_answer") do
      {:error, reason, evaluator} -> {:error, reason, evaluator}
      {:error, reason} -> {:error, reason}
      nil -> {:error, :missing_stub_answer}
      answer -> {:ok, answer}
    end
  end
end
