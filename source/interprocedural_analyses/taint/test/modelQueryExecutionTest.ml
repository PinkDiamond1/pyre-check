(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open OUnit2
open Core
open Pyre
open Test
open Taint
open Interprocedural
module ModelQuery = ModelParseResult.ModelQuery

type query_element = ModelParseResult.ModelAnnotation.t [@@deriving show, equal]

let source ?subkind name =
  let source =
    match subkind with
    | None -> Sources.NamedSource name
    | Some subkind -> Sources.ParametricSource { source_name = name; subkind }
  in
  ModelParseResult.TaintAnnotation.from_source source


let sink name =
  let sink = Sinks.NamedSink name in
  ModelParseResult.TaintAnnotation.from_sink sink


let test_generated_annotations context =
  let assert_generated_annotations ~source ~query ~callable ~expected =
    let { ScratchProject.BuiltTypeEnvironment.type_environment; _ } =
      ScratchProject.setup ~context ["test.py", source] |> ScratchProject.build_type_environment
    in
    let global_resolution = Analysis.TypeEnvironment.ReadOnly.global_resolution type_environment in
    let class_hierarchy_graph =
      Interprocedural.ClassHierarchyGraph.Heap.from_qualifiers
        ~scheduler:(mock_scheduler ())
        ~environment:type_environment
        ~qualifiers:[Ast.Reference.create "test"]
      |> Interprocedural.ClassHierarchyGraph.SharedMemory.from_heap
    in
    let actual =
      ModelQueryExecution.CallableQueryExecutor.generate_annotations_from_query_on_target
        ~verbose:false
        ~resolution:global_resolution
        ~class_hierarchy_graph
        ~target:callable
        query
    in
    assert_equal
      ~cmp:(List.equal equal_query_element)
      ~printer:(List.to_string ~f:show_query_element)
      expected
      actual
  in
  let assert_generated_annotations_for_attributes ~source ~query ~name ~annotation ~expected =
    let { ScratchProject.BuiltTypeEnvironment.type_environment; _ } =
      ScratchProject.setup ~context ["test.py", source] |> ScratchProject.build_type_environment
    in
    let global_resolution = Analysis.TypeEnvironment.ReadOnly.global_resolution type_environment in
    let class_hierarchy_graph =
      Interprocedural.ClassHierarchyGraph.Heap.from_qualifiers
        ~scheduler:(mock_scheduler ())
        ~environment:type_environment
        ~qualifiers:[Ast.Reference.create "test"]
      |> Interprocedural.ClassHierarchyGraph.SharedMemory.from_heap
    in
    let annotation_expression =
      annotation
      >>= fun annotation ->
      try
        let parsed = PyreParser.Parser.parse_exn [annotation] in
        match parsed with
        | [{ Ast.Node.value = Expression expression; _ }] -> Some expression
        | _ -> None
      with
      | _ -> None
    in
    let actual =
      ModelQueryExecution.AttributeQueryExecutor.generate_annotations_from_query_on_target
        ~verbose:false
        ~resolution:global_resolution
        ~class_hierarchy_graph
        ~target:{ name = Ast.Reference.create name; type_annotation = annotation_expression }
        query
    in
    assert_equal
      ~cmp:(List.equal ModelParseResult.TaintAnnotation.equal)
      ~printer:(List.to_string ~f:ModelParseResult.TaintAnnotation.show)
      expected
      actual
  in
  let assert_generated_annotations_for_globals ~source ~query ~name ~expected =
    let { ScratchProject.BuiltTypeEnvironment.type_environment; _ } =
      ScratchProject.setup ~context ["test.py", source] |> ScratchProject.build_type_environment
    in
    let global_resolution = Analysis.TypeEnvironment.ReadOnly.global_resolution type_environment in
    let class_hierarchy_graph =
      Interprocedural.ClassHierarchyGraph.Heap.from_qualifiers
        ~scheduler:(mock_scheduler ())
        ~environment:type_environment
        ~qualifiers:[Ast.Reference.create "test"]
      |> Interprocedural.ClassHierarchyGraph.SharedMemory.from_heap
    in
    let actual =
      ModelQueryExecution.GlobalVariableQueryExecutor.generate_annotations_from_query_on_target
        ~verbose:false
        ~resolution:global_resolution
        ~class_hierarchy_graph
        ~target:{ name = Ast.Reference.create name; type_annotation = None }
        query
    in
    assert_equal
      ~cmp:(List.equal ModelParseResult.TaintAnnotation.equal)
      ~printer:(List.to_string ~f:ModelParseResult.TaintAnnotation.show)
      expected
      actual
  in
  assert_generated_annotations
    ~source:{|
      def foo(): ...
      |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where = [NameConstraint (Matches (Re2.create_exn "foo"))];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Function;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Function { name = "test.foo"; kind = Normal })
    ~expected:[ModelParseResult.ModelAnnotation.ReturnAnnotation (source "Test")];
  assert_generated_annotations
    ~source:{|
      def foo(): ...
      |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where = [NameConstraint (Equals "foo")];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Function;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Function { name = "test.foo"; kind = Normal })
    ~expected:[];
  assert_generated_annotations
    ~source:{|
      def foo(): ...
      |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where = [NameConstraint (Equals "test.foo")];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Function;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Function { name = "test.foo"; kind = Normal })
    ~expected:[ModelParseResult.ModelAnnotation.ReturnAnnotation (source "Test")];

  (* Test multiple constraints. *)
  assert_generated_annotations
    ~source:{|
      def foo(): ...
      def barfoo(): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where =
          [
            NameConstraint (Matches (Re2.create_exn "foo"));
            NameConstraint (Matches (Re2.create_exn "bar"));
          ];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Function;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Function { name = "test.barfoo"; kind = Normal })
    ~expected:[ModelParseResult.ModelAnnotation.ReturnAnnotation (source "Test")];
  assert_generated_annotations
    ~source:{|
      def foo(): ...
      def barfoo(): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where =
          [
            NameConstraint (Matches (Re2.create_exn "foo"));
            NameConstraint (Matches (Re2.create_exn "bar"));
          ];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Function;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Function { name = "test.foo"; kind = Normal })
    ~expected:[];

  (* Method vs. callable productions. *)
  assert_generated_annotations
    ~source:{|
      class C:
        def foo(): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where = [NameConstraint (Matches (Re2.create_exn "foo"))];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Function;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Method { class_name = "test.C"; method_name = "foo"; kind = Normal })
    ~expected:[];

  assert_generated_annotations
    ~source:{|
      class C:
        def foo(): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where = [NameConstraint (Matches (Re2.create_exn "foo"))];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Method;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Method { class_name = "test.C"; method_name = "foo"; kind = Normal })
    ~expected:[ModelParseResult.ModelAnnotation.ReturnAnnotation (source "Test")];

  (* Multiple productions. *)
  assert_generated_annotations
    ~source:{|
      class C:
        def foo(x: int): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where = [NameConstraint (Matches (Re2.create_exn "foo"))];
        models =
          [
            Return [TaintAnnotation (source "Test")];
            NamedParameter { name = "x"; taint = [TaintAnnotation (source "Test")] };
          ];
        find = Method;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Method { class_name = "test.C"; method_name = "foo"; kind = Normal })
    ~expected:
      [
        ModelParseResult.ModelAnnotation.ReturnAnnotation (source "Test");
        ModelParseResult.ModelAnnotation.ParameterAnnotation
          ( AccessPath.Root.PositionalParameter { position = 0; name = "x"; positional_only = false },
            source "Test" );
      ];
  (* All parameter taint. *)
  assert_generated_annotations
    ~source:{|
      class C:
        def foo(x: int, y: str): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where = [NameConstraint (Matches (Re2.create_exn "foo"))];
        models = [AllParameters { excludes = []; taint = [TaintAnnotation (source "Test")] }];
        find = Method;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Method { class_name = "test.C"; method_name = "foo"; kind = Normal })
    ~expected:
      [
        ModelParseResult.ModelAnnotation.ParameterAnnotation
          ( AccessPath.Root.PositionalParameter { position = 0; name = "x"; positional_only = false },
            source "Test" );
        ModelParseResult.ModelAnnotation.ParameterAnnotation
          ( AccessPath.Root.PositionalParameter { position = 1; name = "y"; positional_only = false },
            source "Test" );
      ];
  assert_generated_annotations
    ~source:{|
      class C:
        def foo(x: int, y: str): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where = [NameConstraint (Matches (Re2.create_exn "foo"))];
        models = [AllParameters { excludes = ["x"]; taint = [TaintAnnotation (source "Test")] }];
        find = Method;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Method { class_name = "test.C"; method_name = "foo"; kind = Normal })
    ~expected:
      [
        ModelParseResult.ModelAnnotation.ParameterAnnotation
          ( AccessPath.Root.PositionalParameter { position = 1; name = "y"; positional_only = false },
            source "Test" );
      ];
  assert_generated_annotations
    ~source:{|
      class C:
        def foo(x: int, y: str): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where = [NameConstraint (Matches (Re2.create_exn "foo"))];
        models = [AllParameters { excludes = ["y"]; taint = [TaintAnnotation (source "Test")] }];
        find = Method;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Method { class_name = "test.C"; method_name = "foo"; kind = Normal })
    ~expected:
      [
        ModelParseResult.ModelAnnotation.ParameterAnnotation
          ( AccessPath.Root.PositionalParameter { position = 0; name = "x"; positional_only = false },
            source "Test" );
      ];

  (* Parameter taint. *)
  assert_generated_annotations
    ~source:{|
      class C:
        def foo(x: int, y: str): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where = [NameConstraint (Matches (Re2.create_exn "foo"))];
        models =
          [
            Parameter
              {
                where = [NameConstraint (Matches (Re2.create_exn "x"))];
                taint = [TaintAnnotation (source "Test")];
              };
          ];
        find = Method;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Method { class_name = "test.C"; method_name = "foo"; kind = Normal })
    ~expected:
      [
        ModelParseResult.ModelAnnotation.ParameterAnnotation
          ( AccessPath.Root.PositionalParameter { position = 0; name = "x"; positional_only = false },
            source "Test" );
      ];
  assert_generated_annotations
    ~source:{|
      class C:
        def foo(x: int, y: str): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where = [NameConstraint (Matches (Re2.create_exn "foo"))];
        models =
          [
            Parameter
              {
                where = [Not (NameConstraint (Matches (Re2.create_exn "y")))];
                taint = [TaintAnnotation (source "Test")];
              };
          ];
        find = Method;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Method { class_name = "test.C"; method_name = "foo"; kind = Normal })
    ~expected:
      [
        ModelParseResult.ModelAnnotation.ParameterAnnotation
          ( AccessPath.Root.PositionalParameter { position = 0; name = "x"; positional_only = false },
            source "Test" );
      ];
  assert_generated_annotations
    ~source:{|
      class C:
        def foo(x: int, y: str): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where = [NameConstraint (Matches (Re2.create_exn "foo"))];
        models =
          [
            Parameter
              {
                where =
                  [
                    ModelQuery.ParameterConstraint.AnnotationConstraint
                      (NameConstraint (Matches (Re2.create_exn "int")));
                  ];
                taint = [TaintAnnotation (source "Test")];
              };
          ];
        find = Method;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Method { class_name = "test.C"; method_name = "foo"; kind = Normal })
    ~expected:
      [
        ModelParseResult.ModelAnnotation.ParameterAnnotation
          ( AccessPath.Root.PositionalParameter { position = 0; name = "x"; positional_only = false },
            source "Test" );
      ];
  assert_generated_annotations
    ~source:{|
      class C:
        def foo(x: int, y: str): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where = [NameConstraint (Matches (Re2.create_exn "foo"))];
        models =
          [
            Parameter
              {
                where =
                  [
                    Not
                      (ModelQuery.ParameterConstraint.AnnotationConstraint
                         (NameConstraint (Equals "int")));
                  ];
                taint = [TaintAnnotation (source "Test")];
              };
          ];
        find = Method;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Method { class_name = "test.C"; method_name = "foo"; kind = Normal })
    ~expected:
      [
        ModelParseResult.ModelAnnotation.ParameterAnnotation
          ( AccessPath.Root.PositionalParameter { position = 1; name = "y"; positional_only = false },
            source "Test" );
      ];
  assert_generated_annotations
    ~source:
      {|
      from typing import Annotated
      class C:
        def foo(x: int, y: Annotated[str, "foo"]): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where = [NameConstraint (Matches (Re2.create_exn "foo"))];
        models =
          [
            Parameter
              {
                where =
                  [ModelQuery.ParameterConstraint.AnnotationConstraint IsAnnotatedTypeConstraint];
                taint = [TaintAnnotation (source "Test")];
              };
          ];
        find = Method;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Method { class_name = "test.C"; method_name = "foo"; kind = Normal })
    ~expected:
      [
        ModelParseResult.ModelAnnotation.ParameterAnnotation
          ( AccessPath.Root.PositionalParameter { position = 1; name = "y"; positional_only = false },
            source "Test" );
      ];
  assert_generated_annotations
    ~source:{|
      def foo(x: int, y: str): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where = [NameConstraint (Matches (Re2.create_exn "foo"))];
        models =
          [
            Parameter
              {
                where = [NameConstraint (Matches (Re2.create_exn "x"))];
                taint = [TaintAnnotation (source "Test")];
              };
          ];
        find = Function;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Function { name = "test.foo"; kind = Normal })
    ~expected:
      [
        ModelParseResult.ModelAnnotation.ParameterAnnotation
          ( AccessPath.Root.PositionalParameter { position = 0; name = "x"; positional_only = false },
            source "Test" );
      ];
  assert_generated_annotations
    ~source:{|
      def foo(x: int, y: str): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where = [NameConstraint (Matches (Re2.create_exn "foo"))];
        models =
          [
            Parameter
              {
                where = [Not (NameConstraint (Matches (Re2.create_exn "y")))];
                taint = [TaintAnnotation (source "Test")];
              };
          ];
        find = Function;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Function { name = "test.foo"; kind = Normal })
    ~expected:
      [
        ModelParseResult.ModelAnnotation.ParameterAnnotation
          ( AccessPath.Root.PositionalParameter { position = 0; name = "x"; positional_only = false },
            source "Test" );
      ];
  assert_generated_annotations
    ~source:{|
      def foo(x: int, y: str): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where = [NameConstraint (Matches (Re2.create_exn "foo"))];
        models =
          [
            Parameter
              {
                where =
                  [
                    ModelQuery.ParameterConstraint.AnnotationConstraint
                      (NameConstraint (Matches (Re2.create_exn "int")));
                  ];
                taint = [TaintAnnotation (source "Test")];
              };
          ];
        find = Function;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Function { name = "test.foo"; kind = Normal })
    ~expected:
      [
        ModelParseResult.ModelAnnotation.ParameterAnnotation
          ( AccessPath.Root.PositionalParameter { position = 0; name = "x"; positional_only = false },
            source "Test" );
      ];
  assert_generated_annotations
    ~source:{|
      def foo(x: int, y: str): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where = [NameConstraint (Matches (Re2.create_exn "foo"))];
        models =
          [
            Parameter
              {
                where =
                  [
                    Not
                      (ModelQuery.ParameterConstraint.AnnotationConstraint
                         (NameConstraint (Equals "int")));
                  ];
                taint = [TaintAnnotation (source "Test")];
              };
          ];
        find = Function;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Function { name = "test.foo"; kind = Normal })
    ~expected:
      [
        ModelParseResult.ModelAnnotation.ParameterAnnotation
          ( AccessPath.Root.PositionalParameter { position = 1; name = "y"; positional_only = false },
            source "Test" );
      ];
  assert_generated_annotations
    ~source:
      {|
      from typing import Annotated
      def foo(x: int, y: Annotated[str, "foo"]): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where = [NameConstraint (Matches (Re2.create_exn "foo"))];
        models =
          [
            Parameter
              {
                where =
                  [ModelQuery.ParameterConstraint.AnnotationConstraint IsAnnotatedTypeConstraint];
                taint = [TaintAnnotation (source "Test")];
              };
          ];
        find = Function;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Function { name = "test.foo"; kind = Normal })
    ~expected:
      [
        ModelParseResult.ModelAnnotation.ParameterAnnotation
          ( AccessPath.Root.PositionalParameter { position = 1; name = "y"; positional_only = false },
            source "Test" );
      ];
  assert_generated_annotations
    ~source:{|
      def foo(x, y): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where = [NameConstraint (Matches (Re2.create_exn "foo"))];
        models =
          [
            Parameter
              {
                where = [ModelQuery.ParameterConstraint.IndexConstraint 0];
                taint = [TaintAnnotation (source "Test")];
              };
          ];
        find = Function;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Function { name = "test.foo"; kind = Normal })
    ~expected:
      [
        ModelParseResult.ModelAnnotation.ParameterAnnotation
          ( AccessPath.Root.PositionalParameter { position = 0; name = "x"; positional_only = false },
            source "Test" );
      ];
  assert_generated_annotations
    ~source:{|
      def foo(x, y): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where = [NameConstraint (Matches (Re2.create_exn "foo"))];
        models =
          [
            Parameter
              {
                where = [ModelQuery.ParameterConstraint.IndexConstraint 1];
                taint = [TaintAnnotation (source "Test")];
              };
          ];
        find = Function;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Function { name = "test.foo"; kind = Normal })
    ~expected:
      [
        ModelParseResult.ModelAnnotation.ParameterAnnotation
          ( AccessPath.Root.PositionalParameter { position = 1; name = "y"; positional_only = false },
            source "Test" );
      ];
  assert_generated_annotations
    ~source:{|
      def foo(x, y): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where = [NameConstraint (Matches (Re2.create_exn "foo"))];
        models = [Parameter { where = []; taint = [TaintAnnotation (source "Test")] }];
        find = Function;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Function { name = "test.foo"; kind = Normal })
    ~expected:
      [
        ModelParseResult.ModelAnnotation.ParameterAnnotation
          ( AccessPath.Root.PositionalParameter { position = 0; name = "x"; positional_only = false },
            source "Test" );
        ModelParseResult.ModelAnnotation.ParameterAnnotation
          ( AccessPath.Root.PositionalParameter { position = 1; name = "y"; positional_only = false },
            source "Test" );
      ];

  (* Annotated returns. *)
  assert_generated_annotations
    ~source:
      {|
       from typing import Annotated
       def foo(x: int, y: str) -> Annotated[int, "annotation"]: ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where = [ReturnConstraint IsAnnotatedTypeConstraint];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Function;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Function { name = "test.foo"; kind = Normal })
    ~expected:[ModelParseResult.ModelAnnotation.ReturnAnnotation (source "Test")];
  assert_generated_annotations
    ~source:{|
       def foo(x: int, y: str) -> int: ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where = [ReturnConstraint IsAnnotatedTypeConstraint];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Function;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Function { name = "test.foo"; kind = Normal })
    ~expected:[];
  assert_generated_annotations
    ~source:{|
       def foo(x: int, y: str): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where = [ReturnConstraint IsAnnotatedTypeConstraint];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Function;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Function { name = "test.foo"; kind = Normal })
    ~expected:[];
  assert_generated_annotations
    ~source:{|
       def foo(x: typing.Annotated[int, "annotation"], y: str): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where = [AnyParameterConstraint (AnnotationConstraint IsAnnotatedTypeConstraint)];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Function;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Function { name = "test.foo"; kind = Normal })
    ~expected:[ModelParseResult.ModelAnnotation.ReturnAnnotation (source "Test")];
  assert_generated_annotations
    ~source:{|
       def foo(a, b: typing.Annotated[int, "annotation"], c: str): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where = [AnyParameterConstraint (AnnotationConstraint IsAnnotatedTypeConstraint)];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Function;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Function { name = "test.foo"; kind = Normal })
    ~expected:[ModelParseResult.ModelAnnotation.ReturnAnnotation (source "Test")];
  (* Any of. *)
  assert_generated_annotations
    ~source:{|
       def foo(a, b: typing.Annotated[int, "annotation"], c: str): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where =
          [
            AnyOf
              [
                AnyParameterConstraint (AnnotationConstraint IsAnnotatedTypeConstraint);
                ReturnConstraint IsAnnotatedTypeConstraint;
              ];
          ];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Function;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Function { name = "test.foo"; kind = Normal })
    ~expected:[ModelParseResult.ModelAnnotation.ReturnAnnotation (source "Test")];
  assert_generated_annotations
    ~source:{|
       def foo(a, b, c: str) -> typing.Annotated[int, "annotation"]: ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where =
          [
            AnyOf
              [
                AnyParameterConstraint (AnnotationConstraint IsAnnotatedTypeConstraint);
                ReturnConstraint IsAnnotatedTypeConstraint;
              ];
          ];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Function;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Function { name = "test.foo"; kind = Normal })
    ~expected:[ModelParseResult.ModelAnnotation.ReturnAnnotation (source "Test")];
  assert_generated_annotations
    ~source:{|
       def foo(a, b: typing.Annotated[int, DynamicSource(A)], c: str): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where = [AnyParameterConstraint (AnnotationConstraint IsAnnotatedTypeConstraint)];
        models =
          [
            PositionalParameter
              {
                index = 1;
                taint =
                  [
                    ParametricSourceFromAnnotation
                      { source_pattern = "DynamicSource"; kind = "Dynamic" };
                  ];
              };
          ];
        find = Function;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Function { name = "test.foo"; kind = Normal })
    ~expected:
      [
        ModelParseResult.ModelAnnotation.ParameterAnnotation
          ( AccessPath.Root.PositionalParameter { position = 1; name = "b"; positional_only = false },
            source ~subkind:"A" "Dynamic" );
      ];
  (* Case where we don't match. *)
  assert_generated_annotations
    ~source:{|
       def foo(a, b: typing.Annotated[int, DynamicSource(A)], c: str): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where = [AnyParameterConstraint (AnnotationConstraint IsAnnotatedTypeConstraint)];
        models =
          [
            PositionalParameter
              {
                index = 0;
                taint =
                  [
                    ParametricSourceFromAnnotation
                      { source_pattern = "DynamicSource"; kind = "Dynamic" };
                  ];
              };
          ];
        find = Function;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Function { name = "test.foo"; kind = Normal })
    ~expected:[];
  (* All of. *)
  assert_generated_annotations
    ~source:
      {|
       def foo(a: typing.Annotated[int, "annotation"])-> typing.Annotated[int, "annotation"]: ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where =
          [
            AllOf
              [
                AnyParameterConstraint (AnnotationConstraint IsAnnotatedTypeConstraint);
                ReturnConstraint IsAnnotatedTypeConstraint;
              ];
          ];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Function;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Function { name = "test.foo"; kind = Normal })
    ~expected:[ModelParseResult.ModelAnnotation.ReturnAnnotation (source "Test")];
  (* Some cases where we don't match with "AllOf". *)
  assert_generated_annotations
    ~source:{|
       def foo(a: typing.Annotated[int, "annotation"]): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where =
          [
            AllOf
              [
                AnyParameterConstraint (AnnotationConstraint IsAnnotatedTypeConstraint);
                ReturnConstraint IsAnnotatedTypeConstraint;
              ];
          ];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Function;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Function { name = "test.foo"; kind = Normal })
    ~expected:[];
  assert_generated_annotations
    ~source:{|
       def foo(a) -> typing.Annotated[int, "annotation"]): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where =
          [
            AllOf
              [
                AnyParameterConstraint (AnnotationConstraint IsAnnotatedTypeConstraint);
                ReturnConstraint IsAnnotatedTypeConstraint;
              ];
          ];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Function;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Function { name = "test.foo"; kind = Normal })
    ~expected:[];
  (* Named parameters + parametric sources from annotation. *)
  assert_generated_annotations
    ~source:{|
       def foo(a, b: typing.Annotated[int, DynamicSource(A)], c: str): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where = [AnyParameterConstraint (AnnotationConstraint IsAnnotatedTypeConstraint)];
        models =
          [
            NamedParameter
              {
                name = "b";
                taint =
                  [
                    ParametricSourceFromAnnotation
                      { source_pattern = "DynamicSource"; kind = "Dynamic" };
                  ];
              };
          ];
        find = Function;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Function { name = "test.foo"; kind = Normal })
    ~expected:
      [
        ModelParseResult.ModelAnnotation.ParameterAnnotation
          ( AccessPath.Root.PositionalParameter { position = 1; name = "b"; positional_only = false },
            source ~subkind:"A" "Dynamic" );
      ];
  (* All parameters taint + parametric source from annotation. *)
  assert_generated_annotations
    ~source:{|
       def foo(a, b: typing.Annotated[int, DynamicSource(A)], c: str): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where = [AnyParameterConstraint (AnnotationConstraint IsAnnotatedTypeConstraint)];
        models =
          [
            AllParameters
              {
                excludes = [];
                taint =
                  [
                    ParametricSourceFromAnnotation
                      { source_pattern = "DynamicSource"; kind = "Dynamic" };
                  ];
              };
          ];
        find = Function;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Function { name = "test.foo"; kind = Normal })
    ~expected:
      [
        ModelParseResult.ModelAnnotation.ParameterAnnotation
          ( AccessPath.Root.PositionalParameter { position = 1; name = "b"; positional_only = false },
            source ~subkind:"A" "Dynamic" );
      ];
  (* Returned taint + parametric source from annotation. *)
  assert_generated_annotations
    ~source:{|
       def foo(a) -> typing.Annotated[int, DynamicSource(B)]: ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where = [ReturnConstraint IsAnnotatedTypeConstraint];
        models =
          [
            Return
              [
                ParametricSourceFromAnnotation { source_pattern = "DynamicSource"; kind = "Dynamic" };
              ];
          ];
        find = Function;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Function { name = "test.foo"; kind = Normal })
    ~expected:[ModelParseResult.ModelAnnotation.ReturnAnnotation (source ~subkind:"B" "Dynamic")];
  (* Named parameters + parametric sinks from annotation. *)
  assert_generated_annotations
    ~source:{|
       def foo(a, b: typing.Annotated[int, DynamicSink(BSink)], c: str): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where = [AnyParameterConstraint (AnnotationConstraint IsAnnotatedTypeConstraint)];
        models =
          [
            NamedParameter
              {
                name = "b";
                taint =
                  [ParametricSinkFromAnnotation { sink_pattern = "DynamicSink"; kind = "Dynamic" }];
              };
          ];
        find = Function;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Function { name = "test.foo"; kind = Normal })
    ~expected:
      [
        ModelParseResult.ModelAnnotation.ParameterAnnotation
          ( AccessPath.Root.PositionalParameter { position = 1; name = "b"; positional_only = false },
            ModelParseResult.TaintAnnotation.from_sink
              (Sinks.ParametricSink { sink_name = "Dynamic"; subkind = "BSink" }) );
      ];
  (* Type annotation constraint for callables *)
  assert_generated_annotations
    ~source:{|
       def foo(a, b: typing.Annotated[str, "foo"], c: str, d: int): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where = [AnyParameterConstraint (AnnotationConstraint IsAnnotatedTypeConstraint)];
        models =
          [
            Parameter
              {
                where = [AnnotationConstraint IsAnnotatedTypeConstraint];
                taint = [TaintAnnotation (source "Test")];
              };
          ];
        find = Function;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Function { name = "test.foo"; kind = Normal })
    ~expected:
      [
        ModelParseResult.ModelAnnotation.ParameterAnnotation
          ( AccessPath.Root.PositionalParameter { position = 1; name = "b"; positional_only = false },
            source "Test" );
      ];
  assert_generated_annotations
    ~source:{|
       def foo(a, b: typing.Annotated[str, "foo"], c: str, d: int): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where =
          [
            AnyParameterConstraint
              (AnnotationConstraint (NameConstraint (Matches (Re2.create_exn "str"))));
          ];
        models =
          [
            Parameter
              {
                where = [AnnotationConstraint (NameConstraint (Matches (Re2.create_exn "str")))];
                taint = [TaintAnnotation (source "Test")];
              };
          ];
        find = Function;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Function { name = "test.foo"; kind = Normal })
    ~expected:
      [
        ModelParseResult.ModelAnnotation.ParameterAnnotation
          ( AccessPath.Root.PositionalParameter { position = 1; name = "b"; positional_only = false },
            source "Test" );
        ModelParseResult.ModelAnnotation.ParameterAnnotation
          ( AccessPath.Root.PositionalParameter { position = 2; name = "c"; positional_only = false },
            source "Test" );
      ];
  assert_generated_annotations
    ~source:{|
       def foo(a, b: typing.Annotated[str, "foo"], c: str, d: int): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where = [AnyParameterConstraint (AnnotationConstraint (NameConstraint (Equals "int")))];
        models =
          [
            Parameter
              {
                where = [AnnotationConstraint (NameConstraint (Equals "int"))];
                taint = [TaintAnnotation (source "Test")];
              };
          ];
        find = Function;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Function { name = "test.foo"; kind = Normal })
    ~expected:
      [
        ModelParseResult.ModelAnnotation.ParameterAnnotation
          ( AccessPath.Root.PositionalParameter { position = 3; name = "d"; positional_only = false },
            source "Test" );
      ];
  assert_generated_annotations
    ~source:{|
       def foo() -> int: ...
       def bar() -> str: ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where = [ReturnConstraint (NameConstraint (Equals "int"))];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Function;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Function { name = "test.foo"; kind = Normal })
    ~expected:[ModelParseResult.ModelAnnotation.ReturnAnnotation (source "Test")];
  assert_generated_annotations
    ~source:{|
       def foo() -> int: ...
       def bar() -> str: ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where = [ReturnConstraint (NameConstraint (Equals "int"))];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Function;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Function { name = "test.bar"; kind = Normal })
    ~expected:[];
  assert_generated_annotations
    ~source:{|
       def foo() -> str: ...
       def bar() -> List[str]: ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where = [ReturnConstraint (NameConstraint (Matches (Re2.create_exn "str")))];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Function;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Function { name = "test.foo"; kind = Normal })
    ~expected:[ModelParseResult.ModelAnnotation.ReturnAnnotation (source "Test")];
  assert_generated_annotations
    ~source:{|
       def foo() -> str: ...
       def bar() -> typing.List[str]: ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where = [ReturnConstraint (NameConstraint (Matches (Re2.create_exn "str")))];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Function;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Function { name = "test.bar"; kind = Normal })
    ~expected:[ModelParseResult.ModelAnnotation.ReturnAnnotation (source "Test")];
  assert_generated_annotations
    ~source:{|
       def foo() -> typing.Annotated[str, "foo"]: ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where = [ReturnConstraint IsAnnotatedTypeConstraint];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Function;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Function { name = "test.foo"; kind = Normal })
    ~expected:[ModelParseResult.ModelAnnotation.ReturnAnnotation (source "Test")];
  assert_generated_annotations
    ~source:{|
       def foo() -> typing.Annotated[str, "foo"]: ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where = [ReturnConstraint (NameConstraint (Matches (Re2.create_exn "foo")))];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Function;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Function { name = "test.foo"; kind = Normal })
    ~expected:[ModelParseResult.ModelAnnotation.ReturnAnnotation (source "Test")];

  (* Decorator names. *)
  assert_generated_annotations
    ~source:
      {|
       def d1(c): ...
       def d2(c): ...

       @d1
       def foo(a): ...
       @d2
       def bar(a): ...

       @d1
       @d2
       def baz(a): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where = [AnyDecoratorConstraint (NameConstraint (Matches (Re2.create_exn "d1")))];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Function;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Function { name = "test.foo"; kind = Normal })
    ~expected:[ModelParseResult.ModelAnnotation.ReturnAnnotation (source "Test")];
  assert_generated_annotations
    ~source:
      {|
       def d1(c): ...
       def d2(c): ...

       @d1
       def foo(a): ...
       @d2
       def bar(a): ...

       @d1
       @d2
       def baz(a): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where = [AnyDecoratorConstraint (NameConstraint (Matches (Re2.create_exn "d1")))];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Function;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Function { name = "test.bar"; kind = Normal })
    ~expected:[];
  assert_generated_annotations
    ~source:
      {|
       def d1(c): ...
       def d2(c): ...

       @d1
       def foo(a): ...
       @d2
       def bar(a): ...

       @d1
       @d2
       def baz(a): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where = [AnyDecoratorConstraint (NameConstraint (Matches (Re2.create_exn "d1")))];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Function;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Function { name = "test.baz"; kind = Normal })
    ~expected:[ModelParseResult.ModelAnnotation.ReturnAnnotation (source "Test")];
  assert_generated_annotations
    ~source:
      {|
       from flask import Flask
       app = Flask(__name__)
       @app.route('/')
       def foo(a): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where = [AnyDecoratorConstraint (NameConstraint (Matches (Re2.create_exn "app.route")))];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Function;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Function { name = "test.foo"; kind = Normal })
    ~expected:[ModelParseResult.ModelAnnotation.ReturnAnnotation (source "Test")];
  assert_generated_annotations
    ~source:
      {|
       def d1(c): ...
       def d2(c): ...

       @d1
       def foo(a): ...
       @d2
       def bar(a): ...

       @d1
       @d2
       def baz(a): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where = [AnyDecoratorConstraint (NameConstraint (Matches (Re2.create_exn "d1")))];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Function;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Function { name = "test.baz"; kind = Normal })
    ~expected:[ModelParseResult.ModelAnnotation.ReturnAnnotation (source "Test")];
  assert_generated_annotations
    ~source:
      {|
       def d1(c): ...
       def d2(c): ...

       @d1
       def foo(a): ...
       @d2
       def bar(a): ...

       @d1
       @d2
       def baz(a): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where = [AnyDecoratorConstraint (NameConstraint (Equals "test.d1"))];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Function;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Function { name = "test.baz"; kind = Normal })
    ~expected:[ModelParseResult.ModelAnnotation.ReturnAnnotation (source "Test")];
  assert_generated_annotations
    ~source:
      {|
       def d1(c): ...
       def d2(c): ...

       @d1
       def foo(a): ...
       @d2
       def bar(a): ...

       @d1
       @d2
       def baz(a): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where =
          [
            AnyDecoratorConstraint
              (AllOf
                 [
                   NameConstraint (Equals "test.d1");
                   ArgumentsConstraint
                     (ModelQuery.ArgumentsConstraint.Contains
                        [
                          {
                            Ast.Expression.Call.Argument.name = None;
                            value = +Ast.Expression.(Expression.Constant (Constant.Integer 1));
                          };
                        ]);
                 ]);
          ];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Function;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Function { name = "test.baz"; kind = Normal })
    ~expected:[];
  assert_generated_annotations
    ~source:
      {|
       def d1(c): ...
       def d2(c): ...

       @d1
       def foo(a): ...
       @d2
       def bar(a): ...

       @d1(1)
       @d2
       def baz(a): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where =
          [
            AnyDecoratorConstraint
              (AllOf
                 [
                   NameConstraint (Equals "test.d1");
                   ArgumentsConstraint
                     (Contains
                        [
                          {
                            Ast.Expression.Call.Argument.name = None;
                            value = +Ast.Expression.(Expression.Constant (Constant.Integer 1));
                          };
                        ]);
                 ]);
          ];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Function;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Function { name = "test.baz"; kind = Normal })
    ~expected:[ModelParseResult.ModelAnnotation.ReturnAnnotation (source "Test")];
  assert_generated_annotations
    ~source:
      {|
       def d1(c): ...
       def d2(c): ...

       @d1
       def foo(a): ...
       @d2
       def bar(a): ...

       @d1(1)
       @d2
       def baz(a): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where =
          [
            AnyDecoratorConstraint
              (AllOf
                 [
                   NameConstraint (Equals "test.d1");
                   ArgumentsConstraint
                     (Contains
                        [
                          {
                            Ast.Expression.Call.Argument.name =
                              Some (Ast.Node.create_with_default_location "arg1");
                            value = +Ast.Expression.(Expression.Constant (Constant.Integer 1));
                          };
                        ]);
                 ]);
          ];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Function;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Function { name = "test.baz"; kind = Normal })
    ~expected:[];
  assert_generated_annotations
    ~source:
      {|
       def d1(c): ...
       def d2(c): ...

       @d1
       def foo(a): ...
       @d2
       def bar(a): ...

       @d1(arg1=1)
       @d2
       def baz(a): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where =
          [
            AnyDecoratorConstraint
              (AllOf
                 [
                   NameConstraint (Equals "test.d1");
                   ArgumentsConstraint
                     (Contains
                        [
                          {
                            Ast.Expression.Call.Argument.name =
                              Some (Ast.Node.create_with_default_location "arg1");
                            value = +Ast.Expression.(Expression.Constant (Constant.Integer 1));
                          };
                        ]);
                 ]);
          ];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Function;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Function { name = "test.baz"; kind = Normal })
    ~expected:[ModelParseResult.ModelAnnotation.ReturnAnnotation (source "Test")];
  assert_generated_annotations
    ~source:
      {|
       def d1(c): ...
       def d2(c): ...

       @d1
       def foo(a): ...
       @d2
       def bar(a): ...

       @d1(1, method="POST")
       @d2
       def baz(a): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where =
          [
            AnyDecoratorConstraint
              (AllOf
                 [
                   NameConstraint (Equals "test.d1");
                   ArgumentsConstraint
                     (Contains
                        [
                          {
                            Ast.Expression.Call.Argument.name =
                              Some (Ast.Node.create_with_default_location "method");
                            value =
                              +Ast.Expression.(
                                 Expression.Constant
                                   (Constant.String (Ast.Expression.StringLiteral.create "POST")));
                          };
                          {
                            Ast.Expression.Call.Argument.name = None;
                            value = +Ast.Expression.(Expression.Constant (Constant.Integer 1));
                          };
                        ]);
                 ]);
          ];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Function;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Function { name = "test.baz"; kind = Normal })
    ~expected:[ModelParseResult.ModelAnnotation.ReturnAnnotation (source "Test")];
  assert_generated_annotations
    ~source:
      {|
       def d1(c): ...
       def d2(c): ...

       @d1(1)
       def foo(a): ...
       @d2
       def bar(a): ...

       @d1(1, method="POST")
       @d2
       def baz(a): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where =
          [
            AnyDecoratorConstraint
              (AllOf
                 [
                   NameConstraint (Equals "test.d1");
                   ArgumentsConstraint
                     (Equals
                        [
                          {
                            Ast.Expression.Call.Argument.name =
                              Some (Ast.Node.create_with_default_location "method");
                            value =
                              +Ast.Expression.(
                                 Expression.Constant
                                   (Constant.String (Ast.Expression.StringLiteral.create "POST")));
                          };
                          {
                            Ast.Expression.Call.Argument.name = None;
                            value = +Ast.Expression.(Expression.Constant (Constant.Integer 1));
                          };
                        ]);
                 ]);
          ];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Function;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Function { name = "test.foo"; kind = Normal })
    ~expected:[];
  assert_generated_annotations
    ~source:
      {|
       def d1(c): ...
       def d2(c): ...

       @d1(1)
       def foo(a): ...
       @d2
       def bar(a): ...

       @d1(1, method="POST")
       @d2
       def baz(a): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where =
          [
            AnyDecoratorConstraint
              (AllOf
                 [
                   NameConstraint (Equals "test.d1");
                   ArgumentsConstraint
                     (Equals
                        [
                          {
                            Ast.Expression.Call.Argument.name =
                              Some (Ast.Node.create_with_default_location "method");
                            value =
                              +Ast.Expression.(
                                 Expression.Constant
                                   (Constant.String (Ast.Expression.StringLiteral.create "POST")));
                          };
                          {
                            Ast.Expression.Call.Argument.name = None;
                            value = +Ast.Expression.(Expression.Constant (Constant.Integer 1));
                          };
                        ]);
                 ]);
          ];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Function;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Function { name = "test.baz"; kind = Normal })
    ~expected:[ModelParseResult.ModelAnnotation.ReturnAnnotation (source "Test")];

  assert_generated_annotations
    ~source:
      {|
      class C:
        def foo(): ...
      class D:
        def foo(): ...
      class DC:
        def foo(): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where = [ClassConstraint (NameConstraint (Matches (Re2.create_exn "C")))];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Method;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Method { class_name = "test.C"; method_name = "foo"; kind = Normal })
    ~expected:[ModelParseResult.ModelAnnotation.ReturnAnnotation (source "Test")];
  assert_generated_annotations
    ~source:
      {|
      class C:
        def foo(): ...
      class D:
        def foo(): ...
      class DC:
        def foo(): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where = [ClassConstraint (NameConstraint (Matches (Re2.create_exn "C")))];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Method;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Method { class_name = "test.D"; method_name = "foo"; kind = Normal })
    ~expected:[];

  assert_generated_annotations
    ~source:
      {|
      class C:
        def foo(): ...
      class D:
        def foo(): ...
      class DC:
        def foo(): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where = [ClassConstraint (NameConstraint (Matches (Re2.create_exn "C")))];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Method;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Method { class_name = "test.DC"; method_name = "foo"; kind = Normal })
    ~expected:[ModelParseResult.ModelAnnotation.ReturnAnnotation (source "Test")];
  assert_generated_annotations
    ~source:
      {|
      @d1
      class A:
        def foo(): ...
      @d2
      class B:
        def foo(): ...
      @d3
      class C:
        def foo(): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where =
          [ClassConstraint (DecoratorConstraint (NameConstraint (Matches (Re2.create_exn "d2"))))];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Method;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Method { class_name = "test.B"; method_name = "foo"; kind = Normal })
    ~expected:[ModelParseResult.ModelAnnotation.ReturnAnnotation (source "Test")];
  assert_generated_annotations
    ~source:
      {|
      @d1
      class A:
        def foo(): ...
      @d2
      class B:
        def foo(): ...
      @d3
      class C:
        def foo(): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where =
          [ClassConstraint (DecoratorConstraint (NameConstraint (Matches (Re2.create_exn "4"))))];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Method;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Method { class_name = "test.B"; method_name = "foo"; kind = Normal })
    ~expected:[];
  assert_generated_annotations
    ~source:
      {|
      @d1
      class A:
        def foo(): ...
      @d2
      class B:
        def foo(): ...
      @d1(1)
      @d3
      class C:
        def foo(): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where =
          [
            ClassConstraint
              (DecoratorConstraint
                 (AllOf
                    [
                      NameConstraint (Equals "test.d1");
                      ArgumentsConstraint
                        (Contains
                           [
                             {
                               Ast.Expression.Call.Argument.name = None;
                               value = +Ast.Expression.(Expression.Constant (Constant.Integer 1));
                             };
                           ]);
                    ]));
          ];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Method;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Method { class_name = "test.A"; method_name = "foo"; kind = Normal })
    ~expected:[];
  assert_generated_annotations
    ~source:
      {|
      @d1
      class A:
        def foo(): ...
      @d2
      class B:
        def foo(): ...
      @d1(1)
      @d3
      class C:
        def foo(): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where =
          [
            ClassConstraint
              (DecoratorConstraint
                 (AllOf
                    [
                      NameConstraint (Matches (Re2.create_exn "d1"));
                      ArgumentsConstraint
                        (Contains
                           [
                             {
                               Ast.Expression.Call.Argument.name = None;
                               value = +Ast.Expression.(Expression.Constant (Constant.Integer 1));
                             };
                           ]);
                    ]));
          ];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Method;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Method { class_name = "test.C"; method_name = "foo"; kind = Normal })
    ~expected:[ModelParseResult.ModelAnnotation.ReturnAnnotation (source "Test")];

  (* Test attribute models. *)
  assert_generated_annotations_for_attributes
    ~source:{|
      class C:
        x: ...
      class D(C):
        y: ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where = [ClassConstraint (NameConstraint (Matches (Re2.create_exn "C")))];
        models = [Attribute [TaintAnnotation (source "Test")]];
        find = Attribute;
        expected_models = [];
        unexpected_models = [];
      }
    ~name:"test.C.x"
    ~annotation:None
    ~expected:[source "Test"];
  assert_generated_annotations_for_attributes
    ~source:{|
      class C:
        x: ...
      class D(C):
        y: ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where = [ClassConstraint (NameConstraint (Matches (Re2.create_exn "C")))];
        models = [Attribute [TaintAnnotation (sink "Test")]];
        find = Attribute;
        expected_models = [];
        unexpected_models = [];
      }
    ~name:"test.C.x"
    ~annotation:None
    ~expected:[sink "Test"];
  assert_generated_annotations_for_attributes
    ~source:{|
      class C:
        x: ...
      class D(C):
        y: ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where = [ClassConstraint (NameConstraint (Matches (Re2.create_exn "C")))];
        models = [Attribute [TaintAnnotation (source "Test")]];
        find = Attribute;
        expected_models = [];
        unexpected_models = [];
      }
    ~name:"test.D.y"
    ~annotation:None
    ~expected:[];
  assert_generated_annotations_for_attributes
    ~source:{|
      class C:
        x: ...
      class D(C):
        y: ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where =
          [
            ClassConstraint
              (Extends { class_name = "test.C"; is_transitive = false; includes_self = true });
          ];
        models = [Attribute [TaintAnnotation (source "Test")]];
        find = Attribute;
        expected_models = [];
        unexpected_models = [];
      }
    ~name:"test.C.x"
    ~annotation:None
    ~expected:[source "Test"];
  ();
  assert_generated_annotations_for_attributes
    ~source:{|
      class C:
        x: ...
      class D(C):
        y: ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where =
          [
            ClassConstraint
              (Extends { class_name = "test.C"; is_transitive = false; includes_self = true });
          ];
        models = [Attribute [TaintAnnotation (source "Test")]];
        find = Attribute;
        expected_models = [];
        unexpected_models = [];
      }
    ~name:"test.D.y"
    ~annotation:None
    ~expected:[source "Test"];
  assert_generated_annotations_for_attributes
    ~source:
      {|
      class C:
        x: ...
      class D(C):
        y: ...
      class E:
        z: ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where =
          [
            ClassConstraint
              (Extends { class_name = "test.C"; is_transitive = false; includes_self = true });
          ];
        models = [Attribute [TaintAnnotation (source "Test")]];
        find = Attribute;
        expected_models = [];
        unexpected_models = [];
      }
    ~name:"test.E.z"
    ~annotation:None
    ~expected:[];
  assert_generated_annotations_for_attributes
    ~source:{|
      class C:
        x: int
        y: str
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where = [AnnotationConstraint (NameConstraint (Equals "int"))];
        models = [Attribute [TaintAnnotation (source "Test")]];
        find = Attribute;
        expected_models = [];
        unexpected_models = [];
      }
    ~name:"test.C.x"
    ~annotation:(Some "int")
    ~expected:[source "Test"];
  assert_generated_annotations_for_attributes
    ~source:{|
      class C:
        x: int
        y: str
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where = [AnnotationConstraint (NameConstraint (Equals "int"))];
        models = [Attribute [TaintAnnotation (source "Test")]];
        find = Attribute;
        expected_models = [];
        unexpected_models = [];
      }
    ~name:"test.C.y"
    ~annotation:(Some "str")
    ~expected:[];
  assert_generated_annotations_for_attributes
    ~source:
      {|
      class Foo1:
        ...
      class Foo2:
        ...
      class Bar:
        ...
      class C:
        x: Foo1
        y: Foo2
        z: Bar
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where = [AnnotationConstraint (NameConstraint (Matches (Re2.create_exn "Foo")))];
        models = [Attribute [TaintAnnotation (source "Test")]];
        find = Attribute;
        expected_models = [];
        unexpected_models = [];
      }
    ~name:"test.C.x"
    ~annotation:(Some "typing.Type[Foo1]")
    ~expected:[source "Test"];
  assert_generated_annotations_for_attributes
    ~source:
      {|
      class Foo1:
        ...
      class Foo2:
        ...
      class Bar:
        ...
      class C:
        x: Foo1
        y: Foo2
        z: Bar
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where = [AnnotationConstraint (NameConstraint (Matches (Re2.create_exn "Foo")))];
        models = [Attribute [TaintAnnotation (source "Test")]];
        find = Attribute;
        expected_models = [];
        unexpected_models = [];
      }
    ~name:"test.C.y"
    ~annotation:(Some "typing.Type[Foo2]")
    ~expected:[source "Test"];
  assert_generated_annotations_for_attributes
    ~source:
      {|
      class Foo1:
        ...
      class Foo2:
        ...
      class Bar:
        ...
      class C:
        x: Foo1
        y: Foo2
        z: Bar
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where = [AnnotationConstraint (NameConstraint (Matches (Re2.create_exn "Foo")))];
        models = [Attribute [TaintAnnotation (source "Test")]];
        find = Attribute;
        expected_models = [];
        unexpected_models = [];
      }
    ~name:"test.C.z"
    ~annotation:(Some "typing.Type[Bar]")
    ~expected:[];
  assert_generated_annotations_for_attributes
    ~source:
      {|
      from typing import Annotated
      class C:
        x: int
        y: Annotated[str, "foo"]
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where = [AnnotationConstraint IsAnnotatedTypeConstraint];
        models = [Attribute [TaintAnnotation (source "Test")]];
        find = Attribute;
        expected_models = [];
        unexpected_models = [];
      }
    ~name:"test.C.x"
    ~annotation:(Some "int")
    ~expected:[];
  assert_generated_annotations_for_attributes
    ~source:
      {|
      from typing import Annotated
      class C:
        x: int
        y: Annotated[str, "foo"]
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where = [AnnotationConstraint IsAnnotatedTypeConstraint];
        models = [Attribute [TaintAnnotation (source "Test")]];
        find = Attribute;
        expected_models = [];
        unexpected_models = [];
      }
    ~name:"test.C.y"
    ~annotation:(Some "typing.Annotated[str, \"foo\"]")
    ~expected:[source "Test"];

  (* Test 'Not' clause *)
  assert_generated_annotations
    ~source:{|
      def foo(): ...
      def barfoo(): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where =
          [
            NameConstraint (Matches (Re2.create_exn "foo"));
            Not (NameConstraint (Matches (Re2.create_exn "bar")));
          ];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Function;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Function { name = "test.foo"; kind = Normal })
    ~expected:[ModelParseResult.ModelAnnotation.ReturnAnnotation (source "Test")];
  assert_generated_annotations
    ~source:{|
      def foo(): ...
      def barfoo(): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where =
          [
            NameConstraint (Matches (Re2.create_exn "foo"));
            Not (NameConstraint (Matches (Re2.create_exn "bar")));
          ];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Function;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Function { name = "test.barfoo"; kind = Normal })
    ~expected:[];
  assert_generated_annotations
    ~source:
      {|
       def foo(a) -> typing.Annotated[int, DynamicSource(B)]: ...
       def bar(b): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where = [Not (ReturnConstraint IsAnnotatedTypeConstraint)];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Function;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Function { name = "test.foo"; kind = Normal })
    ~expected:[];
  assert_generated_annotations
    ~source:
      {|
      class C:
        def foo(): ...
      class D:
        def foo(): ...
      class DC:
        def foo(): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where =
          [
            ClassConstraint (NameConstraint (Matches (Re2.create_exn "C")));
            Not (ClassConstraint (NameConstraint (Matches (Re2.create_exn "D"))));
          ];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Method;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Method { class_name = "test.C"; method_name = "foo"; kind = Normal })
    ~expected:[ModelParseResult.ModelAnnotation.ReturnAnnotation (source "Test")];
  assert_generated_annotations
    ~source:
      {|
      class C:
        def foo(): ...
      class D:
        def foo(): ...
      class DC:
        def foo(): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where =
          [
            ClassConstraint (NameConstraint (Matches (Re2.create_exn "C")));
            Not (ClassConstraint (NameConstraint (Matches (Re2.create_exn "D"))));
          ];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Method;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Method { class_name = "test.DC"; method_name = "foo"; kind = Normal })
    ~expected:[];
  assert_generated_annotations
    ~source:
      {|
       def foo(a) -> typing.Annotated[int, DynamicSource(B)]: ...
       def bar(b): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where = [Not (ReturnConstraint IsAnnotatedTypeConstraint)];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Function;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Function { name = "test.bar"; kind = Normal })
    ~expected:[ModelParseResult.ModelAnnotation.ReturnAnnotation (source "Test")];
  assert_generated_annotations_for_attributes
    ~source:
      {|
      class C:
        x: ...
      class D(C):
        y: ...
      class E:
        z: ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where =
          [
            Not
              (ClassConstraint
                 (Extends { class_name = "test.C"; is_transitive = false; includes_self = true }));
          ];
        models = [Attribute [TaintAnnotation (source "Test")]];
        find = Attribute;
        expected_models = [];
        unexpected_models = [];
      }
    ~name:"test.C.x"
    ~annotation:None
    ~expected:[];
  assert_generated_annotations_for_attributes
    ~source:
      {|
      class C:
        x: ...
      class D(C):
        y: ...
      class E:
        z: ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where =
          [
            Not
              (ClassConstraint
                 (Extends { class_name = "test.C"; is_transitive = false; includes_self = true }));
          ];
        models = [Attribute [TaintAnnotation (source "Test")]];
        find = Attribute;
        expected_models = [];
        unexpected_models = [];
      }
    ~name:"test.D.y"
    ~annotation:None
    ~expected:[];
  assert_generated_annotations_for_attributes
    ~source:
      {|
      class C:
        x: ...
      class D(C):
        y: ...
      class E:
        z: ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where =
          [
            Not
              (ClassConstraint
                 (Extends { class_name = "test.C"; is_transitive = false; includes_self = true }));
          ];
        models = [Attribute [TaintAnnotation (source "Test")]];
        find = Attribute;
        expected_models = [];
        unexpected_models = [];
      }
    ~name:"test.E.z"
    ~annotation:None
    ~expected:[source "Test"];

  (* Test transitive extends *)
  assert_generated_annotations_for_attributes
    ~source:
      {|
      class C:
        x: ...
      class D(C):
        y: ...
      class E(D):
        z: ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where =
          [
            ClassConstraint
              (Extends { class_name = "test.C"; is_transitive = true; includes_self = true });
          ];
        models = [Attribute [TaintAnnotation (source "Test")]];
        find = Attribute;
        expected_models = [];
        unexpected_models = [];
      }
    ~name:"test.E.z"
    ~annotation:None
    ~expected:[source "Test"];
  assert_generated_annotations_for_attributes
    ~source:
      {|
      class C:
        x: ...
      class D(C):
        y: ...
      class E(D):
        z: ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where =
          [
            ClassConstraint
              (Extends { class_name = "test.C"; is_transitive = true; includes_self = true });
          ];
        models = [Attribute [TaintAnnotation (source "Test")]];
        find = Attribute;
        expected_models = [];
        unexpected_models = [];
      }
    ~name:"test.D.y"
    ~annotation:None
    ~expected:[source "Test"];
  assert_generated_annotations_for_attributes
    ~source:
      {|
      class C:
        x: ...
      class D(C):
        y: ...
      class E(D):
        z: ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where =
          [
            ClassConstraint
              (Extends { class_name = "test.C"; is_transitive = true; includes_self = true });
          ];
        models = [Attribute [TaintAnnotation (source "Test")]];
        find = Attribute;
        expected_models = [];
        unexpected_models = [];
      }
    ~name:"test.C.x"
    ~annotation:None
    ~expected:[source "Test"];
  assert_generated_annotations
    ~source:
      {|
      class A:
        def foo(): ...
      class B(A):
        def foo(): ...
      class C(B):
        def foo(): ...
      class D:
        def foo(): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where =
          [
            Not
              (ClassConstraint
                 (Extends { class_name = "test.A"; is_transitive = true; includes_self = true }));
          ];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Method;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Method { class_name = "test.A"; method_name = "foo"; kind = Normal })
    ~expected:[];
  assert_generated_annotations
    ~source:
      {|
      class A:
        def foo(): ...
      class B(A):
        def foo(): ...
      class C(B):
        def foo(): ...
      class D:
        def foo(): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where =
          [
            Not
              (ClassConstraint
                 (Extends { class_name = "test.A"; is_transitive = true; includes_self = true }));
          ];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Method;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Method { class_name = "test.B"; method_name = "foo"; kind = Normal })
    ~expected:[];
  assert_generated_annotations
    ~source:
      {|
      class A:
        def foo(): ...
      class B(A):
        def foo(): ...
      class C(B):
        def foo(): ...
      class D:
        def foo(): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where =
          [
            Not
              (ClassConstraint
                 (Extends { class_name = "test.A"; is_transitive = true; includes_self = true }));
          ];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Method;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Method { class_name = "test.C"; method_name = "foo"; kind = Normal })
    ~expected:[];
  assert_generated_annotations
    ~source:
      {|
      class A:
        def foo(): ...
      class B(A):
        def foo(): ...
      class C(B):
        def foo(): ...
      class D:
        def foo(): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where =
          [
            Not
              (ClassConstraint
                 (Extends { class_name = "test.A"; is_transitive = true; includes_self = true }));
          ];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Method;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Method { class_name = "test.D"; method_name = "foo"; kind = Normal })
    ~expected:[ModelParseResult.ModelAnnotation.ReturnAnnotation (source "Test")];

  (* Test includes_self=False *)
  assert_generated_annotations_for_attributes
    ~source:
      {|
      class C:
        x: ...
      class D(C):
        y: ...
      class E(D):
        z: ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where =
          [
            ClassConstraint
              (Extends { class_name = "test.C"; is_transitive = false; includes_self = false });
          ];
        models = [Attribute [TaintAnnotation (source "Test")]];
        find = Attribute;
        expected_models = [];
        unexpected_models = [];
      }
    ~name:"test.C.x"
    ~annotation:None
    ~expected:[];
  assert_generated_annotations_for_attributes
    ~source:
      {|
      class C:
        x: ...
      class D(C):
        y: ...
      class E(D):
        z: ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where =
          [
            ClassConstraint
              (Extends { class_name = "test.C"; is_transitive = false; includes_self = false });
          ];
        models = [Attribute [TaintAnnotation (source "Test")]];
        find = Attribute;
        expected_models = [];
        unexpected_models = [];
      }
    ~name:"test.D.y"
    ~annotation:None
    ~expected:[source "Test"];
  assert_generated_annotations_for_attributes
    ~source:
      {|
      class C:
        x: ...
      class D(C):
        y: ...
      class E(D):
        z: ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where =
          [
            ClassConstraint
              (Extends { class_name = "test.C"; is_transitive = false; includes_self = false });
          ];
        models = [Attribute [TaintAnnotation (source "Test")]];
        find = Attribute;
        expected_models = [];
        unexpected_models = [];
      }
    ~name:"test.E.z"
    ~annotation:None
    ~expected:[];
  assert_generated_annotations
    ~source:
      {|
      class A:
        def foo(): ...
      class B(A):
        def foo(): ...
      class C(B):
        def foo(): ...
      class D:
        def foo(): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where =
          [
            ClassConstraint
              (Extends { class_name = "test.A"; is_transitive = true; includes_self = false });
          ];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Method;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Method { class_name = "test.A"; method_name = "foo"; kind = Normal })
    ~expected:[];
  assert_generated_annotations
    ~source:
      {|
      class A:
        def foo(): ...
      class B(A):
        def foo(): ...
      class C(B):
        def foo(): ...
      class D:
        def foo(): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where =
          [
            ClassConstraint
              (Extends { class_name = "test.A"; is_transitive = true; includes_self = false });
          ];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Method;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Method { class_name = "test.B"; method_name = "foo"; kind = Normal })
    ~expected:[ModelParseResult.ModelAnnotation.ReturnAnnotation (source "Test")];
  assert_generated_annotations
    ~source:
      {|
      class A:
        def foo(): ...
      class B(A):
        def foo(): ...
      class C(B):
        def foo(): ...
      class D:
        def foo(): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where =
          [
            ClassConstraint
              (Extends { class_name = "test.A"; is_transitive = true; includes_self = false });
          ];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Method;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Method { class_name = "test.C"; method_name = "foo"; kind = Normal })
    ~expected:[ModelParseResult.ModelAnnotation.ReturnAnnotation (source "Test")];
  assert_generated_annotations
    ~source:
      {|
      class A:
        def foo(): ...
      class B(A):
        def foo(): ...
      class C(B):
        def foo(): ...
      class D:
        def foo(): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where =
          [
            ClassConstraint
              (Extends { class_name = "test.B"; is_transitive = true; includes_self = false });
          ];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Method;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Method { class_name = "test.A"; method_name = "foo"; kind = Normal })
    ~expected:[];
  assert_generated_annotations
    ~source:
      {|
      class A:
        def foo(): ...
      class B(A):
        def foo(): ...
      class C(B):
        def foo(): ...
      class D:
        def foo(): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where =
          [
            ClassConstraint
              (Extends { class_name = "test.B"; is_transitive = true; includes_self = false });
          ];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Method;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Method { class_name = "test.B"; method_name = "foo"; kind = Normal })
    ~expected:[];
  assert_generated_annotations
    ~source:
      {|
      class A:
        def foo(): ...
      class B(A):
        def foo(): ...
      class C(B):
        def foo(): ...
      class D:
        def foo(): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where =
          [
            ClassConstraint
              (Extends { class_name = "test.B"; is_transitive = true; includes_self = false });
          ];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Method;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Method { class_name = "test.C"; method_name = "foo"; kind = Normal })
    ~expected:[ModelParseResult.ModelAnnotation.ReturnAnnotation (source "Test")];

  (* Test cls.any_child *)
  assert_generated_annotations
    ~source:
      {|
      @decorator
      class A:
        def foo(): ...
      @decorator
      class B(A):
        def foo(): ...
      class C(B):
        def foo(): ...
      class D:
        def foo(): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where =
          [
            ClassConstraint
              (AnyChildConstraint
                 {
                   class_constraint = DecoratorConstraint (NameConstraint (Equals "decorator"));
                   is_transitive = false;
                   includes_self = true;
                 });
          ];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Method;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Method { class_name = "test.A"; method_name = "foo"; kind = Normal })
    ~expected:[ModelParseResult.ModelAnnotation.ReturnAnnotation (source "Test")];
  assert_generated_annotations
    ~source:
      {|
      @decorator
      class A:
        def foo(): ...
      @decorator
      class B(A):
        def foo(): ...
      class C(B):
        def foo(): ...
      class D:
        def foo(): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where =
          [
            ClassConstraint
              (AnyChildConstraint
                 {
                   class_constraint = DecoratorConstraint (NameConstraint (Equals "decorator"));
                   is_transitive = false;
                   includes_self = true;
                 });
          ];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Method;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Method { class_name = "test.B"; method_name = "foo"; kind = Normal })
    ~expected:[ModelParseResult.ModelAnnotation.ReturnAnnotation (source "Test")];
  assert_generated_annotations
    ~source:
      {|
      @decorator
      class A:
        def foo(): ...
      @decorator
      class B(A):
        def foo(): ...
      class C(B):
        def foo(): ...
      class D:
        def foo(): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where =
          [
            ClassConstraint
              (AnyChildConstraint
                 {
                   class_constraint = DecoratorConstraint (NameConstraint (Equals "decorator"));
                   is_transitive = false;
                   includes_self = true;
                 });
          ];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Method;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Method { class_name = "test.C"; method_name = "foo"; kind = Normal })
    ~expected:[];
  assert_generated_annotations
    ~source:
      {|
      @decorator
      class A:
        def foo(): ...
      @decorator
      class B(A):
        def foo(): ...
      class C(B):
        def foo(): ...
      class D:
        def foo(): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where =
          [
            ClassConstraint
              (AnyChildConstraint
                 {
                   class_constraint = DecoratorConstraint (NameConstraint (Equals "decorator"));
                   is_transitive = false;
                   includes_self = false;
                 });
          ];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Method;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Method { class_name = "test.A"; method_name = "foo"; kind = Normal })
    ~expected:[ModelParseResult.ModelAnnotation.ReturnAnnotation (source "Test")];
  assert_generated_annotations
    ~source:
      {|
      @decorator
      class A:
        def foo(): ...
      @decorator
      class B(A):
        def foo(): ...
      class C(B):
        def foo(): ...
      class D:
        def foo(): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where =
          [
            ClassConstraint
              (AnyChildConstraint
                 {
                   class_constraint = DecoratorConstraint (NameConstraint (Equals "decorator"));
                   is_transitive = false;
                   includes_self = false;
                 });
          ];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Method;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Method { class_name = "test.B"; method_name = "foo"; kind = Normal })
    ~expected:[];
  assert_generated_annotations
    ~source:
      {|
      @decorator
      class A:
        def foo(): ...
      @decorator
      class B(A):
        def foo(): ...
      class C(B):
        def foo(): ...
      class D:
        def foo(): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where =
          [
            ClassConstraint
              (AnyChildConstraint
                 {
                   class_constraint = DecoratorConstraint (NameConstraint (Equals "decorator"));
                   is_transitive = false;
                   includes_self = false;
                 });
          ];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Method;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Method { class_name = "test.C"; method_name = "foo"; kind = Normal })
    ~expected:[];
  assert_generated_annotations
    ~source:
      {|
      @decorator
      class A:
        def foo(): ...
      @decorator
      class B(A):
        def foo(): ...
      class C(B):
        def foo(): ...
      class D:
        def foo(): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where =
          [
            ClassConstraint
              (AnyChildConstraint
                 {
                   class_constraint = DecoratorConstraint (NameConstraint (Equals "decorator"));
                   is_transitive = true;
                   includes_self = false;
                 });
          ];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Method;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Method { class_name = "test.A"; method_name = "foo"; kind = Normal })
    ~expected:[ModelParseResult.ModelAnnotation.ReturnAnnotation (source "Test")];
  assert_generated_annotations
    ~source:
      {|
      @decorator
      class A:
        def foo(): ...
      @decorator
      class B(A):
        def foo(): ...
      class C(B):
        def foo(): ...
      class D:
        def foo(): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where =
          [
            ClassConstraint
              (AnyChildConstraint
                 {
                   class_constraint = DecoratorConstraint (NameConstraint (Equals "decorator"));
                   is_transitive = true;
                   includes_self = false;
                 });
          ];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Method;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Method { class_name = "test.B"; method_name = "foo"; kind = Normal })
    ~expected:[];
  assert_generated_annotations
    ~source:
      {|
      @decorator
      class A:
        def foo(): ...
      @decorator
      class B(A):
        def foo(): ...
      class C(B):
        def foo(): ...
      class D:
        def foo(): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where =
          [
            ClassConstraint
              (AnyChildConstraint
                 {
                   class_constraint = DecoratorConstraint (NameConstraint (Equals "decorator"));
                   is_transitive = true;
                   includes_self = false;
                 });
          ];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Method;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Method { class_name = "test.C"; method_name = "foo"; kind = Normal })
    ~expected:[];
  assert_generated_annotations
    ~source:
      {|
      @decorator
      class A:
        def foo(): ...
      class B(A):
        def foo(): ...
      @decorator
      class C(B):
        def foo(): ...
      class D:
        def foo(): ...
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where =
          [
            ClassConstraint
              (AnyChildConstraint
                 {
                   class_constraint = DecoratorConstraint (NameConstraint (Equals "decorator"));
                   is_transitive = true;
                   includes_self = false;
                 });
          ];
        models = [Return [TaintAnnotation (source "Test")]];
        find = Method;
        expected_models = [];
        unexpected_models = [];
      }
    ~callable:(Target.Method { class_name = "test.A"; method_name = "foo"; kind = Normal })
    ~expected:[ModelParseResult.ModelAnnotation.ReturnAnnotation (source "Test")];
  assert_generated_annotations_for_globals
    ~source:{|
      foo = []
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_foo";
        where = [NameConstraint (Matches (Re2.create_exn "foo"))];
        models = [Global [TaintAnnotation (source "Test")]];
        find = Global;
        expected_models = [];
        unexpected_models = [];
      }
    ~name:"test.foo"
    ~expected:[source "Test"];
  assert_generated_annotations_for_globals
    ~source:{|
      foo, bar = [], {}
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_bar";
        where = [NameConstraint (Matches (Re2.create_exn "bar"))];
        models = [Global [TaintAnnotation (source "Test")]];
        find = Global;
        expected_models = [];
        unexpected_models = [];
      }
    ~name:"test.bar"
    ~expected:[source "Test"];
  assert_generated_annotations_for_globals
    ~source:{|
      foo = []
     |}
    ~query:
      {
        location = Ast.Location.any;
        name = "get_baz";
        where = [NameConstraint (Matches (Re2.create_exn "baz"))];
        models = [Global [TaintAnnotation (source "Test")]];
        find = Global;
        expected_models = [];
        unexpected_models = [];
      }
    ~name:"test.foo"
    ~expected:[];
  ()


let test_partition_cache_queries _ =
  let assert_partition ~queries ~expected () =
    let partition = ModelQueryExecution.PartitionCacheQueries.partition queries in
    assert_equal
      ~cmp:ModelQueryExecution.PartitionCacheQueries.equal
      ~printer:ModelQueryExecution.PartitionCacheQueries.show
      expected
      partition
  in
  let empty_query =
    {
      ModelQuery.location = { start = { line = 0; column = 0 }; stop = { line = 0; column = 0 } };
      name = "empty";
      where = [];
      find = Method;
      models = [];
      expected_models = [];
      unexpected_models = [];
    }
  in
  let read_from_cache =
    {
      empty_query with
      name = "read_from_cache";
      where = [ReadFromCache { kind = "thrift"; name = "cache:name" }];
      models =
        [
          Return
            [
              TaintAnnotation
                (ModelParseResult.TaintAnnotation.from_source (Sources.NamedSource "Test"));
            ];
        ];
    }
  in
  let write_to_cache =
    {
      empty_query with
      name = "write_to_cache";
      where = [NameConstraint (Matches (Re2.create_exn "foo"))];
      models =
        [
          WriteToCache
            {
              ModelQuery.WriteToCache.kind = "thrift";
              name =
                [
                  ModelQuery.WriteToCache.Substring.ClassName;
                  ModelQuery.WriteToCache.Substring.Literal ":";
                  ModelQuery.WriteToCache.Substring.MethodName;
                ];
            };
        ];
    }
  in
  let regular =
    {
      empty_query with
      name = "regular";
      where = [NameConstraint (Matches (Re2.create_exn "foo"))];
      models =
        [
          Return
            [
              TaintAnnotation
                (ModelParseResult.TaintAnnotation.from_source (Sources.NamedSource "Test"));
            ];
        ];
    }
  in
  assert_partition
    ~queries:[regular; read_from_cache; write_to_cache]
    ~expected:
      {
        ModelQueryExecution.PartitionCacheQueries.write_to_cache = [write_to_cache];
        read_from_cache = [read_from_cache];
        others = [regular];
      }
    ();
  ()


let test_generated_cache context =
  let assert_generated_cache ~source ~queries ~callables ~expected =
    let { ScratchProject.BuiltTypeEnvironment.type_environment; _ } =
      ScratchProject.setup ~context ["test.py", source] |> ScratchProject.build_type_environment
    in
    let global_resolution = Analysis.TypeEnvironment.ReadOnly.global_resolution type_environment in
    let class_hierarchy_graph =
      Interprocedural.ClassHierarchyGraph.Heap.from_qualifiers
        ~scheduler:(mock_scheduler ())
        ~environment:type_environment
        ~qualifiers:[Ast.Reference.create "test"]
      |> Interprocedural.ClassHierarchyGraph.SharedMemory.from_heap
    in
    let actual =
      ModelQueryExecution.CallableQueryExecutor.generate_cache_from_queries_on_targets
        ~verbose:false
        ~resolution:global_resolution
        ~class_hierarchy_graph
        ~targets:callables
        queries
    in
    let expected =
      List.fold
        ~init:ModelQueryExecution.ReadWriteCache.empty
        ~f:(fun cache (kind, name, target) ->
          ModelQueryExecution.ReadWriteCache.write cache ~kind ~name ~target)
        expected
    in
    assert_equal
      ~cmp:ModelQueryExecution.ReadWriteCache.equal
      ~printer:ModelQueryExecution.ReadWriteCache.show
      expected
      actual
  in
  assert_generated_cache
    ~source:{|
      def foo(): ...
      def no_match(): ...
      |}
    ~queries:
      [
        {
          location = Ast.Location.any;
          name = "get_foo";
          where = [NameConstraint (Matches (Re2.create_exn "foo"))];
          models =
            [
              WriteToCache
                {
                  ModelQuery.WriteToCache.kind = "thrift";
                  name = [ModelQuery.WriteToCache.Substring.FunctionName];
                };
            ];
          find = Function;
          expected_models = [];
          unexpected_models = [];
        };
      ]
    ~callables:
      [
        Target.Function { name = "test.foo"; kind = Normal };
        Target.Function { name = "test.no_match"; kind = Normal };
      ]
    ~expected:["thrift", "foo", Target.Function { name = "test.foo"; kind = Normal }];
  assert_generated_cache
    ~source:
      {|
      class C:
        def foo(self): ...
      class D:
        def foo(self): ...
      |}
    ~queries:
      [
        {
          location = Ast.Location.any;
          name = "get_foo";
          where = [NameConstraint (Matches (Re2.create_exn "foo"))];
          models =
            [
              WriteToCache
                {
                  ModelQuery.WriteToCache.kind = "thrift";
                  name =
                    [
                      ModelQuery.WriteToCache.Substring.ClassName;
                      ModelQuery.WriteToCache.Substring.Literal ":";
                      ModelQuery.WriteToCache.Substring.MethodName;
                    ];
                };
            ];
          find = Method;
          expected_models = [];
          unexpected_models = [];
        };
      ]
    ~callables:
      [
        Target.Method { class_name = "test.C"; method_name = "foo"; kind = Normal };
        Target.Method { class_name = "test.D"; method_name = "foo"; kind = Normal };
      ]
    ~expected:
      [
        ( "thrift",
          "C:foo",
          Target.Method { class_name = "test.C"; method_name = "foo"; kind = Normal } );
        ( "thrift",
          "D:foo",
          Target.Method { class_name = "test.D"; method_name = "foo"; kind = Normal } );
      ];
  (* We can have multiple targets for the same kind+name *)
  assert_generated_cache
    ~source:
      {|
      class C:
        def foo(self): ...
      class D:
        def foo(self): ...
      |}
    ~queries:
      [
        {
          location = Ast.Location.any;
          name = "get_foo";
          where = [NameConstraint (Matches (Re2.create_exn "foo"))];
          models =
            [
              WriteToCache
                {
                  ModelQuery.WriteToCache.kind = "thrift";
                  name = [ModelQuery.WriteToCache.Substring.MethodName];
                };
            ];
          find = Method;
          expected_models = [];
          unexpected_models = [];
        };
      ]
    ~callables:
      [
        Target.Method { class_name = "test.C"; method_name = "foo"; kind = Normal };
        Target.Method { class_name = "test.D"; method_name = "foo"; kind = Normal };
      ]
    ~expected:
      [
        "thrift", "foo", Target.Method { class_name = "test.C"; method_name = "foo"; kind = Normal };
        "thrift", "foo", Target.Method { class_name = "test.D"; method_name = "foo"; kind = Normal };
      ];
  (* Multiple WriteToCache in the same query. *)
  assert_generated_cache
    ~source:
      {|
      class C:
        def foo(self): ...
      class D:
        def foo(self): ...
      |}
    ~queries:
      [
        {
          location = Ast.Location.any;
          name = "get_foo";
          where = [NameConstraint (Matches (Re2.create_exn "C.foo"))];
          models =
            [
              WriteToCache
                {
                  ModelQuery.WriteToCache.kind = "a";
                  name = [ModelQuery.WriteToCache.Substring.MethodName];
                };
              WriteToCache
                {
                  ModelQuery.WriteToCache.kind = "b";
                  name = [ModelQuery.WriteToCache.Substring.MethodName];
                };
            ];
          find = Method;
          expected_models = [];
          unexpected_models = [];
        };
      ]
    ~callables:
      [
        Target.Method { class_name = "test.C"; method_name = "foo"; kind = Normal };
        Target.Method { class_name = "test.D"; method_name = "foo"; kind = Normal };
      ]
    ~expected:
      [
        "a", "foo", Target.Method { class_name = "test.C"; method_name = "foo"; kind = Normal };
        "b", "foo", Target.Method { class_name = "test.C"; method_name = "foo"; kind = Normal };
      ];
  ()


let () =
  "modelQuery"
  >::: [
         "generated_annotations" >:: test_generated_annotations;
         "partition_cache_queries" >:: test_partition_cache_queries;
         "generated_cache" >:: test_generated_cache;
       ]
  |> Test.run
