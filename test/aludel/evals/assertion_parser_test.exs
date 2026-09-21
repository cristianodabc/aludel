defmodule Aludel.Evals.AssertionParserTest do
  use ExUnit.Case, async: true

  alias Aludel.Evals.AssertionParser

  describe "parse/2" do
    test "parses JSON assertions" do
      params = %{
        "assertions_json" => ~s([{"type":"contains","value":"hello"}])
      }

      assert {:ok, [%{"type" => "contains", "value" => "hello"}]} =
               AssertionParser.parse(:json, params)
    end

    test "rejects invalid JSON assertions" do
      params = %{"assertions_json" => "{invalid json}"}

      assert {:error, "Invalid JSON syntax in assertions"} =
               AssertionParser.parse(:json, params)
    end

    test "rejects JSON assertions when the payload is not a list" do
      params = %{"assertions_json" => ~s({"type":"contains","value":"hello"})}

      assert {:error, "Invalid JSON: assertions must be a list"} =
               AssertionParser.parse(:json, params)
    end

    test "rejects JSON assertions with an invalid type" do
      params = %{
        "assertions_json" => ~s([{"type":"invalid_type","value":"hello"}])
      }

      assert {:error, message} = AssertionParser.parse(:json, params)
      assert message =~ "Invalid assertion type at index 1"
    end

    test "rejects JSON string assertions with blank values" do
      params = %{
        "assertions_json" => ~s([{"type":"contains","value":"   "}])
      }

      assert {:error, message} = AssertionParser.parse(:json, params)
      assert message =~ "contains type requires a non-blank 'value' field"
    end

    test "parses visual assertions" do
      params = %{
        "assertions" => %{
          "assertion_type_0" => "contains",
          "assertion_value_0" => "hello",
          "assertion_type_1" => "json_field",
          "assertion_field_1" => "sentiment",
          "assertion_expected_1" => "positive"
        }
      }

      assert {:ok,
              [
                %{"type" => "contains", "value" => "hello"},
                %{
                  "type" => "json_field",
                  "field" => "sentiment",
                  "expected" => "positive"
                }
              ]} = AssertionParser.parse(:visual, params)
    end

    test "parses json_deep_compare assertions in JSON mode" do
      params = %{
        "assertions_json" =>
          ~s([{"type":"json_deep_compare","expected":{"status":"ok","count":2},"threshold":75.0}])
      }

      assert {:ok,
              [
                %{
                  "type" => "json_deep_compare",
                  "expected" => %{"status" => "ok", "count" => 2},
                  "threshold" => 75.0
                }
              ]} = AssertionParser.parse(:json, params)
    end

    test "parses rubric judge assertions in JSON mode" do
      provider_id = Ecto.UUID.generate()

      params = %{
        "assertions_json" =>
          Jason.encode!([
            %{
              "type" => "rubric_judge",
              "rubric" => "The answer must be correct.",
              "provider_id" => provider_id,
              "threshold" => 85,
              "expected" => "Reference answer"
            }
          ])
      }

      assert {:ok, [assertion]} = AssertionParser.parse(:json, params)
      assert assertion["type"] == "rubric_judge"
      assert assertion["provider_id"] == provider_id
      assert assertion["threshold"] == 85
    end

    test "parses built-in rubric judge templates in JSON mode" do
      provider_id = Ecto.UUID.generate()

      params = %{
        "assertions_json" =>
          Jason.encode!([
            %{
              "type" => "rubric_judge",
              "template" => "correctness",
              "provider_id" => provider_id
            }
          ])
      }

      assert {:ok, [assertion]} = AssertionParser.parse(:json, params)
      assert assertion["template"] == "correctness"
    end

    test "parses typed judge assertions in JSON mode" do
      params = %{
        "assertions_json" =>
          Jason.encode!([
            %{
              "type" => "typed_judge",
              "kind" => "noul",
              "question" => "Does the answer disclose personal data?",
              "threshold" => 0.9
            },
            %{
              "type" => "typed_judge",
              "kind" => "choice",
              "question" => "What risk category best describes the output?",
              "choices" => %{"safe" => nil, "pii" => "Personal data disclosure"},
              "expected" => "safe",
              "min_confidence" => 0.75
            },
            %{
              "type" => "typed_judge",
              "kind" => "score",
              "question" => "How severe is the issue?",
              "levels" => ["none", "minor", "major", "critical"],
              "maximum" => "minor",
              "min_confidence" => 0.7
            }
          ])
      }

      assert {:ok, assertions} = AssertionParser.parse(:json, params)
      assert Enum.map(assertions, & &1["kind"]) == ["noul", "choice", "score"]
    end

    test "rejects malformed typed judge assertions" do
      invalid_kind = %{
        "assertions_json" =>
          ~s([{"type":"typed_judge","kind":"unknown","question":"Classify this"}])
      }

      assert {:error, message} = AssertionParser.parse(:json, invalid_kind)
      assert message =~ "requires kind to be one of noul, choice, score"

      blank_question = %{
        "assertions_json" =>
          ~s([{"type":"typed_judge","kind":"noul","question":" ","threshold":0.5}])
      }

      assert {:error, message} = AssertionParser.parse(:json, blank_question)
      assert message =~ "requires a non-blank question"

      invalid_choice = %{
        "assertions_json" =>
          Jason.encode!([
            %{
              "type" => "typed_judge",
              "kind" => "choice",
              "question" => "Classify this",
              "choices" => %{"safe" => nil, "pii" => nil},
              "expected" => "other"
            }
          ])
      }

      assert {:error, message} = AssertionParser.parse(:json, invalid_choice)
      assert message =~ "expected to match a choice key"

      invalid_score = %{
        "assertions_json" =>
          Jason.encode!([
            %{
              "type" => "typed_judge",
              "kind" => "score",
              "question" => "Score this",
              "levels" => ["none", "minor"],
              "minimum" => "none",
              "maximum" => "minor"
            }
          ])
      }

      assert {:error, message} = AssertionParser.parse(:json, invalid_score)
      assert message =~ "requires exactly one of expected, minimum, or maximum"

      invalid_confidence = %{
        "assertions_json" =>
          Jason.encode!([
            %{
              "type" => "typed_judge",
              "kind" => "choice",
              "question" => "Classify this",
              "choices" => %{"safe" => nil, "pii" => nil},
              "expected" => "safe",
              "min_confidence" => 1.1
            }
          ])
      }

      assert {:error, message} = AssertionParser.parse(:json, invalid_confidence)
      assert message =~ "min_confidence must be between 0 and 1"

      invalid_noul_threshold = %{
        "assertions_json" =>
          ~s([{"type":"typed_judge","kind":"noul","question":"Judge this","threshold":1.1}])
      }

      assert {:error, message} = AssertionParser.parse(:json, invalid_noul_threshold)
      assert message =~ "noul threshold must be between 0 and 1"

      too_few_choices = %{
        "assertions_json" =>
          Jason.encode!([
            %{
              "type" => "typed_judge",
              "kind" => "choice",
              "question" => "Classify this",
              "choices" => %{"safe" => nil},
              "expected" => "safe"
            }
          ])
      }

      assert {:error, message} = AssertionParser.parse(:json, too_few_choices)
      assert message =~ "choice kind requires 2 to 255 bounded choices"

      duplicate_levels = %{
        "assertions_json" =>
          Jason.encode!([
            %{
              "type" => "typed_judge",
              "kind" => "score",
              "question" => "Score this",
              "levels" => ["none", "none"],
              "expected" => "none"
            }
          ])
      }

      assert {:error, message} = AssertionParser.parse(:json, duplicate_levels)
      assert message =~ "score kind requires 2 to 10 unique bounded levels"

      missing_rule_level = %{
        "assertions_json" =>
          Jason.encode!([
            %{
              "type" => "typed_judge",
              "kind" => "score",
              "question" => "Score this",
              "levels" => ["none", "minor"],
              "minimum" => "major"
            }
          ])
      }

      assert {:error, message} = AssertionParser.parse(:json, missing_rule_level)
      assert message =~ "score rule value must match"

      overlong_question = %{
        "assertions_json" =>
          Jason.encode!([
            %{
              "type" => "typed_judge",
              "kind" => "noul",
              "question" => String.duplicate("x", 2_001)
            }
          ])
      }

      assert {:error, message} = AssertionParser.parse(:json, overlong_question)
      assert message =~ "question cannot exceed 2000 characters"

      too_many_choices =
        1..256
        |> Map.new(fn index -> {"choice_#{index}", nil} end)
        |> then(fn choices ->
          %{
            "assertions_json" =>
              Jason.encode!([
                %{
                  "type" => "typed_judge",
                  "kind" => "choice",
                  "question" => "Classify this",
                  "choices" => choices,
                  "expected" => "choice_1"
                }
              ])
          }
        end)

      assert {:error, message} = AssertionParser.parse(:json, too_many_choices)
      assert message =~ "2 to 255 bounded choices"

      too_many_levels = %{
        "assertions_json" =>
          Jason.encode!([
            %{
              "type" => "typed_judge",
              "kind" => "score",
              "question" => "Score this",
              "levels" => Enum.map(1..11, &"level_#{&1}"),
              "minimum" => "level_1"
            }
          ])
      }

      assert {:error, message} = AssertionParser.parse(:json, too_many_levels)
      assert message =~ "2 to 10 unique bounded levels"

      oversized_choice = %{
        "assertions_json" =>
          Jason.encode!([
            %{
              "type" => "typed_judge",
              "kind" => "choice",
              "question" => "Classify this",
              "choices" => %{
                "safe" => String.duplicate("x", 2_001),
                String.duplicate("y", 201) => nil
              },
              "expected" => "safe"
            }
          ])
      }

      assert {:error, message} = AssertionParser.parse(:json, oversized_choice)
      assert message =~ "bounded choices"

      oversized_level = %{
        "assertions_json" =>
          Jason.encode!([
            %{
              "type" => "typed_judge",
              "kind" => "score",
              "question" => "Score this",
              "levels" => ["none", String.duplicate("x", 201)],
              "maximum" => "none"
            }
          ])
      }

      assert {:error, message} = AssertionParser.parse(:json, oversized_level)
      assert message =~ "bounded levels"
    end

    test "parses built-in rubric judges in visual mode" do
      provider_id = Ecto.UUID.generate()

      params = %{
        "assertions" => %{
          "assertion_type_0" => "rubric_judge",
          "assertion_rubric_source_0" => "template",
          "assertion_template_0" => "faithfulness",
          "assertion_provider_id_0" => provider_id,
          "assertion_threshold_0" => "85",
          "assertion_expected_0" => "Reference answer",
          "assertion_context_0" => "Grounding evidence"
        }
      }

      assert {:ok,
              [
                %{
                  "type" => "rubric_judge",
                  "template" => "faithfulness",
                  "provider_id" => ^provider_id,
                  "threshold" => 85.0,
                  "expected" => "Reference answer",
                  "context" => "Grounding evidence"
                }
              ]} = AssertionParser.parse(:visual, params)
    end

    test "parses custom rubric judges in visual mode" do
      provider_id = Ecto.UUID.generate()

      params = %{
        "assertions" => %{
          "assertion_type_0" => "rubric_judge",
          "assertion_rubric_source_0" => "custom",
          "assertion_rubric_0" => "Score factual correctness.",
          "assertion_provider_id_0" => provider_id,
          "assertion_threshold_0" => "",
          "assertion_expected_0" => "",
          "assertion_context_0" => ""
        }
      }

      assert {:ok,
              [
                %{
                  "type" => "rubric_judge",
                  "rubric" => "Score factual correctness.",
                  "provider_id" => ^provider_id
                }
              ]} = AssertionParser.parse(:visual, params)
    end

    test "rejects unknown or ambiguous rubric judge templates" do
      provider_id = Ecto.UUID.generate()

      unknown = %{
        "assertions_json" =>
          Jason.encode!([
            %{
              "type" => "rubric_judge",
              "template" => "unknown",
              "provider_id" => provider_id
            }
          ])
      }

      assert {:error, message} = AssertionParser.parse(:json, unknown)
      assert message =~ "known 'template'"

      ambiguous = %{
        "assertions_json" =>
          Jason.encode!([
            %{
              "type" => "rubric_judge",
              "rubric" => "Judge correctness.",
              "template" => "correctness",
              "provider_id" => provider_id
            }
          ])
      }

      assert {:error, message} = AssertionParser.parse(:json, ambiguous)
      assert message =~ "either 'rubric' or a known 'template'"
    end

    test "rejects incomplete rubric judge assertions" do
      params = %{
        "assertions_json" => ~s([{"type":"rubric_judge","rubric":" ","provider_id":"bad"}])
      }

      assert {:error, message} = AssertionParser.parse(:json, params)
      assert message =~ "rubric_judge type requires a non-blank 'rubric'"
    end

    test "parses json_deep_compare assertions in visual mode" do
      params = %{
        "assertions" => %{
          "assertion_type_0" => "json_deep_compare",
          "assertion_expected_json_0" => ~s({"status":"ok","count":2}),
          "assertion_threshold_0" => "75.0"
        }
      }

      assert {:ok,
              [
                %{
                  "type" => "json_deep_compare",
                  "expected" => %{"status" => "ok", "count" => 2},
                  "threshold" => 75.0
                }
              ]} = AssertionParser.parse(:visual, params)
    end

    test "rejects visual assertions with invalid indices" do
      params = %{
        "assertions" => %{
          "assertion_type_abc" => "contains",
          "assertion_value_abc" => "hello"
        }
      }

      assert {:error, "Invalid assertion index: abc"} =
               AssertionParser.parse(:visual, params)
    end

    test "rejects visual string assertions with blank values" do
      params = %{
        "assertions" => %{
          "assertion_type_0" => "contains",
          "assertion_value_0" => "  "
        }
      }

      assert {:error, message} = AssertionParser.parse(:visual, params)
      assert message =~ "contains type requires a non-blank 'value' field"
    end

    test "rejects oversized regular expression patterns" do
      params = %{
        "assertions_json" =>
          Jason.encode!([
            %{"type" => "regex", "value" => String.duplicate("a", 4_097)}
          ])
      }

      assert {:error, message} = AssertionParser.parse(:json, params)
      assert message == "Assertion at index 1: regex pattern cannot exceed 4096 bytes"
    end

    test "rejects invalid regular expression patterns" do
      params = %{
        "assertions_json" => ~s([{"type":"regex","value":"["}])
      }

      assert {:error, message} = AssertionParser.parse(:json, params)
      assert message == "Assertion at index 1: regex pattern is invalid"
    end

    test "rejects json_field assertions missing expected keys" do
      params = %{
        "assertions_json" => ~s([{"type":"json_field"}])
      }

      assert {:error, message} = AssertionParser.parse(:json, params)
      assert message =~ "json_field type requires 'field' and 'expected' fields"
    end

    test "rejects json_field assertions with blank field values" do
      params = %{
        "assertions_json" => ~s([{"type":"json_field","field":"   ","expected":"positive"}])
      }

      assert {:error, message} = AssertionParser.parse(:json, params)
      assert message =~ "json_field type requires a non-blank 'field' value"
    end

    test "rejects json_field assertions with blank expected values in JSON mode" do
      params = %{
        "assertions_json" => ~s([{"type":"json_field","field":"sentiment","expected":"   "}])
      }

      assert {:error, message} = AssertionParser.parse(:json, params)
      assert message =~ "json_field type requires a non-blank 'expected' value"
    end

    test "rejects json_field assertions with blank expected values in visual mode" do
      params = %{
        "assertions" => %{
          "assertion_type_0" => "json_field",
          "assertion_field_0" => "sentiment",
          "assertion_expected_0" => "  "
        }
      }

      assert {:error, message} = AssertionParser.parse(:visual, params)
      assert message =~ "json_field type requires a non-blank 'expected' value"
    end

    test "rejects json_deep_compare assertions with invalid expected JSON" do
      params = %{
        "assertions_json" =>
          ~s([{"type":"json_deep_compare","expected":"not-json-object","threshold":75.0}])
      }

      assert {:error, message} = AssertionParser.parse(:json, params)
      assert message =~ "json_deep_compare type requires an 'expected' map or list"
    end

    test "rejects json_deep_compare assertions with invalid thresholds" do
      params = %{
        "assertions_json" =>
          ~s([{"type":"json_deep_compare","expected":{"status":"ok"},"threshold":120}])
      }

      assert {:error, message} = AssertionParser.parse(:json, params)
      assert message =~ "json_deep_compare type requires a threshold between 0 and 100"
    end
  end

  describe "build_form_params/1" do
    test "builds JSON and visual params from assertions" do
      assertions = [%{"type" => "contains", "value" => "hello"}]

      assert %{
               "assertions_json" => assertions_json,
               "assertions" => %{
                 "assertion_type_0" => "contains",
                 "assertion_value_0" => "hello"
               }
             } = AssertionParser.build_form_params(assertions)

      assert assertions_json =~ "\"type\": \"contains\""
    end

    test "builds visual params for typed json_field assertions" do
      assertions = [%{"type" => "json_field", "field" => "count", "expected" => 1}]

      assert %{
               "assertions" => %{
                 "assertion_type_0" => "json_field",
                 "assertion_field_0" => "count",
                 "assertion_expected_0" => "1",
                 "assertion_expected_json_value_0" => expected_json
               }
             } = AssertionParser.build_form_params(assertions)

      assert expected_json == "1"
    end

    test "builds visual params for json_deep_compare assertions" do
      assertions = [
        %{
          "type" => "json_deep_compare",
          "expected" => %{"status" => "ok", "count" => 2},
          "threshold" => 75.0
        }
      ]

      assert %{
               "assertions_json" => assertions_json,
               "assertions" => %{
                 "assertion_type_0" => "json_deep_compare",
                 "assertion_expected_json_0" => expected_json,
                 "assertion_threshold_0" => "75.0"
               }
             } = AssertionParser.build_form_params(assertions)

      assert assertions_json =~ "\"type\": \"json_deep_compare\""
      assert expected_json =~ "\"status\": \"ok\""
    end

    test "builds visual params for rubric judge assertions" do
      provider_id = Ecto.UUID.generate()

      assertions = [
        %{
          "type" => "rubric_judge",
          "template" => "correctness",
          "provider_id" => provider_id,
          "threshold" => 90,
          "expected" => "Paris",
          "context" => "The question asks for France's capital."
        },
        %{
          "type" => "rubric_judge",
          "rubric" => "Prefer concise, correct answers.",
          "provider_id" => provider_id
        }
      ]

      assert %{
               "assertions" => %{
                 "assertion_rubric_source_0" => "template",
                 "assertion_template_0" => "correctness",
                 "assertion_provider_id_0" => ^provider_id,
                 "assertion_threshold_0" => "90",
                 "assertion_expected_0" => "Paris",
                 "assertion_context_0" => "The question asks for France's capital.",
                 "assertion_rubric_source_1" => "custom",
                 "assertion_rubric_1" => "Prefer concise, correct answers."
               }
             } = AssertionParser.build_form_params(assertions)
    end

    test "preserves typed rubric evidence through visual form params" do
      assertions = [
        %{
          "type" => "rubric_judge",
          "template" => "faithfulness",
          "provider_id" => Ecto.UUID.generate(),
          "expected" => %{"answer" => "Paris"},
          "context" => ["Grounding", %{"source" => "atlas"}]
        }
      ]

      params = AssertionParser.build_form_params(assertions)

      assert {:ok, ^assertions} = AssertionParser.parse(:visual, params)
    end
  end

  describe "preview_visual/1" do
    test "keeps json_field assertions in draft mode when required inputs are blank" do
      params = %{
        "assertions" => %{
          "assertion_type_0" => "json_field",
          "assertion_field_0" => "",
          "assertion_expected_0" => ""
        }
      }

      assert {:ok,
              [
                %{
                  "type" => "json_field",
                  "field" => "",
                  "expected" => ""
                }
              ]} = AssertionParser.preview_visual(params)
    end

    test "switches away from deep compare inputs in draft mode" do
      params = %{
        "assertions" => %{
          "assertion_type_0" => "json_field",
          "assertion_field_0" => "status",
          "assertion_expected_0" => "ok",
          "assertion_expected_json_0" => ~s({"status":"ok"}),
          "assertion_threshold_0" => "80.0"
        }
      }

      assert {:ok,
              [
                %{
                  "type" => "json_field",
                  "field" => "status",
                  "expected" => "ok"
                }
              ]} = AssertionParser.preview_visual(params)
    end

    test "preserves typed json_field expected values when the visual field is unchanged" do
      params = %{
        "assertions" => %{
          "assertion_type_0" => "json_field",
          "assertion_field_0" => "count",
          "assertion_expected_0" => "1",
          "assertion_expected_json_value_0" => "1"
        }
      }

      assert {:ok, [%{"type" => "json_field", "field" => "count", "expected" => 1}]} =
               AssertionParser.parse(:visual, params)
    end
  end
end
