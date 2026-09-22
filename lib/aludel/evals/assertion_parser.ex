defmodule Aludel.Evals.AssertionParser do
  @moduledoc """
  Parses and validates assertion payloads from suite editor forms.
  """

  alias Aludel.Evals.JudgeCatalog
  alias Aludel.Evals.Metric.Registry
  alias Aludel.Evals.RegexMatcher

  @type parse_mode :: :json | :visual
  @max_typed_label_chars 200
  @max_typed_description_chars 2_000
  @max_typed_description_entries 30

  @doc """
  Parses and validates assertion form parameters in JSON or visual-editor form.

  Successful results use the persisted assertion map format accepted by suite
  execution. Validation failures return a user-facing error message.
  """
  @spec parse(parse_mode(), map()) :: {:ok, [map()]} | {:error, String.t()}
  def parse(:json, params) do
    case Jason.decode(params["assertions_json"] || "[]") do
      {:ok, assertions} when is_list(assertions) ->
        validate(assertions)

      {:ok, _value} ->
        {:error, "Invalid JSON: assertions must be a list"}

      {:error, %Jason.DecodeError{}} ->
        {:error, "Invalid JSON syntax in assertions"}
    end
  end

  def parse(:visual, params) do
    params
    |> Map.get("assertions", %{})
    |> normalize_assertion_params()
    |> parse_visual_assertions(:strict)
    |> case do
      {:ok, assertions} -> validate(assertions)
      {:error, _message} = error -> error
    end
  end

  @doc """
  Builds assertion maps from incomplete visual-editor parameters for previews.

  Unlike `parse/2`, this does not require every assertion field to be complete.
  """
  @spec preview_visual(map()) :: {:ok, [map()]} | {:error, String.t()}
  def preview_visual(params) do
    params
    |> Map.get("assertions", %{})
    |> normalize_assertion_params()
    |> parse_visual_assertions(:preview)
  end

  @doc """
  Validates persisted assertion maps against the registered metric contracts.
  """
  @spec validate([map()]) :: {:ok, [map()]} | {:error, String.t()}
  def validate(assertions) when is_list(assertions) do
    assertions
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, assertions}, fn {assertion, idx}, _acc ->
      case validate_assertion(assertion, idx) do
        :ok -> {:cont, {:ok, assertions}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  @doc """
  Converts persisted assertions into parameters for both assertion editors.
  """
  @spec build_form_params([map()]) :: map()
  def build_form_params(assertions) do
    %{
      "assertions_json" => Jason.encode!(assertions, pretty: true),
      "assertions" => build_assertion_params(assertions)
    }
  end

  defp parse_visual_assertions(assertion_params, mode) do
    with {:ok, assertion_indices} <- parse_assertion_indices(assertion_params) do
      assertion_indices
      |> Enum.reduce_while({:ok, []}, &collect_visual_assertion(assertion_params, &1, &2, mode))
      |> case do
        {:ok, assertions} -> {:ok, Enum.reverse(assertions)}
        {:error, _message} = error -> error
      end
    end
  end

  defp build_assertion_params(assertions) do
    assertions
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {assertion, idx}, acc ->
      acc
      |> Map.put("assertion_type_#{idx}", assertion["type"])
      |> maybe_put_assertion_value(idx, assertion)
    end)
  end

  defp maybe_put_assertion_value(params, idx, %{"type" => "json_field"} = assertion) do
    params
    |> Map.put("assertion_field_#{idx}", assertion["field"] || "")
    |> Map.put(
      "assertion_expected_#{idx}",
      format_json_field_expected(Map.get(assertion, "expected", ""))
    )
    |> Map.put(
      "assertion_expected_json_value_#{idx}",
      Jason.encode!(Map.get(assertion, "expected", ""))
    )
  end

  defp maybe_put_assertion_value(params, idx, %{"type" => "json_deep_compare"} = assertion) do
    params
    |> Map.put(
      "assertion_expected_json_#{idx}",
      Jason.encode!(Map.get(assertion, "expected", %{}), pretty: true)
    )
    |> Map.put("assertion_threshold_#{idx}", format_threshold(assertion["threshold"]))
  end

  defp maybe_put_assertion_value(params, idx, %{"type" => "rubric_judge"} = assertion) do
    params
    |> Map.put("assertion_rubric_source_#{idx}", rubric_source(assertion))
    |> Map.put("assertion_template_#{idx}", assertion["template"] || "")
    |> Map.put("assertion_rubric_#{idx}", assertion["rubric"] || "")
    |> Map.put("assertion_provider_id_#{idx}", assertion["provider_id"] || "")
    |> Map.put("assertion_threshold_#{idx}", format_threshold(assertion["threshold"]))
    |> put_evidence_form_value(idx, "expected", assertion["expected"])
    |> put_evidence_form_value(idx, "context", assertion["context"])
  end

  defp maybe_put_assertion_value(params, idx, assertion) do
    Map.put(params, "assertion_value_#{idx}", assertion["value"] || "")
  end

  defp build_visual_assertion(assertion_params, idx, :strict) do
    type = Map.get(assertion_params, "assertion_type_#{idx}")

    case type do
      "json_field" ->
        {:ok,
         %{
           "type" => type,
           "field" => Map.get(assertion_params, "assertion_field_#{idx}", ""),
           "expected" =>
             parse_json_field_expected(
               Map.get(assertion_params, "assertion_expected_#{idx}", ""),
               Map.get(assertion_params, "assertion_expected_json_value_#{idx}", "")
             )
         }}

      "json_deep_compare" ->
        with {:ok, expected} <-
               parse_expected_json(
                 Map.get(assertion_params, "assertion_expected_json_#{idx}", ""),
                 idx
               ),
             {:ok, threshold} <-
               parse_threshold(
                 Map.get(assertion_params, "assertion_threshold_#{idx}", ""),
                 idx,
                 "json_deep_compare"
               ) do
          {:ok,
           %{"type" => type, "expected" => expected}
           |> maybe_put_threshold(threshold)}
        end

      "rubric_judge" ->
        build_visual_rubric_judge(assertion_params, idx, :strict)

      _other ->
        {:ok,
         %{
           "type" => type,
           "value" => Map.get(assertion_params, "assertion_value_#{idx}", "")
         }}
    end
  end

  defp build_visual_assertion(assertion_params, idx, :preview) do
    type = Map.get(assertion_params, "assertion_type_#{idx}")

    case type do
      "json_field" ->
        {:ok,
         %{
           "type" => type,
           "field" => Map.get(assertion_params, "assertion_field_#{idx}", ""),
           "expected" =>
             parse_json_field_expected(
               Map.get(assertion_params, "assertion_expected_#{idx}", ""),
               Map.get(assertion_params, "assertion_expected_json_value_#{idx}", "")
             )
         }}

      "json_deep_compare" ->
        {:ok,
         %{"type" => type}
         |> maybe_put_preview_expected(
           Map.get(assertion_params, "assertion_expected_json_#{idx}", "")
         )
         |> maybe_put_preview_threshold(
           Map.get(assertion_params, "assertion_threshold_#{idx}", "")
         )}

      "rubric_judge" ->
        build_visual_rubric_judge(assertion_params, idx, :preview)

      _other ->
        {:ok,
         %{
           "type" => type,
           "value" => Map.get(assertion_params, "assertion_value_#{idx}", "")
         }}
    end
  end

  defp parse_assertion_indices(assertion_params) do
    assertion_params
    |> Map.keys()
    |> Enum.filter(&String.starts_with?(&1, "assertion_type_"))
    |> Enum.reduce_while({:ok, []}, fn "assertion_type_" <> idx, {:ok, indices} ->
      case Integer.parse(idx) do
        {parsed_idx, ""} ->
          {:cont, {:ok, [parsed_idx | indices]}}

        _ ->
          {:halt, {:error, "Invalid assertion index: #{idx}"}}
      end
    end)
    |> case do
      {:ok, indices} -> {:ok, Enum.sort(indices)}
      {:error, _message} = error -> error
    end
  end

  defp normalize_assertion_params(params) when is_map(params), do: params
  defp normalize_assertion_params(params) when is_list(params), do: Map.new(params)
  defp normalize_assertion_params(_params), do: %{}

  defp validate_assertion(assertion, idx) do
    type = Map.get(assertion, "type")
    valid_types = Registry.types()

    cond do
      type not in valid_types ->
        {:error,
         "Invalid assertion type at index #{idx}: #{inspect(type)}. Must be one of: #{Enum.join(valid_types, ", ")}"}

      type == "json_field" ->
        validate_json_field_assertion(assertion, idx)

      type == "json_deep_compare" ->
        validate_json_deep_compare_assertion(assertion, idx)

      type == "rubric_judge" ->
        validate_rubric_judge_assertion(assertion, idx)

      type == "typed_judge" ->
        validate_typed_judge_assertion(assertion, idx)

      type == "regex" ->
        validate_regex_assertion(assertion, idx)

      true ->
        validate_string_assertion(assertion, idx, type)
    end
  end

  defp validate_json_field_assertion(assertion, idx) do
    cond do
      not Map.has_key?(assertion, "field") or not Map.has_key?(assertion, "expected") ->
        {:error,
         "Assertion at index #{idx}: json_field type requires 'field' and 'expected' fields"}

      blank_string?(Map.get(assertion, "field")) ->
        {:error, "Assertion at index #{idx}: json_field type requires a non-blank 'field' value"}

      blank_string?(Map.get(assertion, "expected")) ->
        {:error,
         "Assertion at index #{idx}: json_field type requires a non-blank 'expected' value"}

      true ->
        :ok
    end
  end

  defp validate_string_assertion(assertion, idx, type) do
    cond do
      not Map.has_key?(assertion, "value") ->
        {:error, "Assertion at index #{idx}: #{type} type requires 'value' field"}

      blank_string?(Map.get(assertion, "value")) ->
        {:error, "Assertion at index #{idx}: #{type} type requires a non-blank 'value' field"}

      true ->
        :ok
    end
  end

  defp validate_regex_assertion(assertion, idx) do
    with :ok <- validate_string_assertion(assertion, idx, "regex") do
      case RegexMatcher.validate_pattern(assertion["value"]) do
        :ok ->
          :ok

        {:error, :pattern_too_large} ->
          {:error, "Assertion at index #{idx}: regex pattern cannot exceed 4096 bytes"}

        {:error, :invalid_pattern} ->
          {:error, "Assertion at index #{idx}: regex pattern is invalid"}
      end
    end
  end

  defp validate_json_deep_compare_assertion(assertion, idx) do
    expected = Map.get(assertion, "expected")
    threshold = Map.get(assertion, "threshold")

    cond do
      not Map.has_key?(assertion, "expected") ->
        {:error, "Assertion at index #{idx}: json_deep_compare type requires an 'expected' field"}

      not (is_map(expected) or is_list(expected)) ->
        {:error,
         "Assertion at index #{idx}: json_deep_compare type requires an 'expected' map or list"}

      not valid_threshold?(threshold) ->
        {:error,
         "Assertion at index #{idx}: json_deep_compare type requires a threshold between 0 and 100"}

      true ->
        :ok
    end
  end

  defp validate_rubric_judge_assertion(assertion, idx) do
    provider_id = Map.get(assertion, "provider_id")

    with :ok <- validate_rubric_source(assertion, idx) do
      cond do
        not valid_provider_id?(provider_id) ->
          {:error, "Assertion at index #{idx}: rubric_judge type requires a valid 'provider_id'"}

        not valid_threshold?(assertion["threshold"]) ->
          {:error,
           "Assertion at index #{idx}: rubric_judge type requires a threshold between 0 and 100"}

        true ->
          :ok
      end
    end
  end

  defp validate_rubric_source(assertion, idx) do
    case {Map.get(assertion, "rubric"), Map.get(assertion, "template")} do
      {nil, nil} -> invalid_rubric_source(idx)
      {rubric, nil} -> validate_custom_rubric(rubric, idx)
      {nil, template_id} -> validate_template(template_id, idx)
      {_rubric, _template_id} -> invalid_rubric_source(idx)
    end
  end

  defp validate_custom_rubric(rubric, idx) when is_binary(rubric) do
    cond do
      String.trim(rubric) == "" ->
        {:error,
         "Assertion at index #{idx}: rubric_judge type requires a non-blank 'rubric' field"}

      String.length(rubric) > 4_000 ->
        {:error, "Assertion at index #{idx}: rubric_judge rubric cannot exceed 4000 characters"}

      true ->
        :ok
    end
  end

  defp validate_custom_rubric(_rubric, idx) do
    invalid_rubric_source(idx)
  end

  defp validate_template(template_id, idx) when is_binary(template_id) do
    case JudgeCatalog.fetch(template_id) do
      {:ok, _template} ->
        :ok

      :error ->
        {:error, "Assertion at index #{idx}: rubric_judge type requires a known 'template' value"}
    end
  end

  defp validate_template(_template_id, idx) do
    invalid_rubric_source(idx)
  end

  defp invalid_rubric_source(idx) do
    {:error,
     "Assertion at index #{idx}: rubric_judge type requires either 'rubric' or a known 'template'"}
  end

  defp validate_typed_judge_assertion(assertion, idx) do
    with :ok <- validate_typed_judge_question(assertion, idx) do
      case Map.get(assertion, "kind") do
        "noul" ->
          validate_typed_judge_noul(assertion, idx)

        "choice" ->
          validate_typed_judge_choice(assertion, idx)

        "score" ->
          validate_typed_judge_score(assertion, idx)

        _other ->
          {:error,
           "Assertion at index #{idx}: typed_judge type requires kind to be one of noul, choice, score"}
      end
    end
  end

  defp validate_typed_judge_question(assertion, idx) do
    case Map.get(assertion, "question") do
      question when is_binary(question) ->
        cond do
          String.trim(question) == "" ->
            {:error, "Assertion at index #{idx}: typed_judge type requires a non-blank question"}

          String.length(question) > 2_000 ->
            {:error,
             "Assertion at index #{idx}: typed_judge question cannot exceed 2000 characters"}

          true ->
            :ok
        end

      _other ->
        {:error, "Assertion at index #{idx}: typed_judge type requires a non-blank question"}
    end
  end

  defp validate_typed_judge_noul(assertion, idx) do
    if valid_probability?(Map.get(assertion, "threshold", 0.5)) do
      :ok
    else
      {:error, "Assertion at index #{idx}: typed_judge noul threshold must be between 0 and 1"}
    end
  end

  defp validate_typed_judge_choice(assertion, idx) do
    choices = Map.get(assertion, "choices")
    expected = Map.get(assertion, "expected")

    cond do
      not valid_typed_judge_choices?(choices) ->
        {:error,
         "Assertion at index #{idx}: typed_judge choice kind requires 2 to 255 bounded choices"}

      not (is_binary(expected) and Map.has_key?(choices, expected)) ->
        {:error,
         "Assertion at index #{idx}: typed_judge choice kind requires expected to match a choice key"}

      not valid_probability?(Map.get(assertion, "min_confidence", 0.0)) ->
        {:error, "Assertion at index #{idx}: typed_judge min_confidence must be between 0 and 1"}

      true ->
        :ok
    end
  end

  defp validate_typed_judge_score(assertion, idx) do
    levels = Map.get(assertion, "levels")

    cond do
      not valid_typed_judge_levels?(levels) ->
        {:error,
         "Assertion at index #{idx}: typed_judge score kind requires 2 to 10 unique bounded levels"}

      not valid_probability?(Map.get(assertion, "min_confidence", 0.0)) ->
        {:error, "Assertion at index #{idx}: typed_judge min_confidence must be between 0 and 1"}

      score_rule_count(assertion) != 1 ->
        {:error,
         "Assertion at index #{idx}: typed_judge score kind requires exactly one of expected, minimum, or maximum"}

      not valid_typed_judge_score_rule?(assertion, levels) ->
        {:error,
         "Assertion at index #{idx}: typed_judge score rule value must match one of the configured levels"}

      true ->
        :ok
    end
  end

  defp valid_typed_judge_choices?(choices)
       when is_map(choices) and map_size(choices) in 2..255 do
    Enum.all?(choices, fn {key, value} ->
      valid_typed_judge_label?(key) and valid_typed_judge_description?(value)
    end)
  end

  defp valid_typed_judge_choices?(_choices) do
    false
  end

  defp valid_typed_judge_levels?(levels) when is_list(levels) do
    Enum.all?(levels, &valid_typed_judge_label?/1) and
      Enum.uniq(levels) == levels and length(levels) in 2..10
  end

  defp valid_typed_judge_levels?(_levels) do
    false
  end

  defp valid_typed_judge_label?(value) when is_binary(value) do
    trimmed = String.trim(value)
    trimmed != "" and String.length(trimmed) <= @max_typed_label_chars
  end

  defp valid_typed_judge_label?(_value) do
    false
  end

  defp valid_typed_judge_description?(nil) do
    true
  end

  defp valid_typed_judge_description?(value) when is_binary(value) do
    String.length(value) <= @max_typed_description_chars
  end

  defp valid_typed_judge_description?(value)
       when is_map(value) and map_size(value) <= @max_typed_description_entries do
    Enum.all?(value, fn {key, nested_value} ->
      is_binary(key) and String.length(key) <= @max_typed_label_chars and
        valid_typed_judge_description_value?(nested_value)
    end)
  end

  defp valid_typed_judge_description?(_value) do
    false
  end

  defp valid_typed_judge_description_value?(value)
       when is_nil(value) or is_boolean(value) or is_number(value) do
    true
  end

  defp valid_typed_judge_description_value?(value) when is_binary(value) do
    String.length(value) <= @max_typed_description_chars
  end

  defp valid_typed_judge_description_value?(_value) do
    false
  end

  defp score_rule_count(assertion) do
    ["expected", "minimum", "maximum"]
    |> Enum.count(&Map.has_key?(assertion, &1))
  end

  defp valid_typed_judge_score_rule?(assertion, levels) do
    ["expected", "minimum", "maximum"]
    |> Enum.find_value(false, fn field ->
      value = Map.get(assertion, field)
      is_binary(value) and value in levels
    end)
  end

  defp parse_expected_json(value, idx) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) or is_list(decoded) ->
        {:ok, decoded}

      {:ok, _decoded} ->
        {:error,
         "Assertion at index #{idx}: json_deep_compare type requires an 'expected' map or list"}

      {:error, %Jason.DecodeError{}} ->
        {:error,
         "Assertion at index #{idx}: json_deep_compare type requires valid JSON in the expected payload"}
    end
  end

  defp parse_expected_json(_value, idx) do
    {:error,
     "Assertion at index #{idx}: json_deep_compare type requires valid JSON in the expected payload"}
  end

  defp build_visual_rubric_judge(assertion_params, idx, :strict) do
    with {:ok, source} <- parse_rubric_source(assertion_params, idx),
         {:ok, threshold} <-
           parse_threshold(
             Map.get(assertion_params, "assertion_threshold_#{idx}", ""),
             idx,
             "rubric_judge"
           ) do
      assertion =
        %{
          "type" => "rubric_judge",
          "provider_id" => Map.get(assertion_params, "assertion_provider_id_#{idx}", "")
        }
        |> Map.merge(source)
        |> maybe_put_threshold(threshold)
        |> maybe_put_evidence(assertion_params, idx, "expected")
        |> maybe_put_evidence(assertion_params, idx, "context")

      {:ok, assertion}
    end
  end

  defp build_visual_rubric_judge(assertion_params, idx, :preview) do
    source = preview_rubric_source(assertion_params, idx)

    assertion =
      %{
        "type" => "rubric_judge",
        "provider_id" => Map.get(assertion_params, "assertion_provider_id_#{idx}", "")
      }
      |> Map.merge(source)
      |> maybe_put_preview_threshold(Map.get(assertion_params, "assertion_threshold_#{idx}", ""))
      |> maybe_put_evidence(assertion_params, idx, "expected")
      |> maybe_put_evidence(assertion_params, idx, "context")

    {:ok, assertion}
  end

  defp parse_rubric_source(assertion_params, idx) do
    case Map.get(assertion_params, "assertion_rubric_source_#{idx}", "template") do
      "template" ->
        {:ok, %{"template" => Map.get(assertion_params, "assertion_template_#{idx}", "")}}

      "custom" ->
        {:ok, %{"rubric" => Map.get(assertion_params, "assertion_rubric_#{idx}", "")}}

      _other ->
        {:error, "Assertion at index #{idx}: rubric_judge type requires a valid rubric source"}
    end
  end

  defp preview_rubric_source(assertion_params, idx) do
    case Map.get(assertion_params, "assertion_rubric_source_#{idx}", "template") do
      "custom" ->
        %{"rubric" => Map.get(assertion_params, "assertion_rubric_#{idx}", "")}

      _other ->
        %{"template" => Map.get(assertion_params, "assertion_template_#{idx}", "")}
    end
  end

  defp parse_threshold("", _idx, _type) do
    {:ok, nil}
  end

  defp parse_threshold(value, idx, type) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {threshold, ""} ->
        {:ok, threshold}

      _other ->
        {:error, "Assertion at index #{idx}: #{type} type requires a threshold between 0 and 100"}
    end
  end

  defp parse_threshold(_value, idx, type) do
    {:error, "Assertion at index #{idx}: #{type} type requires a threshold between 0 and 100"}
  end

  defp collect_visual_assertion(assertion_params, idx, {:ok, assertions}, mode) do
    case build_visual_assertion(assertion_params, idx, mode) do
      {:ok, assertion} -> {:cont, {:ok, [assertion | assertions]}}
      {:error, _message} = error -> {:halt, error}
    end
  end

  defp maybe_put_threshold(assertion, nil), do: assertion
  defp maybe_put_threshold(assertion, threshold), do: Map.put(assertion, "threshold", threshold)

  defp put_evidence_form_value(params, idx, field, value) do
    params
    |> Map.put("assertion_#{field}_#{idx}", format_evidence(value))
    |> Map.put("assertion_#{field}_json_value_#{idx}", Jason.encode!(value))
  end

  defp maybe_put_evidence(assertion, assertion_params, idx, field) do
    text = Map.get(assertion_params, "assertion_#{field}_#{idx}", "")
    encoded = Map.get(assertion_params, "assertion_#{field}_json_value_#{idx}", "")

    case parse_optional_evidence(text, encoded) do
      :omit -> assertion
      {:put, value} -> Map.put(assertion, field, value)
    end
  end

  defp parse_optional_evidence(value, _encoded) when value in [nil, ""] do
    :omit
  end

  defp parse_optional_evidence(value, encoded) when is_binary(value) do
    case Jason.decode(encoded) do
      {:ok, decoded} ->
        if value == format_evidence(decoded), do: {:put, decoded}, else: {:put, value}

      _other ->
        {:put, value}
    end
  end

  defp parse_optional_evidence(value, _encoded) do
    {:put, value}
  end

  defp maybe_put_preview_expected(assertion, value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) or is_list(decoded) ->
        Map.put(assertion, "expected", decoded)

      _other ->
        assertion
    end
  end

  defp maybe_put_preview_expected(assertion, _value), do: assertion

  defp maybe_put_preview_threshold(assertion, value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {threshold, ""} -> Map.put(assertion, "threshold", threshold)
      _other -> assertion
    end
  end

  defp maybe_put_preview_threshold(assertion, _value), do: assertion

  defp valid_threshold?(nil), do: true
  defp valid_threshold?(value) when is_integer(value), do: value >= 0 and value <= 100
  defp valid_threshold?(value) when is_float(value), do: value >= 0.0 and value <= 100.0
  defp valid_threshold?(_value), do: false

  defp valid_probability?(value) when is_integer(value), do: value >= 0 and value <= 1
  defp valid_probability?(value) when is_float(value), do: value >= 0.0 and value <= 1.0
  defp valid_probability?(_value), do: false

  defp valid_provider_id?(provider_id) when is_binary(provider_id) do
    match?({:ok, _uuid}, Ecto.UUID.cast(provider_id))
  end

  defp valid_provider_id?(_provider_id) do
    false
  end

  defp parse_json_field_expected(expected_text, expected_json) when is_binary(expected_text) do
    case Jason.decode(expected_json) do
      {:ok, decoded} ->
        if expected_text == format_json_field_expected(decoded), do: decoded, else: expected_text

      _other ->
        expected_text
    end
  end

  defp parse_json_field_expected(expected, _expected_json), do: expected

  defp format_json_field_expected(nil), do: "null"
  defp format_json_field_expected(value) when is_binary(value), do: value

  defp format_json_field_expected(value)
       when is_integer(value) or is_float(value) or is_boolean(value),
       do: inspect(value)

  defp format_json_field_expected(value) when is_map(value) or is_list(value),
    do: Jason.encode!(value)

  defp format_json_field_expected(value), do: to_string(value)

  defp format_threshold(nil), do: ""
  defp format_threshold(value), do: to_string(value)

  defp rubric_source(%{"rubric" => rubric}) when is_binary(rubric) do
    "custom"
  end

  defp rubric_source(_assertion) do
    "template"
  end

  defp format_evidence(nil) do
    ""
  end

  defp format_evidence(value) when is_binary(value) do
    value
  end

  defp format_evidence(value) when is_map(value) or is_list(value) do
    Jason.encode!(value)
  end

  defp format_evidence(value) do
    to_string(value)
  end

  defp blank_string?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank_string?(_value), do: false
end
