import Lake
open Lake DSL

package «ProvedSRE» where
  version := v!"0.1.0"


lean_lib «ProvedSRE» where

@[default_target]
lean_exe «provedsre» where
  root := `ProvedSRE.Verify
