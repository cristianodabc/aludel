defmodule Aludel.Evals.Metrics.TypedJudge do
  @moduledoc """
  Evaluates generated output with a typed judgment adapter.

  This metric supports three narrow question shapes:

  - `noul`: yes/no probability, passing when `answer >= threshold`
  - `choice`: closed-label classification, passing when the expected label and
    minimum confidence are satisfied
  - `score`: ordered levels, passing against an expected, minimum, or maximum
    level with optional confidence
  """

  @behaviour Aludel.Evals.Metric

  alias Aludel.Evals.Metric
  alias Aludel.Evals.Metric.Context
  alias Aludel.Evals.Metric.Evaluator
  alias Aludel.Evals.Metric.Result
  alias Aludel.Interfaces.TypedJudge

  @schema_version 1
  @default_noul_threshold 0.5
  @default_min_confidence 0.0
  @max_question_chars 2_000
  @max_label_chars 200
  @max_description_chars 2_000
  @max_description_entries 30
  @max_metadata_string_chars 2_000
  @max_metadata_map_entries 50
  @max_metadata_list_items 50

  @impl true
  def type do
    "typed_judge"
  end

  @impl true
  def evaluate(%Context{} = context, %{"kind" => kind} = assertion)
      when kind in ["noul", "choice", "score"] do
    with {:ok, normalized} <- normalize_assertion(assertion),
         {:ok, answer} <- TypedJudge.ask(context, normalized) do
      evaluate_answer(answer, normalized)
    else
      {:error, :invalid_configuration} ->
        Metric.invalid_result(type())

      {:error, :invalid_response, evaluator} ->
        adapter_invalid_response_result(assertion, evaluator)

      {:error, reason, evaluator} ->
        unavailable_result(reason, assertion, evaluator)

      {:error, reason} ->
        unavailable_result(reason, assertion, %{})
    end
  end

  def evaluate(output, assertion) when is_binary(output) and is_map(assertion) do
    evaluate(Context.new(output), assertion)
  end

  def evaluate(_input, _assertion) do
    Metric.invalid_result(type())
  end

  defp normalize_assertion(%{"kind" => "noul", "question" => question} = assertion)
       when is_binary(question) do
    threshold = Map.get(assertion, "threshold", @default_noul_threshold)

    if valid_question?(question) and probability?(threshold) do
      {:ok,
       %{
         "type" => type(),
         "kind" => "noul",
         "question" => String.trim(question),
         "threshold" => threshold / 1
       }
       |> maybe_put_adapter_field(assertion)}
    else
      {:error, :invalid_configuration}
    end
  end

  defp normalize_assertion(%{"kind" => "choice", "question" => question} = assertion)
       when is_binary(question) do
    choices = Map.get(assertion, "choices")
    expected = Map.get(assertion, "expected")
    min_confidence = Map.get(assertion, "min_confidence", @default_min_confidence)

    if valid_question?(question) and valid_choices?(choices) and
         Map.has_key?(choices, expected) and probability?(min_confidence) do
      {:ok,
       %{
         "type" => type(),
         "kind" => "choice",
         "question" => String.trim(question),
         "choices" => choices,
         "expected" => expected,
         "min_confidence" => min_confidence / 1
       }
       |> maybe_put_adapter_field(assertion)}
    else
      {:error, :invalid_configuration}
    end
  end

  defp normalize_assertion(%{"kind" => "score", "question" => question} = assertion)
       when is_binary(question) do
    levels = Map.get(assertion, "levels")
    min_confidence = Map.get(assertion, "min_confidence", @default_min_confidence)

    cond do
      not valid_question?(question) or not valid_levels?(levels) or
          not probability?(min_confidence) ->
        {:error, :invalid_configuration}

      score_rule(assertion, levels) == :error ->
        {:error, :invalid_configuration}

      true ->
        {:ok,
         %{
           "type" => type(),
           "kind" => "score",
           "question" => String.trim(question),
           "levels" => levels,
           "min_confidence" => min_confidence / 1,
           "rule" => score_rule(assertion, levels)
         }
         |> maybe_put_adapter_field(assertion)}
    end
  end

  defp normalize_assertion(_assertion) do
    {:error, :invalid_configuration}
  end

  defp evaluate_answer(answer, %{"kind" => "noul"} = assertion) do
    value = Map.get(answer, "answer")

    if probability?(value) do
      value = value / 1
      passed = value >= assertion["threshold"]

      %Result{
        type: type(),
        passed: passed,
        score: Float.round(value * 100, 1),
        reason: noul_reason(passed, value, assertion["threshold"]),
        metadata: metadata(assertion, answer, %{"answer" => value}),
        evaluator: completed_evaluator(answer)
      }
    else
      invalid_response_result(assertion, answer)
    end
  end

  defp evaluate_answer(answer, %{"kind" => "choice"} = assertion) do
    label = Map.get(answer, "answer")
    confidence = confidence(answer)

    if is_binary(label) and Map.has_key?(assertion["choices"], label) and probability?(confidence) do
      passed = label == assertion["expected"] and confidence >= assertion["min_confidence"]
      score = if label == assertion["expected"], do: confidence * 100, else: 0.0

      %Result{
        type: type(),
        passed: passed,
        score: Float.round(score, 1),
        reason: choice_reason(passed, label, confidence, assertion),
        metadata:
          metadata(assertion, answer, %{
            "answer" => label,
            "confidence" => confidence
          }),
        evaluator: completed_evaluator(answer)
      }
    else
      invalid_response_result(assertion, answer)
    end
  end

  defp evaluate_answer(answer, %{"kind" => "score"} = assertion) do
    value = Map.get(answer, "value")
    confidence = confidence(answer)

    if valid_score_value?(value, assertion["levels"]) and probability?(confidence) do
      value = value / 1
      level = nearest_level(value, assertion["levels"])
      passed = score_passed?(value, level, confidence, assertion)
      score = score_value(value, assertion["levels"], confidence)

      %Result{
        type: type(),
        passed: passed,
        score: score,
        reason: score_reason(passed, level, confidence, assertion),
        metadata:
          metadata(assertion, answer, %{
            "answer" => level,
            "value" => value,
            "confidence" => confidence
          }),
        evaluator: completed_evaluator(answer)
      }
    else
      invalid_response_result(assertion, answer)
    end
  end

  defp unavailable_result(reason, assertion, evaluator) do
    %Result{
      type: type(),
      passed: false,
      score: 0.0,
      reason: "Typed judge is unavailable",
      metadata:
        %{
          "schema_version" => @schema_version,
          "kind" => Map.get(assertion, "kind"),
          "question" => Map.get(assertion, "question")
        }
        |> bound_metadata(),
      evaluator: failure_evaluator(:unavailable, reason, evaluator)
    }
  end

  defp adapter_invalid_response_result(assertion, evaluator) do
    %Result{
      type: type(),
      passed: false,
      score: 0.0,
      reason: "Typed judge returned invalid structured output",
      metadata:
        %{
          "schema_version" => @schema_version,
          "kind" => Map.get(assertion, "kind"),
          "question" => Map.get(assertion, "question")
        }
        |> bound_metadata(),
      evaluator: failure_evaluator(:error, :invalid_response, evaluator)
    }
  end

  defp invalid_response_result(assertion, answer) do
    %Result{
      type: type(),
      passed: false,
      score: 0.0,
      reason: "Typed judge returned invalid structured output",
      metadata:
        metadata(assertion, answer, %{
          "answer" => Map.get(answer, "answer")
        }),
      evaluator:
        Evaluator.error(%{
          "type" => "invalid_response",
          "message" => "Typed judge response did not match the required schema"
        })
    }
  end

  defp completed_evaluator(%{
         "evaluator" => %{"duration_ms" => duration_ms} = details
       })
       when is_number(duration_ms) and duration_ms >= 0 do
    Evaluator.completed(duration_ms,
      provider: bounded_optional_string(details["provider"]),
      model: bounded_optional_string(details["model"]),
      input_tokens: non_negative_integer(details["input_tokens"]),
      output_tokens: non_negative_integer(details["output_tokens"]),
      cost_usd: non_negative_number(details["cost_usd"])
    )
  end

  defp completed_evaluator(_answer) do
    nil
  end

  defp failure_evaluator(status, reason, details) do
    error = %{
      "type" => error_type(reason),
      "message" => failure_message(status)
    }

    attrs = [
      duration_ms: non_negative_number(details["duration_ms"]),
      provider: bounded_optional_string(details["provider"]),
      model: bounded_optional_string(details["model"])
    ]

    Evaluator.new(status, Keyword.put(attrs, :error, error))
  end

  defp failure_message(:error) do
    "Typed judge response did not match the required schema"
  end

  defp failure_message(:unavailable) do
    "Typed judge adapter is unavailable"
  end

  defp bounded_optional_string(value) when is_binary(value) do
    bound_value(value)
  end

  defp bounded_optional_string(_value) do
    nil
  end

  defp non_negative_integer(value) when is_integer(value) and value >= 0 do
    value
  end

  defp non_negative_integer(_value) do
    nil
  end

  defp non_negative_number(value) when is_number(value) and value >= 0 do
    value
  end

  defp non_negative_number(_value) do
    nil
  end

  defp metadata(assertion, answer, attrs) do
    base =
      assertion
      |> Map.take([
        "kind",
        "question",
        "threshold",
        "expected",
        "min_confidence",
        "choices",
        "levels",
        "rule"
      ])
      |> Map.put("schema_version", @schema_version)

    base
    |> Map.merge(attrs)
    |> Map.put("raw_confidence", Map.get(answer, "confidence"))
    |> bound_metadata()
  end

  defp bound_metadata(metadata) do
    bound_value(metadata)
  end

  defp bound_value(value) when is_map(value) do
    value
    |> Enum.take(@max_metadata_map_entries)
    |> Map.new(fn {key, nested_value} -> {to_string(key), bound_value(nested_value)} end)
    |> maybe_put_truncated_marker(map_size(value), @max_metadata_map_entries)
  end

  defp bound_value(value) when is_list(value) do
    bounded =
      value
      |> Enum.take(@max_metadata_list_items)
      |> Enum.map(&bound_value/1)

    if length(value) > @max_metadata_list_items do
      bounded ++ [%{"truncated" => true}]
    else
      bounded
    end
  end

  defp bound_value(value) when is_binary(value) do
    if String.length(value) > @max_metadata_string_chars do
      String.slice(value, 0, @max_metadata_string_chars)
    else
      value
    end
  end

  defp bound_value(value)
       when is_nil(value) or is_boolean(value) or is_number(value) do
    value
  end

  defp bound_value(value) do
    value
    |> inspect()
    |> bound_value()
  end

  defp maybe_put_truncated_marker(map, original_size, limit) when original_size > limit do
    Map.put(map, "truncated", true)
  end

  defp maybe_put_truncated_marker(map, _original_size, _limit) do
    map
  end

  defp score_rule(assertion, levels) do
    rules =
      ["expected", "minimum", "maximum"]
      |> Enum.filter(fn field -> Map.has_key?(assertion, field) end)

    case rules do
      [field] ->
        value = assertion[field]

        if is_binary(value) and value in levels do
          %{"type" => field, "level" => value}
        else
          :error
        end

      _other ->
        :error
    end
  end

  defp maybe_put_adapter_field(normalized, %{"stub_answer" => stub_answer}) do
    Map.put(normalized, "stub_answer", stub_answer)
  end

  defp maybe_put_adapter_field(normalized, _assertion) do
    normalized
  end

  defp score_passed?(
         _value,
         level,
         confidence,
         %{"rule" => %{"type" => "expected", "level" => expected}} = assertion
       ) do
    level == expected and confidence >= assertion["min_confidence"]
  end

  defp score_passed?(
         value,
         _level,
         confidence,
         %{"rule" => %{"type" => "minimum", "level" => minimum}} = assertion
       ) do
    value >= level_rank(minimum, assertion["levels"]) and
      confidence >= assertion["min_confidence"]
  end

  defp score_passed?(
         value,
         _level,
         confidence,
         %{"rule" => %{"type" => "maximum", "level" => maximum}} = assertion
       ) do
    value <= level_rank(maximum, assertion["levels"]) and
      confidence >= assertion["min_confidence"]
  end

  defp score_value(value, levels, confidence) do
    max_rank = max(length(levels) - 1, 1)
    Float.round(value / max_rank * confidence * 100, 1)
  end

  defp level_rank(level, levels) do
    Enum.find_index(levels, &(&1 == level))
  end

  defp confidence(%{"confidence" => confidence}) when is_number(confidence) do
    confidence / 1
  end

  defp confidence(_answer) do
    nil
  end

  defp noul_reason(true, value, threshold) do
    "Typed yes/no score #{format_number(value)} met threshold #{format_number(threshold)}"
  end

  defp noul_reason(false, value, threshold) do
    "Typed yes/no score #{format_number(value)} was below threshold #{format_number(threshold)}"
  end

  defp choice_reason(true, label, confidence, _assertion) do
    "Typed choice matched #{label} with confidence #{format_number(confidence)}"
  end

  defp choice_reason(false, label, confidence, assertion) do
    "Typed choice #{label} did not satisfy expected #{assertion["expected"]} with minimum confidence #{format_number(assertion["min_confidence"])}; confidence was #{format_number(confidence)}"
  end

  defp score_reason(true, level, confidence, _assertion) do
    "Typed score #{level} passed with confidence #{format_number(confidence)}"
  end

  defp score_reason(false, level, confidence, assertion) do
    %{"type" => rule, "level" => expected} = assertion["rule"]

    "Typed score #{level} did not satisfy #{rule} #{expected} with minimum confidence #{format_number(assertion["min_confidence"])}; confidence was #{format_number(confidence)}"
  end

  defp valid_question?(question) when is_binary(question) do
    question = String.trim(question)
    question != "" and String.length(question) <= @max_question_chars
  end

  defp valid_choices?(choices) when is_map(choices) and map_size(choices) in 2..255 do
    Enum.all?(choices, fn {key, value} ->
      valid_label?(key) and valid_description?(value)
    end)
  end

  defp valid_choices?(_choices) do
    false
  end

  defp valid_levels?(levels) when is_list(levels) do
    Enum.all?(levels, &valid_label?/1) and
      Enum.uniq(levels) == levels and length(levels) in 2..10
  end

  defp valid_levels?(_levels) do
    false
  end

  defp probability?(value) when is_number(value) do
    value >= 0 and value <= 1
  end

  defp probability?(_value) do
    false
  end

  defp valid_score_value?(value, levels) when is_number(value) do
    value >= 0 and value <= length(levels) - 1
  end

  defp valid_score_value?(_value, _levels) do
    false
  end

  defp nearest_level(value, levels) do
    Enum.at(levels, round(value))
  end

  defp valid_label?(value) when is_binary(value) do
    trimmed = String.trim(value)
    trimmed != "" and String.length(trimmed) <= @max_label_chars
  end

  defp valid_label?(_value) do
    false
  end

  defp valid_description?(nil) do
    true
  end

  defp valid_description?(value) when is_binary(value) do
    String.length(value) <= @max_description_chars
  end

  defp valid_description?(value)
       when is_map(value) and map_size(value) <= @max_description_entries do
    Enum.all?(value, fn {key, nested_value} ->
      valid_description_key?(key) and valid_description_value?(nested_value)
    end)
  end

  defp valid_description?(_value) do
    false
  end

  defp valid_description_key?(key) when is_binary(key) do
    String.length(key) <= @max_label_chars
  end

  defp valid_description_key?(_key) do
    false
  end

  defp valid_description_value?(value)
       when is_nil(value) or is_boolean(value) or is_number(value) do
    true
  end

  defp valid_description_value?(value) when is_binary(value) do
    String.length(value) <= @max_description_chars
  end

  defp valid_description_value?(_value) do
    false
  end

  defp error_type(reason) when is_atom(reason) do
    Atom.to_string(reason)
  end

  defp error_type({reason, _details}) when is_atom(reason) do
    Atom.to_string(reason)
  end

  defp error_type(_reason) do
    "typed_judge_error"
  end

  defp format_number(value) do
    :erlang.float_to_binary(value / 1, decimals: 2)
  end
end
