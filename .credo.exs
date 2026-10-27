# This file contains the configuration for Credo and was generated
# with the command: mix credo.gen.config
#
# If you find anything wrong or unclear in this file, please report an
# issue on GitHub: https://github.com/rrrene/credo/issues
#
%{
  configs: [
    %{
      name: "default",
      files: %{
        included: [
          "lib/",
          "dev/",
          "test/",
          "priv/",
          "mix.exs"
        ],
        excluded: [~r"/_build/", ~r"/deps/", ~r"/node_modules/"]
      },
      plugins: [],
      requires: [],
      strict: true,
      color: true,
      checks: %{
        enabled: [
          # Consistency Checks
          {Credo.Check.Consistency.ExceptionNames, []},
          {Credo.Check.Consistency.LineEndings, []},
          {Credo.Check.Consistency.ParameterPatternMatching, []},
          {Credo.Check.Consistency.SpaceAroundOperators, []},
          {Credo.Check.Consistency.SpaceInParentheses, []},
          {Credo.Check.Consistency.TabsOrSpaces, []},

          # Design Checks
          {Credo.Check.Design.AliasUsage,
           [priority: :low, if_nested_deeper_than: 2, if_called_more_often_than: 1]},
          {Credo.Check.Design.TagFIXME, []},

          # Readability Checks
          # Credo 1.7.19 newly reports these established alias groups on 1.x.
          {Credo.Check.Readability.AliasOrder,
           [
             files: %{
               excluded: [
                 "lib/ex_mcp/acp/adapters/claude_sdk/mapper.ex",
                 "lib/ex_mcp/acp/adapters/pi/prompt_flow.ex",
                 "lib/ex_mcp/acp/adapters/zcode.ex",
                 "lib/ex_mcp/acp/adapters/zcode/mapper.ex",
                 "test/ex_mcp/integration/acp_adapter_cli_interop_test.exs"
               ]
             }
           ]},
          {Credo.Check.Readability.FunctionNames, []},
          {Credo.Check.Readability.MaxLineLength, [priority: :low, max_length: 120]},
          {Credo.Check.Readability.ModuleAttributeNames, []},
          {Credo.Check.Readability.ModuleDoc, []},
          {Credo.Check.Readability.ModuleNames, []},
          {Credo.Check.Readability.ParenthesesInCondition, []},
          {Credo.Check.Readability.ParenthesesOnZeroArityDefs, []},
          {Credo.Check.Readability.PipeIntoAnonymousFunctions, []},
          {Credo.Check.Readability.PredicateFunctionNames, []},
          {Credo.Check.Readability.PreferImplicitTry, []},
          {Credo.Check.Readability.RedundantBlankLines, []},
          {Credo.Check.Readability.Semicolons, []},
          {Credo.Check.Readability.SpaceAfterCommas, []},
          {Credo.Check.Readability.StringSigils, []},
          {Credo.Check.Readability.TrailingBlankLine, []},
          {Credo.Check.Readability.TrailingWhiteSpace, []},
          {Credo.Check.Readability.UnnecessaryAliasExpansion, []},
          {Credo.Check.Readability.VariableNames, []},
          {Credo.Check.Readability.WithSingleClause, []},

          # Refactoring Opportunities
          {Credo.Check.Refactor.Apply, []},
          {Credo.Check.Refactor.CondStatements, []},
          {Credo.Check.Refactor.CyclomaticComplexity, [max_complexity: 11]},
          {Credo.Check.Refactor.FilterCount, []},
          {Credo.Check.Refactor.FilterFilter, []},
          {Credo.Check.Refactor.FunctionArity, []},
          {Credo.Check.Refactor.LongQuoteBlocks, [max_line_count: 250]},
          {Credo.Check.Refactor.MapJoin, []},
          {Credo.Check.Refactor.MatchInCondition, []},
          {Credo.Check.Refactor.NegatedConditionsInUnless, []},
          # Credo 1.7.19 newly reports this legacy callback parser's nesting.
          {Credo.Check.Refactor.Nesting,
           [max_nesting: 4, files: %{excluded: ["lib/ex_mcp/authorization/full_oauth_flow.ex"]}]},
          {Credo.Check.Refactor.RedundantWithClauseResult, []},
          {Credo.Check.Refactor.RejectReject, []},
          {Credo.Check.Refactor.UnlessWithElse, []},
          {Credo.Check.Refactor.WithClauses, []},

          # Warnings
          {Credo.Check.Warning.ApplicationConfigInModuleAttribute, []},
          {Credo.Check.Warning.BoolOperationOnSameValues, []},
          {Credo.Check.Warning.Dbg, []},
          # Credo 1.7.19 newly reports legacy length/1 checks in these files;
          # their list-shape semantics are retained on the 1.x maintenance line.
          {Credo.Check.Warning.ExpensiveEmptyEnumCheck,
           [
             files: %{
               excluded: [
                 "lib/ex_mcp/authorization/oauth_flow.ex",
                 "lib/ex_mcp/protocol/trace_context.ex",
                 "lib/ex_mcp/security/validation.ex",
                 "lib/ex_mcp/session_manager.ex",
                 "lib/ex_mcp/testing/assertions.ex",
                 "test/ex_mcp/application_test.exs",
                 "test/ex_mcp/cancellation_comprehensive_test.exs",
                 "test/ex_mcp/cancellation_test.exs",
                 "test/ex_mcp/client_complete_test.exs",
                 "test/ex_mcp/compliance/completion_compliance_test.exs",
                 "test/ex_mcp/compliance/features/completion.ex",
                 "test/ex_mcp/compliance/features/prompts.ex",
                 "test/ex_mcp/compliance/features/resource_templates.ex",
                 "test/ex_mcp/compliance/features/resources.ex",
                 "test/ex_mcp/compliance/features/roots.ex",
                 "test/ex_mcp/compliance/features/tools.ex",
                 "test/ex_mcp/compliance/features/transport.ex",
                 "test/ex_mcp/compliance/pagination_compliance_test.exs",
                 "test/ex_mcp/compliance/resources_compliance_test.exs",
                 "test/ex_mcp/compliance/server_streamable_http_compliance_test.exs",
                 "test/ex_mcp/content/validation_test.exs",
                 "test/ex_mcp/integration/everything_http_interop_test.exs",
                 "test/ex_mcp/integration/interop_test.exs",
                 "test/ex_mcp/progress_meta_comprehensive_test.exs",
                 "test/ex_mcp/reliability/health_check_test.exs",
                 "test/ex_mcp/sampling_test.exs",
                 "test/ex_mcp/session_management_integration_test.exs",
                 "test/ex_mcp/structured_output_test.exs",
                 "test/ex_mcp/testing/builders_test.exs",
                 "test/ex_mcp/transport/stdio_isolation_test.exs",
                 "test/ex_mcp/types/v20251125_test.exs",
                 "test/support/performance_profiler.ex",
                 "test/support/test_support.ex",
                 "test/test_helper.exs"
               ]
             }
           ]},
          {Credo.Check.Warning.IExPry, []},
          {Credo.Check.Warning.IoInspect, []},
          {Credo.Check.Warning.MissedMetadataKeyInLoggerConfig, []},
          {Credo.Check.Warning.OperationOnSameValues, []},
          {Credo.Check.Warning.OperationWithConstantResult, []},
          {Credo.Check.Warning.RaiseInsideRescue, []},
          {Credo.Check.Warning.SpecWithStruct, []},
          {Credo.Check.Warning.UnsafeExec, []},
          {Credo.Check.Warning.UnusedEnumOperation, []},
          {Credo.Check.Warning.UnusedFileOperation, []},
          {Credo.Check.Warning.UnusedKeywordOperation, []},
          {Credo.Check.Warning.UnusedListOperation, []},
          {Credo.Check.Warning.UnusedPathOperation, []},
          {Credo.Check.Warning.UnusedRegexOperation, []},
          {Credo.Check.Warning.UnusedStringOperation, []},
          {Credo.Check.Warning.UnusedTupleOperation, []},
          {Credo.Check.Warning.WrongTestFileExtension, []}
        ],
        disabled: [
          # Disabled because JSON-RPC error codes must match spec exactly
          {Credo.Check.Readability.LargeNumbers, []},
          # TODOs are tracked in TASKS.md
          {Credo.Check.Design.TagTODO, []},
          # Negated conditions are sometimes clearer
          {Credo.Check.Refactor.NegatedConditionsWithElse, []},
          
          # Checks scheduled for next check update (opt-in for now)
          {Credo.Check.Refactor.UtcNowTruncate, []},

          # Controversial and experimental checks (opt-in, just move the check to `:enabled`
          # and be sure to use `mix credo --strict` to see low priority checks)
          {Credo.Check.Consistency.MultiAliasImportRequireUse, []},
          {Credo.Check.Consistency.UnusedVariableNames, []},
          {Credo.Check.Design.DuplicatedCode, []},
          {Credo.Check.Design.SkipTestWithoutComment, []},
          {Credo.Check.Readability.AliasAs, []},
          {Credo.Check.Readability.BlockPipe, []},
          {Credo.Check.Readability.ImplTrue, []},
          {Credo.Check.Readability.MultiAlias, []},
          {Credo.Check.Readability.NestedFunctionCalls, []},
          {Credo.Check.Readability.OneArityFunctionInPipe, []},
          {Credo.Check.Readability.OnePipePerLine, []},
          {Credo.Check.Readability.SeparateAliasRequire, []},
          {Credo.Check.Readability.SingleFunctionToBlockPipe, []},
          {Credo.Check.Readability.SinglePipe, []},
          {Credo.Check.Readability.Specs, []},
          {Credo.Check.Readability.StrictModuleLayout, []},
          {Credo.Check.Readability.WithCustomTaggedTuple, []},
          {Credo.Check.Refactor.ABCSize, []},
          {Credo.Check.Refactor.AppendSingleItem, []},
          {Credo.Check.Refactor.DoubleBooleanNegation, []},
          {Credo.Check.Refactor.FilterReject, []},
          {Credo.Check.Refactor.IoPuts, []},
          {Credo.Check.Refactor.MapMap, []},
          {Credo.Check.Refactor.ModuleDependencies, []},
          {Credo.Check.Refactor.NegatedIsNil, []},
          {Credo.Check.Refactor.PassAsyncInTestCases, []},
          {Credo.Check.Refactor.PipeChainStart, []},
          {Credo.Check.Refactor.RejectFilter, []},
          {Credo.Check.Refactor.VariableRebinding, []},
          {Credo.Check.Warning.LazyLogging, []},
          {Credo.Check.Warning.LeakyEnvironment, []},
          {Credo.Check.Warning.MapGetUnsafePass, []},
          {Credo.Check.Warning.MixEnv, []},
          {Credo.Check.Warning.UnsafeToAtom, []}
        ]
      }
    }
  ]
}
