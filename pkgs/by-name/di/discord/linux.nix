{
  # Package metadata
  pname,
  source,
  meta,
  binaryName,
  desktopName,
  hostVersion,
  passthru,
  moduleSrcs,
  # Package utilities
  disableBreakingUpdates,
  stageApp,
  # Feature flags (cross-platform)
  withOpenASAR ? false,
  withVencord ? false,
  withEquicord ? false,
  withMoonlight ? false,
  # Disabling this would normally break Discord.
  # The intended use-case is when NEW_UPDATE_ENDPOINT is set via other means,
  # such as a declaratively linked settings.json
  disableUpdates ? true,
  # Feature flags (Linux exclusive)
  withTTS ? true,
  enableAutoscroll ? false,
  # Package arguments
  commandLineArgs ? "",
  useFHSEnv ? true,
  # Miscellaneous
  lib,
  stdenv,
  makeShellWrapper,
  gtk3,
  brotli,
  jq,
  addDriverRunpath,
  fetchurl,
  makeDesktopItem,
  autoPatchelfHook,
  cups,
  libdrm,
  libuuid,
  libxdamage,
  libx11,
  libxscrnsaver,
  libxtst,
  libxcb,
  libxshmfence,
  wrapGAppsHook3,
  alsa-lib,
  libgbm,
  nspr,
  nss,
  libpulseaudio,
  libcxx,
  systemdLibs,
  atk,
  at-spi2-atk,
  at-spi2-core,
  cairo,
  dbus,
  expat,
  fontconfig,
  freetype,
  gdk-pixbuf,
  glib,
  libglvnd,
  libnotify,
  libxcomposite,
  libva,
  libxcursor,
  libxext,
  libxfixes,
  libxi,
  libxrandr,
  libxrender,
  libxkbcommon,
  pango,
  pciutils,
  pipewire,
  libappindicator,
  libdbusmenu,
  wayland,
  speechd-minimal,
  openasar,
  vencord,
  equicord,
  moonlight,
}@args:

let
  inherit (source) version;

  src = fetchurl { inherit (source.distro) url hash; };

  targetPkgs =
    pkgs:
    (lib.attrValues {
      inherit (pkgs)
        libcxx
        systemdLibs
        libpulseaudio
        libdrm
        libgbm
        alsa-lib
        atk
        at-spi2-atk
        at-spi2-core
        cairo
        cups
        dbus
        expat
        fontconfig
        freetype
        gdk-pixbuf
        glib
        gtk3
        libglvnd
        libnotify
        libx11
        libxcomposite
        libuuid
        libva
        libxcursor
        libxdamage
        libxext
        libxfixes
        libxi
        libxrandr
        libxrender
        libxtst
        nspr
        libxcb
        libxkbcommon
        pango
        pciutils
        pipewire
        libxscrnsaver
        libappindicator
        libdbusmenu
        wayland
        ;

      inherit (pkgs.stdenv.cc) cc;
    })
    ++ lib.optionals withTTS [ pkgs.speechd-minimal ]
    # nss is intentionally NOT in libPath: it would leak via LD_LIBRARY_PATH
    # to xdg-open and break Firefox children when versions diverge (#514859,
    # PR #186603)
    ++ lib.optionals useFHSEnv [ pkgs.nss ];
in
stdenv.mkDerivation (finalAttrs: {
  inherit
    version
    src
    meta
    disableBreakingUpdates
    stageApp
    ;

  pname = if useFHSEnv then "${pname}-unwrapped" else pname;

  libPath = if useFHSEnv then null else lib.makeLibraryPath (targetPkgs args);

  nativeBuildInputs = [
    makeShellWrapper
    brotli
    jq
  ]
  ++ lib.optionals (!useFHSEnv) [
    autoPatchelfHook
    cups
    libdrm
    libuuid
    libxdamage
    libx11
    libxscrnsaver
    libxtst
    libxcb
    libxshmfence
    wrapGAppsHook3
  ];

  buildInputs = lib.optionals (!useFHSEnv) [
    alsa-lib
    libgbm
    nspr
    nss
    # The distro layout ships prebuilt `.node` modules:
    # discord_dispatch is linked against openssl 1.1, discord_voice against libpulseaudio.
    # Ignore the missing dependency on insecure openssl_1_1: discord_dispatch is
    # effectively unused in practice.
    libpulseaudio
  ];

  strictDeps = true;

  dontUnpack = true;

  dontPatchELF = useFHSEnv;
  dontStrip = useFHSEnv;

  autoPatchelfIgnoreMissingDeps = lib.optionals (!useFHSEnv) [
    "libssl.so.1.1"
    "libcrypto.so.1.1"
  ];

  installPhase = ''
    runHook preInstall

    mkdir -p $out/{bin,opt/${binaryName}/app-${version},share/icons/hicolor/256x256/apps}

    # The host distro is a brotli-compressed tar with all files under a `files/`
    # prefix (the channel binary, libffmpeg.so, resources/, etc) and a top-level
    # manifest in `delta_manifest.json`. Module distros follow the same format
    # with module contents under `files/`
    extractDistro() {
      local src="$1"
      local dest="$2"
      local tarball
      tarball=$(mktemp)
      brotli -d < "$src" > "$tarball"
      tar xf "$tarball" --strip-components=1 -C "$dest"

      tar xfO "$tarball" delta_manifest.json

      rm "$tarball"
    }

    host=$(mktemp)

    extractDistro $src $out/opt/${binaryName}/app-${version} \
      | jq '{ host_version: ${builtins.toJSON hostVersion}, distro_manifest: ., install_state: "Installed" }' \
      > "$host"
    chmod +x $out/opt/${binaryName}/app-${version}/${binaryName}

    modules=$(mktemp)

    # The module directory layout must match what Discord's node runtime
    # expects: modules/<name>-<version>/<name>
    ${lib.concatMapAttrsStringSep "\n" (
      name: mod:
      let
        module_version = {
          inherit (mod) version;
          module = {
            inherit name;
            host_version = hostVersion;
          };
        };
      in
      ''
        mkdir -p $out/opt/${binaryName}/app-${version}/modules/${name}-${toString mod.version}/${name}
        extractDistro ${mod.src} $out/opt/${binaryName}/app-${version}/modules/${name}-${toString mod.version}/${name} \
          | jq '{ module_version: ${builtins.toJSON module_version}, distro_manifest: ., install_state: "Installed" }' \
          >> "$modules"
      ''
    ) moduleSrcs}

    jq '[. + { $modules }]' "$host" --slurpfile modules "$modules" > "$out/opt/${binaryName}/delta_manifests.json"
    rm "$host" "$modules"

    mkdir -p $out/opt/${binaryName}/app-${version}/modules/discord_krisp-${toString moduleSrcs.discord_krisp.version}/discord_krisp/KMS/logs

    # Chromium 148 multiplies Plasma's GTK DPI scale by the native Wayland surface
    # scale, which makes the UI too large. See #551645
    wrapProgramShell $out/opt/${binaryName}/app-${version}/${binaryName} \
        "''${gappsWrapperArgs[@]}" \
        --run 'case ":''${XDG_CURRENT_DESKTOP:-}:" in *:KDE:*) discordKdeWayland=1 ;; *) unset discordKdeWayland ;; esac' \
        --add-flags "\''${NIXOS_OZONE_WL:+\''${WAYLAND_DISPLAY:+--ozone-platform=wayland --enable-features=WaylandWindowDecorations --enable-wayland-ime=true}}" \
        --add-flags "\''${WAYLAND_DISPLAY:+\''${discordKdeWayland:+--force-device-scale-factor=1}}" \
        ${lib.strings.optionalString withTTS ''
          --run 'if [[ "''${NIXOS_SPEECH:-default}" != "False" ]]; then NIXOS_SPEECH=True; else unset NIXOS_SPEECH; fi' \
          --add-flags "\''${NIXOS_SPEECH:+--enable-speech-dispatcher}" \
        ''} \
        ${lib.strings.optionalString enableAutoscroll "--add-flags \"--enable-blink-features=MiddleClickAutoscroll\""} \
        --prefix XDG_DATA_DIRS : "${gtk3}/share/gsettings-schemas/${gtk3.name}/" \
        --prefix LD_LIBRARY_PATH : $out/opt/${binaryName}/app-${version}:${addDriverRunpath.driverLink}/lib \
        ${lib.strings.optionalString (!useFHSEnv) "--prefix LD_LIBRARY_PATH : ${finalAttrs.libPath}"} \
        --suffix VK_ADD_DRIVER_FILES : "${addDriverRunpath.driverLink}/share/vulkan/icd.d" \
        ${lib.strings.optionalString disableUpdates "--run \"${lib.getExe finalAttrs.disableBreakingUpdates} &\""} \
        --run "${finalAttrs.stageApp} $out/opt/${binaryName}/app-${version} $out/opt/${binaryName}/delta_manifests.json" \
        --run '[ -t 1 ] || exec > /dev/null 2>&1' \
        --add-flags ${lib.escapeShellArg commandLineArgs}

    substituteInPlace $out/opt/${binaryName}/app-${version}/${binaryName} \
        --replace-fail $out/opt/${binaryName}/app-${version}/.${binaryName}-wrapped \
                       \''${DISCORD_USER_DATA_DIR-\''${XDG_CONFIG_HOME:-\$HOME/.config}}/${lib.toLower binaryName}/app-${version}/.${binaryName}-wrapped

    ln -s $out/opt/${binaryName}/app-${version}/${binaryName} $out/bin/
    # Without || true the install would fail on case-insensitive filesystems
    ln -s $out/opt/${binaryName}/app-${version}/${binaryName} $out/bin/${lib.strings.toLower binaryName} || true

    ln -s $out/opt/${binaryName}/app-${version}/discord.png $out/share/icons/hicolor/256x256/apps/${pname}.png

    ln -s "$desktopItem/share/applications" $out/share/

    runHook postInstall
  '';

  postInstall =
    lib.strings.optionalString withOpenASAR ''
      cp -f ${openasar} $out/opt/${binaryName}/app-${version}/resources/app.asar
    ''
    + lib.strings.optionalString withVencord ''
      mv $out/opt/${binaryName}/app-${version}/resources/app.asar $out/opt/${binaryName}/app-${version}/resources/_app.asar
      mkdir $out/opt/${binaryName}/app-${version}/resources/app.asar
      echo '{"name":"discord","main":"index.js"}' > $out/opt/${binaryName}/app-${version}/resources/app.asar/package.json
      echo 'require("${vencord}/patcher.js")' > $out/opt/${binaryName}/app-${version}/resources/app.asar/index.js
    ''
    + lib.strings.optionalString withEquicord ''
      mv $out/opt/${binaryName}/app-${version}/resources/app.asar $out/opt/${binaryName}/app-${version}/resources/_app.asar
      mkdir $out/opt/${binaryName}/app-${version}/resources/app.asar
      echo '{"name":"discord","main":"index.js"}' > $out/opt/${binaryName}/app-${version}/resources/app.asar/package.json
      echo 'require("${equicord}/desktop/patcher.js")' > $out/opt/${binaryName}/app-${version}/resources/app.asar/index.js
    ''
    + lib.strings.optionalString withMoonlight ''
      mv $out/opt/${binaryName}/app-${version}/resources/app.asar $out/opt/${binaryName}/app-${version}/resources/_app.asar
      mkdir $out/opt/${binaryName}/app-${version}/resources/app
      echo '{"name":"discord","main":"injector.js","private": true}' > $out/opt/${binaryName}/app-${version}/resources/app/package.json
      echo 'require("${moonlight}/injector.js").inject(require("path").join(__dirname, "../_app.asar"));' > $out/opt/${binaryName}/app-${version}/resources/app/injector.js
    '';

  desktopItem = makeDesktopItem {
    name = pname;
    exec = binaryName;
    icon = pname;
    inherit desktopName;
    comment = meta.description;
    genericName = "Instant Messenger";
    categories = [
      "Network"
      "InstantMessaging"
    ];
    mimeTypes = [ "x-scheme-handler/discord" ];
    startupWMClass = "discord";
  };

  passthru = passthru // {
    inherit targetPkgs;
  };
})
