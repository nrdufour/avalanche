{ lib
, buildGoModule
, secondbrain-src
}:

buildGoModule rec {
  pname = "secondbrain";
  version = "0.1.0";

  # Source from flake input (updated via `nix flake update secondbrain`)
  src = secondbrain-src;

  vendorHash = null;

  subPackages = [
    "cmd/sb"
  ];

  ldflags = [
    "-s"
    "-w"
    "-X main.Version=${version}"
  ];

  meta = with lib; {
    description = "Capture, classify, and recall fleeting thoughts";
    longDescription = ''
      SecondBrain is a thought capture and classification system that uses
      LLM-powered analysis to sort fleeting thoughts into structured buckets
      (people, ideas, projects, admin) with semantic search via pgvector.
    '';
    homepage = "https://forge.internal/nemo/secondbrain";
    license = licenses.mit;
    maintainers = [ ];
    mainProgram = "sb";
    platforms = platforms.linux;
  };
}
