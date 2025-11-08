{
  pkgs,
  lib ? pkgs.lib,
  brew-api,
  stdenvNoCC ? pkgs.stdenvNoCC,
  ...
}: let
  getName = cask: lib.lists.elemAt cask.name 0;
  getBinary = artifacts: lib.lists.elemAt artifacts.binary 0;
  getApp = artifacts: lib.lists.elemAt artifacts.app 0;

  getVariationData = cask: variation:
    if cask ? variations && lib.attrsets.hasAttr variation cask.variations
    then cask.variations."${variation}"
    else throw "Variation '${variation}' not found for ${cask.token}. Available: ${builtins.toString (lib.attrsets.attrNames (cask.variations or {}))}";

  caskToDerivation = cask: {variation ? null}: let
    specificVariationData =
      if variation != null
      then getVariationData cask variation
      else {};

    defaultCaskData = {
      url = cask.url or null;
      sha256 = cask.sha256 or null;
      version = cask.version or null;
      artifacts = cask.artifacts or [];
    };

    selectedData = defaultCaskData // specificVariationData;

    inherit (selectedData) url sha256 version;
    artifacts = lib.attrsets.mergeAttrsList selectedData.artifacts;

    isBinary = lib.attrsets.hasAttr "binary" artifacts;
    isApp = lib.attrsets.hasAttr "app" artifacts;
    isPkg = lib.attrsets.hasAttr "pkg" artifacts;
  in
    stdenvNoCC.mkDerivation (finalAttrs: {
      pname = cask.token;
      inherit version;

      src = pkgs.fetchurl {
        inherit url;
        sha256 = lib.strings.optionalString (sha256 != null && sha256 != "no_check") sha256;
      };

      nativeBuildInputs = with pkgs;
        [
          gzip
          _7zz
          unzip
          makeWrapper
        ]
        ++ lib.lists.optional isPkg (
          with pkgs; [
            xar
            cpio
            fd
            pbzx
            unixtools.xxd
          ]
        );

      unpackPhase =
        if isPkg
        then ''
          xar -xf $src
          mkdir -p package
          cd package
          for pkg in $(cat Distribution | grep -oE "#.+\.pkg" | sed -e "s/^#//" -e "s/$/\/Payload/"); do
            magic=$(xxd -l 6 "../$pkg" | awk '{print $2$3$4}' | head -n1)
            case $magic in
              70627a78*) echo "PBZX detected"; pbzx -n "../$pkg" | cpio -idm ;;
              1f8b08*) echo "GZIP detected"; zcat "../$pkg" | cpio -idm ;;
              425a68*) echo "BZIP2 detected"; bzcat "../$pkg" | cpio -idm ;;
              fd377a58*) echo "XZ detected"; xzcat "../$pkg" | cpio -idm ;;
              *) echo "Unknown or already uncompressed"; file "../$pkg" ;;
            esac
          done
        ''
        else if isApp 
        then ''
          if [[ "$src" == *.dmg ]]; then
            echo "Detected .dmg – mounting with hdiutil"
            mnt=$(TMPDIR=/tmp mktemp -d -t nix-XXXXXXXXXX)
            finish() {
              echo "Detaching $mnt"
              /usr/bin/hdiutil detach "$mnt" -force
              rm -rf "$mnt"
            }
            trap finish EXIT
            /usr/bin/hdiutil attach -nobrowse -mountpoint "$mnt" "$src"
            echo "Copying mounted contents"
            cp -ar "$mnt/." "$PWD/"
          elif [[ "$src" == *.zip ]]; then
            echo "Detected .zip - extracting with unzip"
            unzip "$src"
          elif [[ "$src" == *.tar.xz ]]; then
            echo "Detected .tar.xz - extracting with gnutar"
            tar -xvf "$src"
          else
            echo "Some kind of other archive – extracting with 7zz"
            7zz x -snld "$src"
          fi
        ''
        else if isBinary
then ''
          if [ "$(file --mime-type -b "$src")" == "application/gzip" ]; then
            gunzip $src -c > ${getBinary artifacts}
          elif [ "$(file --mime-type -b "$src")" == "application/x-mach-binary" ]; then
            cp $src ${getBinary artifacts}
          fi
        ''
else "";

      sourceRoot = lib.strings.optionalString isApp (getApp artifacts);

# Patching shebangs invalidates code signing
      dontPatchShebangs = true;

      installPhase =
        if isPkg
then ''
          if [ -d "Applications" ]; then
            mkdir -p $out/Applications
            cp -R Applications/* $out/Applications/
          fi

          if [ -n "$(fd -d 1 -t d '\.app$' .)" ]; then
            mkdir -p $out/Applications
            cp -R *.app $out/Applications/
          fi

          if [ -d "Resources" ]; then
            mkdir -p $out/Resources
            cp -R Resources/* $out/Resources/
          fi

          if [ -d "Contents" ]; then
           name=$(awk '/<key>CFBundleName<\/key>/{getline; if ($0 ~ /<string>/) {sub(/.*<string>/,""); sub(/<\/string>.*/,""); n=$0}} /<key>CFBundleExecutable<\/key>/{getline; if ($0 ~ /<string>/) {sub(/.*<string>/,""); sub(/<\/string>.*/,""); e=$0}} END{if (n!="") print n ".app"; else if (e!="") print e ".app"; else print "Unknown.app"}' Contents/Info.plist)
           mkdir -p "$out/Applications/$name"
           cp -R Contents/* $out/Applications/$name/Contents/
          fi

          if [ -d "Library" ]; then
            mkdir -p $out/Library
            cp -R Library/* $out/Library/
          fi
        ''
else if isApp
then ''
          mkdir -p "$out/Applications/${finalAttrs.sourceRoot}"
          cp -R . "$out/Applications/${finalAttrs.sourceRoot}"

          if [[ -e "$out/Applications/${finalAttrs.sourceRoot}/Contents/MacOS/${getName cask}" ]]; then
            makeWrapper "$out/Applications/${finalAttrs.sourceRoot}/Contents/MacOS/${getName cask}" $out/bin/${cask.token}
          elif [[ -e "$out/Applications/${finalAttrs.sourceRoot}/Contents/MacOS/${lib.strings.removeSuffix ".app" finalAttrs.sourceRoot}" ]]; then
            makeWrapper "$out/Applications/${finalAttrs.sourceRoot}/Contents/MacOS/${lib.strings.removeSuffix ".app" finalAttrs.sourceRoot}" $out/bin/${cask.token}
          fi
        ''
else if (isBinary && !isApp)
then ''
          mkdir -p $out/bin
          cp -R ./* $out/bin/
        ''
else "";

      meta = {
        inherit (cask) homepage;
        description = cask.desc;
        platforms = lib.platforms.darwin;
        mainProgram =
          if (isBinary && !isApp)
          then (getBinary artifacts)
          else cask.token;
      };
    });

  casks = lib.trivial.importJSON (brew-api + "/cask.json");
in
  lib.attrsets.listToAttrs (
    lib.lists.map (cask: {
      name = cask.token;
      value = lib.customisation.makeOverridable (caskToDerivation cask) {};
    })
    casks
  )