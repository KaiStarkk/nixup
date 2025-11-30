{
  lib,
  stdenv,
  makeWrapper,
  jq,
  coreutils,
  gnugrep,
  gawk,
  gnused,
  moreutils,
  ncurses,
  alejandra,
  nix,
  diffutils,
  findutils,
}:
stdenv.mkDerivation {
  pname = "nixup";
  version = "1.0.0";

  src = ./.;

  nativeBuildInputs = [makeWrapper];

  installPhase = ''
    runHook preInstall

    # Install the main script
    install -Dm755 bin/nixup $out/bin/nixup

    # Install library modules
    install -Dm644 lib/core.sh $out/lib/core.sh
    install -Dm644 lib/help.sh $out/lib/help.sh
    install -Dm644 lib/progress.sh $out/lib/progress.sh
    install -Dm644 lib/packages.sh $out/lib/packages.sh
    install -Dm644 lib/updates.sh $out/lib/updates.sh
    install -Dm644 lib/config.sh $out/lib/config.sh
    install -Dm644 lib/diff.sh $out/lib/diff.sh

    # Wrap the script with required dependencies
    wrapProgram $out/bin/nixup \
      --prefix PATH : ${lib.makeBinPath [
        jq
        coreutils
        gnugrep
        gawk
        gnused
        moreutils
        ncurses
        alejandra
        nix
        diffutils
        findutils
      ]}

    runHook postInstall
  '';

  meta = with lib; {
    description = "Fast NixOS package update checker and configuration manager";
    homepage = "https://github.com/KaiStarkk/nixup";
    license = licenses.mit;
    platforms = platforms.linux;
    mainProgram = "nixup";
  };
}
