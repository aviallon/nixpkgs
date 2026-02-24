{
  lib,
  stdenv,
  fetchFromGitHub,
  cmake,
  boost,
  cereal,
  immer,
  zug,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "lager";
  version = "0.1.2";

  src = fetchFromGitHub {
    owner = "arximboldi";
    repo = "lager";
    tag = "v${finalAttrs.version}";
    hash = "sha256-ssGBQu8ba798MSTtJeCBE3WQ7AFfvSGLhZ7WBYHEgfw=";
  };

  strictDeps = true;

  nativeBuildInputs = [ cmake ];

  buildInputs = [
    boost
    cereal
    immer
    zug
  ];

  cmakeFlags = [
    (lib.cmakeBool "lager_BUILD_DEBUGGER_EXAMPLES" false)
    (lib.cmakeBool "lager_BUILD_DOCS" false)
    (lib.cmakeBool "lager_BUILD_EXAMPLES" false)
    (lib.cmakeBool "lager_BUILD_TESTS" false)
  ];

  # remove BUILD file to avoid conflicts with the build directory
  preConfigure = ''
    rm BUILD
  '';

  meta = {
    changelog = "https://github.com/arximboldi/lager/releases/tag/${finalAttrs.src.tag}";
    description = "C++ library for value-oriented design using the unidirectional data-flow architecture — Redux for C++";
    homepage = "https://sinusoid.es/lager/";
    license = lib.licenses.mit;
    maintainers = [ ];
  };
})
