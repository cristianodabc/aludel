defmodule Aludel.Evals.Metrics.TypedJudgeTest do
  use ExUnit.Case, async: false

  alias Aludel.Evals.Metric.Context
  alias Aludel.Evals.Metric.Registry

  setup do
    previous = Application.get_env(:aludel, :typed_judge_adapter)
    Application.put_env(:aludel, :typed_judge_adapter, Aludel.TypedJudgeStub)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:aludel, :typed_judge_adapter)
        value -> Application.put_env(:aludel, :typed_judge_adapter, value)
      end
    end)
  end

  test "yes/no judgments pass above threshold" do
    assertion = %{
      "type" => "typed_judge",
      "kind" => "noul",
      "question" => "Does the answer disclose PII?",
      "threshold" => 0.8,
      "stub_answer" => %{"answer" => 0.92}
    }

    assert {:ok, result} = Registry.evaluate(Context.new("email: user@example.com"), assertion)
    assert result.passed
    assert result.score == 92.0
    assert result.metadata["answer"] == 0.92
    assert result.metadata["threshold"] == 0.8
    assert result.metadata["schema_version"] == 1
  end

  test "yes/no judgments fail below threshold" do
    assertion = %{
      "type" => "typed_judge",
      "kind" => "noul",
      "question" => "Does the answer disclose PII?",
      "threshold" => 0.8,
      "stub_answer" => %{"answer" => 0.2}
    }

    assert {:ok, result} = Registry.evaluate("safe response", assertion)
    refute result.passed
    assert result.score == 20.0
    assert result.reason =~ "below threshold"
  end

  test "choice judgments pass on expected label with confidence" do
    assertion = %{
      "type" => "typed_judge",
      "kind" => "choice",
      "question" => "What risk category best describes the output?",
      "choices" => %{"safe" => "No issue", "pii" => "Personal data disclosure"},
      "expected" => "safe",
      "min_confidence" => 0.7,
      "stub_answer" => %{"answer" => "safe", "confidence" => 0.84}
    }

    assert {:ok, result} = Registry.evaluate(Context.new("safe response"), assertion)
    assert result.passed
    assert result.score == 84.0
    assert result.metadata["answer"] == "safe"
    assert result.metadata["confidence"] == 0.84
  end

  test "choice judgments fail on wrong label" do
    assertion = %{
      "type" => "typed_judge",
      "kind" => "choice",
      "question" => "What risk category best describes the output?",
      "choices" => %{"safe" => "No issue", "pii" => "Personal data disclosure"},
      "expected" => "safe",
      "min_confidence" => 0.7,
      "stub_answer" => %{"answer" => "pii", "confidence" => 0.95}
    }

    assert {:ok, result} = Registry.evaluate(Context.new("email: user@example.com"), assertion)
    refute result.passed
    assert result.score == 0.0
    assert result.reason =~ "did not satisfy expected safe"
  end

  test "choice judgments fail when confidence is too low" do
    assertion = %{
      "type" => "typed_judge",
      "kind" => "choice",
      "question" => "What risk category best describes the output?",
      "choices" => %{"safe" => "No issue", "pii" => "Personal data disclosure"},
      "expected" => "safe",
      "min_confidence" => 0.9,
      "stub_answer" => %{"answer" => "safe", "confidence" => 0.42}
    }

    assert {:ok, result} = Registry.evaluate(Context.new("safe response"), assertion)
    refute result.passed
    assert result.score == 42.0
    assert result.reason =~ "minimum confidence 0.90"
  end

  test "choice judgments isolate labels outside the closed choice set" do
    assertion = %{
      "type" => "typed_judge",
      "kind" => "choice",
      "question" => "What risk category best describes the output?",
      "choices" => %{"safe" => "No issue", "pii" => "Personal data disclosure"},
      "expected" => "safe",
      "stub_answer" => %{"answer" => "other", "confidence" => 0.99}
    }

    assert {:ok, result} = Registry.evaluate(Context.new("answer"), assertion)
    refute result.passed
    assert result.reason == "Typed judge returned invalid structured output"
    assert result.evaluator.status == :error
  end

  test "score judgments pass and fail against maximum level" do
    passing_assertion = %{
      "type" => "typed_judge",
      "kind" => "score",
      "question" => "How severe is the issue?",
      "levels" => ["none", "minor", "major", "critical"],
      "maximum" => "minor",
      "min_confidence" => 0.6,
      "stub_answer" => %{"answer" => "minor", "value" => 1.0, "confidence" => 0.8}
    }

    failing_assertion = %{
      passing_assertion
      | "stub_answer" => %{"answer" => "major", "value" => 2.0, "confidence" => 0.9}
    }

    assert {:ok, passing_result} =
             Registry.evaluate(Context.new("minor issue"), passing_assertion)

    assert passing_result.passed

    assert {:ok, failing_result} =
             Registry.evaluate(Context.new("major issue"), failing_assertion)

    refute failing_result.passed
    assert failing_result.reason =~ "maximum minor"
  end

  test "score judgments support expected and minimum rules" do
    expected_assertion = %{
      "type" => "typed_judge",
      "kind" => "score",
      "question" => "How severe is the issue?",
      "levels" => ["none", "minor", "major", "critical"],
      "expected" => "minor",
      "min_confidence" => 0.6,
      "stub_answer" => %{"answer" => "minor", "value" => 1.0, "confidence" => 0.8}
    }

    minimum_assertion = %{
      "type" => "typed_judge",
      "kind" => "score",
      "question" => "How useful is the response?",
      "levels" => ["poor", "ok", "good", "excellent"],
      "minimum" => "good",
      "min_confidence" => 0.6,
      "stub_answer" => %{"answer" => "excellent", "value" => 3.0, "confidence" => 0.9}
    }

    assert {:ok, expected_result} =
             Registry.evaluate(Context.new("minor issue"), expected_assertion)

    assert expected_result.passed

    assert {:ok, minimum_result} =
             Registry.evaluate(Context.new("excellent answer"), minimum_assertion)

    assert minimum_result.passed
  end

  test "score judgments fail when confidence is too low" do
    assertion = %{
      "type" => "typed_judge",
      "kind" => "score",
      "question" => "How severe is the issue?",
      "levels" => ["none", "minor", "major", "critical"],
      "maximum" => "minor",
      "min_confidence" => 0.9,
      "stub_answer" => %{"answer" => "minor", "value" => 1.0, "confidence" => 0.4}
    }

    assert {:ok, result} = Registry.evaluate(Context.new("minor issue"), assertion)
    refute result.passed
    assert result.reason =~ "minimum confidence 0.90"
  end

  test "metadata bounding does not corrupt oversized JSON-compatible fields" do
    choices =
      1..60
      |> Map.new(fn idx ->
        {"label_#{idx}", String.duplicate("large choice #{idx}", 50)}
      end)
      |> Map.put("safe", String.duplicate("safe choice", 50))

    assertion = %{
      "type" => "typed_judge",
      "kind" => "choice",
      "question" => "What risk category best describes the output?",
      "choices" => choices,
      "expected" => "safe",
      "stub_answer" => %{"answer" => "safe", "confidence" => 0.95}
    }

    assert {:ok, result} = Registry.evaluate(Context.new("safe response"), assertion)
    assert result.passed
    assert result.metadata["choices"]["truncated"] == true
    assert Jason.encode!(result.metadata)
  end

  test "adapter errors are unavailable without leaking details" do
    assertion = %{
      "type" => "typed_judge",
      "kind" => "choice",
      "question" => "What risk category best describes the output?",
      "choices" => %{"safe" => nil, "pii" => nil},
      "expected" => "safe",
      "stub_answer" => {:error, {:network_error, %{authorization: "secret-token"}}}
    }

    assert {:ok, result} = Registry.evaluate(Context.new("answer"), assertion)
    refute result.passed
    assert result.reason == "Typed judge is unavailable"
    assert result.evaluator.status == :unavailable
    assert result.evaluator.error["type"] == "network_error"
    refute inspect(result) =~ "secret-token"
  end

  test "invalid adapter responses are isolated" do
    assertion = %{
      "type" => "typed_judge",
      "kind" => "choice",
      "question" => "What risk category best describes the output?",
      "choices" => %{"safe" => nil, "pii" => nil},
      "expected" => "safe",
      "stub_answer" => %{"answer" => "safe", "confidence" => 2.0}
    }

    assert {:ok, result} = Registry.evaluate(Context.new("answer"), assertion)
    refute result.passed
    assert result.reason == "Typed judge returned invalid structured output"
    assert result.evaluator.status == :error
    assert result.evaluator.error["type"] == "invalid_response"
  end

  test "choice and score judgments require explicit valid confidence" do
    choice_assertion = %{
      "type" => "typed_judge",
      "kind" => "choice",
      "question" => "Is the response safe?",
      "choices" => %{"safe" => nil, "unsafe" => nil},
      "expected" => "safe",
      "stub_answer" => %{"answer" => "safe"}
    }

    score_assertion = %{
      "type" => "typed_judge",
      "kind" => "score",
      "question" => "How severe is the response?",
      "levels" => ["none", "minor", "major"],
      "maximum" => "minor",
      "stub_answer" => %{"answer" => "minor", "value" => 1.0}
    }

    assert {:ok, choice_result} = Registry.evaluate(Context.new("safe"), choice_assertion)
    assert choice_result.evaluator.status == :error

    assert {:ok, score_result} = Registry.evaluate(Context.new("minor"), score_assertion)
    assert score_result.evaluator.status == :error
  end

  test "score boundaries use the continuous Jev value and reject out-of-range values" do
    assertion = %{
      "type" => "typed_judge",
      "kind" => "score",
      "question" => "How severe is the response?",
      "levels" => ["none", "minor", "major", "critical"],
      "maximum" => "minor",
      "stub_answer" => %{
        "answer" => "minor",
        "value" => 1.4,
        "confidence" => 0.9
      }
    }

    assert {:ok, boundary_result} = Registry.evaluate(Context.new("response"), assertion)
    refute boundary_result.passed
    assert boundary_result.metadata["answer"] == "minor"
    assert boundary_result.metadata["value"] == 1.4

    invalid_assertion = put_in(assertion["stub_answer"]["value"], -100.0)
    assert {:ok, invalid_result} = Registry.evaluate(Context.new("response"), invalid_assertion)
    assert invalid_result.evaluator.status == :error
  end

  test "adapter failures retain bounded evaluator attribution" do
    assertion = %{
      "type" => "typed_judge",
      "kind" => "choice",
      "question" => "Is the response safe?",
      "choices" => %{"safe" => nil, "unsafe" => nil},
      "expected" => "safe",
      "stub_answer" =>
        {:error, :authentication_failed,
         %{"provider" => "typesafe", "model" => "jev-latest", "duration_ms" => 12.4}}
    }

    assert {:ok, result} = Registry.evaluate(Context.new("response"), assertion)
    assert result.evaluator.status == :unavailable
    assert result.evaluator.provider == "typesafe"
    assert result.evaluator.model == "jev-latest"
    assert result.evaluator.duration_ms == 12.4
  end

  test "adapter evaluator evidence is normalized on successful judgments" do
    assertion = %{
      "type" => "typed_judge",
      "kind" => "choice",
      "question" => "Is the response safe?",
      "choices" => %{"safe" => nil, "unsafe" => nil},
      "expected" => "safe",
      "stub_answer" => %{
        "answer" => "safe",
        "confidence" => 0.96,
        "evaluator" => %{
          "provider" => "typesafe",
          "model" => "jev-1.13.0",
          "duration_ms" => 82.4,
          "input_tokens" => 125,
          "output_tokens" => 0,
          "cost_usd" => 0.000_005_25
        }
      }
    }

    assert {:ok, result} = Registry.evaluate(Context.new("safe response"), assertion)
    assert result.evaluator.status == :completed
    assert result.evaluator.provider == "typesafe"
    assert result.evaluator.model == "jev-1.13.0"
    assert result.evaluator.duration_ms == 82.4
    assert result.evaluator.input_tokens == 125
    assert result.evaluator.output_tokens == 0
    assert result.evaluator.cost_usd == 0.000_005_25
  end
end
