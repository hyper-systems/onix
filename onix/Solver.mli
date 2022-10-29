val resolve_repo : string -> OpamFilename.Dir.t * OpamUrl.t

val solve :
  ?resolutions:OpamFormula.atom list ->
  repo_url:string ->
  with_test:Opam_utils.dep_flag ->
  with_doc:Opam_utils.dep_flag ->
  with_dev_setup:Opam_utils.dep_flag ->
  string list ->
  Lock_file.t
(** Find a package solution for provided root opam files given repo URL. *)
