Set env vars modifying the paths:

OPENSSL_ENGINES=/nix/store/i7yzlkqzjlnpfskc4l3c8br6312645wy-libp11-0.4.16/lib/engines
OPENSSL_CONF=openssl-engine.cnf
OPENSSL_EXTRA_CONF=/nix/store/kwx23225xz7chh5n7pm2l6aigjzy0k79-source/secboot/conf

run generate_esl_auth.sh
