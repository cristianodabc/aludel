defmodule Aludel.Interfaces.LLM.Providers.Ollama do
  @moduledoc """
  Ollama API adapter implementation.

  Handles API communication with local Ollama models through the
  configured HTTP adapter.

  Ollama doesn't require authentication, so requests use ReqLLM's native
  Ollama provider without sending placeholder credentials.
  """

  alias Aludel.Interfaces.LLM.{Config, ErrorParser}

  @behaviour Aludel.Interfaces.LLM.Behaviour

  @impl true
  def generate(model, prompt, config, opts) do
    opts = Keyword.delete(opts, :api_key)
    {provider_options, opts} = Keyword.pop(opts, :provider_options, [])

    req_opts =
      [
        provider_options: provider_options || [],
        temperature: config["temperature"] || 0.8
      ]
      |> maybe_put_max_tokens(config["max_tokens"])
      |> Keyword.merge(opts)

    model_spec = %{provider: :ollama, id: model}

    case Config.http_adapter().request(model_spec, prompt, req_opts) do
      {:ok, response} ->
        {:ok, response}

      {:error, reason} ->
        ErrorParser.parse_error(reason)
    end
  end

  defp maybe_put_max_tokens(opts, nil) do
    opts
  end

  defp maybe_put_max_tokens(opts, max_tokens) do
    Keyword.put(opts, :max_tokens, max_tokens)
  end
end
