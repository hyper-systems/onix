open Utils

type package = {
  name : OpamPackage.Name.t;
  version : OpamPackage.Version.t;
  opam : Fpath.t;
  path : OpamFilename.Dir.t;
}

type t = {
  self : package;
  ocaml_version : OpamPackage.Version.t;
  scope : package OpamPackage.Name.Map.t;
  vars : OpamTypes.variable_contents OpamVariable.Full.Map.t;
}

module Vars = struct
  let add_native_system_vars vars =
    let system_variables = OpamSysPoll.variables in
    List.fold_left
      (fun vars ((name : OpamVariable.t), value) ->
        match value with
        | (lazy None) -> vars
        | (lazy (Some contents)) ->
          let var = OpamVariable.Full.global name in
          OpamVariable.Full.Map.add var contents vars)
      vars system_variables

  let add_global_vars vars =
    let string = OpamVariable.string in
    let bool = OpamVariable.bool in
    let add var =
      OpamVariable.Full.Map.add
        (OpamVariable.Full.global (OpamVariable.of_string var))
    in
    let add_pkg name var =
      OpamVariable.Full.Map.add
        ((OpamVariable.Full.create (OpamPackage.Name.of_string name))
           (OpamVariable.of_string var))
    in

    vars
    |> add "opam-version" (string (OpamVersion.to_string OpamVersion.current))
    |> add "jobs" (string (Nix_utils.get_nix_build_jobs ()))
    |> add "make" (string "make")
    |> add "os-version" (string "unknown")
    |> add_pkg "ocaml" "preinstalled" (bool true)
    |> add_pkg "ocaml" "native" (bool true)
    |> add_pkg "ocaml" "native-tools" (bool true)
    |> add_pkg "ocaml" "native-dynlink" (bool true)

  let default =
    OpamVariable.Full.Map.empty |> add_native_system_vars |> add_global_vars

  let make_path_lib ?suffix ~ocaml_version pkg =
    let prefix = OpamFilename.Dir.to_string pkg.path in
    let pkg_name = OpamPackage.Name.to_string pkg.name in
    match suffix with
    | Some suffix ->
      String.concat "/"
        [
          prefix;
          "lib/ocaml";
          OpamPackage.Version.to_string ocaml_version;
          "site-lib";
          suffix;
          pkg_name;
        ]
    | None ->
      String.concat "/"
        [
          prefix;
          "lib/ocaml";
          OpamPackage.Version.to_string ocaml_version;
          "site-lib";
          pkg_name;
        ]

  let make_path ~scoped pkg path =
    let prefix = OpamFilename.Dir.to_string pkg.path in
    let pkg_name = OpamPackage.Name.to_string pkg.name in
    if scoped then String.concat "/" [prefix; path; pkg_name]
    else String.concat "/" [prefix; path]

  let resolve_from_package_scope t package_name v =
    let bool x = Some (OpamVariable.bool x) in
    let string x = Some (OpamVariable.string x) in
    if OpamVariable.Full.is_global v then None
    else
      let var_str = OpamVariable.to_string (OpamVariable.Full.variable v) in
      match (var_str, OpamPackage.Name.Map.find_opt package_name t.scope) with
      | "installed", Some _ -> bool true
      | "installed", None -> bool false
      | "pinned", Some pkg -> bool (Opam_utils.is_pinned_version pkg.version)
      | "pinned", None -> bool false
      | "name", _ -> string (OpamPackage.Name.to_string package_name)
      | "lib", Some pkg ->
        string (make_path_lib ~ocaml_version:t.ocaml_version pkg)
      | "stublibs", Some pkg | "toplevel", Some pkg ->
        string
          (make_path_lib ~suffix:var_str ~ocaml_version:t.ocaml_version pkg)
      | "bin", Some pkg | "sbin", Some pkg | "man", Some pkg ->
        string (make_path ~scoped:false pkg var_str)
      | "doc", Some pkg | "share", Some pkg | "etc", Some pkg ->
        string (make_path ~scoped:true pkg var_str)
      | "build", _ -> string "ONIX_NOT_IMPLEMENTED_build"
      | "dev", _ -> bool false
      | "version", Some pkg ->
        string (OpamPackage.Version.to_string pkg.version)
      | "build-id", Some { path; _ } -> string (OpamFilename.Dir.to_string path)
      | "build-id", _ -> None
      | "opamfile", Some pkg -> string (Fpath.to_string pkg.opam)
      | "depends", _ | "hash", _ -> string ("ONIX_NOT_IMPLEMENTED_" ^ var_str)
      | _ -> None

  let resolve_from_scope t full_var =
    match OpamVariable.Full.scope full_var with
    | Self -> resolve_from_package_scope t t.self.name full_var
    | Package pkg_name -> resolve_from_package_scope t pkg_name full_var
    | Global ->
      let pkg_var =
        OpamVariable.Full.create t.self.name
          (OpamVariable.Full.variable full_var)
      in
      resolve_from_package_scope t t.self.name pkg_var

  let resolve_from_env full_var = OpamVariable.Full.read_from_env full_var

  let resolve_from_static vars full_var =
    OpamVariable.Full.Map.find_opt full_var vars

  let resolve_from_local local_vars var =
    match OpamVariable.Full.package var with
    | Some _ -> None
    | None -> (
      let var = OpamVariable.Full.variable var in
      try
        match OpamVariable.Map.find var local_vars with
        | None -> raise Exit (* Variable explicitly undefined *)
        | some -> some
      with Not_found -> None)

  let get_package_path () = None

  let resolve_from_global_scope t full_var =
    let string x = Some (OpamVariable.string x) in
    let var_str = OpamVariable.Full.to_string full_var in
    match (var_str, OpamPackage.Name.Map.find_opt t.self.name t.scope) with
    | "prefix", Some { path; _ }
    | "switch", Some { path; _ }
    | "root", Some { path; _ } -> string (OpamFilename.Dir.to_string path)
    | "user", _ -> Some (OpamVariable.string (Unix.getlogin ()))
    | "group", _ -> (
      try
        let gid = Unix.getgid () in
        let gname = (Unix.getgrgid gid).gr_name in
        Some (OpamVariable.string gname)
      with Not_found -> None)
    | "sys-ocaml-version", _ ->
      string (OpamPackage.Version.to_string t.ocaml_version)
    | _ -> None

  let try_resolvers resolvers full_var =
    let rec loop resolvers =
      match resolvers with
      | [] -> None
      | resolver :: resolvers' ->
        let contents = resolver full_var in
        if Option.is_some contents then contents else loop resolvers'
    in
    try loop resolvers with Exit -> None
end

let debug_var var contents =
  Fmt.pr "Variable lookup: %S = %a@."
    (OpamVariable.Full.to_string var)
    (Fmt.Dump.option
       (Fmt.using OpamVariable.string_of_variable_contents Fmt.Dump.string))
    contents

let resolve t ?(local = OpamVariable.Map.empty) full_var =
  let contents =
    Vars.try_resolvers
      [
        Vars.resolve_from_local local;
        Vars.resolve_from_env;
        Vars.resolve_from_static t.vars;
        Vars.resolve_from_global_scope t;
        Vars.resolve_from_scope t;
      ]
      full_var
  in
  contents

let make ~self ~ocaml_version ?(vars = Vars.default) scope =
  (* TODO: check ocaml versions. *)
  let ocaml_version = OpamPackage.Version.of_string ocaml_version in
  { self; ocaml_version; vars; scope }

let decode_depend json =
  match json with
  | `Assoc bindings ->
    let name = ref None in
    let version = ref None in
    let path = ref None in
    let opam = ref None in
    let decode_binding (key, json) =
      match (key, json) with
      | "name", `String x -> name := Some x
      | "name", _ -> invalid_arg "could not decode JSON: name must be a string"
      | "version", `String x -> version := Some x
      | "version", _ ->
        invalid_arg "could not decode JSON: version must be a string"
      | "path", `String x -> path := Some x
      | "path", _ -> invalid_arg "could not decode JSON: path must be a string"
      | "opam", `String x -> opam := Some x
      | "opam", _ -> invalid_arg "could not decode JSON: opam must be a string"
      | _, _ -> invalid_arg ("could not decode JSON: unknown key: " ^ key)
    in
    List.iter decode_binding bindings;
    let name =
      !name
      |> Option.or_fail "could not decode JSON: missing name key"
      |> OpamPackage.Name.of_string
    in
    let version =
      !version
      |> Option.or_fail "could not decode JSON: missing version key"
      |> OpamPackage.Version.of_string
    in
    let path =
      !path
      |> Option.or_fail "could not decode JSON: missing path key"
      |> OpamFilename.Dir.of_string
    in
    let opam =
      !opam
      |> Option.or_fail "could not decode JSON: missing opam key"
      |> Fpath.v
    in
    { name; version; opam; path }
  | _ -> invalid_arg "depends entry must be an object"

let read_json ~ocaml_version ~path json =
  match json with
  | `Assoc bindings ->
    let name = ref None in
    let version = ref None in
    let opam = ref None in
    let depends = ref [] in
    let decode_binding (key, json) =
      match (key, json) with
      | "name", `String x -> name := Some x
      | "name", _ -> invalid_arg "could not decode JSON: name must be a string"
      | "version", `String x -> version := Some x
      | "version", _ ->
        invalid_arg "could not decode JSON: version must be a string"
      | "opam", `String x -> opam := Some x
      | "opam", _ -> invalid_arg "could not decode JSON: opam must be a string"
      | "depends", `List xs -> depends := List.map decode_depend xs
      | "depends", _ ->
        invalid_arg "could not decode JSON: depends must be an array"
      | _, _ -> invalid_arg ("could not decode JSON: unknown key: " ^ key)
    in
    List.iter decode_binding bindings;
    let name =
      !name
      |> Option.or_fail "could not decode JSON: missing name key"
      |> OpamPackage.Name.of_string
    in
    let version =
      !version
      |> Option.or_fail "could not decode JSON: missing version key"
      |> OpamPackage.Version.of_string
    in
    let opam =
      !opam
      |> Option.or_fail "could not decode JSON: missing opam key"
      |> Fpath.v
    in
    let path = path |> OpamFilename.Dir.of_string in
    let self = { name; version; opam; path } in
    let depends =
      List.fold_left
        (fun acc pkg -> OpamPackage.Name.Map.add pkg.name pkg acc)
        OpamPackage.Name.Map.empty !depends
    in
    let scope = OpamPackage.Name.Map.add self.name self depends in
    make ~self ~ocaml_version scope
  | _ -> invalid_arg "build context must be an object"

let read_file ~ocaml_version ~path file =
  let json = Yojson.Basic.from_file file in
  read_json ~ocaml_version ~path json
