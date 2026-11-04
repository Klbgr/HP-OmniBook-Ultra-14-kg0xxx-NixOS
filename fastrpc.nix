{ lib, stdenv, fetchFromGitHub, autoreconfHook, pkg-config, libyaml, libbsd }:

# Qualcomm FastRPC user library (libcdsprpc.so etc.): the CPU side of DSP
# offload, needed by the QNN HTP stub (libQnnHtpV81Stub.so links against it).
stdenv.mkDerivation (finalAttrs: {
  pname = "fastrpc";
  version = "1.0.8";

  src = fetchFromGitHub {
    owner = "qualcomm";
    repo = "fastrpc";
    rev = "v${finalAttrs.version}";
    hash = "sha256-XL0u7zNRxpUHBQ761aXFUupR0AHJfRFRZPa92LNn2ZQ=";
  };

  nativeBuildInputs = [ autoreconfHook pkg-config ];
  buildInputs = [ libyaml libbsd ];

  configureFlags = [
    "--with-config-base-dir=/etc/fastrpc"
    "--with-udevrulesdir=${placeholder "out"}/lib/udev/rules.d"
    "--with-systemdsystemunitdir=${placeholder "out"}/lib/systemd/system"
    "--with-sysusersdir=${placeholder "out"}/lib/sysusers.d"
  ];

  meta = {
    description = "Qualcomm FastRPC user-space library";
    homepage = "https://github.com/qualcomm/fastrpc";
    license = lib.licenses.bsd3;
    platforms = lib.platforms.linux;
  };
})
