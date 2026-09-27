FROM dmirtillo/vrising-dedicated:latest

# Bundle BepInEx (IL2CPP) pack for V Rising into a non-mounted image location.
# Our entrypoint syncs it into the bind-mounted server dir at runtime.
COPY bepinex/BepInExPack_V_Rising/ /opt/bepinex/

# Pre-generated IL2CPP interop assemblies (from VRising.Unhollowed.Client).
# Pre-seeding these lets BepInEx skip the Unity base-library download + Cpp2IL
# dump step, which hangs under Wine (unity.bepinex.dev returns 404 for 2022.3.58f1).
COPY interop/ /opt/bepinex-interop/

# Patch the base start.sh (runs as the 'steam' user) so that after wineboot it
# starts Wine's service daemon (RpcSs/PlugPlay) and waits, before launching the
# game. CoreCLR's managed startup needs RpcSs/COM; without this the BepInEx
# preloader hangs ("err:ole:start_rpcss Failed to start RpcSs service").
RUN sed -i 's#^\(WINEDLLOVERRIDES="mscoree,mshtml=" DISPLAY=:0.0 wineboot --init\)#\1\nwineserver -w || true\nWINEDLLOVERRIDES="mscoree,mshtml=" DISPLAY=:0.0 wine64 services.exe \&\nsleep 8\necho "[castlelink] Wine services (rpcss) warmed"#' /start.sh

# Wrapper entrypoint that injects BepInEx then calls the original /start.sh
COPY castlelink-entrypoint.sh /castlelink-entrypoint.sh
RUN chmod +x /castlelink-entrypoint.sh

# The base image sets ENTRYPOINT ["/start.sh"], which takes precedence over CMD.
# Override ENTRYPOINT so our wrapper runs first (it exports doorstop/CoreCLR env
# then exec's /start.sh).
ENTRYPOINT ["/castlelink-entrypoint.sh"]

