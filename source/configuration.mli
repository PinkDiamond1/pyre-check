(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

module Buck : sig
  type t = {
    mode: string option;
    isolation_prefix: string option;
    bxl_builder: string option;
    use_buck2: bool;
    targets: string list;
    (* This is the buck root of the source directory, i.e. output of `buck root`. *)
    source_root: PyrePath.t;
    (* This is the root of directory where built artifacts will be placed. *)
    artifact_root: PyrePath.t;
  }
  [@@deriving sexp, compare, hash, yojson]
end

module ChangeIndicator : sig
  type t = {
    root: PyrePath.t;
    relative: string;
  }
  [@@deriving sexp, compare, hash, yojson]

  val to_path : t -> PyrePath.t
end

module UnwatchedFiles : sig
  type t = {
    root: PyrePath.t;
    checksum_path: string;
  }
  [@@deriving sexp, compare, hash, yojson]
end

module UnwatchedDependency : sig
  type t = {
    change_indicator: ChangeIndicator.t;
    files: UnwatchedFiles.t;
  }
  [@@deriving sexp, compare, hash, yojson]
end

module SourcePaths : sig
  type t =
    | Simple of SearchPath.t list
    | WithUnwatchedDependency of {
        sources: SearchPath.t list;
        unwatched_dependency: UnwatchedDependency.t;
      }
    | Buck of Buck.t
  [@@deriving sexp, compare, hash, yojson]

  val to_search_paths : t -> SearchPath.t list
end

module RemoteLogging : sig
  type t = {
    logger: string;
    identifier: string;
  }
  [@@deriving sexp, compare, hash, yojson]
end

module PythonVersion : sig
  type t = {
    major: int;
    minor: int;
    micro: int;
  }
  [@@deriving sexp, compare, hash, yojson]

  val default : t
end

module SharedMemory : sig
  type t = {
    heap_size: int;
    dependency_table_power: int;
    hash_table_power: int;
  }
  [@@deriving sexp, compare, hash, yojson]

  val default : t
end

module Extension : sig
  type t = {
    suffix: string;
    include_suffix_in_module_qualifier: bool;
  }
  [@@deriving show, sexp, compare, hash, yojson]

  val create_extension : string -> t

  val suffix : t -> string
end

module Analysis : sig
  type incremental_style =
    | Shallow
    | FineGrained
  [@@deriving show]

  type shared_memory = {
    heap_size: int;
    dependency_table_power: int;
    hash_table_power: int;
  }
  [@@deriving show]

  type constraint_solving_style =
    | FunctionCallLevel
    | ExpressionLevel
  [@@deriving show]

  val default_constraint_solving_style : constraint_solving_style

  val default_enable_readonly_analysis : bool

  val default_enable_unawaited_awaitable_analysis : bool

  type t = {
    parallel: bool;
    analyze_external_sources: bool;
    filter_directories: PyrePath.t list option;
    ignore_all_errors: PyrePath.t list option;
    number_of_workers: int;
    local_root: PyrePath.t;
    debug: bool;
    project_root: PyrePath.t;
    source_paths: SearchPath.t list;
    search_paths: SearchPath.t list;
    taint_model_paths: PyrePath.t list;
    strict: bool;
    show_error_traces: bool;
    excludes: Str.regexp list;
    extensions: Extension.t list;
    store_type_check_resolution: bool;
    store_type_errors: bool;
    incremental_style: incremental_style;
    log_directory: PyrePath.t;
    python_major_version: int;
    python_minor_version: int;
    python_micro_version: int;
    shared_memory: shared_memory;
    enable_type_comments: bool;
    constraint_solving_style: constraint_solving_style;
    enable_readonly_analysis: bool;
    enable_unawaited_awaitable_analysis: bool;
  }
  [@@deriving show]

  val create
    :  ?parallel:bool ->
    ?analyze_external_sources:bool ->
    ?filter_directories:PyrePath.t list ->
    ?ignore_all_errors:PyrePath.t list ->
    ?number_of_workers:int ->
    ?local_root:PyrePath.t ->
    ?project_root:PyrePath.t ->
    ?search_paths:SearchPath.t list ->
    ?taint_model_paths:PyrePath.t list ->
    ?strict:bool ->
    ?debug:bool ->
    ?show_error_traces:bool ->
    ?excludes:string list ->
    ?extensions:Extension.t list ->
    ?store_type_check_resolution:bool ->
    ?store_type_errors:bool ->
    ?incremental_style:incremental_style ->
    ?log_directory:string ->
    ?python_major_version:int ->
    ?python_minor_version:int ->
    ?python_micro_version:int ->
    ?shared_memory_heap_size:int ->
    ?shared_memory_dependency_table_power:int ->
    ?shared_memory_hash_table_power:int ->
    ?enable_type_comments:bool ->
    ?constraint_solving_style:constraint_solving_style ->
    ?enable_readonly_analysis:bool ->
    ?enable_unawaited_awaitable_analysis:bool ->
    source_paths:SearchPath.t list ->
    unit ->
    t

  val log_directory : t -> PyrePath.t

  val search_paths : t -> SearchPath.t list

  val extension_suffixes : t -> string list

  val find_extension : t -> ArtifactPath.t -> Extension.t option

  val validate_paths : t -> unit
end

module TaintOutputFormat : sig
  type t =
    | Json
    | ShardedJson
  [@@deriving sexp, compare, hash]

  val of_string : string -> (t, string) Result.t
end

module MissingFlowKind : sig
  type t =
    (* Find missing flows through obscure models. *)
    | Obscure
    (* Find missing flows due to missing type information. *)
    | Type
  [@@deriving sexp, compare, equal, hash]

  val of_string : string -> (t, string) Result.t
end

module StaticAnalysis : sig
  type t = {
    repository_root: PyrePath.t option;
    (* A directory to write files in. *)
    save_results_to: PyrePath.t option;
    output_format: TaintOutputFormat.t;
    dump_call_graph: PyrePath.t option;
    verify_models: bool;
    verify_dsl: bool;
    (* Analysis configuration *)
    configuration: Analysis.t;
    rule_filter: int list option;
    source_filter: string list option;
    sink_filter: string list option;
    transform_filter: string list option;
    find_missing_flows: MissingFlowKind.t option;
    dump_model_query_results: PyrePath.t option;
    use_cache: bool;
    inline_decorators: bool;
    maximum_model_source_tree_width: int option;
    maximum_model_sink_tree_width: int option;
    maximum_model_tito_tree_width: int option;
    maximum_tree_depth_after_widening: int option;
    maximum_return_access_path_width: int option;
    maximum_return_access_path_depth_after_widening: int option;
    maximum_tito_collapse_depth: int option;
    maximum_tito_positions: int option;
    maximum_overrides_to_analyze: int option;
    maximum_trace_length: int option;
    maximum_tito_depth: int option;
    check_invariants: bool;
    limit_entrypoints: bool;
  }

  val create
    :  Analysis.t ->
    ?repository_root:PyrePath.t ->
    ?save_results_to:PyrePath.t ->
    ?output_format:TaintOutputFormat.t ->
    ?dump_call_graph:PyrePath.t ->
    ?verify_models:bool ->
    ?verify_dsl:bool ->
    ?rule_filter:int list ->
    ?source_filter:string list ->
    ?sink_filter:string list ->
    ?transform_filter:string list ->
    ?find_missing_flows:MissingFlowKind.t ->
    ?dump_model_query_results:PyrePath.t ->
    ?use_cache:bool ->
    ?inline_decorators:bool ->
    ?maximum_model_source_tree_width:int ->
    ?maximum_model_sink_tree_width:int ->
    ?maximum_model_tito_tree_width:int ->
    ?maximum_tree_depth_after_widening:int ->
    ?maximum_return_access_path_width:int ->
    ?maximum_return_access_path_depth_after_widening:int ->
    ?maximum_tito_collapse_depth:int ->
    ?maximum_tito_positions:int ->
    ?maximum_overrides_to_analyze:int ->
    ?maximum_trace_length:int ->
    ?maximum_tito_depth:int ->
    ?check_invariants:bool ->
    ?limit_entrypoints:bool ->
    unit ->
    t
end
