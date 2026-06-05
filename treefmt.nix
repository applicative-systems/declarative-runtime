{ ... }:
{
  projectRootFile = "flake.nix";
  programs.nixfmt.enable = true;

  # Markdown formatting. Scoped to *.md so prettier does not touch JSON/YAML/JS.
  programs.prettier = {
    enable = true;
    includes = [ "*.md" ];
  };
}
